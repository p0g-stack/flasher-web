//! Native USB via nusb. Discovery matches the ff/42/03 interface from the
//! descriptors; opening pins the exact serial and claims only that device.

use std::collections::HashSet;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use nusb::descriptors::TransferType;
use nusb::transfer::{Buffer, Bulk, Direction, In, Out};
use nusb::{Device, Endpoint, Interface};

use crate::error::{LinkError, TransportError};
use crate::session::{BulkTransport, Session};
use crate::{timeout, LinkDevice, Opened};

const FASTBOOT_CLASS: u8 = 0xff;
const FASTBOOT_SUBCLASS: u8 = 0x42;
const FASTBOOT_PROTOCOL: u8 = 0x03;

static OPEN_SERIALS: LazyLock<Mutex<HashSet<String>>> =
    LazyLock::new(|| Mutex::new(HashSet::new()));

/// One live session per serial/interface in this process. nusb also refuses a
/// second claim at the OS level; this gives the caller a clear Busy instead of a
/// backend-specific claim error, and it is released even if the session is
/// dropped without `close`.
struct SessionGuard {
    key: String,
}

impl SessionGuard {
    fn acquire(key: String) -> Result<Self, LinkError> {
        let mut open = OPEN_SERIALS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !open.insert(key.clone()) {
            return Err(LinkError::from_transport(
                "open",
                TransportError::new(
                    "usb",
                    "Busy",
                    format!("{key} is already open by this process"),
                    false,
                ),
            ));
        }
        Ok(Self { key })
    }
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        OPEN_SERIALS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&self.key);
    }
}

pub struct NativeTransport {
    // Held so the claimed interface and its endpoints stay valid.
    _device: Device,
    _interface: Interface,
    ep_out: Endpoint<Bulk, Out>,
    ep_in: Endpoint<Bulk, In>,
    _guard: SessionGuard,
}

fn fastboot_interface(info: &nusb::DeviceInfo) -> Option<u8> {
    info.interfaces().find_map(|interface| {
        if interface.class() == FASTBOOT_CLASS
            && interface.subclass() == FASTBOOT_SUBCLASS
            && interface.protocol() == FASTBOOT_PROTOCOL
        {
            Some(interface.interface_number())
        } else {
            None
        }
    })
}

fn link_device(info: &nusb::DeviceInfo, interface: u8) -> LinkDevice {
    let serial = info.serial_number().unwrap_or("").to_string();
    let label = info
        .product_string()
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| {
            if serial.is_empty() {
                format!("USB {:04x}:{:04x}", info.vendor_id(), info.product_id())
            } else {
                serial.clone()
            }
        });
    LinkDevice {
        serial,
        label,
        transport: "native".to_string(),
        vendor_id: info.vendor_id(),
        product_id: info.product_id(),
        interface,
    }
}

fn usb_error(stage: &'static str, error: &dyn std::error::Error, uncertain: bool) -> LinkError {
    LinkError::from_transport(stage, TransportError::native("usb", error, uncertain))
}

fn usb_timeout(stage: &'static str, uncertain: bool) -> LinkError {
    let mut error = TransportError::timeout("usb", stage);
    error.uncertain = uncertain;
    LinkError::from_transport(stage, error)
}

pub async fn devices(limit: Duration) -> Result<Vec<LinkDevice>, LinkError> {
    let list = match timeout(limit, async { nusb::list_devices().await }).await {
        Some(Ok(list)) => list,
        Some(Err(error)) => return Err(usb_error("devices", &error, false)),
        None => return Err(usb_timeout("devices", false)),
    };
    Ok(list
        .filter_map(|info| {
            let interface = fastboot_interface(&info)?;
            Some(link_device(&info, interface))
        })
        .collect())
}

pub async fn open(
    serial: &str,
    open_limit: Duration,
    io_limit: Duration,
) -> Result<Opened, LinkError> {
    let list = match timeout(open_limit, async { nusb::list_devices().await }).await {
        Some(Ok(list)) => list,
        Some(Err(error)) => return Err(usb_error("open", &error, false)),
        None => return Err(usb_timeout("open", false)),
    };
    let matches: Vec<_> = list
        .filter(|info| info.serial_number() == Some(serial))
        .collect();
    let info = match matches.as_slice() {
        [one] => one,
        [] => {
            return Err(LinkError::from_transport(
                "open",
                TransportError::new("usb", "NoDevice", format!("no USB device with serial {serial}"), false),
            ))
        }
        _ => {
            return Err(LinkError::from_transport(
                "open",
                TransportError::new(
                    "usb",
                    "Ambiguous",
                    format!("{serial} names {} USB devices", matches.len()),
                    false,
                ),
            ))
        }
    };
    let Some(interface_number) = fastboot_interface(info) else {
        return Err(LinkError::from_transport(
            "open",
            TransportError::new(
                "usb",
                "MissingInterface",
                format!("{serial} has no ff/42/03 interface"),
                false,
            ),
        ));
    };
    let guard = SessionGuard::acquire(format!("{serial}:{interface_number}"))?;
    let device = match timeout(open_limit, async { info.open().await }).await {
        Some(Ok(device)) => device,
        Some(Err(error)) => return Err(usb_error("open", &error, false)),
        None => return Err(usb_timeout("open", false)),
    };
    let interface = match timeout(open_limit, async {
        device.claim_interface(interface_number).await
    })
    .await
    {
        Some(Ok(interface)) => interface,
        Some(Err(error)) => return Err(usb_error("open", &error, false)),
        None => return Err(usb_timeout("open", false)),
    };
    let Some(descriptor) = interface.descriptor() else {
        return Err(LinkError::from_transport(
            "open",
            TransportError::new(
                "usb",
                "MissingInterface",
                format!("{serial} has no active description for interface {interface_number}"),
                false,
            ),
        ));
    };
    let mut out = None;
    let mut input = None;
    for endpoint in descriptor.endpoints() {
        if endpoint.transfer_type() != TransferType::Bulk {
            continue;
        }
        match endpoint.direction() {
            Direction::Out if out.is_none() => out = Some((endpoint.address(), endpoint.max_packet_size())),
            Direction::In if input.is_none() => input = Some((endpoint.address(), endpoint.max_packet_size())),
            _ => {}
        }
    }
    let (out_address, _max_out) = out.ok_or_else(|| {
        LinkError::from_transport(
            "open",
            TransportError::new("usb", "MissingEndpoints", format!("{serial} has no bulk OUT endpoint"), false),
        )
    })?;
    let (in_address, max_in) = input.ok_or_else(|| {
        LinkError::from_transport(
            "open",
            TransportError::new("usb", "MissingEndpoints", format!("{serial} has no bulk IN endpoint"), false),
        )
    })?;
    let ep_out = match interface.endpoint::<Bulk, Out>(out_address) {
        Ok(endpoint) => endpoint,
        Err(error) => return Err(usb_error("open", &error, false)),
    };
    let ep_in = match interface.endpoint::<Bulk, In>(in_address) {
        Ok(endpoint) => endpoint,
        Err(error) => return Err(usb_error("open", &error, false)),
    };
    let device_info = link_device(info, interface_number);
    let transport = NativeTransport {
        _device: device,
        _interface: interface,
        ep_out,
        ep_in,
        _guard: guard,
    };
    let session = Session::new(transport, serial.to_string(), max_in, io_limit);
    Ok(Opened {
        session,
        device: device_info,
    })
}

impl BulkTransport for NativeTransport {
    fn blame(&self) -> &'static str {
        "usb"
    }

    async fn write_all(&mut self, data: Vec<u8>) -> Result<(), TransportError> {
        let expected = data.len();
        // The Vec moves into nusb's default-allocator Buffer, so the chunk is
        // not copied again before the transfer.
        self.ep_out.submit(Buffer::from(data));
        let completion = self.ep_out.next_complete().await;
        if let Err(error) = completion.status {
            return Err(TransportError::native("usb", &error, true));
        }
        if completion.actual_len != expected {
            return Err(TransportError::new(
                "usb",
                "ShortWrite",
                format!("wrote {} of {expected} bytes", completion.actual_len),
                true,
            ));
        }
        Ok(())
    }

    async fn read(&mut self, max: usize) -> Result<Vec<u8>, TransportError> {
        self.ep_in.submit(Buffer::new(max));
        let completion = self.ep_in.next_complete().await;
        if let Err(error) = completion.status {
            return Err(TransportError::native("usb", &error, true));
        }
        let bytes = completion.actual_len.min(max);
        let mut data = completion.buffer.into_vec();
        data.truncate(bytes);
        Ok(data)
    }

    async fn close(&mut self) -> Result<(), TransportError> {
        // Dropping the device releases the claimed interface on every backend.
        Ok(())
    }
}
