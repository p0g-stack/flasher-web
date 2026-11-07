//! A reusable fastboot link: device discovery, exclusive serial selection, and
//! a streaming command/download session over native USB or browser WebUSB.
//!
//! This crate knows nothing about flutter_rust_bridge or Dart. The native app
//! exports it through a thin `api/` shim. The only network code is the
//! `tcp-smoke` test seam, which is off by default.

use std::future::Future;
use std::time::Duration;

use crate::error::LinkError;
use crate::session::Session;

pub mod error;
pub mod session;

#[cfg(all(feature = "tcp-smoke", not(target_arch = "wasm32")))]
pub mod tcp;

#[cfg(not(target_arch = "wasm32"))]
mod native;
#[cfg(target_arch = "wasm32")]
mod webusb;

#[cfg(not(target_arch = "wasm32"))]
pub type UsbTransport = native::NativeTransport;
#[cfg(target_arch = "wasm32")]
pub type UsbTransport = webusb::WebUsbTransport;

pub type LinkSession = Session<UsbTransport>;

/// One fastboot device, identified by its USB descriptors.
#[derive(Debug, Clone)]
pub struct LinkDevice {
    pub serial: String,
    /// A product/name from descriptors; never inferred from VID/PID.
    pub label: String,
    /// `native` or `webusb`.
    pub transport: String,
    pub vendor_id: u16,
    pub product_id: u16,
    /// The interface whose descriptor is ff/42/03.
    pub interface: u8,
}

/// A session and the descriptor identity it was opened from.
pub struct Opened {
    pub session: LinkSession,
    pub device: LinkDevice,
}

/// Open sessions live for as long as the caller keeps them.
const OPEN_TIMEOUT: Duration = Duration::from_secs(15);
const IO_TIMEOUT: Duration = Duration::from_secs(15);

/// Fastboot devices this place may use. On the web this is only the granted
/// list; opening a chooser is the page's job, not the transport's.
pub async fn devices() -> Result<Vec<LinkDevice>, LinkError> {
    #[cfg(not(target_arch = "wasm32"))]
    {
        native::devices(OPEN_TIMEOUT).await
    }
    #[cfg(target_arch = "wasm32")]
    {
        webusb::devices(OPEN_TIMEOUT).await
    }
}

/// Open the one fastboot device whose serial is exactly `serial`.
pub async fn open(serial: &str) -> Result<Opened, LinkError> {
    if serial.is_empty() {
        return Err(LinkError::user(
            "open",
            "EmptySerial",
            "refusing an empty serial",
        ));
    }
    let opened = {
        #[cfg(not(target_arch = "wasm32"))]
        {
            native::open(serial, OPEN_TIMEOUT, IO_TIMEOUT).await?
        }
        #[cfg(target_arch = "wasm32")]
        {
            webusb::open(serial, OPEN_TIMEOUT, IO_TIMEOUT).await?
        }
    };
    if opened.session.serial() != serial {
        return Err(LinkError::protocol(
            "open",
            "serial changed between matching and opening",
        ));
    }
    Ok(opened)
}

#[cfg(not(target_arch = "wasm32"))]
pub(crate) async fn timeout<F: Future>(limit: Duration, future: F) -> Option<F::Output> {
    tokio::time::timeout(limit, future).await.ok()
}

#[cfg(target_arch = "wasm32")]
pub(crate) async fn timeout<F: Future>(limit: Duration, future: F) -> Option<F::Output> {
    futures_lite::future::race(
        async { Some(future.await) },
        async {
            futures_timer::Delay::new(limit).await;
            None
        },
    )
    .await
}
