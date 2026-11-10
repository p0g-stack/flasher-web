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

/// Responsibility is evidence-based and independent of the reporting API.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Blame {
    Host,
    User,
    Device,
    Unknown,
}

impl Blame {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Host => "host",
            Self::User => "user",
            Self::Device => "device",
            Self::Unknown => "unknown",
        }
    }
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
    /// A matching attachment removal observed after a failed transfer.
    /// This does not establish its cause or whether a write applied.
    pub disconnect_observed: bool,
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
            disconnect_observed: false,
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
            disconnect_observed: false,
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
            disconnect_observed: false,
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
    pub blame: Blame,
    /// The layer that produced the failure (`caller`, `protocol`, `usb`,
    /// `browser`, `tcp`, `transport`). Evidence, never responsibility.
    pub source: String,
    pub name: String,
    pub message: String,
    pub stage: &'static str,
    pub uncertain: bool,
    pub disconnect_observed: bool,
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
            blame: Blame::Unknown,
            source: "caller".to_string(),
            name: name.to_string(),
            message: message.into(),
            stage,
            uncertain: false,
            disconnect_observed: false,
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
        error.blame = Blame::User;
        error
    }

    /// A complete FAIL: the device answered and refused. `retire` stays false
    /// so mode probes can continue on the same link.
    pub fn device(stage: &'static str, reason: impl Into<String>) -> Self {
        Self {
            blame: Blame::Device,
            source: "protocol".to_string(),
            name: "FastbootFail".to_string(),
            message: reason.into(),
            stage,
            uncertain: false,
            disconnect_observed: false,
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

    /// An invalid reply does not establish responsibility. An unparseable
    /// stream retires the session.
    pub fn protocol(stage: &'static str, message: impl Into<String>) -> Self {
        Self {
            blame: Blame::Unknown,
            source: "protocol".to_string(),
            name: "Protocol".to_string(),
            message: message.into(),
            stage,
            uncertain: true,
            disconnect_observed: false,
            stack: String::new(),
            causes: Vec::new(),
            cleanup_errors: Vec::new(),
            messages: Vec::new(),
            retire: true,
        }
    }

    /// Preserve the producing API separately. Only explicit access/ownership
    /// evidence establishes host responsibility; generic I/O stays unknown.
    pub fn from_transport(stage: &'static str, error: TransportError) -> Self {
        Self {
            blame: match error.name.as_str() {
                "SecurityError" | "PermissionDenied" | "Busy" | "ClaimRefused" => Blame::Host,
                "NotFoundError" if stage == "choose" => Blame::User,
                _ => Blame::Unknown,
            },
            source: error.blame,
            name: error.name,
            message: error.message,
            stage,
            uncertain: error.uncertain,
            disconnect_observed: error.disconnect_observed,
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
        assert_eq!(misuse.blame, Blame::Unknown);
        assert_eq!(misuse.source, "caller");
        assert!(!misuse.session_retired());

        let input = LinkError::user("choose", "NotFoundError", "no device selected");
        assert_eq!(input.blame, Blame::User);
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
        assert_eq!(fail.blame, Blame::Device);
        assert_eq!(fail.name, "FastbootFail");
        assert_eq!(fail.messages.len(), 1);
        assert!(!fail.session_retired());
    }

    #[test]
    fn malformed_replies_do_not_establish_responsibility_and_retire() {
        let error = LinkError::protocol("command", "unparseable fastboot response: junk");
        assert_eq!(error.blame, Blame::Unknown);
        assert_eq!(error.source, "protocol");
        assert_eq!(error.name, "Protocol");
        assert!(error.session_retired());
    }

    #[test]
    fn transport_evidence_survives_unknown_responsibility() {
        let mut transport =
            TransportError::new("browser", "NetworkError", "transfer failed".to_string(), true);
        transport.stack = "at send (webusb.js:9)".to_string();
        transport.causes = vec!["inner".to_string()];
        transport.disconnect_observed = true;
        let error = LinkError::from_transport("writeDownload", transport);
        assert_eq!(error.blame, Blame::Unknown);
        assert_eq!(error.source, "browser");
        assert_eq!(error.name, "NetworkError");
        assert_eq!(error.message, "transfer failed");
        assert_eq!(error.stack, "at send (webusb.js:9)");
        assert_eq!(error.causes, vec!["inner".to_string()]);
        assert!(error.uncertain);
        assert!(error.disconnect_observed);
        assert!(error.session_retired());
    }

    #[test]
    fn transport_classification_requires_evidence() {
        for (stage, name, expected) in [
            ("command", "Timeout", Blame::Unknown),
            ("command", "NetworkError", Blame::Unknown),
            ("command", "NotFoundError", Blame::Unknown),
            ("command", "Disconnected", Blame::Unknown),
            ("command", "ShortWrite", Blame::Unknown),
            ("open", "UsbError", Blame::Unknown),
            ("open", "SecurityError", Blame::Host),
            ("open", "PermissionDenied", Blame::Host),
            ("open", "Busy", Blame::Host),
            ("open", "ClaimRefused", Blame::Host),
            ("choose", "NotFoundError", Blame::User),
        ] {
            let error = LinkError::from_transport(stage,
                TransportError::new("browser", name, "original".into(), false));
            assert_eq!(error.blame, expected, "{stage}/{name}");
            assert_eq!(error.source, "browser");
            assert_eq!(error.message, "original");
        }
    }

    #[test]
    fn a_missing_handle_reports_a_retired_session() {
        let error = LinkError::unknown_session(7);
        assert_eq!(error.name, "UnknownSession");
        assert_eq!(error.blame, Blame::Unknown);
        assert!(error.session_retired());
    }
}
