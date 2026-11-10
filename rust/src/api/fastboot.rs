//! Thin frb surface for the reusable `fastboot-link` crate. All USB and
//! protocol work lives there; this file only owns handle lifetime and converts
//! typed failures for Dart. It never parses an error message.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use fastboot_link::error::LinkError;
use fastboot_link::LinkSession;
use futures::lock::Mutex;

#[cfg(not(target_arch = "wasm32"))]
use std::sync::{LazyLock, Mutex as RegistryMutex};

#[cfg(target_arch = "wasm32")]
use std::cell::RefCell;

/// A live session. The mutex rejects overlapping operations by serializing
/// them; the handle is removed as soon as the session is retired.
struct Entry {
    session: Mutex<LinkSession>,
}

#[cfg(not(target_arch = "wasm32"))]
static REGISTRY: LazyLock<RegistryMutex<HashMap<u32, Arc<Entry>>>> =
    LazyLock::new(|| RegistryMutex::new(HashMap::new()));

#[cfg(target_arch = "wasm32")]
thread_local! {
    static REGISTRY: RefCell<HashMap<u32, Arc<Entry>>> = RefCell::new(HashMap::new());
}

static NEXT_HANDLE: AtomicU32 = AtomicU32::new(1);

#[cfg(not(target_arch = "wasm32"))]
fn registry_insert(entry: Arc<Entry>) -> u32 {
    let mut registry = REGISTRY
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    loop {
        let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        if handle != 0 && !registry.contains_key(&handle) {
            registry.insert(handle, entry);
            return handle;
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn registry_insert(entry: Arc<Entry>) -> u32 {
    REGISTRY.with(|registry| {
        let mut registry = registry.borrow_mut();
        loop {
            let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
            if handle != 0 && !registry.contains_key(&handle) {
                registry.insert(handle, entry);
                return handle;
            }
        }
    })
}

#[cfg(not(target_arch = "wasm32"))]
fn registry_get(handle: u32) -> Option<Arc<Entry>> {
    REGISTRY
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&handle)
        .cloned()
}

#[cfg(target_arch = "wasm32")]
fn registry_get(handle: u32) -> Option<Arc<Entry>> {
    REGISTRY.with(|registry| registry.borrow().get(&handle).cloned())
}

#[cfg(not(target_arch = "wasm32"))]
fn registry_remove(handle: u32) -> Option<Arc<Entry>> {
    REGISTRY
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(&handle)
}

#[cfg(target_arch = "wasm32")]
fn registry_remove(handle: u32) -> Option<Arc<Entry>> {
    REGISTRY.with(|registry| registry.borrow_mut().remove(&handle))
}

#[derive(Debug, Clone, Default)]
pub struct FastbootMessage {
    /// `INFO` or `TEXT`; the two are not flattened.
    pub kind: String,
    pub text: String,
}

/// Typed original evidence plus classification. Dart maps this to its own
/// `LinkFailure` without splitting a formatted string.
#[derive(Debug, Clone, Default)]
pub struct FastbootFailure {
    pub blame: String,
    pub source: String,
    /// True when the handle is no longer usable, independent of blame.
    pub session_retired: bool,
    pub name: String,
    pub message: String,
    pub stage: String,
    pub uncertain: bool,
    pub disconnect_observed: bool,
    pub stack: String,
    pub causes: Vec<String>,
    pub cleanup_errors: Vec<String>,
    /// INFO/TEXT evidence preceding a failure.
    pub messages: Vec<FastbootMessage>,
}

impl From<LinkError> for FastbootFailure {
    fn from(error: LinkError) -> Self {
        let session_retired = error.session_retired();
        Self {
            blame: error.blame.as_str().to_string(),
            source: error.source,
            session_retired,
            name: error.name,
            message: error.message,
            stage: error.stage.to_string(),
            uncertain: error.uncertain,
            disconnect_observed: error.disconnect_observed,
            stack: error.stack,
            causes: error.causes,
            cleanup_errors: error.cleanup_errors,
            messages: error
                .messages
                .into_iter()
                .map(|message| FastbootMessage {
                    kind: message.kind,
                    text: message.text,
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct FastbootDeviceInfo {
    pub serial: String,
    pub label: String,
    pub transport: String,
    pub vendor_id: u16,
    pub product_id: u16,
    pub interface_number: u8,
}

#[derive(Debug, Clone)]
pub struct FastbootDiscoveryFailure {
    pub serial: String,
    pub label: String,
    pub failure: FastbootFailure,
}

#[derive(Debug, Clone, Default)]
pub struct FastbootDeviceList {
    pub devices: Vec<FastbootDeviceInfo>,
    pub discovery_failures: Vec<FastbootDiscoveryFailure>,
    pub failure: Option<FastbootFailure>,
}

#[derive(Debug, Clone, Default)]
pub struct FastbootOpenReply {
    /// Zero when `failure` is set.
    pub handle: u32,
    pub serial: String,
    pub transport: String,
    pub failure: Option<FastbootFailure>,
}

#[derive(Debug, Clone, Default)]
pub struct FastbootCommandReply {
    pub value: String,
    pub messages: Vec<FastbootMessage>,
    pub failure: Option<FastbootFailure>,
}

#[derive(Debug, Clone, Default)]
pub struct FastbootVoidReply {
    pub messages: Vec<FastbootMessage>,
    pub failure: Option<FastbootFailure>,
}

pub async fn fastboot_devices() -> FastbootDeviceList {
    match fastboot_link::devices().await {
        Ok(discovery) => FastbootDeviceList {
            devices: discovery.devices
                .into_iter()
                .map(|device| FastbootDeviceInfo {
                    serial: device.serial,
                    label: device.label,
                    transport: device.transport,
                    vendor_id: device.vendor_id,
                    product_id: device.product_id,
                    interface_number: device.interface,
                })
                .collect(),
            failure: None,
            discovery_failures: discovery.failures.into_iter().map(|item| FastbootDiscoveryFailure {
                serial: item.serial,
                label: item.label,
                failure: item.error.into(),
            }).collect(),
        },
        Err(error) => FastbootDeviceList {
            devices: Vec::new(),
            discovery_failures: Vec::new(),
            failure: Some(error.into()),
        },
    }
}

pub async fn fastboot_open(serial: String) -> FastbootOpenReply {
    match fastboot_link::open(&serial).await {
        Ok(opened) => {
            let handle = registry_insert(Arc::new(Entry {
                session: Mutex::new(opened.session),
            }));
            FastbootOpenReply {
                handle,
                serial: opened.device.serial,
                transport: opened.device.transport,
                failure: None,
            }
        }
        Err(error) => FastbootOpenReply {
            handle: 0,
            serial,
            transport: String::new(),
            failure: Some(error.into()),
        },
    }
}

enum Operation {
    Command { command: String, write: bool },
    Begin { length: u32 },
    End,
}

async fn with_session(
    handle: u32,
    operation: Operation,
) -> Result<FastbootCommandReply, FastbootFailure> {
    let Some(entry) = registry_get(handle) else {
        return Err(LinkError::unknown_session(handle).into());
    };
    let mut session = entry.session.lock().await;
    let result = match operation {
        Operation::Command { command, write } => session.command(&command, write).await,
        Operation::Begin { length } => session.begin_download(length).await,
        Operation::End => session.end_download().await,
    };
    match result {
        Ok(outcome) => Ok(FastbootCommandReply {
            value: outcome.value,
            messages: outcome
                .messages
                .into_iter()
                .map(|message| FastbootMessage {
                    kind: message.kind,
                    text: message.text,
                })
                .collect(),
            failure: None,
        }),
        Err(error) => {
            if session.is_retired() {
                registry_remove(handle);
            }
            Err(error.into())
        }
    }
}

pub async fn fastboot_command(handle: u32, command: String, write: bool) -> FastbootCommandReply {
    match with_session(handle, Operation::Command { command, write }).await {
        Ok(reply) => reply,
        Err(failure) => FastbootCommandReply {
            value: String::new(),
            messages: Vec::new(),
            failure: Some(failure),
        },
    }
}

pub async fn fastboot_begin_download(handle: u32, length: u32) -> FastbootVoidReply {
    match with_session(handle, Operation::Begin { length }).await {
        Ok(reply) => FastbootVoidReply {
            messages: reply.messages,
            failure: None,
        },
        Err(failure) => FastbootVoidReply {
            messages: Vec::new(),
            failure: Some(failure),
        },
    }
}

pub async fn fastboot_write_download(handle: u32, bytes: Vec<u8>) -> FastbootVoidReply {
    let Some(entry) = registry_get(handle) else {
        return FastbootVoidReply {
            messages: Vec::new(),
            failure: Some(LinkError::unknown_session(handle).into()),
        };
    };
    let mut session = entry.session.lock().await;
    match session.write_download(bytes).await {
        Ok(()) => FastbootVoidReply {
            messages: Vec::new(),
            failure: None,
        },
        Err(error) => {
            if session.is_retired() {
                registry_remove(handle);
            }
            FastbootVoidReply {
                messages: Vec::new(),
                failure: Some(error.into()),
            }
        }
    }
}

pub async fn fastboot_end_download(handle: u32) -> FastbootCommandReply {
    match with_session(handle, Operation::End).await {
        Ok(reply) => reply,
        Err(failure) => FastbootCommandReply {
            value: String::new(),
            messages: Vec::new(),
            failure: Some(failure),
        },
    }
}

pub async fn fastboot_close(handle: u32) -> FastbootVoidReply {
    let Some(entry) = registry_remove(handle) else {
        return FastbootVoidReply {
            messages: Vec::new(),
            failure: None,
        };
    };
    let mut session = entry.session.lock().await;
    match session.close().await {
        Ok(()) => FastbootVoidReply {
            messages: Vec::new(),
            failure: None,
        },
        Err(error) => FastbootVoidReply {
            messages: Vec::new(),
            failure: Some(error.into()),
        },
    }
}
