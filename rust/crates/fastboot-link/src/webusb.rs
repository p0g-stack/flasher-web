//! Browser fastboot policy over nusb's WebUSB backend. Discovery never opens a
//! chooser; the page grants access, then its worker reopens the exact serial.
//! Select from nusb's complete configuration descriptors only after open.

use std::cell::RefCell;
use std::collections::HashSet;
use std::future::Future;
use std::rc::Rc;
use std::time::Duration;

use wasm_bindgen::closure::Closure;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use wasm_bindgen_futures::JsFuture;
use nusb::descriptors::TransferType;
use nusb::transfer::{Buffer, Bulk, Direction, In, Out, TransferError};
use nusb::{Device, Endpoint, Interface};

use crate::error::{LinkError, TransportError};
use crate::session::{BulkTransport, Session};
use crate::{timeout, LinkDevice, Opened};

const FASTBOOT_CLASS: u8 = 0xff;
const FASTBOOT_SUBCLASS: u8 = 0x42;
const FASTBOOT_PROTOCOL: u8 = 0x03;
/// A fastboot response is one short transfer. This is large enough for the
/// 64-byte protocol limit and for a USB 3 bulk packet.
const RESPONSE_MAX: usize = 1024;
/// Backup bound inside one WebUSB transfer. Session owns the real operation
/// timeout (15 s for probes, 180 s for destructive commands), which is smaller;
/// this only stops a stuck transfer from outliving every caller.
const TRANSPORT_IO_TIMEOUT: Duration = Duration::from_secs(600);


struct Selection {
    config_value: u8,
    interface: u8,
    alternate: u8,
    out: Option<(u8, usize)>,
    input: Option<(u8, usize)>,
}

thread_local! {
    /// In-one-worker guard. Web Locks covers other tabs/workers; this refuses a
    /// second simultaneous open even where the Locks API is unavailable (a
    /// synthetic test page, for instance).
    static OPEN_KEYS: RefCell<HashSet<String>> = RefCell::new(HashSet::new());
}

struct WebGuard {
    key: String,
}

impl WebGuard {
    fn acquire(key: String) -> Result<Self, LinkError> {
        let busy = OPEN_KEYS.with(|open| !open.borrow_mut().insert(key.clone()));
        if busy {
            return Err(open_error(
                "Busy",
                format!("{key} is already open in this worker"),
            ));
        }
        Ok(Self { key })
    }
}

impl Drop for WebGuard {
    fn drop(&mut self) {
        OPEN_KEYS.with(|open| {
            open.borrow_mut().remove(&self.key);
        });
    }
}

/// The page-wide Web Lock held for the lifetime of one session. The lock
/// callback returns a promise that stays pending until `release`; a second tab
/// asking with `ifAvailable` receives null and is refused.
struct BrowserLock {
    hold: Option<js_sys::Function>,
    request: Option<js_sys::Promise>,
    callback: Option<Closure<dyn FnMut(JsValue) -> JsValue>>,
}

impl BrowserLock {
    fn none() -> Self {
        Self {
            hold: None,
            request: None,
            callback: None,
        }
    }

    async fn release(&mut self) -> Result<(), TransportError> {
        if let Some(resolve) = self.hold.take() {
            let _ = resolve.call0(&JsValue::NULL);
        }
        if let Some(request) = self.request.take() {
            match timeout(Duration::from_secs(2), JsFuture::from(request)).await {
                Some(Ok(_)) => {}
                Some(Err(error)) => {
                    self.forget_callback();
                    return Err(js_error(&error, true));
                }
                None => {
                    self.forget_callback();
                    return Err(browser_timeout("close", true));
                }
            }
        }
        self.forget_callback();
        Ok(())
    }

    fn forget_callback(&mut self) {
        if let Some(callback) = self.callback.take() {
            callback.forget();
        }
    }
}

impl Drop for BrowserLock {
    fn drop(&mut self) {
        if let Some(resolve) = self.hold.take() {
            let _ = resolve.call0(&JsValue::NULL);
        }
        // The lock request may still hold the JS function.
        self.forget_callback();
    }
}

fn navigator() -> Option<JsValue> {
    let global = js_sys::global();
    if let Ok(window) = global.clone().dyn_into::<web_sys::Window>() {
        return Some(JsValue::from(&window.navigator()));
    }
    if let Ok(scope) = global.dyn_into::<web_sys::WorkerGlobalScope>() {
        return Some(JsValue::from(&scope.navigator()));
    }
    None
}

/// Acquire the cross-tab lock when the browser exposes Web Locks. Browsers that
/// do not still get the in-worker guard; the USB claim remains the last line of
/// defence.
async fn acquire_browser_lock(
    key: &str,
    limit: Duration,
) -> Result<BrowserLock, TransportError> {
    let Some(navigator) = navigator() else {
        return Ok(BrowserLock::none());
    };
    let locks = match js_sys::Reflect::get(&navigator, &JsValue::from_str("locks")) {
        Ok(value) if !value.is_null() && !value.is_undefined() => value,
        _ => return Ok(BrowserLock::none()),
    };
    let request_fn = match js_sys::Reflect::get(&locks, &JsValue::from_str("request")) {
        Ok(value) => value,
        _ => return Ok(BrowserLock::none()),
    };
    let Some(request_fn) = request_fn.dyn_into::<js_sys::Function>().ok() else {
        return Ok(BrowserLock::none());
    };
    let hold_resolve: Rc<RefCell<Option<js_sys::Function>>> = Rc::new(RefCell::new(None));
    let hold = js_sys::Promise::new(&mut |resolve, _reject| {
        *hold_resolve.borrow_mut() = Some(resolve);
    });
    let acquired_resolve: Rc<RefCell<Option<js_sys::Function>>> = Rc::new(RefCell::new(None));
    let acquired = js_sys::Promise::new(&mut |resolve, _reject| {
        *acquired_resolve.borrow_mut() = Some(resolve);
    });
    let callback = {
        let acquired_resolve = acquired_resolve.clone();
        let hold_resolve = hold_resolve.clone();
        let hold = hold.clone();
        Closure::<dyn FnMut(JsValue) -> JsValue>::new(move |lock: JsValue| {
            let granted = !lock.is_null() && !lock.is_undefined();
            if let Some(resolve) = acquired_resolve.borrow().as_ref() {
                let _ = resolve.call1(&JsValue::NULL, &JsValue::from_bool(granted));
            }
            if !granted {
                // `ifAvailable` with a held lock: resolve the request now
                // instead of leaving a pending callback behind.
                if let Some(resolve) = hold_resolve.borrow().as_ref() {
                    let _ = resolve.call0(&JsValue::NULL);
                }
            }
            JsValue::from(&hold)
        })
    };
    let options = js_sys::Object::new();
    let _ = js_sys::Reflect::set(&options, &JsValue::from_str("ifAvailable"), &JsValue::TRUE);
    let args = js_sys::Array::new();
    args.push(&JsValue::from_str(&format!("flasher-web-fastboot:{key}")));
    args.push(&options);
    args.push(callback.as_ref());
    let request = match request_fn.apply(&locks, &args) {
        Ok(value) => match value.dyn_into::<js_sys::Promise>() {
            Ok(promise) => promise,
            Err(_) => {
                callback.forget();
                return Err(TransportError::new(
                    "browser",
                    "LocksUnavailable",
                    "navigator.locks.request did not return a promise".to_string(),
                    false,
                ));
            }
        },
        Err(error) => {
            callback.forget();
            return Err(js_error(&error, false));
        }
    };
    let granted = match timeout(limit, JsFuture::from(acquired)).await {
        Some(Ok(value)) => value.as_bool().unwrap_or(false),
        Some(Err(error)) => {
            if let Some(resolve) = hold_resolve.borrow().as_ref() {
                let _ = resolve.call0(&JsValue::NULL);
            }
            callback.forget();
            return Err(js_error(&error, false));
        }
        None => {
            if let Some(resolve) = hold_resolve.borrow().as_ref() {
                let _ = resolve.call0(&JsValue::NULL);
            }
            callback.forget();
            return Err(browser_timeout("open", false));
        }
    };
    if !granted {
        callback.forget();
        return Err(TransportError::new(
            "browser",
            "Busy",
            format!("another page or worker holds fastboot:{key}"),
            false,
        ));
    }
    let hold = hold_resolve.borrow_mut().take();
    Ok(BrowserLock {
        hold,
        request: Some(request),
        callback: Some(callback),
    })
}

struct Claimed {
    device: Device,
    interface: Interface,
    out: Endpoint<Bulk, Out>,
    input: Endpoint<Bulk, In>,
}

pub struct WebUsbTransport {
    // Dropped before the locks, so nusb starts releasing the interface/device
    // before another session can acquire our application-level exclusivity.
    claimed: Option<Claimed>,
    local: Option<WebGuard>,
    lock: Option<BrowserLock>,
}

/// Keep the browser's own name/message/stack; do not re-describe a DOMException.
fn js_error(value: &JsValue, uncertain: bool) -> TransportError {
    let field = |name: &str| {
        js_sys::Reflect::get(value, &JsValue::from_str(name))
            .ok()
            .and_then(|value| value.as_string())
            .filter(|value| !value.is_empty())
    };
    let name = field("name").unwrap_or_else(|| "WebUsbError".to_string());
    let message = field("message")
        .or_else(|| value.as_string())
        .unwrap_or_else(|| format!("{value:?}"));
    TransportError {
        blame: "browser".to_string(),
        name,
        message,
        stack: field("stack").unwrap_or_default(),
        causes: Vec::new(),
        uncertain,
    }
}

fn browser_timeout(stage: &'static str, uncertain: bool) -> TransportError {
    let mut error = TransportError::timeout("browser", stage);
    error.uncertain = uncertain;
    error
}

fn evidence(detail: &nusb::WebUsbError, uncertain: bool) -> TransportError {
    TransportError {
        blame: "browser".into(),
        name: detail.name.clone(),
        message: detail.message.clone(),
        stack: detail.stack.clone(),
        causes: Vec::new(),
        uncertain,
    }
}

fn usb_error(error: &nusb::Error, uncertain: bool) -> TransportError {
    error.webusb_error().map(|detail| evidence(detail, uncertain))
        .unwrap_or_else(|| TransportError::native("browser", error, uncertain))
}

fn transfer_error(error: TransferError, detail: Option<nusb::WebUsbError>) -> TransportError {
    detail.as_ref().map(|detail| evidence(detail, true))
        .unwrap_or_else(|| TransportError::native("browser", &error, true))
}

async fn bounded<T>(
    future: impl Future<Output = Result<T, nusb::Error>>,
    stage: &'static str,
    limit: Duration,
    uncertain: bool,
) -> Result<T, TransportError> {
    match timeout(limit, future).await {
        Some(Ok(value)) => Ok(value),
        Some(Err(error)) => Err(usb_error(&error, uncertain)),
        None => Err(browser_timeout(stage, uncertain)),
    }
}

fn selection(device: &Device) -> Option<Selection> {
    let active = device.active_configuration().ok().map(|config| config.configuration_value());
    let mut fallback = None;
    for config in device.configurations() {
        for interface in config.interface_alt_settings() {
            if (interface.class(), interface.subclass(), interface.protocol())
                != (FASTBOOT_CLASS, FASTBOOT_SUBCLASS, FASTBOOT_PROTOCOL) {
                continue;
            }
            let mut found = Selection {
                config_value: config.configuration_value(),
                interface: interface.interface_number(),
                alternate: interface.alternate_setting(),
                out: None,
                input: None,
            };
            for endpoint in interface.endpoints() {
                if endpoint.transfer_type() != TransferType::Bulk { continue; }
                let endpoint_info = (endpoint.address(), endpoint.max_packet_size());
                match endpoint.direction() {
                    Direction::Out if found.out.is_none() => found.out = Some(endpoint_info),
                    Direction::In if found.input.is_none() => found.input = Some(endpoint_info),
                    _ => {}
                }
            }
            if active == Some(found.config_value) { return Some(found); }
            if fallback.is_none() { fallback = Some(found); }
        }
    }
    fallback
}

fn link_device(info: &nusb::DeviceInfo, interface: u8) -> LinkDevice {
    let serial = info.serial_number().unwrap_or("").to_string();
    let label = info.product_string().filter(|value| !value.is_empty())
        .map(ToString::to_string).unwrap_or_else(|| {
            if serial.is_empty() { format!("USB {:04x}:{:04x}", info.vendor_id(), info.product_id()) }
            else { serial.clone() }
        });
    LinkDevice {
        serial, label, transport: "webusb".into(),
        vendor_id: info.vendor_id(), product_id: info.product_id(), interface,
    }
}

fn open_error(name: &str, message: impl Into<String>) -> LinkError {
    LinkError::from_transport("open", TransportError::new("browser", name, message.into(), false))
}

async fn close_device(device: &Device) -> Result<(), TransportError> {
    match bounded(async { device.force_close().await }, "close", Duration::from_secs(2), true).await {
        // A rebooted device has already released its interface.
        Err(error) if error.name == "NotFoundError" => Ok(()),
        result => result,
    }
}

async fn failed_open(device: &Device, mut error: LinkError) -> LinkError {
    if let Err(cleanup) = close_device(device).await {
        error.cleanup_errors.push(format!("browser close: {}: {}", cleanup.name, cleanup.message));
    }
    error
}

pub async fn devices(limit: Duration) -> Result<Vec<LinkDevice>, LinkError> {
    let granted = bounded(async { nusb::list_devices().await }, "devices", limit, false)
        .await.map_err(|error| LinkError::from_transport("devices", error))?;
    let mut devices = Vec::new();
    for info in granted {
        // DeviceInfo::interfaces may be empty before open on WebUSB. Do not
        // mistake that for absence of a fastboot interface.
        let device = bounded(async { info.open().await }, "devices", limit, false)
            .await.map_err(|error| LinkError::from_transport("devices", error))?;
        if let Some(selection) = selection(&device) {
            devices.push(link_device(&info, selection.interface));
        }
        // nusb's shared lease closes only its last handle; discovery must not
        // force-close another independently opened session.
    }
    Ok(devices)
}

pub async fn open(serial: &str, open_limit: Duration, io_limit: Duration) -> Result<Opened, LinkError> {
    let granted = bounded(async { nusb::list_devices().await }, "open", open_limit, false)
        .await.map_err(|error| LinkError::from_transport("open", error))?;
    let matches: Vec<_> = granted.filter(|info| info.serial_number() == Some(serial)).collect();
    let info = match matches.as_slice() {
        [one] => one,
        [] => return Err(open_error("NoDevice", format!("no granted WebUSB device with serial {serial}"))),
        _ => return Err(open_error("Ambiguous", format!("{serial} names {} granted WebUSB devices", matches.len()))),
    };
    let device = bounded(async { info.open().await }, "open", open_limit, false)
        .await.map_err(|error| LinkError::from_transport("open", error))?;
    let selected = selection(&device).ok_or_else(|| open_error("MissingInterface", format!("{serial} has no ff/42/03 interface")))?;
    let key = format!("{serial}:{}", selected.interface);
    let local = WebGuard::acquire(key.clone())?;
    let lock = acquire_browser_lock(&key, open_limit).await
        .map_err(|error| LinkError::from_transport("open", error))?;
    let claimed = async {
        if device.active_configuration().ok().map(|config| config.configuration_value()) != Some(selected.config_value) {
            bounded(async { device.set_configuration(selected.config_value).await }, "open", open_limit, false).await?;
        }
        let interface = bounded(async { device.claim_interface(selected.interface).await }, "open", open_limit, false).await?;
        // Like AOSP fastboot and fastboot.js, only claim: never send
        // SET_INTERFACE for alternate 0. Some bootloaders reset their endpoint
        // data toggles on it and then drop the host's next packet, so every
        // command times out until the phone re-enumerates.
        if selected.alternate != 0 {
            bounded(async { interface.set_alt_setting(selected.alternate).await }, "open", open_limit, false).await?;
        }
        let (Some(out), Some(input)) = (selected.out, selected.input) else {
            return Err(TransportError::new("browser", "MissingEndpoints",
                format!("{serial} lacks a bulk OUT/IN pair on interface {}", selected.interface), false));
        };
        let out = interface.endpoint::<Bulk, Out>(out.0).map_err(|error| usb_error(&error, false))?;
        let input = interface.endpoint::<Bulk, In>(input.0).map_err(|error| usb_error(&error, false))?;
        Ok((interface, out, input))
    }.await;
    let (interface, out, input) = match claimed {
        Ok(claimed) => claimed,
        Err(error) => return Err(failed_open(&device, LinkError::from_transport("open", error)).await),
    };
    let response_max = RESPONSE_MAX.max(input.max_packet_size());
    let transport = WebUsbTransport {
        claimed: Some(Claimed { device, interface, out, input }),
        local: Some(local), lock: Some(lock),
    };
    Ok(Opened {
        session: Session::new(transport, serial.to_string(), response_max, io_limit),
        device: link_device(info, selected.interface),
    })
}

impl BulkTransport for WebUsbTransport {
    fn blame(&self) -> &'static str { "browser" }

    async fn write_all(&mut self, data: Vec<u8>) -> Result<(), TransportError> {
        let expected = data.len();
        let endpoint = &mut self.claimed.as_mut().expect("closed transport").out;
        endpoint.submit(Buffer::from(data));
        let completion = timeout(TRANSPORT_IO_TIMEOUT, endpoint.next_complete()).await
            .ok_or_else(|| browser_timeout("write", true))?;
        if let Err(error) = completion.status {
            return Err(transfer_error(error, endpoint.take_webusb_error()));
        }
        if completion.actual_len != expected {
            return Err(TransportError::new("browser", "ShortWrite",
                format!("wrote {} of {expected} bytes", completion.actual_len), true));
        }
        Ok(())
    }

    async fn read(&mut self, max: usize) -> Result<Vec<u8>, TransportError> {
        let endpoint = &mut self.claimed.as_mut().expect("closed transport").input;
        endpoint.submit(Buffer::new(max));
        let completion = timeout(TRANSPORT_IO_TIMEOUT, endpoint.next_complete()).await
            .ok_or_else(|| browser_timeout("read", true))?;
        if let Err(error) = completion.status {
            return Err(transfer_error(error, endpoint.take_webusb_error()));
        }
        let mut data = completion.buffer.into_vec();
        data.truncate(completion.actual_len.min(max));
        Ok(data)
    }

    async fn close(&mut self) -> Result<(), TransportError> {
        let mut failure = None;
        if let Some(Claimed { device, interface, out, input }) = self.claimed.take() {
            drop((out, input));
            if let Err(error) = bounded(async { interface.release().await }, "close", Duration::from_secs(2), true).await {
                if error.name != "NotFoundError" { failure = Some(error); }
            }
            if let Err(error) = close_device(&device).await {
                append_cleanup(&mut failure, error);
            }
        }
        if let Some(mut lock) = self.lock.take() {
            if let Err(error) = lock.release().await { append_cleanup(&mut failure, error); }
        }
        self.local.take();
        failure.map_or(Ok(()), Err)
    }
}

fn append_cleanup(failure: &mut Option<TransportError>, error: TransportError) {
    if let Some(failure) = failure {
        failure.causes.push(format!("cleanup: {}: {}", error.name, error.message));
    } else { *failure = Some(error); }
}
