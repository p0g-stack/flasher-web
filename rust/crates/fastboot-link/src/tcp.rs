//! Test-only bulk transport over TCP. Every message is a u32 big-endian frame
//! length followed by that many bytes; the payloads are the real fastboot
//! command/response bytes and, during a download, the real image pieces.
//!
//! This module is behind `tcp-smoke` and is never reachable from the app. It
//! exercises the same `Session` parser, handshake, and length accounting as
//! USB, without a USB device or privileges.

use std::io;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::error::TransportError;
use crate::session::{BulkTransport, Session};

/// The largest frame either direction may carry. A session chunk is at most
/// 1 MiB; responses are tiny. Keep a bound so a peer cannot demand unbounded
/// memory.
pub const MAX_FRAME: usize = 1024 * 1024;

pub struct TcpTransport {
    stream: TcpStream,
}

impl TcpTransport {
    pub fn new(stream: TcpStream) -> Self {
        Self { stream }
    }
}

async fn write_frame<W: AsyncWrite + Unpin>(writer: &mut W, data: &[u8]) -> io::Result<()> {
    let len = u32::try_from(data.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "frame too large"))?;
    writer.write_all(&len.to_be_bytes()).await?;
    writer.write_all(data).await?;
    writer.flush().await
}

async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R, max: usize) -> io::Result<Vec<u8>> {
    let mut header = [0u8; 4];
    reader.read_exact(&mut header).await?;
    let len = u32::from_be_bytes(header) as usize;
    if len > max {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame of {len} bytes exceeds {max}"),
        ));
    }
    let mut data = vec![0u8; len];
    reader.read_exact(&mut data).await?;
    Ok(data)
}

impl BulkTransport for TcpTransport {
    fn blame(&self) -> &'static str {
        "tcp"
    }

    async fn write_all(&mut self, data: Vec<u8>) -> Result<(), TransportError> {
        write_frame(&mut self.stream, &data)
            .await
            .map_err(|error| TransportError::native("tcp", &error, true))
    }

    async fn read(&mut self, max: usize) -> Result<Vec<u8>, TransportError> {
        read_frame(&mut self.stream, max.min(MAX_FRAME))
            .await
            .map_err(|error| TransportError::native("tcp", &error, true))
    }

    async fn close(&mut self) -> Result<(), TransportError> {
        self.stream
            .shutdown()
            .await
            .map_err(|error| TransportError::native("tcp", &error, true))
    }
}

/// A local fastboot responder for the smoke example. It answers the handful of
/// commands the example uses and enforces the download length exactly; it is
/// deliberately not a general fastboot server.
pub struct Responder {
    pub product: String,
    pub serial: String,
    pub fail_download: bool,
}

impl Responder {
    pub async fn serve(self, stream: TcpStream) -> io::Result<()> {
        let mut stream = stream;
        let mut download: Option<(String, u32, u32)> = None;
        loop {
            let frame = match read_frame(&mut stream, MAX_FRAME).await {
                Ok(frame) => frame,
                Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
                Err(error) => return Err(error),
            };
            let mut is_data = false;
            let mut completed: Option<String> = None;
            let mut overrun = false;
            if let Some((part, expected, received)) = download.as_mut() {
                is_data = true;
                let next = u64::from(*received) + frame.len() as u64;
                if next > u64::from(*expected) {
                    overrun = true;
                } else {
                    *received = next as u32;
                    if *received == *expected {
                        completed = Some((*part).clone());
                    }
                }
            }
            if overrun {
                download = None;
                write_frame(&mut stream, b"FAILdata exceeds declared length").await?;
                continue;
            }
            if let Some(part) = completed {
                download = None;
                if self.fail_download {
                    write_frame(&mut stream, b"FAILdownload rejected by responder").await?;
                } else {
                    let reply = format!("OKAY{part}");
                    write_frame(&mut stream, reply.as_bytes()).await?;
                }
                continue;
            }
            if is_data {
                continue;
            }
            let command = match std::str::from_utf8(&frame) {
                Ok(command) => command,
                Err(_) => {
                    write_frame(&mut stream, b"FAILcommand is not utf-8").await?;
                    continue;
                }
            };
            if command == "getvar:product" {
                let info = format!("INFOproduct: {}", self.product);
                write_frame(&mut stream, info.as_bytes()).await?;
                let okay = format!("OKAY{}", self.product);
                write_frame(&mut stream, okay.as_bytes()).await?;
            } else if command == "getvar:serialno" {
                let info = format!("INFOserialno: {}", self.serial);
                write_frame(&mut stream, info.as_bytes()).await?;
                let okay = format!("OKAY{}", self.serial);
                write_frame(&mut stream, okay.as_bytes()).await?;
            } else if command == "getvar:version" {
                write_frame(&mut stream, b"INFOversion: 0.4").await?;
                write_frame(&mut stream, b"OKAY0.4").await?;
            } else if let Some(length) = command.strip_prefix("download:") {
                match u32::from_str_radix(length, 16) {
                    Ok(length) if length > 0 => {
                        download = Some((String::new(), length, 0));
                        let data = format!("DATA{length:08x}");
                        write_frame(&mut stream, data.as_bytes()).await?;
                    }
                    _ => write_frame(&mut stream, b"FAILbad download length").await?,
                }
            } else if let Some(part) = command.strip_prefix("flash:") {
                if part.is_empty() {
                    write_frame(&mut stream, b"FAILmissing partition").await?;
                } else {
                    let okay = format!("OKAYflashed {part}");
                    write_frame(&mut stream, okay.as_bytes()).await?;
                }
            } else if command == "reboot" || command == "reboot-bootloader" {
                write_frame(&mut stream, b"OKAY").await?;
                return Ok(());
            } else {
                write_frame(&mut stream, b"FAILunknown command").await?;
            }
        }
    }
}

/// Drive the example client against a connected responder.
pub async fn client(
    stream: TcpStream,
    serial: &str,
    expect_product: Option<&str>,
) -> Result<String, String> {
    let transport = TcpTransport::new(stream);
    let mut session = Session::new(
        transport,
        serial.to_string(),
        4096,
        Duration::from_secs(10),
    );
    let product = session
        .command("getvar:product", false)
        .await
        .map_err(|e| e.to_string())?;
    if let Some(expected) = expect_product {
        if product.value != expected {
            return Err(format!(
                "product mismatch: device said {:?}, expected {expected:?}",
                product.value
            ));
        }
    } else if product.value.is_empty() {
        return Err("device returned an empty product".to_string());
    }
    let serialno = session
        .command("getvar:serialno", false)
        .await
        .map_err(|e| e.to_string())?;
    if serialno.value != serial {
        return Err(format!(
            "serial mismatch: device said {:?}, expected {serial:?}",
            serialno.value
        ));
    }
    let image: Vec<u8> = (0..8193u32).map(|index| (index % 251) as u8).collect();
    let image_len = image.len();
    session
        .begin_download(image.len() as u32)
        .await
        .map_err(|e| e.to_string())?;
    // Each piece moves into the session; no copy of the image is made.
    let mut rest = image;
    while !rest.is_empty() {
        let tail = rest.split_off(rest.len().min(4096));
        session
            .write_download(rest)
            .await
            .map_err(|e| e.to_string())?;
        rest = tail;
    }
    let finished = session
        .end_download()
        .await
        .map_err(|e| e.to_string())?;
    let flashed = session
        .command("flash:boot", true)
        .await
        .map_err(|e| e.to_string())?;
    session.close().await.map_err(|e| e.to_string())?;
    Ok(format!(
        "product={} serial={} bytes={} end={} flash={}",
        product.value,
        serialno.value,
        image_len,
        finished.value,
        flashed.value
    ))
}
