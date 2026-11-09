//! Android update payload (`CrAU`) manifest parsing and operation decoding.
//!
//! Field numbers follow AOSP `system/update_engine/update_metadata.proto`.
//! Parsing and operation handling are a port of otaripper (Apache-2.0)
//! `src/payload.rs`, `src/cmd/extractor.rs` and `src/proto/`, and of the
//! upstream Python `flasher_builder/payload.py` full-OTA check.
//!
//! This crate has no flutter_rust_bridge dependency and does no I/O: callers
//! hand it the header, manifest and operation bytes they already hold. The
//! codecs are pure Rust, so it builds for native and single-threaded wasm.

use std::io::Read;

use anyhow::{bail, ensure, Context};
use sha2::{Digest, Sha256};

/// Errors are plain messages; callers show them next to the failing step.
type Result<T, E = anyhow::Error> = std::result::Result<T, E>;

const PAYLOAD_MAGIC: &[u8] = b"CrAU";
const SUPPORTED_VERSION_MAX: u64 = 2;
const MAX_METADATA_SIG_SIZE: u64 = 64 * 1024 * 1024;
const MAX_MANIFEST_SIZE: u64 = 256 * 1024 * 1024;
const DEFAULT_BLOCK_SIZE: u64 = 4096;

/// Operation types from `InstallOperation.Type`.
const OP_REPLACE: u32 = 0;
const OP_REPLACE_BZ: u32 = 1;
const OP_ZERO: u32 = 6;
const OP_DISCARD: u32 = 7;
const OP_REPLACE_XZ: u32 = 8;
const OP_REPLACE_ZSTD: u32 = 14;

/// Where a payload's manifest and data start, from its first 24 bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PayloadHeader {
    pub manifest_len: u64,
    pub signature_len: u64,
    pub data_start: u64,
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

/// Destination blocks of one operation, in bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Extent {
    pub offset: u64,
    pub length: u64,
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

/// Validate the fixed-size payload header against the file length.
pub fn payload_header(head24: &[u8], payload_size: u64) -> Result<PayloadHeader> {
    ensure!(head24.len() >= 20, "the payload header is incomplete");
    ensure!(&head24[0..4] == PAYLOAD_MAGIC, "not an Android update payload");
    let version = u64::from_be_bytes(head24[4..12].try_into().expect("eight bytes"));
    ensure!(
        version <= SUPPORTED_VERSION_MAX,
        "payload format version {version} is newer than this build supports"
    );
    let manifest_len = u64::from_be_bytes(head24[12..20].try_into().expect("eight bytes"));
    ensure!(
        manifest_len <= MAX_MANIFEST_SIZE,
        "the payload manifest size is out of range"
    );

    let (header_size, signature_len) = if version >= 2 {
        ensure!(head24.len() >= 24, "the payload header is incomplete");
        let signature_len = u32::from_be_bytes(head24[20..24].try_into().expect("four bytes")) as u64;
        ensure!(
            signature_len <= MAX_METADATA_SIG_SIZE,
            "the payload metadata signature size is out of range"
        );
        (24u64, signature_len)
    } else {
        (20u64, 0u64)
    };

    let data_start = header_size
        .checked_add(manifest_len)
        .and_then(|total| total.checked_add(signature_len))
        .context("the payload header sizes overflow")?;
    ensure!(
        data_start <= payload_size,
        "the payload is missing data at the end (needs {data_start} bytes, has {payload_size})"
    );
    Ok(PayloadHeader { manifest_len, signature_len, data_start })
}

/// A payload manifest, parsed once and queried by the core.
pub struct Manifest {
    block_size: u64,
    minor_version: u32,
    partitions: Vec<Partition>,
}

struct Partition {
    name: String,
    size: u64,
    hash: Option<Vec<u8>>,
    ops: Vec<Op>,
}

struct Op {
    kind: u32,
    data_offset: u64,
    data_length: u64,
    data_hash: Option<Vec<u8>>,
    dst: Vec<RawExtent>,
    src_extents_present: bool,
    src_length: u64,
    src_hash: Option<Vec<u8>>,
}

#[derive(Clone, Copy)]
struct RawExtent {
    start_block: u64,
    num_blocks: u64,
}

/// One parsed protobuf value we care about.
enum Field<'a> {
    Varint(u64),
    Fixed,
    Bytes(&'a [u8]),
}

/// A bounds-checked protobuf reader: groups are not part of update_metadata.
struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, pos: 0 }
    }

    fn varint(&mut self) -> Result<u64> {
        let mut value = 0u64;
        for shift in (0..70).step_by(7) {
            let byte = *self
                .bytes
                .get(self.pos)
                .context("truncated payload manifest integer")?;
            self.pos += 1;
            if shift == 63 && byte > 1 {
                bail!("payload manifest integer overflows 64 bits");
            }
            value |= u64::from(byte & 0x7f) << shift;
            if byte < 0x80 {
                return Ok(value);
            }
        }
        bail!("payload manifest integer is longer than 10 bytes")
    }

    fn take(&mut self, len: usize) -> Result<&'a [u8]> {
        let end = self.pos.checked_add(len).context("payload manifest offset overflow")?;
        let bytes = self
            .bytes
            .get(self.pos..end)
            .context("truncated payload manifest field")?;
        self.pos = end;
        Ok(bytes)
    }

    fn next(&mut self) -> Result<Option<(u32, Field<'a>)>> {
        if self.pos >= self.bytes.len() {
            return Ok(None);
        }
        let tag = self.varint()?;
        let field = u32::try_from(tag >> 3).context("payload manifest field number too large")?;
        ensure!(field != 0 && field <= (1 << 29) - 1, "invalid payload manifest field number");
        let value = match tag & 7 {
            0 => Field::Varint(self.varint()?),
            1 => {
                self.take(8)?;
                Field::Fixed
            }
            2 => {
                let len = usize::try_from(self.varint()?).context("payload manifest field too large")?;
                Field::Bytes(self.take(len)?)
            }
            5 => {
                self.take(4)?;
                Field::Fixed
            }
            wire => bail!("unsupported payload manifest wire type {wire}"),
        };
        Ok(Some((field, value)))
    }
}

fn varint_of(value: Field<'_>, what: &str) -> Result<u64> {
    match value {
        Field::Varint(value) => Ok(value),
        _ => bail!("payload manifest {what} has the wrong encoding"),
    }
}

fn bytes_of<'a>(value: Field<'a>, what: &str) -> Result<&'a [u8]> {
    match value {
        Field::Bytes(bytes) => Ok(bytes),
        _ => bail!("payload manifest {what} has the wrong encoding"),
    }
}

fn parse_extent(bytes: &[u8]) -> Result<RawExtent> {
    let mut reader = Reader::new(bytes);
    let mut start_block = None;
    let mut num_blocks = None;
    while let Some((field, value)) = reader.next()? {
        match field {
            1 => start_block = Some(varint_of(value, "extent start block")?),
            2 => num_blocks = Some(varint_of(value, "extent block count")?),
            _ => {}
        }
    }
    Ok(RawExtent {
        start_block: start_block.context("payload extent has no start block")?,
        num_blocks: num_blocks.context("payload extent has no block count")?,
    })
}

fn parse_operation(bytes: &[u8]) -> Result<Op> {
    let mut reader = Reader::new(bytes);
    let mut kind = None;
    let mut data_offset = 0;
    let mut data_length = 0;
    let mut data_hash = None;
    let mut dst = Vec::new();
    let mut src_extents_present = false;
    let mut src_length = 0;
    let mut src_hash = None;
    while let Some((field, value)) = reader.next()? {
        match field {
            1 => {
                let raw = varint_of(value, "operation type")?;
                kind = Some(u32::try_from(raw).context("operation type too large")?);
            }
            2 => data_offset = varint_of(value, "operation data offset")?,
            3 => data_length = varint_of(value, "operation data length")?,
            4 => {
                src_extents_present = true;
                parse_extent(bytes_of(value, "source extent")?)?;
            }
            5 => src_length = varint_of(value, "operation source length")?,
            6 => dst.push(parse_extent(bytes_of(value, "destination extent")?)?),
            8 => data_hash = Some(bytes_of(value, "operation data hash")?.to_vec()),
            9 => src_hash = Some(bytes_of(value, "operation source hash")?.to_vec()),
            _ => {}
        }
    }
    Ok(Op {
        kind: kind.context("payload operation has no type")?,
        data_offset,
        data_length,
        data_hash,
        dst,
        src_extents_present,
        src_length,
        src_hash,
    })
}

fn parse_partition(bytes: &[u8]) -> Result<Partition> {
    let mut reader = Reader::new(bytes);
    let mut name = None;
    let mut size = 0;
    let mut hash = None;
    let mut ops = Vec::new();
    while let Some((field, value)) = reader.next()? {
        match field {
            1 => {
                let raw = bytes_of(value, "partition name")?;
                let text = std::str::from_utf8(raw).context("partition name is not UTF-8")?;
                ensure!(!text.is_empty(), "payload partition has an empty name");
                name = Some(text.to_owned());
            }
            7 => {
                let mut info = Reader::new(bytes_of(value, "partition info")?);
                while let Some((field, value)) = info.next()? {
                    match field {
                        1 => size = varint_of(value, "partition size")?,
                        2 => hash = Some(bytes_of(value, "partition hash")?.to_vec()),
                        _ => {}
                    }
                }
            }
            8 => ops.push(parse_operation(bytes_of(value, "install operation")?)?),
            _ => {}
        }
    }
    Ok(Partition {
        name: name.context("payload partition has no name")?,
        size,
        hash,
        ops,
    })
}

fn parse_manifest(bytes: &[u8]) -> Result<Manifest> {
    let mut reader = Reader::new(bytes);
    let mut block_size = DEFAULT_BLOCK_SIZE;
    let mut minor_version = 0;
    let mut partitions = Vec::new();
    let mut names = std::collections::HashSet::new();
    while let Some((field, value)) = reader.next()? {
        match field {
            3 => {
                block_size = varint_of(value, "block size")?;
                ensure!(block_size > 0, "payload block size is zero");
            }
            12 => {
                minor_version =
                    u32::try_from(varint_of(value, "minor version")?).context("minor version too large")?;
            }
            13 => {
                let partition = parse_partition(bytes_of(value, "partition")?)?;
                ensure!(
                    names.insert(partition.name.clone()),
                    "payload has more than one partition named {:?}",
                    partition.name
                );
                partitions.push(partition);
            }
            _ => {}
        }
    }
    ensure!(block_size > 0, "payload block size is zero");
    Ok(Manifest { block_size, minor_version, partitions })
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(text, "{byte:02x}");
    }
    text
}

fn read_all(mut reader: impl Read, codec: &str, limit: u64) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    reader.by_ref().take(limit)
        .read_to_end(&mut out)
        .with_context(|| format!("invalid {codec} operation data"))?;
    let mut extra = [0u8; 1];
    let more = reader.read(&mut extra)
        .with_context(|| format!("invalid {codec} operation data"))?;
    ensure!(more == 0, "{codec} operation exceeds its destination extents");
    Ok(out)
}

impl Manifest {
    /// Parse the bounded manifest the header points at.
    pub fn parse(manifest: &[u8]) -> Result<Manifest> {
        parse_manifest(manifest)
    }

    pub fn block_size(&self) -> u64 {
        self.block_size
    }

    /// Manifest minor version; zstd operations appear from version 10 on.
    pub fn minor_version(&self) -> u32 {
        self.minor_version
    }

    /// Partitions in manifest order, with their image hash when present.
    pub fn partitions(&self) -> Vec<PartitionInfo> {
        self.partitions
            .iter()
            .map(|partition| PartitionInfo {
                name: partition.name.clone(),
                size: partition.size,
                op_count: partition.ops.len() as u32,
                sha256: partition
                    .hash
                    .as_ref()
                    .filter(|hash| !hash.is_empty())
                    .map(|hash| hex(hash)),
            })
            .collect()
    }

    /// Operations of one partition, data offsets relative to the payload data.
    pub fn operations(&self, name: &str) -> Vec<OpInfo> {
        let Some(partition) = self.partitions.iter().find(|held| held.name == name) else {
            return Vec::new();
        };
        partition
            .ops
            .iter()
            .enumerate()
            .map(|(index, op)| OpInfo {
                index: index as u32,
                kind: op.kind,
                data_offset: op.data_offset,
                data_length: op.data_length,
                data_sha256: op.data_hash.clone(),
                dst: op
                    .dst
                    .iter()
                    .map(|extent| Extent {
                        offset: extent.start_block.saturating_mul(self.block_size),
                        length: extent.num_blocks.saturating_mul(self.block_size),
                    })
                    .collect(),
            })
            .collect()
    }

    /// Bytes an operation writes, in destination order.
    ///
    /// `data` is the operation's `data_length` bytes from the payload. The
    /// op's data hash is checked first, as otaripper does; ZERO and DISCARD
    /// return nothing, and the caller leaves those extents zeroed.
    pub fn decode_op(&self, name: &str, index: u32, data: Vec<u8>) -> Result<Vec<u8>> {
        let partition = self
            .partitions
            .iter()
            .find(|held| held.name == name)
            .with_context(|| format!("payload has no partition named {name:?}"))?;
        let op = partition
            .ops
            .get(index as usize)
            .with_context(|| format!("partition {name:?} has no operation {index}"))?;
        ensure!(
            data.len() as u64 == op.data_length,
            "operation {index} of {name:?} takes {} bytes of data, got {}",
            op.data_length,
            data.len()
        );
        validate_extents(self, partition)?;
        let total = extent_bytes(self, op)?;
        let what = format!("operation {index} of {name:?}");
        decode_operation(op.kind, data, op.data_hash.as_deref(), total, self.block_size, &what)
    }

    /// Validate the stronger contract required by in-place virtual reads.
    /// Missing operation hashes fail closed; callers may use normal extraction.
    pub fn verify_virtual(&self, max_operation_bytes: u64) -> Result<()> {
        self.verify_full()?;
        for partition in &self.partitions {
            for (index, op) in partition.ops.iter().enumerate() {
                ensure!(
                    op.data_length <= max_operation_bytes,
                    "operation {index} of {:?} exceeds the virtual encoded-operation limit",
                    partition.name
                );
                if !matches!(op.kind, OP_ZERO | OP_DISCARD) {
                    ensure!(
                        extent_bytes(self, op)? <= max_operation_bytes,
                        "operation {index} of {:?} exceeds the virtual decoded-operation limit",
                        partition.name
                    );
                }
                if op.data_length > 0 || !matches!(op.kind, OP_ZERO | OP_DISCARD) {
                    ensure!(
                        op.data_hash.as_ref().is_some_and(|hash| hash.len() == 32),
                        "operation {index} of {:?} has no data SHA-256; use a normal folder build",
                        partition.name
                    );
                }
            }
        }
        Ok(())
    }

    /// Port of upstream `verify_full_payload`: this manifest describes a
    /// complete image for every partition, or it needs an older image.
    ///
    /// Returns the number of partitions checked.
    pub fn verify_full(&self) -> Result<u32> {
        ensure!(self.block_size > 0, "invalid payload block size");
        ensure!(!self.partitions.is_empty(), "payload has no partition images");
        for partition in &self.partitions {
            ensure!(
                partition.size > 0,
                "payload partition {:?} has no image size",
                partition.name
            );
            let mut spans = Vec::new();
            for (index, op) in partition.ops.iter().enumerate() {
                ensure!(
                    matches!(
                        op.kind,
                        OP_REPLACE | OP_REPLACE_BZ | OP_ZERO | OP_DISCARD | OP_REPLACE_XZ | OP_REPLACE_ZSTD
                    ),
                    "operation {index} of {:?} needs the source partition (type {})",
                    partition.name,
                    op.kind
                );
                ensure!(
                    !op.src_extents_present,
                    "operation {index} of {:?} reads source extents",
                    partition.name
                );
                ensure!(
                    op.src_length == 0,
                    "operation {index} of {:?} reads source bytes",
                    partition.name
                );
                ensure!(
                    op.src_hash.as_ref().is_none_or(|hash| hash.is_empty()),
                    "operation {index} of {:?} has a source hash",
                    partition.name
                );
                op.data_offset
                    .checked_add(op.data_length)
                    .with_context(|| {
                        format!("operation {index} of {:?} has an invalid data range", partition.name)
                    })?;
                for extent in &op.dst {
                    ensure!(
                        extent.num_blocks > 0,
                        "operation {index} of {:?} has an empty destination extent",
                        partition.name
                    );
                    let end = extent
                        .start_block
                        .checked_add(extent.num_blocks)
                        .context("payload extent overflows its block range")?;
                    spans.push((extent.start_block, end));
                }
            }
            spans.sort_unstable();
            let mut end = 0u64;
            for (first, last) in spans {
                ensure!(
                    first == end,
                    "payload partition {:?} does not contain a complete image",
                    partition.name
                );
                end = last;
            }
            ensure!(
                end == partition.size.div_ceil(self.block_size),
                "payload partition {:?} does not contain a complete image",
                partition.name
            );
        }
        Ok(self.partitions.len() as u32)
    }
}

/// Bytes one full-OTA operation writes, without its manifest.
///
/// This is [Manifest::decode_op] after the lookup, for a worker that was
/// handed one operation: its `kind`, payload `data`, the data SHA-256 from the
/// manifest (checked first when present), the bytes its destination extents
/// hold and the payload block size. `what` names the operation in errors.
/// ZERO and DISCARD return nothing; the caller leaves those extents zeroed.
pub fn decode_operation(
    kind: u32,
    data: Vec<u8>,
    data_sha256: Option<&[u8]>,
    total: u64,
    block_size: u64,
    what: &str,
) -> Result<Vec<u8>> {
    ensure!(block_size > 0, "invalid payload block size");
    if let Some(expected) = data_sha256 {
        let actual = Sha256::digest(&data);
        ensure!(actual.as_slice() == expected, "{what} fails its data SHA-256 check");
    }
    let out = match kind {
        OP_REPLACE => data,
        OP_REPLACE_BZ => read_all(bzip2::read::BzDecoder::new(&data[..]), "bzip2", total)?,
        OP_REPLACE_XZ => read_all(lzma_rust2::XzReader::new(&data[..], true), "xz", total)?,
        OP_REPLACE_ZSTD => {
            let decoder = ruzstd::decoding::StreamingDecoder::new(&data[..])
                .context("invalid zstd operation data")?;
            read_all(decoder, "zstd", total)?
        }
        OP_ZERO | OP_DISCARD => return Ok(Vec::new()),
        other => bail!("{what} has type {other}, which a full OTA cannot apply"),
    };

    // otaripper checks that the decoded data fills the extents up to a
    // block boundary; the remainder of the last block stays zero.
    let aligned = (out.len() as u64).div_ceil(block_size) * block_size;
    ensure!(
        aligned == total,
        "{what} decodes {} bytes but its extents hold {total}",
        out.len()
    );
    Ok(out)
}

/// Byte spans of one partition's operations, with bounds and overlap checks.
fn validate_extents(manifest: &Manifest, partition: &Partition) -> Result<()> {
    let mut spans = Vec::new();
    for (index, op) in partition.ops.iter().enumerate() {
        for extent in &op.dst {
            ensure!(
                extent.num_blocks > 0,
                "operation {index} of {:?} has an empty destination extent",
                partition.name
            );
            let start = extent
                .start_block
                .checked_mul(manifest.block_size)
                .with_context(|| format!("operation {index} of {:?} overflows", partition.name))?;
            let length = extent
                .num_blocks
                .checked_mul(manifest.block_size)
                .with_context(|| format!("operation {index} of {:?} overflows", partition.name))?;
            let end = start
                .checked_add(length)
                .with_context(|| format!("operation {index} of {:?} overflows", partition.name))?;
            ensure!(
                end <= partition.size,
                "operation {index} of {:?} writes at {start}..{end}, past the {} byte image",
                partition.name,
                partition.size
            );
            spans.push((start, end));
        }
    }
    spans.sort_unstable();
    for pair in spans.windows(2) {
        ensure!(
            pair[1].0 >= pair[0].1,
            "partition {:?} has overlapping destination extents ({} < {})",
            partition.name,
            pair[1].0,
            pair[0].1
        );
    }
    Ok(())
}

fn extent_bytes(manifest: &Manifest, op: &Op) -> Result<u64> {
    op.dst.iter().try_fold(0u64, |total, extent| {
        let length = extent
            .num_blocks
            .checked_mul(manifest.block_size)
            .context("payload extent length overflow")?;
        total.checked_add(length).context("payload extent size overflow")
    })
}

/// Streaming SHA-256 with an explicit zero run for holes in sparse images.
pub struct Sha256Hasher {
    hasher: Sha256,
}

impl Sha256Hasher {
    pub fn new() -> Sha256Hasher {
        Sha256Hasher { hasher: Sha256::new() }
    }

    pub fn update(&mut self, bytes: &[u8]) {
        self.hasher.update(bytes);
    }

    /// Feed `n` zero bytes without allocating them.
    pub fn update_zeros(&mut self, n: u64) {
        const CHUNK: [u8; 64 * 1024] = [0; 64 * 1024];
        let mut left = n;
        while left > 0 {
            let take = left.min(CHUNK.len() as u64) as usize;
            self.hasher.update(&CHUNK[..take]);
            left -= take as u64;
        }
    }

    /// Lowercase hex of everything fed so far; the hasher can keep going.
    pub fn finish_hex(&self) -> String {
        hex(self.hasher.clone().finalize().as_slice())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    const BLOCK: u64 = 4096;

    fn varint(mut value: u64) -> Vec<u8> {
        let mut out = Vec::new();
        loop {
            let byte = (value & 0x7f) as u8;
            value >>= 7;
            if value == 0 {
                out.push(byte);
                return out;
            }
            out.push(byte | 0x80);
        }
    }

    fn field_varint(field: u32, value: u64) -> Vec<u8> {
        let mut out = varint(u64::from(field) << 3);
        out.extend(varint(value));
        out
    }

    fn field_bytes(field: u32, bytes: &[u8]) -> Vec<u8> {
        let mut out = varint((u64::from(field) << 3) | 2);
        out.extend(varint(bytes.len() as u64));
        out.extend_from_slice(bytes);
        out
    }

    fn extent_message(start: u64, blocks: u64) -> Vec<u8> {
        let mut out = field_varint(1, start);
        out.extend(field_varint(2, blocks));
        out
    }

    fn information(size: u64, hash: Option<&[u8]>) -> Vec<u8> {
        let mut out = field_varint(1, size);
        if let Some(hash) = hash {
            out.extend(field_bytes(2, hash));
        }
        out
    }

    fn bz(data: &[u8]) -> Vec<u8> {
        let mut encoder = bzip2::write::BzEncoder::new(Vec::new(), bzip2::Compression::best());
        encoder.write_all(data).unwrap();
        encoder.finish().unwrap()
    }

    fn xz(data: &[u8]) -> Vec<u8> {
        let mut writer =
            lzma_rust2::XzWriter::new(Vec::new(), lzma_rust2::XzOptions::default()).unwrap();
        writer.write_all(data).unwrap();
        writer.finish().unwrap()
    }

    fn zstd(data: &[u8]) -> Vec<u8> {
        ruzstd::encoding::compress_to_vec(data, ruzstd::encoding::CompressionLevel::Fastest)
    }

    #[derive(Clone)]
    struct OpFixture {
        kind: u32,
        dst: Vec<(u64, u64)>,
        data: Vec<u8>,
        hash: bool,
        src: bool,
    }

    impl OpFixture {
        fn new(kind: u32, dst: &[(u64, u64)], data: Vec<u8>) -> Self {
            Self { kind, dst: dst.to_vec(), data, hash: true, src: false }
        }

        fn encode(&self, offset: u64) -> Vec<u8> {
            let mut out = field_varint(1, u64::from(self.kind));
            out.extend(field_varint(2, offset));
            out.extend(field_varint(3, self.data.len() as u64));
            if self.src {
                out.extend(field_bytes(4, &extent_message(0, 1)));
                out.extend(field_varint(5, u64::from(BLOCK)));
            }
            for &(start, blocks) in &self.dst {
                out.extend(field_bytes(6, &extent_message(start, blocks)));
            }
            if self.hash && !self.data.is_empty() {
                out.extend(field_bytes(8, Sha256::digest(&self.data).as_slice()));
            }
            out
        }
    }

    #[derive(Clone)]
    struct PartitionFixture {
        name: &'static str,
        size: u64,
        hash: Option<Vec<u8>>,
        ops: Vec<OpFixture>,
    }

    impl PartitionFixture {
        fn encode(&self) -> Vec<u8> {
            let mut out = field_bytes(1, self.name.as_bytes());
            out.extend(field_bytes(7, &information(self.size, self.hash.as_deref())));
            let mut offset = 0u64;
            for op in &self.ops {
                out.extend(field_bytes(8, &op.encode(offset)));
                offset += op.data.len() as u64;
            }
            out
        }
    }

    fn manifest_of(block_size: u64, parts: &[PartitionFixture]) -> Vec<u8> {
        let mut out = field_varint(3, block_size);
        out.extend(field_varint(12, 10));
        for part in parts {
            out.extend(field_bytes(13, &part.encode()));
        }
        out
    }

    fn parse(block_size: u64, parts: &[PartitionFixture]) -> Manifest {
        Manifest::parse(&manifest_of(block_size, parts)).unwrap()
    }

    fn payload_header_bytes(algorithm: u64, manifest_len: u64, signature_len: u32) -> Vec<u8> {
        let mut out = b"CrAU".to_vec();
        out.extend_from_slice(&algorithm.to_be_bytes());
        out.extend_from_slice(&manifest_len.to_be_bytes());
        out.extend_from_slice(&signature_len.to_be_bytes());
        out
    }

    #[test]
    fn header_checks() {
        let header = payload_header_bytes(2, 10, 5);
        let parsed = payload_header(&header, 100).unwrap();
        assert_eq!(parsed.manifest_len, 10);
        assert_eq!(parsed.signature_len, 5);
        assert_eq!(parsed.data_start, 39);
        assert!(payload_header(&header, 38).is_err());
        assert!(payload_header(b"MZ\x90\x00", 100).is_err());
        assert!(payload_header(&payload_header_bytes(3, 10, 0), 100).is_err());
        assert!(payload_header(&payload_header_bytes(2, 1 << 30, 0), u64::MAX).is_err());
        assert!(payload_header(&payload_header_bytes(2, 10, 0)[..23], 100).is_err());

        let mut version_one = b"CrAU".to_vec();
        version_one.extend_from_slice(&1u64.to_be_bytes());
        version_one.extend_from_slice(&0u64.to_be_bytes());
        let parsed = payload_header(&version_one, 20).unwrap();
        assert_eq!(parsed.data_start, 20);
    }

    #[test]
    fn decodes_each_full_operation_kind() {
        let first = vec![7u8; BLOCK as usize];
        let second: Vec<u8> = (0..BLOCK as usize).map(|i| (i * 31 % 251) as u8).collect();
        let third = vec![0xaa; BLOCK as usize];
        let fourth: Vec<u8> = (0..BLOCK as usize).map(|i| (i % 17) as u8).collect();
        let partition = PartitionFixture {
            name: "boot",
            size: 4 * BLOCK,
            hash: Some(vec![0xab; 32]),
            ops: vec![
                OpFixture::new(OP_REPLACE, &[(0, 1)], first.clone()),
                OpFixture::new(OP_REPLACE_BZ, &[(1, 1)], bz(&second)),
                OpFixture::new(OP_REPLACE_XZ, &[(2, 1)], xz(&third)),
                OpFixture::new(OP_REPLACE_ZSTD, &[(3, 1)], zstd(&fourth)),
            ],
        };
        let manifest = parse(BLOCK, &[partition.clone()]);
        assert_eq!(manifest.block_size(), BLOCK);
        assert_eq!(manifest.minor_version(), 10);
        assert_eq!(manifest.verify_full().unwrap(), 1);

        let info = manifest.partitions();
        assert_eq!(info.len(), 1);
        assert_eq!(info[0].name, "boot");
        assert_eq!(info[0].size, 4 * BLOCK);
        assert_eq!(info[0].op_count, 4);
        assert_eq!(info[0].sha256.as_deref(), Some("abababababababababababababababababababababababababababababababab"));

        let ops = manifest.operations("boot".into());
        assert_eq!(ops.len(), 4);
        assert_eq!(ops[2].kind, OP_REPLACE_XZ);
        assert_eq!(ops[2].dst, vec![Extent { offset: 2 * BLOCK, length: BLOCK }]);

        assert_eq!(manifest.decode_op("boot".into(), 0, first).unwrap().len(), BLOCK as usize);
        assert_eq!(manifest.decode_op("boot".into(), 1, partition.ops[1].data.clone()).unwrap(), second);
        assert_eq!(manifest.decode_op("boot".into(), 2, partition.ops[2].data.clone()).unwrap(), third);
        assert_eq!(manifest.decode_op("boot".into(), 3, partition.ops[3].data.clone()).unwrap(), fourth);
        assert!(manifest.operations("missing".into()).is_empty());
    }

    #[test]
    fn zero_and_discard_write_nothing() {
        let partition = PartitionFixture {
            name: "vbmeta",
            size: 3 * BLOCK,
            hash: None,
            ops: vec![
                OpFixture::new(OP_ZERO, &[(0, 1)], Vec::new()),
                OpFixture::new(OP_DISCARD, &[(1, 2)], Vec::new()),
            ],
        };
        let manifest = parse(BLOCK, &[partition]);
        assert_eq!(manifest.verify_full().unwrap(), 1);
        assert!(manifest.decode_op("vbmeta".into(), 0, Vec::new()).unwrap().is_empty());
        assert!(manifest.decode_op("vbmeta".into(), 1, Vec::new()).unwrap().is_empty());
        assert!(manifest.partitions()[0].sha256.is_none());
    }

    #[test]
    fn multi_extent_operation_concatenates() {
        let data = vec![3u8; 2 * BLOCK as usize];
        let partition = PartitionFixture {
            name: "dtbo",
            size: 2 * BLOCK,
            hash: None,
            ops: vec![OpFixture::new(OP_REPLACE, &[(1, 1), (0, 1)], data.clone())],
        };
        let manifest = parse(BLOCK, &[partition]);
        assert_eq!(manifest.verify_full().unwrap(), 1);
        assert_eq!(manifest.decode_op("dtbo".into(), 0, data).unwrap().len(), 2 * BLOCK as usize);
    }

    #[test]
    fn rejects_bad_operation_data() {
        let data = vec![9u8; BLOCK as usize];
        let partition = PartitionFixture {
            name: "boot",
            size: BLOCK,
            hash: None,
            ops: vec![OpFixture::new(OP_REPLACE, &[(0, 1)], data.clone())],
        };
        let manifest = parse(BLOCK, &[partition]);

        let mut wrong_hash = data.clone();
        wrong_hash[0] = 0;
        assert!(manifest.decode_op("boot".into(), 0, wrong_hash).is_err());
        assert!(manifest.decode_op("boot".into(), 0, data[..10].to_vec()).is_err());
        assert!(manifest.decode_op("boot".into(), 1, data.clone()).is_err());
        assert!(manifest.decode_op("nope".into(), 0, data).is_err());
    }

    #[test]
    fn rejects_incremental_and_unknown_operations() {
        for (kind, src) in [
            (2, false),  // MOVE
            (3, false),  // BSDIFF
            (4, true),   // SOURCE_COPY
            (5, true),   // SOURCE_BSDIFF
            (9, false),  // PUFFDIFF
            (10, true),  // BROTLI_BSDIFF
            (11, false), // ZUCCHINI
            (12, true),  // LZ4DIFF_BSDIFF
            (13, true),  // LZ4DIFF_PUFFDIFF
            (99, false), // unknown
        ] {
            let mut op = OpFixture::new(kind, &[(0, 1)], vec![0u8; BLOCK as usize]);
            op.src = src;
            let partition = PartitionFixture { name: "system", size: BLOCK, hash: None, ops: vec![op] };
            let manifest = parse(BLOCK, &[partition]);
            let error = manifest.verify_full().unwrap_err().to_string();
            assert!(error.contains("needs the source partition") || error.contains("complete image"), "{kind}: {error}");
            assert!(manifest.decode_op("system".into(), 0, vec![0u8; BLOCK as usize]).is_err());
        }
    }

    #[test]
    fn source_fields_are_rejected_by_verify_full() {
        let mut op = OpFixture::new(OP_REPLACE, &[(0, 1)], vec![0u8; BLOCK as usize]);
        op.src = true;
        let partition = PartitionFixture { name: "system", size: BLOCK, hash: None, ops: vec![op] };
        let manifest = parse(BLOCK, &[partition]);
        assert!(manifest.verify_full().is_err());
    }

    #[test]
    fn verify_full_checks_coverage() {
        let data = vec![1u8; BLOCK as usize];
        let gap = PartitionFixture {
            name: "boot",
            size: 2 * BLOCK,
            hash: None,
            ops: vec![OpFixture::new(OP_REPLACE, &[(1, 1)], data.clone())],
        };
        assert!(parse(BLOCK, &[gap]).verify_full().is_err());

        let overlap = PartitionFixture {
            name: "boot",
            size: 2 * BLOCK,
            hash: None,
            ops: vec![
                OpFixture::new(OP_REPLACE, &[(0, 2)], vec![0u8; 2 * BLOCK as usize]),
                OpFixture::new(OP_ZERO, &[(1, 1)], Vec::new()),
            ],
        };
        assert!(parse(BLOCK, &[overlap.clone()]).verify_full().is_err());
        assert!(parse(BLOCK, &[overlap]).decode_op("boot".into(), 0, vec![0u8; 2 * BLOCK as usize]).is_err());

        let short = PartitionFixture {
            name: "boot",
            size: 2 * BLOCK,
            hash: None,
            ops: vec![OpFixture::new(OP_REPLACE, &[(0, 1)], data.clone())],
        };
        assert!(parse(BLOCK, &[short]).verify_full().is_err());

        let no_size = PartitionFixture {
            name: "boot",
            size: 0,
            hash: None,
            ops: vec![OpFixture::new(OP_REPLACE, &[(0, 1)], data)],
        };
        assert!(parse(BLOCK, &[no_size]).verify_full().is_err());

        // A last block that is short by less than a block is allowed, as
        // otaripper allows it; the rest of the block stays zero.
        let partial = PartitionFixture {
            name: "boot",
            size: BLOCK,
            hash: None,
            ops: vec![OpFixture::new(OP_REPLACE, &[(0, 1)], vec![0u8; BLOCK as usize - 1])],
        };
        let manifest = parse(BLOCK, &[partial]);
        assert_eq!(manifest.verify_full().unwrap(), 1);
        assert_eq!(
            manifest.decode_op("boot".into(), 0, vec![0u8; BLOCK as usize - 1]).unwrap().len(),
            BLOCK as usize - 1
        );

        let short_data = PartitionFixture {
            name: "boot",
            size: 2 * BLOCK,
            hash: None,
            ops: vec![OpFixture::new(OP_REPLACE, &[(0, 2)], vec![1u8; BLOCK as usize])],
        };
        let manifest = parse(BLOCK, &[short_data]);
        assert_eq!(manifest.verify_full().unwrap(), 1);
        let error = manifest
            .decode_op("boot".into(), 0, vec![1u8; BLOCK as usize])
            .unwrap_err()
            .to_string();
        assert!(error.contains("decodes"));
    }

    #[test]
    fn rejects_malformed_manifests() {
        let empty = Manifest::parse(&[]).unwrap();
        assert_eq!(empty.block_size(), DEFAULT_BLOCK_SIZE);
        assert!(empty.partitions().is_empty());
        assert!(empty.verify_full().is_err());
        assert!(Manifest::parse(&field_varint(3, 0)).is_err());
        assert!(Manifest::parse(&[0x08]).is_err());
        assert!(Manifest::parse(&[0x0b]).is_err());

        let part = PartitionFixture {
            name: "boot",
            size: BLOCK,
            hash: None,
            ops: vec![OpFixture::new(OP_REPLACE, &[(0, 1)], vec![0u8; BLOCK as usize])],
        };
        let mut without_name = field_varint(3, BLOCK);
        without_name.extend(field_bytes(13, b""));
        assert!(Manifest::parse(&without_name).is_err());
        let duplicate = manifest_of(BLOCK, &[part.clone(), part]);
        assert!(Manifest::parse(&duplicate)
            .err()
            .unwrap()
            .to_string()
            .contains("more than one"));
    }

    #[test]
    fn sha256_hasher_matches_sha2() {
        let mut hasher = Sha256Hasher::new();
        hasher.update(b"abc");
        assert_eq!(
            hasher.finish_hex(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        hasher.update_zeros(7);
        let mut reference = Sha256::new();
        reference.update(b"abc");
        reference.update([0u8; 7]);
        assert_eq!(hasher.finish_hex(), hex(reference.finalize().as_slice()));
    }
}
