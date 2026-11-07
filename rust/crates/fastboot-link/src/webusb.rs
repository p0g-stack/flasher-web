//! Browser WebUSB. Discovery never opens a chooser: it reports only the
//! devices the page already holds a grant for. Descriptors are inspected
//! before `open()` so the right configuration/interface is selected first.

use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;
use std::time::Duration;

use wasm_bindgen::closure::Closure;
use wasm_bindgen::convert::FromWasmAbi;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use wasm_bindgen_futures::JsFuture;
use web_sys::{
    Usb, UsbAlternateInterface, UsbConfiguration, UsbDevice, UsbDirection, UsbEndpointType,
    UsbInterface, UsbTransferStatus,
};

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

struct Endpoint {
    number: u8,
    packet: u32,
}

struct Selection {
    config_value: u8,
    interface: u8,
    alternate: u8,
    out: Option<Endpoint>,
    input: Option<Endpoint>,
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

pub struct WebUsbTransport {
    device: UsbDevice,
    endpoint_out: u8,
    endpoint_in: u8,
    _local: WebGuard,
    lock: Option<BrowserLock>,
    closed: bool,
}

fn usb() -> Result<Usb, TransportError> {
    let global = js_sys::global();
    if let Ok(window) = global.clone().dyn_into::<web_sys::Window>() {
        return Ok(window.navigator().usb());
    }
    if let Ok(scope) = global.dyn_into::<web_sys::WorkerGlobalScope>() {
        return Ok(scope.navigator().usb());
    }
    Err(TransportError::new(
        "browser",
        "Unreachable",
        "no Window or WorkerGlobalScope here".to_string(),
        false,
    ))
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

async fn await_promise<T: FromWasmAbi + 'static>(
    promise: js_sys::Promise<T>,
    stage: &'static str,
    limit: Duration,
    uncertain: bool,
) -> Result<T, TransportError> {
    match timeout(limit, JsFuture::from(promise)).await {
        Some(Ok(value)) => Ok(value),
        Some(Err(error)) => Err(js_error(&error, uncertain)),
        None => Err(browser_timeout(stage, uncertain)),
    }
}

fn bulk_endpoints(alternate: &UsbAlternateInterface) -> (Option<Endpoint>, Option<Endpoint>) {
    let mut out = None;
    let mut input = None;
    for endpoint in alternate.endpoints().iter() {
        if endpoint.type_() != UsbEndpointType::Bulk {
            continue;
        }
        let found = Endpoint {
            number: endpoint.endpoint_number(),
            packet: endpoint.packet_size(),
        };
        match endpoint.direction() {
            UsbDirection::Out if out.is_none() => out = Some(found),
            UsbDirection::In if input.is_none() => input = Some(found),
            _ => {}
        }
    }
    (out, input)
}

/// The descriptors of the granted device, without opening it. Prefer the
/// active configuration when it is already the fastboot one; otherwise this is
/// the configuration the caller must select.
fn selection(device: &UsbDevice) -> Option<Selection> {
    let active = device
        .configuration()
        .map(|configuration| configuration.configuration_value());
    let mut fallback = None;
    for configuration in device.configurations().iter() {
        let configuration: UsbConfiguration = configuration;
        let config_value = configuration.configuration_value();
        for interface in configuration.interfaces().iter() {
            let interface: UsbInterface = interface;
            for alternate in interface.alternates().iter() {
                let alternate: UsbAlternateInterface = alternate;
                if alternate.interface_class() != FASTBOOT_CLASS
                    || alternate.interface_subclass() != FASTBOOT_SUBCLASS
                    || alternate.interface_protocol() != FASTBOOT_PROTOCOL
                {
                    continue;
                }
                let (out, input) = bulk_endpoints(&alternate);
                let found = Selection {
                    config_value,
                    interface: interface.interface_number(),
                    alternate: alternate.alternate_setting(),
                    out,
                    input,
                };
                if active == Some(config_value) {
                    return Some(found);
                }
                if fallback.is_none() {
                    fallback = Some(found);
                }
            }
        }
    }
    fallback
}

fn link_device(device: &UsbDevice, interface: u8) -> LinkDevice {
    let serial = device.serial_number().unwrap_or_default();
    let label = device
        .product_name()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| {
            if serial.is_empty() {
                format!("USB {:04x}:{:04x}", device.vendor_id(), device.product_id())
            } else {
                serial.clone()
            }
        });
    LinkDevice {
        serial,
        label,
        transport: "webusb".to_string(),
        vendor_id: device.vendor_id(),
        product_id: device.product_id(),
        interface,
    }
}

fn open_error(name: &str, message: impl Into<String>) -> LinkError {
    LinkError::from_transport(
        "open",
        TransportError::new("browser", name, message.into(), false),
    )
}

async fn close_device(device: &UsbDevice) -> Result<(), TransportError> {
    // A rebooted phone can leave the bus before close is called. The interface
    // is already released in that case; only real cleanup failures are worth
    // reporting.
    if !device.opened() {
        return Ok(());
    }
    match timeout(Duration::from_secs(2), JsFuture::from(device.close())).await {
        Some(Ok(_)) => Ok(()),
        Some(Err(error)) => {
            let error = js_error(&error, true);
            if error.name == "NotFoundError" {
                Ok(())
            } else {
                Err(error)
            }
        }
        None => Err(browser_timeout("close", true)),
    }
}

async fn failed_open(device: &UsbDevice, mut error: LinkError) -> LinkError {
    if let Err(cleanup) = close_device(device).await {
        error
            .cleanup_errors
            .push(format!("browser close: {}: {}", cleanup.name, cleanup.message));
    }
    error
}

pub async fn devices(limit: Duration) -> Result<Vec<LinkDevice>, LinkError> {
    let usb = usb().map_err(|error| LinkError::from_transport("devices", error))?;
    let granted = await_promise(usb.get_devices(), "devices", limit, false)
        .await
        .map_err(|error| LinkError::from_transport("devices", error))?;
    let mut devices = Vec::new();
    for device in granted.iter() {
        let Some(selection) = selection(&device) else {
            continue;
        };
        devices.push(link_device(&device, selection.interface));
    }
    Ok(devices)
}

pub async fn open(
    serial: &str,
    open_limit: Duration,
    io_limit: Duration,
) -> Result<Opened, LinkError> {
    let usb = usb().map_err(|error| LinkError::from_transport("open", error))?;
    let granted = await_promise(usb.get_devices(), "open", open_limit, false)
        .await
        .map_err(|error| LinkError::from_transport("open", error))?;
    let matches: Vec<UsbDevice> = granted
        .iter()
        .filter(|device| device.serial_number().as_deref() == Some(serial))
        .collect();
    let device = match matches.as_slice() {
        [one] => one.clone(),
        [] => {
            return Err(open_error(
                "NoDevice",
                format!("no granted WebUSB device with serial {serial}"),
            ))
        }
        _ => {
            return Err(open_error(
                "Ambiguous",
                format!("{serial} names {} granted WebUSB devices", matches.len()),
            ))
        }
    };
    let Some(selection) = selection(&device) else {
        return Err(open_error(
            "MissingInterface",
            format!("{serial} has no ff/42/03 interface"),
        ));
    };
    let key = format!("{serial}:{}", selection.interface);
    let local = WebGuard::acquire(key.clone())?;
    let lock = match acquire_browser_lock(&key, open_limit).await {
        Ok(lock) => lock,
        Err(error) => return Err(LinkError::from_transport("open", error)),
    };
    if let Err(error) = await_promise(device.open(), "open", open_limit, false).await {
        return Err(LinkError::from_transport("open", error));
    }
    let active = device
        .configuration()
        .map(|configuration| configuration.configuration_value());
    if active != Some(selection.config_value) {
        if let Err(error) = await_promise(
            device.select_configuration(selection.config_value),
            "open",
            open_limit,
            false,
        )
        .await
        {
            return Err(failed_open(&device, LinkError::from_transport("open", error)).await);
        }
    }
    if let Err(error) = await_promise(
        device.claim_interface(selection.interface),
        "open",
        open_limit,
        false,
    )
    .await
    {
        return Err(failed_open(&device, LinkError::from_transport("open", error)).await);
    }
    if selection.alternate != 0 {
        if let Err(error) = await_promise(
            device.select_alternate_interface(selection.interface, selection.alternate),
            "open",
            open_limit,
            false,
        )
        .await
        {
            return Err(failed_open(&device, LinkError::from_transport("open", error)).await);
        }
    }
    let (Some(out), Some(input)) = (selection.out, selection.input) else {
        return Err(failed_open(
            &device,
            open_error(
                "MissingEndpoints",
                format!("{serial} lacks a bulk OUT/IN pair on interface {}", selection.interface),
            ),
        )
        .await);
    };
    let device_info = link_device(&device, selection.interface);
    let transport = WebUsbTransport {
        device,
        endpoint_out: out.number,
        endpoint_in: input.number,
        _local: local,
        lock: Some(lock),
        closed: false,
    };
    let response_max = RESPONSE_MAX.max(input.packet as usize);
    let session = Session::new(transport, serial.to_string(), response_max, io_limit);
    Ok(Opened {
        session,
        device: device_info,
    })
}

impl BulkTransport for WebUsbTransport {
    fn blame(&self) -> &'static str {
        "browser"
    }

    async fn write_all(&mut self, data: Vec<u8>) -> Result<(), TransportError> {
        let array = js_sys::Uint8Array::from(&data[..]);
        let promise = match self
            .device
            .transfer_out_with_u8_array(self.endpoint_out, &array)
        {
            Ok(promise) => promise,
            Err(error) => return Err(js_error(&error, true)),
        };
        let result = await_promise(promise, "write", TRANSPORT_IO_TIMEOUT, true).await?;
        let status = result.status();
        match status {
            UsbTransferStatus::Ok => {}
            UsbTransferStatus::Stall => {
                return Err(TransportError::new(
                    "browser",
                    "TransferStall",
                    "bulk OUT endpoint stalled".to_string(),
                    true,
                ))
            }
            UsbTransferStatus::Babble => {
                return Err(TransportError::new(
                    "browser",
                    "TransferBabble",
                    "device babbled during bulk OUT".to_string(),
                    true,
                ))
            }
            _ => {
                return Err(TransportError::new(
                    "browser",
                    "TransferStatus",
                    format!("unexpected bulk OUT status {status:?}"),
                    true,
                ))
            }
        }
        if result.bytes_written() as usize != data.len() {
            return Err(TransportError::new(
                "browser",
                "ShortWrite",
                format!(
                    "wrote {} of {} bytes",
                    result.bytes_written(),
                    data.len()
                ),
                true,
            ));
        }
        Ok(())
    }

    async fn read(&mut self, max: usize) -> Result<Vec<u8>, TransportError> {
        let max = max.min(u32::MAX as usize) as u32;
        let result = await_promise(
            self.device.transfer_in(self.endpoint_in, max),
            "read",
            TRANSPORT_IO_TIMEOUT,
            true,
        )
        .await?;
        let status = result.status();
        match status {
            UsbTransferStatus::Ok => {}
            UsbTransferStatus::Stall => {
                return Err(TransportError::new(
                    "browser",
                    "TransferStall",
                    "bulk IN endpoint stalled".to_string(),
                    true,
                ))
            }
            UsbTransferStatus::Babble => {
                return Err(TransportError::new(
                    "browser",
                    "TransferBabble",
                    "device babbled during bulk IN".to_string(),
                    true,
                ))
            }
            _ => {
                return Err(TransportError::new(
                    "browser",
                    "TransferStatus",
                    format!("unexpected bulk IN status {status:?}"),
                    true,
                ))
            }
        }
        let Some(view) = result.data() else {
            return Ok(Vec::new());
        };
        let bytes = js_sys::Uint8Array::new_with_byte_offset_and_length(
            &view.buffer(),
            // This backend is wasm32-only; usize and these JS offsets fit u32.
            view.byte_offset() as u32,
            view.byte_length() as u32,
        );
        Ok(bytes.to_vec())
    }

    async fn close(&mut self) -> Result<(), TransportError> {
        if self.closed {
            return Ok(());
        }
        self.closed = true;
        let device_result = close_device(&self.device).await;
        let lock_result = match self.lock.take() {
            Some(mut lock) => lock.release().await,
            None => Ok(()),
        };
        match (device_result, lock_result) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(error), Ok(())) => Err(error),
            (Ok(()), Err(error)) => Err(error),
            (Err(mut error), Err(lock)) => {
                error
                    .causes
                    .push(format!("lock release: {}: {}", lock.name, lock.message));
                Err(error)
            }
        }
    }
}

impl Drop for WebUsbTransport {
    fn drop(&mut self) {
        if !self.closed {
            // Drop cannot await. Starting close releases the interface; the
            // pending promise is the browser's to finish.
            let _ = self.device.close();
        }
        // The lock's Drop resolves its hold promise, releasing the page lock.
    }
}
