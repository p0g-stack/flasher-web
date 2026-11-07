//! Errors keep the original evidence: the transport's own name/message, the
//! native source chain, the browser stack, and any cleanup failures. The
//! classification (`stage`, `uncertain`) is added, never substituted.

use std::fmt;

/// One device message, keeping INFO (new line) and TEXT (continuation of the
/// previous line) distinct.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkMessage {
    pub kind: String,
    pub text: String,
}

/// A failure below the fastboot protocol: bulk I/O, a rejected WebUSB call,
/// a USB open, or a timeout.
#[derive(Debug, Clone)]
pub struct TransportError {
    /// Which layer produced this: `usb`, `browser`, or `tcp`. It becomes the
    /// public error's `source`, never its blame.
    pub blame: String,
    pub name: String,
    /// The transport's original text, not a re-description.
    pub message: String,
    /// A browser stack trace, when the browser supplied one.
    pub stack: String,
    /// Native source chain, outermost first, excluding `message`.
    pub causes: Vec<String>,
    /// True when the device may still be acting (a write or read was in
    /// flight when this failed).
    pub uncertain: bool,
}

impl TransportError {
    pub fn new(blame: &str, name: &str, message: String, uncertain: bool) -> Self {
        Self {
            blame: blame.to_string(),
            name: name.to_string(),
            message,
            stack: String::new(),
            causes: Vec::new(),
            uncertain,
        }
    }

    /// Keep the chain of a native error instead of flattening it to `Display`.
    pub fn native(blame: &str, error: &dyn std::error::Error, uncertain: bool) -> Self {
        let mut causes = Vec::new();
        let mut source = error.source();
        while let Some(cause) = source {
            causes.push(cause.to_string());
            source = cause.source();
        }
        Self {
            blame: blame.to_string(),
            name: "UsbError".to_string(),
            message: error.to_string(),
            stack: String::new(),
            causes,
            uncertain,
        }
    }

    pub fn timeout(blame: &str, stage: &str) -> Self {
        Self {
            blame: blame.to_string(),
            name: "Timeout".to_string(),
            message: format!("{stage} did not complete in time"),
            stack: String::new(),
            causes: Vec::new(),
            uncertain: true,
        }
    }
}

impl fmt::Display for TransportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.name, self.message)
    }
}

impl std::error::Error for TransportError {}

/// A failure surfaced by [`crate::Session`] or [`crate::open`]. It keeps the
/// transport evidence and adds the fastboot stage and uncertainty.
#[derive(Debug, Clone)]
pub struct LinkError {
    /// Who is responsible: `host`, `user`, `device`, or `unknown`. This is a
    /// closed set; the producing layer is kept in [`Self::source`].
    pub blame: String,
    /// The layer that produced the failure (`caller`, `protocol`, `usb`,
    /// `browser`, `tcp`, `transport`). Evidence, never responsibility.
    pub source: String,
    pub name: String,
    pub message: String,
    pub stage: &'static str,
    pub uncertain: bool,
    pub stack: String,
    pub causes: Vec<String>,
    pub cleanup_errors: Vec<String>,
    /// INFO/TEXT records received before this failure. A FAIL often carries
    /// the device's only explanation after several INFO frames.
    pub messages: Vec<LinkMessage>,
    /// Internal: whether the session must be retired after this error.
    /// Caller mistakes (an empty serial, an over-long chunk) do not retire it.
    pub(crate) retire: bool,
}

impl LinkError {
    /// Caller API misuse: a command out of order, an empty chunk, a handle
    /// that is already gone. Unknown to the user, and non-retiring by itself.
    pub fn caller(stage: &'static str, name: &str, message: impl Into<String>) -> Self {
        Self {
            blame: "unknown".to_string(),
            source: "caller".to_string(),
            name: name.to_string(),
            message: message.into(),
            stage,
            uncertain: false,
            stack: String::new(),
            causes: Vec::new(),
            cleanup_errors: Vec::new(),
            messages: Vec::new(),
            retire: false,
        }
    }

    /// The user's own input, such as an empty serial. Non-retiring.
    pub fn user(stage: &'static str, name: &str, message: impl Into<String>) -> Self {
        let mut error = Self::caller(stage, name, message);
        error.blame = "user".to_string();
        error
    }

    /// A complete FAIL: the device answered and refused. `retire` stays false
    /// so mode probes can continue on the same link.
    pub fn device(stage: &'static str, reason: impl Into<String>) -> Self {
        Self {
            blame: "device".to_string(),
            source: "protocol".to_string(),
            name: "FastbootFail".to_string(),
            message: reason.into(),
            stage,
            uncertain: false,
            stack: String::new(),
            causes: Vec::new(),
            cleanup_errors: Vec::new(),
            messages: Vec::new(),
            // A complete FAIL ends that command, and the device is still
            // answerable: mode probes use unknown getvars, so the session stays
            // usable. Transport/protocol failures still retire it.
            retire: false,
        }
    }

    pub fn device_with_messages(
        stage: &'static str,
        reason: impl Into<String>,
        messages: Vec<LinkMessage>,
    ) -> Self {
        let mut error = Self::device(stage, reason);
        error.messages = messages;
        error
    }

    /// An invalid device reply. It is the device's answer, so it is blamed on
    /// the device, but an unparseable stream retires the session.
    pub fn protocol(stage: &'static str, message: impl Into<String>) -> Self {
        Self {
            blame: "device".to_string(),
            source: "protocol".to_string(),
            name: "Protocol".to_string(),
            message: message.into(),
            stage,
            uncertain: true,
            stack: String::new(),
            causes: Vec::new(),
            cleanup_errors: Vec::new(),
            messages: Vec::new(),
            retire: true,
        }
    }

    /// A bulk I/O or browser failure. `error.blame` records the producing layer
    /// as `source`; the public blame is the host this app runs on.
    pub fn from_transport(stage: &'static str, error: TransportError) -> Self {
        Self {
            blame: "host".to_string(),
            source: error.blame,
            name: error.name,
            message: error.message,
            stage,
            uncertain: error.uncertain,
            stack: error.stack,
            causes: error.causes,
            cleanup_errors: Vec::new(),
            messages: Vec::new(),
            retire: true,
        }
    }

    /// Attach the INFO/TEXT evidence collected before a transport or protocol
    /// failure.
    pub fn with_messages(mut self, messages: Vec<LinkMessage>) -> Self {
        self.messages = messages;
        self
    }

    pub fn unknown_session(handle: u32) -> Self {
        let mut error =
            Self::caller("session", "UnknownSession", format!("no live session {handle}"));
        error.retire = true;
        error
    }

    /// Lifecycle information; never infer this from blame or error names.
    pub fn session_retired(&self) -> bool {
        self.retire
    }

    pub fn with_cleanup(mut self, cleanup: Vec<String>) -> Self {
        self.cleanup_errors.extend(cleanup);
        self
    }
}

impl fmt::Display for LinkError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} at {}: {}", self.name, self.stage, self.message)
    }
}

impl std::error::Error for LinkError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_blame_is_closed_and_source_is_evidence() {
        let misuse = LinkError::caller("command", "Busy", "another operation is in flight");
        assert_eq!(misuse.blame, "unknown");
        assert_eq!(misuse.source, "caller");
        assert!(!misuse.session_retired());

        let input = LinkError::user("open", "EmptySerial", "refusing an empty serial");
        assert_eq!(input.blame, "user");
        assert_eq!(input.source, "caller");
        assert!(!input.session_retired());

        let fail = LinkError::device_with_messages(
            "command",
            "unknown variable",
            vec![LinkMessage {
                kind: "INFO".to_string(),
                text: "probe".to_string(),
            }],
        );
        assert_eq!(fail.blame, "device");
        assert_eq!(fail.name, "FastbootFail");
        assert_eq!(fail.messages.len(), 1);
        assert!(!fail.session_retired());
    }

    #[test]
    fn protocol_replies_are_the_devices_and_retire() {
        let error = LinkError::protocol("command", "unparseable fastboot response: junk");
        assert_eq!(error.blame, "device");
        assert_eq!(error.source, "protocol");
        assert_eq!(error.name, "Protocol");
        assert!(error.session_retired());
    }

    #[test]
    fn transport_evidence_survives_host_blame() {
        let mut transport =
            TransportError::new("browser", "NetworkError", "transfer failed".to_string(), true);
        transport.stack = "at send (webusb.js:9)".to_string();
        transport.causes = vec!["inner".to_string()];
        let error = LinkError::from_transport("writeDownload", transport);
        assert_eq!(error.blame, "host");
        assert_eq!(error.source, "browser");
        assert_eq!(error.name, "NetworkError");
        assert_eq!(error.message, "transfer failed");
        assert_eq!(error.stack, "at send (webusb.js:9)");
        assert_eq!(error.causes, vec!["inner".to_string()]);
        assert!(error.uncertain);
        assert!(error.session_retired());
    }

    #[test]
    fn a_missing_handle_reports_a_retired_session() {
        let error = LinkError::unknown_session(7);
        assert_eq!(error.name, "UnknownSession");
        assert_eq!(error.blame, "unknown");
        assert!(error.session_retired());
    }
}
