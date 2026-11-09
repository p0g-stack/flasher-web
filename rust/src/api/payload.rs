//! Android update payload (`CrAU`) manifest parsing and operation decoding.
//!
//! Field numbers follow AOSP `system/update_engine/update_metadata.proto`.
//! The parsing, operation decoding and SHA-256 code is the otaripper
//! (Apache-2.0) port in the reusable `ota-payload` crate; this module is the
//! frb-facing wrapper and keeps the public Dart API, converting the crate's
//! plain Rust types.

use anyhow::{bail, ensure};
use flutter_rust_bridge::frb;

/// Errors are plain messages; callers show them next to the failing step.
type Result<T, E = anyhow::Error> = std::result::Result<T, E>;

/// Where a payload's manifest and data start, from its first 24 bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PayloadHeader {
    pub manifest_len: u64,
    pub signature_len: u64,
    pub data_start: u64,
}

impl From<ota_payload::PayloadHeader> for PayloadHeader {
    fn from(header: ota_payload::PayloadHeader) -> Self {
        Self {
            manifest_len: header.manifest_len,
            signature_len: header.signature_len,
            data_start: header.data_start,
        }
    }
}

/// A partition image in the payload, in manifest order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PartitionInfo {
    pub name: String,
    pub size: u64,
    pub op_count: u32,
    /// SHA-256 of the complete image, lowercase hex, when the manifest has one.
    pub sha256: Option<String>,
}

impl From<ota_payload::PartitionInfo> for PartitionInfo {
    fn from(info: ota_payload::PartitionInfo) -> Self {
        Self {
            name: info.name,
            size: info.size,
            op_count: info.op_count,
            sha256: info.sha256,
        }
    }
}

/// Destination blocks of one operation, in bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Extent {
    pub offset: u64,
    pub length: u64,
}

impl From<ota_payload::Extent> for Extent {
    fn from(extent: ota_payload::Extent) -> Self {
        Self { offset: extent.offset, length: extent.length }
    }
}

/// One install operation, with its data offset relative to the payload data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpInfo {
    pub index: u32,
    pub kind: u32,
    pub data_offset: u64,
    pub data_length: u64,
    /// The manifest's SHA-256 of the operation data, raw bytes, when present.
    pub data_sha256: Option<Vec<u8>>,
    pub dst: Vec<Extent>,
}

impl From<ota_payload::OpInfo> for OpInfo {
    fn from(info: ota_payload::OpInfo) -> Self {
        Self {
            index: info.index,
            kind: info.kind,
            data_offset: info.data_offset,
            data_length: info.data_length,
            data_sha256: info.data_sha256,
            dst: info.dst.into_iter().map(Extent::from).collect(),
        }
    }
}

/// Validate the fixed-size payload header against the file length.
#[frb(sync)]
pub fn payload_header(head24: Vec<u8>, payload_size: u64) -> Result<PayloadHeader> {
    ota_payload::payload_header(&head24, payload_size).map(PayloadHeader::from)
}

/// A payload manifest, parsed once and queried by the core.
#[frb(opaque)]
pub struct Manifest {
    inner: ota_payload::Manifest,
}

impl Manifest {
    /// Parse the bounded manifest the header points at.
    #[frb(sync)]
    pub fn parse(manifest: Vec<u8>) -> Result<Manifest> {
        Ok(Manifest { inner: ota_payload::Manifest::parse(&manifest)? })
    }

    #[frb(sync)]
    pub fn block_size(&self) -> u64 {
        self.inner.block_size()
    }

    /// Manifest minor version; zstd operations appear from version 10 on.
    #[frb(sync)]
    pub fn minor_version(&self) -> u32 {
        self.inner.minor_version()
    }

    /// Partitions in manifest order, with their image hash when present.
    #[frb(sync)]
    pub fn partitions(&self) -> Vec<PartitionInfo> {
        self.inner.partitions().into_iter().map(PartitionInfo::from).collect()
    }

    /// Operations of one partition, data offsets relative to the payload data.
    #[frb(sync)]
    pub fn operations(&self, name: String) -> Vec<OpInfo> {
        self.inner.operations(&name).into_iter().map(OpInfo::from).collect()
    }

    /// Bytes an operation writes, in destination order.
    ///
    /// `data` is the operation's `data_length` bytes from the payload. The
    /// op's data hash is checked first, as otaripper does; ZERO and DISCARD
    /// return nothing, and the caller leaves those extents zeroed.
    #[frb(sync)]
    pub fn decode_op(&self, name: String, index: u32, data: Vec<u8>) -> Result<Vec<u8>> {
        self.inner.decode_op(&name, index, data)
    }

    /// Port of upstream `verify_full_payload`: this manifest describes a
    /// complete image for every partition, or it needs an older image.
    ///
    /// Returns the number of partitions checked.
    #[frb(sync)]
    pub fn verify_full(&self) -> Result<u32> {
        self.inner.verify_full()
    }

    /// Full, hash-authenticated operations small enough for virtual reads.
    #[frb(sync)]
    pub fn verify_virtual(&self, max_operation_bytes: u64) -> Result<()> {
        self.inner.verify_virtual(max_operation_bytes)
    }
}

/// Bytes one operation writes, decoded outside its manifest.
///
/// The same decode as [Manifest::decode_op] for a decode worker that holds
/// only the operation: `kind`, the payload `data`, the manifest's data
/// SHA-256 (checked first), the bytes its extents hold, the block size, and
/// `what` to name it in errors.
#[frb(sync)]
pub fn decode_operation(
    kind: u32,
    data: Vec<u8>,
    data_sha256: Option<Vec<u8>>,
    total: u64,
    block_size: u64,
    what: String,
) -> Result<Vec<u8>> {
    ota_payload::decode_operation(kind, data, data_sha256.as_deref(), total, block_size, &what)
}

/// Streaming SHA-256 with an explicit zero run for holes in sparse images.
#[frb(opaque)]
pub struct Sha256Hasher {
    inner: ota_payload::Sha256Hasher,
}

impl Sha256Hasher {
    #[frb(sync)]
    pub fn new() -> Sha256Hasher {
        Sha256Hasher { inner: ota_payload::Sha256Hasher::new() }
    }

    #[frb(sync)]
    pub fn update(&mut self, bytes: Vec<u8>) {
        self.inner.update(&bytes);
    }

    /// Feed `n` zero bytes without allocating them.
    #[frb(sync)]
    pub fn update_zeros(&mut self, n: u64) {
        self.inner.update_zeros(n);
    }

    /// Lowercase hex of everything fed so far; the hasher can keep going.
    #[frb(sync)]
    pub fn finish_hex(&self) -> String {
        self.inner.finish_hex()
    }
}

/// Incremental gzip decoder (RFC 1952), as the bloat assets are gzipped.
#[frb(opaque)]
pub struct GzipDecoder {
    stage: GzipStage,
    pending: Vec<u8>,
    inflate: Option<Box<miniz_oxide::inflate::stream::InflateState>>,
    crc: crc32fast::Hasher,
    produced: u64,
    error: Option<String>,
    finished: bool,
}

#[derive(PartialEq, Eq)]
enum GzipStage {
    Header,
    Deflate,
    Trailer,
}

fn gzip_header_len(data: &[u8]) -> Result<Option<usize>> {
    if data.is_empty() {
        return Ok(None);
    }
    if data[0] != 0x1f {
        bail!("bloat data is not a gzip stream");
    }
    if data.len() >= 2 && data[1] != 0x8b {
        bail!("bloat data is not a gzip stream");
    }
    if data.len() >= 3 && data[2] != 8 {
        bail!("gzip data uses an unsupported compression method");
    }
    if data.len() < 10 {
        return Ok(None);
    }
    let flags = data[3];
    ensure!(flags & 0xe0 == 0, "gzip header uses reserved flags");
    let mut pos = 10;
    if flags & 0x04 != 0 {
        if data.len() < pos + 2 {
            return Ok(None);
        }
        let len = u16::from_le_bytes([data[pos], data[pos + 1]]) as usize;
        pos += 2;
        if data.len() < pos + len {
            return Ok(None);
        }
        pos += len;
    }
    for mask in [0x08u8, 0x10] {
        if flags & mask != 0 {
            let Some(end) = data[pos..].iter().position(|&byte| byte == 0) else {
                return Ok(None);
            };
            pos += end + 1;
        }
    }
    if flags & 0x02 != 0 {
        if data.len() < pos + 2 {
            return Ok(None);
        }
        pos += 2;
    }
    Ok(Some(pos))
}

impl GzipDecoder {
    #[frb(sync)]
    pub fn new() -> GzipDecoder {
        GzipDecoder {
            stage: GzipStage::Header,
            pending: Vec::new(),
            inflate: None,
            crc: crc32fast::Hasher::new(),
            produced: 0,
            error: None,
            finished: false,
        }
    }

    /// Decode more input; bytes that finish a member come out now.
    #[frb(sync)]
    pub fn push(&mut self, bytes: Vec<u8>) -> Vec<u8> {
        if self.finished || self.error.is_some() {
            return Vec::new();
        }
        self.pending.extend_from_slice(&bytes);
        let mut out = Vec::new();
        if let Err(error) = self.drive(&mut out) {
            self.error = Some(format!("{error:#}"));
        }
        out
    }

    /// Bytes left over, or the error that ended decoding early.
    #[frb(sync)]
    pub fn finish(&mut self) -> Result<Vec<u8>> {
        if let Some(error) = self.error.take() {
            self.finished = true;
            bail!(error);
        }
        ensure!(!self.finished, "gzip decoder already finished");
        self.finished = true;
        let mut out = Vec::new();
        self.drive(&mut out)?;
        ensure!(
            self.stage == GzipStage::Header && self.pending.is_empty(),
            "gzip stream ended before its trailer"
        );
        Ok(out)
    }

    fn drive(&mut self, out: &mut Vec<u8>) -> Result<()> {
        loop {
            match self.stage {
                GzipStage::Header => {
                    let Some(len) = gzip_header_len(&self.pending)? else {
                        return Ok(());
                    };
                    self.pending.drain(..len);
                    self.inflate = Some(miniz_oxide::inflate::stream::InflateState::new_boxed(
                        miniz_oxide::DataFormat::Raw,
                    ));
                    self.crc = crc32fast::Hasher::new();
                    self.produced = 0;
                    self.stage = GzipStage::Deflate;
                }
                GzipStage::Deflate => {
                    let mut inflate = self.inflate.take().expect("deflate state");
                    let mut buffer = vec![0u8; 64 * 1024];
                    let mut ended = false;
                    loop {
                        let result = miniz_oxide::inflate::stream::inflate(
                            &mut inflate,
                            &self.pending,
                            &mut buffer,
                            miniz_oxide::MZFlush::None,
                        );
                        let written = result.bytes_written;
                        self.pending.drain(..result.bytes_consumed);
                        out.extend_from_slice(&buffer[..written]);
                        self.crc.update(&buffer[..written]);
                        self.produced += written as u64;
                        match result.status {
                            Ok(miniz_oxide::MZStatus::StreamEnd) => {
                                ended = true;
                                break;
                            }
                            Ok(miniz_oxide::MZStatus::Ok) => {
                                if result.bytes_consumed == 0 && written == 0 {
                                    break;
                                }
                            }
                            Ok(miniz_oxide::MZStatus::NeedDict) => {
                                bail!("gzip deflate stream needs a preset dictionary")
                            }
                            Err(miniz_oxide::MZError::Buf) => {
                                if written == 0 {
                                    break;
                                }
                            }
                            Err(error) => bail!("invalid gzip deflate stream: {error:?}"),
                        }
                    }
                    if !ended {
                        self.inflate = Some(inflate);
                        return Ok(());
                    }
                    self.stage = GzipStage::Trailer;
                }
                GzipStage::Trailer => {
                    if self.pending.len() < 8 {
                        return Ok(());
                    }
                    let expected_crc = u32::from_le_bytes(self.pending[0..4].try_into().expect("four bytes"));
                    let expected_size =
                        u32::from_le_bytes(self.pending[4..8].try_into().expect("four bytes"));
                    ensure!(
                        expected_crc == self.crc.clone().finalize(),
                        "gzip checksum mismatch"
                    );
                    ensure!(
                        expected_size == self.produced as u32,
                        "gzip length mismatch"
                    );
                    self.pending.drain(..8);
                    self.stage = GzipStage::Header;
                    if self.pending.is_empty() {
                        return Ok(());
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn gzip(data: &[u8]) -> Vec<u8> {
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(data).unwrap();
        encoder.finish().unwrap()
    }

    #[test]
    fn gzip_decodes_across_chunk_boundaries() {
        let plain: Vec<u8> = (0..200_000).map(|i| (i * 7 % 253) as u8).collect();
        let compressed = gzip(&plain);
        let mut decoder = GzipDecoder::new();
        let mut out = Vec::new();
        for chunk in [1usize, 2, 3, 10, 100, 1000, 60_000] {
            let mut at = 0;
            while at < compressed.len() {
                let end = (at + chunk).min(compressed.len());
                out.extend(decoder.push(compressed[at..end].to_vec()));
                at = end;
            }
            if out.len() == plain.len() {
                break;
            }
        }
        out.extend(decoder.finish().unwrap());
        assert_eq!(out, plain);
    }

    #[test]
    fn gzip_handles_header_options_and_members() {
        let mut member = Vec::new();
        member.extend_from_slice(&[0x1f, 0x8b, 8, 0x1e]); // FEXTRA|FNAME|FCOMMENT|FHCRC
        member.extend_from_slice(&[0, 0, 0, 0, 0, 255]);
        member.extend_from_slice(&4u16.to_le_bytes());
        member.extend_from_slice(b"NAME");
        member.extend_from_slice(b"file.txt\0");
        member.extend_from_slice(b"comment\0");
        member.extend_from_slice(&[0x5a, 0x5a]);
        let deflated = {
            let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::fast());
            encoder.write_all(b"hello").unwrap();
            encoder.finish().unwrap()
        };
        member.extend_from_slice(&deflated);
        let mut crc = crc32fast::Hasher::new();
        crc.update(b"hello");
        member.extend_from_slice(&crc.finalize().to_le_bytes());
        member.extend_from_slice(&5u32.to_le_bytes());
        member.extend_from_slice(&gzip(b" world"));

        let mut decoder = GzipDecoder::new();
        let mut out = decoder.push(member);
        out.extend(decoder.finish().unwrap());
        assert_eq!(out, b"hello world");
    }

    #[test]
    fn gzip_reports_truncation_and_bad_checksum() {
        let plain = b"payload bytes that need checking".to_vec();
        let compressed = gzip(&plain);
        let mut decoder = GzipDecoder::new();
        let _ = decoder.push(compressed[..compressed.len() - 4].to_vec());
        assert!(decoder.finish().is_err());

        let mut bad = compressed.clone();
        let crc_at = bad.len() - 8;
        bad[crc_at] ^= 0xff;
        let mut decoder = GzipDecoder::new();
        let _ = decoder.push(bad);
        assert!(decoder.finish().is_err());

        let mut decoder = GzipDecoder::new();
        assert!(decoder.push(b"not gzip".to_vec()).is_empty());
        assert!(decoder.finish().is_err());
    }
}
