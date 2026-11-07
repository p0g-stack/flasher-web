//! The fastboot state machine over any bulk transport. It owns the
//! download handshake and length accounting so callers can stream an image in
//! bounded pieces; the transport never sees the whole image.

use std::time::Duration;

use fastboot_protocol::protocol::FastBootResponse;

use crate::error::{LinkError, LinkMessage, TransportError};
use crate::timeout;

/// The largest piece a caller may hand to [`Session::write_download`]. Fastboot
/// itself is length-counted; this bound keeps memory flat and lets every host
/// (including a Web Worker) copy a piece without a whole-image allocation.
pub const MAX_CHUNK: usize = 1024 * 1024;

/// The fastboot command line is one USB transfer; keep it within the protocol's
/// 64-byte packet budget.
const MAX_COMMAND: usize = 64;

/// A command can be preceded by many INFO/TEXT frames (`getvar:all`). Keep a
/// bound so a chatty or broken device cannot loop forever.
const MAX_RESPONSES: usize = 4096;

/// A write command (`flash:`, `erase:`, reboot) can take minutes on the
/// device while it writes storage and sends no INFO. Probes keep the shorter
/// session timeout; the transport's own read bound is longer still, so this is
/// the effective limit.
const WRITE_TIMEOUT: Duration = Duration::from_secs(180);

#[allow(async_fn_in_trait)]
pub trait BulkTransport {
    /// The layer that produced a transport failure; it becomes the error's
    /// `source`, never its public blame.
    fn blame(&self) -> &'static str;
    /// Send exactly `data`; a short completion is a failure. Ownership moves to
    /// the transport so a download chunk reaches the endpoint without a copy.
    async fn write_all(&mut self, data: Vec<u8>) -> Result<(), TransportError>;
    /// Read one fastboot response (or one frame from the test transport).
    async fn read(&mut self, max: usize) -> Result<Vec<u8>, TransportError>;
    /// Release the device/interface. Errors are cleanup evidence, not the
    /// original failure.
    async fn close(&mut self) -> Result<(), TransportError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutcome {
    /// The final OKAY payload, if any.
    pub value: String,
    /// INFO/TEXT frames seen before the final reply.
    pub messages: Vec<LinkMessage>,
}

#[derive(Debug, Clone, Copy)]
enum State {
    Idle,
    Downloading { expected: u32, sent: u32 },
}

pub struct Session<T: BulkTransport> {
    transport: Option<T>,
    serial: String,
    state: State,
    max_in: usize,
    timeout: Duration,
    retired: bool,
}

impl<T: BulkTransport> Session<T> {
    pub fn new(transport: T, serial: String, max_in: usize, timeout: Duration) -> Self {
        Self {
            transport: Some(transport),
            serial,
            state: State::Idle,
            max_in: max_in.max(64),
            timeout,
            retired: false,
        }
    }

    pub fn serial(&self) -> &str {
        &self.serial
    }

    pub fn is_retired(&self) -> bool {
        self.retired
    }

    fn closed_error(&self, stage: &'static str) -> LinkError {
        let mut error = LinkError::caller(stage, "Closed", "session is retired; reopen the device");
        error.retire = true;
        error
    }

    /// `write` is carried for the caller's policy (UI may treat a write
    /// differently); the protocol is identical. Transport failures are
    /// uncertain whether the command reads or writes.
    pub async fn command(&mut self, command: &str, write: bool) -> Result<CommandOutcome, LinkError> {
        let stage = "command";
        if self.retired {
            return Err(self.closed_error(stage));
        }
        if !matches!(self.state, State::Idle) {
            return Err(LinkError::caller(
                stage,
                "Busy",
                "a download is in progress; finish it before another command",
            ));
        }
        if command.is_empty()
            || command.len() > MAX_COMMAND
            || !command.bytes().all(|b| (0x20..=0x7e).contains(&b))
        {
            return Err(LinkError::caller(
                stage,
                "InvalidCommand",
                "fastboot commands are 1..=64 printable ASCII bytes",
            ));
        }
        let limit = if write { WRITE_TIMEOUT } else { self.timeout };
        let outcome = self.command_inner(stage, command, limit).await;
        self.finish(outcome).await
    }

    async fn command_inner(
        &mut self,
        stage: &'static str,
        command: &str,
        limit: Duration,
    ) -> Result<CommandOutcome, LinkError> {
        self.send(stage, command.as_bytes().to_vec(), limit).await?;
        let mut messages = Vec::new();
        for _ in 0..MAX_RESPONSES {
            let response = match self.read_response(stage, limit).await {
                Ok(response) => response,
                Err(error) => return Err(error.with_messages(messages)),
            };
            match response {
                FastBootResponse::Info(message) => record(&mut messages, "INFO", message),
                FastBootResponse::Text(message) => record(&mut messages, "TEXT", message),
                FastBootResponse::Okay(value) => {
                    return Ok(CommandOutcome { value, messages })
                }
                FastBootResponse::Fail(reason) => {
                    return Err(LinkError::device_with_messages(stage, reason, messages))
                }
                FastBootResponse::Data(_) => {
                    return Err(LinkError::protocol(
                        stage,
                        "device sent DATA when no download was requested",
                    )
                    .with_messages(messages))
                }
            }
        }
        Err(LinkError::protocol(
            stage,
            format!("more than {MAX_RESPONSES} INFO/TEXT responses"),
        )
        .with_messages(messages))
    }

    pub async fn begin_download(&mut self, length: u32) -> Result<CommandOutcome, LinkError> {
        let stage = "beginDownload";
        if self.retired {
            return Err(self.closed_error(stage));
        }
        if !matches!(self.state, State::Idle) {
            return Err(LinkError::caller(
                stage,
                "Busy",
                "a download is already in progress",
            ));
        }
        if length == 0 {
            return Err(LinkError::caller(
                stage,
                "InvalidLength",
                "download length must be greater than zero",
            ));
        }
        let outcome = self.begin_inner(stage, length).await;
        self.finish(outcome).await
    }

    async fn begin_inner(
        &mut self,
        stage: &'static str,
        length: u32,
    ) -> Result<CommandOutcome, LinkError> {
        let command = format!("download:{length:08x}");
        self.send(stage, command.into_bytes(), self.timeout).await?;
        let mut messages = Vec::new();
        for _ in 0..MAX_RESPONSES {
            let response = match self.read_response(stage, self.timeout).await {
                Ok(response) => response,
                Err(error) => return Err(error.with_messages(messages)),
            };
            match response {
                FastBootResponse::Info(message) => record(&mut messages, "INFO", message),
                FastBootResponse::Text(message) => record(&mut messages, "TEXT", message),
                FastBootResponse::Data(actual) => {
                    if actual != length {
                        return Err(LinkError::protocol(
                            stage,
                            format!("device asked for {actual:#x} bytes, expected {length:#x}"),
                        )
                        .with_messages(messages));
                    }
                    self.state = State::Downloading {
                        expected: length,
                        sent: 0,
                    };
                    return Ok(CommandOutcome {
                        value: String::new(),
                        messages,
                    });
                }
                FastBootResponse::Okay(_) => {
                    return Err(LinkError::protocol(
                        stage,
                        "device answered OKAY without a DATA phase",
                    )
                    .with_messages(messages))
                }
                FastBootResponse::Fail(reason) => {
                    return Err(LinkError::device_with_messages(stage, reason, messages))
                }
            }
        }
        Err(LinkError::protocol(
            stage,
            format!("more than {MAX_RESPONSES} responses before DATA"),
        )
        .with_messages(messages))
    }

    pub async fn write_download(&mut self, bytes: Vec<u8>) -> Result<(), LinkError> {
        let stage = "writeDownload";
        if self.retired {
            return Err(self.closed_error(stage));
        }
        let State::Downloading { expected, sent } = self.state else {
            return Err(LinkError::caller(
                stage,
                "NotDownloading",
                "writeDownload requires a successful beginDownload",
            ));
        };
        if bytes.is_empty() {
            return Err(LinkError::caller(
                stage,
                "EmptyChunk",
                "an empty download chunk is not sent",
            ));
        }
        if bytes.len() > MAX_CHUNK {
            return Err(LinkError::caller(
                stage,
                "ChunkTooLarge",
                format!("chunk is {} bytes; the maximum is {MAX_CHUNK}", bytes.len()),
            ));
        }
        let end = u64::from(sent) + bytes.len() as u64;
        if end > u64::from(expected) {
            return Err(LinkError::caller(
                stage,
                "Overrun",
                format!(
                    "chunk ends at {end}, past the declared download of {expected} bytes"
                ),
            ));
        }
        let sent = end as u32;
        let result = self.send(stage, bytes, self.timeout).await;
        match result {
            Ok(()) => {
                self.state = State::Downloading { expected, sent };
                Ok(())
            }
            Err(error) => {
                let cleanup = self.retire().await;
                Err(error.with_cleanup(cleanup))
            }
        }
    }

    pub async fn end_download(&mut self) -> Result<CommandOutcome, LinkError> {
        let stage = "endDownload";
        if self.retired {
            return Err(self.closed_error(stage));
        }
        let State::Downloading { expected, sent } = self.state else {
            return Err(LinkError::caller(
                stage,
                "NotDownloading",
                "endDownload requires a successful beginDownload",
            ));
        };
        if sent != expected {
            let mut error = LinkError::protocol(
                stage,
                format!("only {sent} of {expected} download bytes were sent"),
            );
            error.uncertain = false;
            let cleanup = self.retire().await;
            return Err(error.with_cleanup(cleanup));
        }
        let outcome = self.end_inner(stage, WRITE_TIMEOUT).await;
        self.finish(outcome).await
    }

    async fn end_inner(
        &mut self,
        stage: &'static str,
        limit: Duration,
    ) -> Result<CommandOutcome, LinkError> {
        let mut messages = Vec::new();
        for _ in 0..MAX_RESPONSES {
            let response = match self.read_response(stage, limit).await {
                Ok(response) => response,
                Err(error) => return Err(error.with_messages(messages)),
            };
            match response {
                FastBootResponse::Info(message) => record(&mut messages, "INFO", message),
                FastBootResponse::Text(message) => record(&mut messages, "TEXT", message),
                FastBootResponse::Okay(value) => {
                    self.state = State::Idle;
                    return Ok(CommandOutcome { value, messages });
                }
                FastBootResponse::Fail(reason) => {
                    // The data phase is over even though the device refused
                    // it; a complete FAIL leaves the link answerable.
                    self.state = State::Idle;
                    return Err(LinkError::device_with_messages(stage, reason, messages))
                }
                FastBootResponse::Data(_) => {
                    return Err(LinkError::protocol(
                        stage,
                        "device sent DATA after the download was complete",
                    )
                    .with_messages(messages))
                }
            }
        }
        Err(LinkError::protocol(
            stage,
            format!("more than {MAX_RESPONSES} responses after the download"),
        )
        .with_messages(messages))
    }

    pub async fn close(&mut self) -> Result<(), LinkError> {
        let cleanup = self.retire().await;
        if cleanup.is_empty() {
            Ok(())
        } else {
            Err(LinkError {
                blame: "host".to_string(),
                source: "transport".to_string(),
                name: "Close".to_string(),
                message: "the device did not close cleanly".to_string(),
                stage: "close",
                uncertain: true,
                stack: String::new(),
                causes: Vec::new(),
                cleanup_errors: cleanup,
                messages: Vec::new(),
                retire: true,
            })
        }
    }

    async fn send(
        &mut self,
        stage: &'static str,
        data: Vec<u8>,
        limit: Duration,
    ) -> Result<(), LinkError> {
        if self.transport.is_none() {
            return Err(self.closed_error(stage));
        }
        let transport = self.transport.as_mut().expect("checked above");
        let blame = transport.blame();
        let result = timeout(limit, transport.write_all(data)).await;
        match result {
            Some(Ok(())) => Ok(()),
            Some(Err(error)) => Err(LinkError::from_transport(stage, error)),
            None => Err(LinkError::from_transport(
                stage,
                TransportError::timeout(blame, stage),
            )),
        }
    }

    async fn read_response(
        &mut self,
        stage: &'static str,
        limit: Duration,
    ) -> Result<FastBootResponse, LinkError> {
        if self.transport.is_none() {
            return Err(self.closed_error(stage));
        }
        let transport = self.transport.as_mut().expect("checked above");
        let blame = transport.blame();
        let max = self.max_in;
        let result = timeout(limit, transport.read(max)).await;
        let bytes = match result {
            Some(Ok(bytes)) => bytes,
            Some(Err(error)) => return Err(LinkError::from_transport(stage, error)),
            None => {
                return Err(LinkError::from_transport(
                    stage,
                    TransportError::timeout(blame, stage),
                ))
            }
        };
        FastBootResponse::from_bytes(&bytes).map_err(|error| {
            LinkError::protocol(stage, format!("unparseable fastboot response: {error}"))
        })
    }

    async fn finish<V>(&mut self, result: Result<V, LinkError>) -> Result<V, LinkError> {
        match result {
            Ok(value) => Ok(value),
            Err(mut error) => {
                if error.retire {
                    let cleanup = self.retire().await;
                    error = error.with_cleanup(cleanup);
                }
                Err(error)
            }
        }
    }

    /// Close and drop the transport. A session never reopens or retries a
    /// write; the caller may open a fresh session after the user acts.
    async fn retire(&mut self) -> Vec<String> {
        self.retired = true;
        self.state = State::Idle;
        let Some(mut transport) = self.transport.take() else {
            return Vec::new();
        };
        let blame = transport.blame();
        match timeout(Duration::from_secs(2), transport.close()).await {
            Some(Ok(())) => Vec::new(),
            Some(Err(error)) => vec![format!("{blame} close: {}: {}", error.name, error.message)],
            None => vec![format!("{blame} close timed out")],
        }
    }
}

/// Keep the protocol distinction between INFO (a new line) and TEXT
/// (continuation of the previous line) instead of flattening both.
fn record(messages: &mut Vec<LinkMessage>, kind: &str, text: String) {
    messages.push(LinkMessage {
        kind: kind.to_string(),
        text,
    });
}
