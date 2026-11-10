//! The fastboot state machine over any bulk transport. It owns the
//! download handshake and length accounting so callers can stream an image in
//! bounded pieces; the transport never sees the whole image.

use std::time::Duration;
#[cfg(not(target_arch = "wasm32"))]
use tokio::time::Instant;
#[cfg(target_arch = "wasm32")]
use web_time::Instant;

use fastboot_protocol::protocol::FastBootResponse;

use crate::error::{Blame, LinkError, LinkMessage, TransportError};
use crate::timeout;

/// The largest piece a caller may hand to [`Session::write_download`]. Fastboot
/// itself is length-counted; this bound keeps memory flat and lets every host
/// (including a Web Worker) copy a piece without a whole-image allocation.
pub const MAX_CHUNK: usize = 1024 * 1024;

/// Download bytes reach the device in multiples of this size; only the last
/// transfer of a download may be shorter. A short USB packet ends the device's
/// pending read, so a separately sent 28-byte sparse header in the middle of a
/// download can stall fastbootd. AOSP `FastBootDriver::SparseWriteCallback`
/// coalesces into the same unit (`TRANSPORT_CHUNK_SIZE`).
const TRANSPORT_CHUNK: usize = 1024;

/// The fastboot command line is one USB transfer; keep it within the protocol's
/// 64-byte packet budget.
const MAX_COMMAND: usize = 64;

/// A command can be preceded by many INFO/TEXT frames (`getvar:all`). Keep a
/// bound so a chatty or broken device cannot loop forever.
const MAX_RESPONSES: usize = 4096;

/// Research §6.1 proposes 3–5 seconds for the first harmless probe, versus
/// fastboot.js's 10 seconds. Five seconds allows host scheduling slack without
/// making a silent freshly opened phone wait the normal 15 seconds.
const FIRST_PROBE_TIMEOUT: Duration = Duration::from_secs(5);
/// Preserve the existing storage-processing allowance, including silent writes.
const WRITE_TIMEOUT: Duration = Duration::from_secs(180);
/// Read-only commands can report useful INFO, but cannot extend forever.
const READ_OPERATION_TIMEOUT: Duration = Duration::from_secs(60);

struct ResponseBudget {
    started: Instant,
    progress: Instant,
    overall: Duration,
    idle: Duration,
}

impl ResponseBudget {
    fn new(overall: Duration, idle: Duration) -> Self {
        let now = Instant::now();
        Self { started: now, progress: now, overall, idle }
    }

    fn remaining(&self) -> (Duration, &'static str, Duration) {
        let overall = self.overall.saturating_sub(self.started.elapsed());
        let idle = self.idle.saturating_sub(self.progress.elapsed());
        if overall <= idle {
            (overall, "OperationDeadline", self.overall)
        } else {
            (idle, "NoProgress", self.idle)
        }
    }

    // New, nonempty INFO/TEXT is activity, not proof a write completed.
    // Repeating the same frame does not count as progress.
    fn observe(&mut self, messages: &[LinkMessage], kind: &str, text: &str) {
        if !text.is_empty() && !messages.last().is_some_and(|last| last.kind == kind && last.text == text) {
            self.progress = Instant::now();
        }
    }
}

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
    /// Accepted download bytes not yet sent: always fewer than
    /// [`TRANSPORT_CHUNK`], flushed by `end_download`.
    pending: Vec<u8>,
    max_in: usize,
    timeout: Duration,
    retired: bool,
    first_probe_done: bool,
}

impl<T: BulkTransport> Session<T> {
    pub fn new(transport: T, serial: String, max_in: usize, timeout: Duration) -> Self {
        Self {
            transport: Some(transport),
            serial,
            state: State::Idle,
            pending: Vec::new(),
            max_in: max_in.max(64),
            timeout,
            retired: false,
            first_probe_done: false,
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
        let first_probe = !write && !self.first_probe_done;
        if !write { self.first_probe_done = true; }
        let idle = if write { WRITE_TIMEOUT } else if first_probe {
            self.timeout.min(FIRST_PROBE_TIMEOUT)
        } else { self.timeout };
        let overall = if write || first_probe { idle } else {
            self.timeout.saturating_mul(4).min(READ_OPERATION_TIMEOUT)
        };
        let mut outcome = self.command_inner(stage, command, ResponseBudget::new(overall, idle)).await;
        if !write {
            if let Err(error) = &mut outcome { error.uncertain = false; }
        }
        self.finish(outcome).await
    }

    async fn command_inner(
        &mut self,
        stage: &'static str,
        command: &str,
        mut budget: ResponseBudget,
    ) -> Result<CommandOutcome, LinkError> {
        self.send(stage, command.as_bytes().to_vec(), budget.remaining().0).await?;
        let mut messages = Vec::new();
        for _ in 0..MAX_RESPONSES {
            let response = match self.read_budgeted(stage, &budget).await {
                Ok(response) => response,
                Err(error) => return Err(error.with_messages(messages)),
            };
            match response {
                FastBootResponse::Info(message) => {
                    budget.observe(&messages, "INFO", &message);
                    record(&mut messages, "INFO", message);
                }
                FastBootResponse::Text(message) => {
                    budget.observe(&messages, "TEXT", &message);
                    record(&mut messages, "TEXT", message);
                }
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
        let mut budget = ResponseBudget::new(
            self.timeout.saturating_mul(4).min(READ_OPERATION_TIMEOUT), self.timeout);
        self.send(stage, command.into_bytes(), self.timeout).await?;
        let mut messages = Vec::new();
        for _ in 0..MAX_RESPONSES {
            let response = match self.read_budgeted(stage, &budget).await {
                Ok(response) => response,
                Err(error) => return Err(error.with_messages(messages)),
            };
            match response {
                FastBootResponse::Info(message) => {
                    budget.observe(&messages, "INFO", &message);
                    record(&mut messages, "INFO", message);
                }
                FastBootResponse::Text(message) => {
                    budget.observe(&messages, "TEXT", &message);
                    record(&mut messages, "TEXT", message);
                }
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
        // Send whole TRANSPORT_CHUNK units; keep the residual for the next
        // write. An aligned chunk with nothing pending is sent without a copy.
        let mut data = if self.pending.is_empty() {
            bytes
        } else {
            let mut joined = std::mem::take(&mut self.pending);
            joined.extend_from_slice(&bytes);
            joined
        };
        let residual = data.len() % TRANSPORT_CHUNK;
        if residual != 0 {
            self.pending = data.split_off(data.len() - residual);
        }
        self.state = State::Downloading { expected, sent: end as u32 };
        if data.is_empty() {
            return Ok(());
        }
        let result = self.send(stage, data, self.timeout).await;
        match result {
            Ok(()) => Ok(()),
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
        let budget = ResponseBudget::new(WRITE_TIMEOUT, WRITE_TIMEOUT);
        if !self.pending.is_empty() {
            let tail = std::mem::take(&mut self.pending);
            if let Err(error) = self.send("writeDownload", tail, self.timeout).await {
                let cleanup = self.retire().await;
                return Err(error.with_cleanup(cleanup));
            }
        }
        let outcome = self.end_inner(stage, budget).await;
        self.finish(outcome).await
    }

    async fn end_inner(
        &mut self,
        stage: &'static str,
        mut budget: ResponseBudget,
    ) -> Result<CommandOutcome, LinkError> {
        let mut messages = Vec::new();
        for _ in 0..MAX_RESPONSES {
            let response = match self.read_budgeted(stage, &budget).await {
                Ok(response) => response,
                Err(error) => return Err(error.with_messages(messages)),
            };
            match response {
                FastBootResponse::Info(message) => {
                    budget.observe(&messages, "INFO", &message);
                    record(&mut messages, "INFO", message);
                }
                FastBootResponse::Text(message) => {
                    budget.observe(&messages, "TEXT", &message);
                    record(&mut messages, "TEXT", message);
                }
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
                blame: Blame::Unknown,
                source: "transport".to_string(),
                name: "Close".to_string(),
                message: "the device did not close cleanly".to_string(),
                stage: "close",
                uncertain: true,
                disconnect_observed: false,
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
            None => {
                let mut error = TransportError::timeout(blame, stage);
                error.message = format!("{stage} transfer exceeded {} ms", limit.as_millis());
                Err(LinkError::from_transport(stage, error))
            }
        }
    }

    async fn read_budgeted(
        &mut self,
        stage: &'static str,
        budget: &ResponseBudget,
    ) -> Result<FastBootResponse, LinkError> {
        let (remaining, kind, allowance) = budget.remaining();
        let source = self.transport.as_ref().map_or("transport", |transport| transport.blame());
        let deadline_error = || {
            let mut error = TransportError::timeout(source, stage);
            error.name = kind.into();
            error.message = format!("{stage} exceeded {kind} deadline of {} ms", allowance.as_millis());
            LinkError::from_transport(stage, error)
        };
        if remaining.is_zero() { return Err(deadline_error()); }
        match self.read_response(stage, remaining).await {
            Err(error) if error.name == "Timeout" => Err(deadline_error()),
            result => result,
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
        self.pending = Vec::new();
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

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    struct Recorder {
        writes: Vec<usize>,
        replies: VecDeque<Vec<u8>>,
        delays: VecDeque<Duration>,
        write_delay: Duration,
    }

    impl BulkTransport for Recorder {
        fn blame(&self) -> &'static str {
            "usb"
        }
        async fn write_all(&mut self, data: Vec<u8>) -> Result<(), TransportError> {
            tokio::time::sleep(self.write_delay).await;
            self.writes.push(data.len());
            Ok(())
        }
        async fn read(&mut self, _max: usize) -> Result<Vec<u8>, TransportError> {
            if let Some(delay) = self.delays.pop_front() {
                tokio::time::sleep(delay).await;
            }
            match self.replies.pop_front() {
                Some(reply) => Ok(reply),
                None => std::future::pending().await,
            }
        }
        async fn close(&mut self) -> Result<(), TransportError> {
            Ok(())
        }
    }

    #[test]
    fn sparse_headers_never_reach_the_device_as_short_transfers() {
        // A sparse image arrives as a 28-byte file header, a 12-byte chunk
        // header and then data; only the final transfer may be short.
        let pieces = [28, 12, MAX_CHUNK, MAX_CHUNK, 12, 500];
        let total: usize = pieces.iter().sum();
        let transport = Recorder {
            writes: Vec::new(),
            replies: VecDeque::from([format!("DATA{total:08x}").into_bytes(), b"OKAY".to_vec()]),
            delays: VecDeque::new(),
            write_delay: Duration::ZERO,
        };
        let mut session = Session::new(transport, "S".into(), 64, Duration::from_secs(5));
        tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap().block_on(async {
            session.begin_download(total as u32).await.unwrap();
            for size in pieces {
                session.write_download(vec![0; size]).await.unwrap();
            }
            session.end_download().await.unwrap();
        });
        let writes = &session.transport.as_ref().unwrap().writes;
        // The download command itself, then the data transfers.
        let data = &writes[1..];
        assert_eq!(data.iter().sum::<usize>(), total);
        let (last, body) = data.split_last().unwrap();
        assert!(body.iter().all(|len| len % TRANSPORT_CHUNK == 0), "{data:?}");
        assert!(*last > 0);
    }
    #[test]
    fn first_probe_and_silent_writes_have_separate_absolute_deadlines() {
        tokio::runtime::Builder::new_current_thread().enable_time()
            .start_paused(true).build().unwrap().block_on(async {
                for (write, expected) in [(false, FIRST_PROBE_TIMEOUT), (true, WRITE_TIMEOUT)] {
                    let transport = Recorder {
                        writes: Vec::new(), replies: VecDeque::new(), delays: VecDeque::new(),
                        write_delay: if write { Duration::ZERO } else { Duration::from_secs(3) },
                    };
                    let mut session = Session::new(transport, "S".into(), 64, Duration::from_secs(15));
                    let start = Instant::now();
                    let error = session.command(if write { "flash:boot" } else { "getvar:product" }, write).await.unwrap_err();
                    assert_eq!(start.elapsed(), expected);
                    assert_eq!(error.name, "OperationDeadline");
                    assert_eq!(error.blame, Blame::Unknown);
                    assert_eq!(error.uncertain, write);
                    assert!(session.is_retired());
                }
            });
    }

    #[test]
    fn info_stream_cannot_extend_absolute_or_no_progress_deadlines() {
        tokio::runtime::Builder::new_current_thread().enable_time()
            .start_paused(true).build().unwrap().block_on(async {
                for (repeat, expected, name) in [
                    (false, Duration::from_secs(60), "OperationDeadline"),
                    (true, Duration::from_secs(20), "NoProgress"),
                ] {
                    let transport = Recorder {
                        writes: Vec::new(),
                        write_delay: Duration::ZERO,
                        replies: std::iter::once(b"OKAY".to_vec()).chain((0..100).map(|i|
                            format!("INFO{}", if repeat { 0 } else { i }).into_bytes())).collect(),
                        delays: std::iter::once(Duration::ZERO).chain(std::iter::repeat_n(Duration::from_secs(5), 100)).collect(),
                    };
                    let mut session = Session::new(transport, "S".into(), 64, Duration::from_secs(15));
                    session.command("getvar:product", false).await.unwrap();
                    let start = Instant::now();
                    let error = session.command("getvar:all", false).await.unwrap_err();
                    assert_eq!(start.elapsed(), expected);
                    assert_eq!(error.name, name);
                    assert!(!error.messages.is_empty());
                    assert!(session.is_retired());
                }
            });
    }
}
