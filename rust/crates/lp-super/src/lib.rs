//! Empty logical-partition metadata and flashable Android sparse super images.
//! No device access, filesystem access, or platform policy lives in this crate.

use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fmt;

pub const BLOCK_SIZE: u32 = 4096;
pub const METADATA_MAX_SIZE: u32 = 65536;
pub const METADATA_SLOTS: u32 = 3;
const GEOMETRY_MAGIC: u32 = 0x616c4467;
const HEADER_MAGIC: u32 = 0x414c5030;
const SPARSE_MAGIC: u32 = 0xed26ff3a;
const ALIGNMENT: u32 = 1024 * 1024;
const GROUP_RESERVE: u64 = 4 * 1024 * 1024;
const ENTRY_SIZES: [usize; 4] = [52, 24, 48, 64];

pub type Result<T, E = Error> = std::result::Result<T, E>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error(&'static str);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for Error {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Geometry {
    pub metadata_max_size: u32,
    pub metadata_slot_count: u32,
    pub logical_block_size: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Partition {
    pub name: String,
    pub attributes: u32,
    pub first_extent_index: u32,
    pub num_extents: u32,
    pub group_index: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Extent {
    pub num_sectors: u64,
    pub target_type: u32,
    pub target_data: u64,
    pub target_source: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
    pub name: String,
    pub flags: u32,
    pub maximum_size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockDevice {
    pub first_logical_sector: u64,
    pub alignment: u32,
    pub alignment_offset: u32,
    pub size: u64,
    pub partition_name: String,
    pub flags: u32,
}

/// Semantic fields; wire magic, sizes, descriptors and SHA-256 values are derived.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Metadata {
    pub geometry: Geometry,
    pub major_version: u16,
    pub minor_version: u16,
    pub flags: u32,
    pub partitions: Vec<Partition>,
    pub extents: Vec<Extent>,
    pub groups: Vec<Group>,
    pub block_devices: Vec<BlockDevice>,
}

/// Reproduce lpmake's 64 KiB, three-slot, virtual-A/B empty layout.
/// Names are unsuffixed bases, kept in caller order, with `_a` then `_b` per base.
/// Each group has a maximum of `super_size - 4 MiB`; neither has allocated extents.
pub fn build_empty_metadata<S: AsRef<str>>(super_size: u64, names: &[S]) -> Result<Metadata> {
    if super_size <= GROUP_RESERVE
        || super_size % u64::from(BLOCK_SIZE) != 0
        || super_size / u64::from(BLOCK_SIZE) >= u64::from(u32::MAX)
    {
        return Err(Error(
            "super size must be block-aligned, greater than 4 MiB, and fit libsparse",
        ));
    }
    // Bound the table before allocating or converting any counts to u32.
    if names.is_empty() || names.len() > (METADATA_MAX_SIZE as usize - 256 - 3 * 48 - 64) / (2 * 52)
    {
        return Err(Error(
            "partition list is empty or exceeds the metadata slot",
        ));
    }
    let mut seen = BTreeSet::new();
    let mut partitions = Vec::with_capacity(names.len() * 2);
    for name in names {
        let name = name.as_ref();
        if name.is_empty()
            || name.len() > 34
            || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
            || !seen.insert(name)
        {
            return Err(Error(
                "partition bases must be unique ASCII names of 1..=34 bytes",
            ));
        }
        for (slot, group_index) in [("a", 1), ("b", 2)] {
            partitions.push(Partition {
                name: format!("{name}_{slot}"),
                attributes: 1,
                first_extent_index: 0,
                num_extents: 0,
                group_index,
            });
        }
    }
    Ok(Metadata {
        geometry: Geometry {
            metadata_max_size: METADATA_MAX_SIZE,
            metadata_slot_count: METADATA_SLOTS,
            logical_block_size: BLOCK_SIZE,
        },
        major_version: 10,
        minor_version: 2,
        flags: 1,
        partitions,
        extents: Vec::new(),
        groups: vec![
            Group {
                name: "default".into(),
                flags: 0,
                maximum_size: 0,
            },
            Group {
                name: "qti_dynamic_partitions_a".into(),
                flags: 0,
                maximum_size: super_size - GROUP_RESERVE,
            },
            Group {
                name: "qti_dynamic_partitions_b".into(),
                flags: 0,
                maximum_size: super_size - GROUP_RESERVE,
            },
        ],
        block_devices: vec![BlockDevice {
            first_logical_sector: u64::from(ALIGNMENT) / 512,
            alignment: ALIGNMENT,
            alignment_offset: 0,
            size: super_size,
            partition_name: "super".into(),
            flags: 0,
        }],
    })
}

/// Produce bytes for download + flash:super, equivalent to fastboot wipe-super.
/// This clears logical allocation, not the old contents of unallocated sectors.
pub fn generate_wipe_super<S: AsRef<str>>(super_size: u64, names: &[S]) -> Result<Vec<u8>> {
    let metadata = build_empty_metadata(super_size, names)?;
    let geometry = serialize_geometry(&metadata.geometry)?;
    let blob = serialize_metadata(&metadata)?;
    let data_size =
        2 * BLOCK_SIZE as usize + 2 * METADATA_SLOTS as usize * METADATA_MAX_SIZE as usize;
    // libsparse: reserved zero FILL, contiguous metadata RAW, remaining DONT_CARE.
    let mut out = Vec::with_capacity(28 + 3 * 12 + 4 + data_size);
    out.extend_from_slice(&SPARSE_MAGIC.to_le_bytes());
    for n in [1u16, 0, 28, 12] {
        out.extend_from_slice(&n.to_le_bytes());
    }
    for n in [
        BLOCK_SIZE,
        (super_size / u64::from(BLOCK_SIZE)) as u32,
        3,
        0,
    ] {
        out.extend_from_slice(&n.to_le_bytes());
    }
    chunk_header(&mut out, 0xcac2, 1, 4);
    out.extend_from_slice(&0u32.to_le_bytes());
    chunk_header(
        &mut out,
        0xcac1,
        data_size as u32 / BLOCK_SIZE,
        data_size as u32,
    );
    out.extend_from_slice(&geometry);
    out.extend_from_slice(&geometry);
    for _ in 0..2 * METADATA_SLOTS {
        out.extend_from_slice(&blob);
        out.resize(out.len() + METADATA_MAX_SIZE as usize - blob.len(), 0);
    }
    chunk_header(
        &mut out,
        0xcac3,
        (super_size / u64::from(BLOCK_SIZE)) as u32 - 1 - data_size as u32 / BLOCK_SIZE,
        0,
    );
    Ok(out)
}

fn chunk_header(out: &mut Vec<u8>, kind: u16, blocks: u32, payload: u32) {
    out.extend_from_slice(&kind.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&blocks.to_le_bytes());
    out.extend_from_slice(&(12 + payload).to_le_bytes());
}

/// Canonical liblp geometry (4096 bytes, SHA-256 over the 52-byte structure).
pub fn serialize_geometry(geometry: &Geometry) -> Result<Vec<u8>> {
    validate_geometry(geometry)?;
    let mut out = vec![0; BLOCK_SIZE as usize];
    put32(&mut out, 0, GEOMETRY_MAGIC);
    put32(&mut out, 4, 52);
    put32(&mut out, 40, geometry.metadata_max_size);
    put32(&mut out, 44, geometry.metadata_slot_count);
    put32(&mut out, 48, geometry.logical_block_size);
    let checksum = Sha256::digest(&out[..52]);
    out[8..40].copy_from_slice(&checksum);
    Ok(out)
}

/// Header + tables, without padding to metadata_max_size, as SerializeMetadata.
pub fn serialize_metadata(metadata: &Metadata) -> Result<Vec<u8>> {
    validate(metadata)?;
    let header_size = if metadata.minor_version >= 2 {
        256
    } else {
        128
    };
    let counts = [
        metadata.partitions.len(),
        metadata.extents.len(),
        metadata.groups.len(),
        metadata.block_devices.len(),
    ];
    let table_size: usize = counts
        .iter()
        .zip(ENTRY_SIZES)
        .map(|(n, size)| n * size)
        .sum();
    let mut out = vec![0; header_size + table_size];
    put32(&mut out, 0, HEADER_MAGIC);
    out[4..6].copy_from_slice(&metadata.major_version.to_le_bytes());
    out[6..8].copy_from_slice(&metadata.minor_version.to_le_bytes());
    put32(&mut out, 8, header_size as u32);
    put32(&mut out, 44, table_size as u32);
    if header_size == 256 {
        put32(&mut out, 128, metadata.flags);
    }
    let mut offset = 0;
    for (i, (&count, size)) in counts.iter().zip(ENTRY_SIZES).enumerate() {
        put32(&mut out, 80 + 12 * i, offset as u32);
        put32(&mut out, 84 + 12 * i, count as u32);
        put32(&mut out, 88 + 12 * i, size as u32);
        offset += count * size;
    }
    let mut pos = header_size;
    for p in &metadata.partitions {
        put_name(&mut out[pos..pos + 36], &p.name);
        for (i, n) in [
            p.attributes,
            p.first_extent_index,
            p.num_extents,
            p.group_index,
        ]
        .into_iter()
        .enumerate()
        {
            put32(&mut out, pos + 36 + 4 * i, n);
        }
        pos += 52;
    }
    for e in &metadata.extents {
        put64(&mut out, pos, e.num_sectors);
        put32(&mut out, pos + 8, e.target_type);
        put64(&mut out, pos + 12, e.target_data);
        put32(&mut out, pos + 20, e.target_source);
        pos += 24;
    }
    for g in &metadata.groups {
        put_name(&mut out[pos..pos + 36], &g.name);
        put32(&mut out, pos + 36, g.flags);
        put64(&mut out, pos + 40, g.maximum_size);
        pos += 48;
    }
    for d in &metadata.block_devices {
        put64(&mut out, pos, d.first_logical_sector);
        put32(&mut out, pos + 8, d.alignment);
        put32(&mut out, pos + 12, d.alignment_offset);
        put64(&mut out, pos + 16, d.size);
        put_name(&mut out[pos + 24..pos + 60], &d.partition_name);
        put32(&mut out, pos + 60, d.flags);
        pos += 64;
    }
    let checksum = Sha256::digest(&out[header_size..]);
    out[48..80].copy_from_slice(&checksum);
    let checksum = Sha256::digest(&out[..header_size]);
    out[12..44].copy_from_slice(&checksum);
    Ok(out)
}

/// Parse/validate metadata-only lpmake images, raw super images, or our sparse
/// images without expanding the logical-partition area. Full images must have
/// identical primary/backup geometries and metadata in every slot. This is a
/// strict image validator, not liblp's damaged-device backup recovery reader.
/// Supported metadata slots are at most 64 KiB; sparse CRC chunks are rejected.
pub fn parse_image(image: &[u8]) -> Result<Metadata> {
    let source = Image::new(image)?;
    let metadata_only = get32(image, 0)? == GEOMETRY_MAGIC;
    let geometry_offset = if metadata_only {
        0
    } else {
        u64::from(BLOCK_SIZE)
    };
    let geometry_bytes = source.read(geometry_offset, BLOCK_SIZE as usize)?;
    let geometry = parse_geometry(&geometry_bytes)?;
    let metadata_offset = if metadata_only {
        u64::from(BLOCK_SIZE)
    } else {
        3 * u64::from(BLOCK_SIZE)
    };
    let header = source.read(metadata_offset, 128)?;
    let header_size = get32(&header, 8)? as usize;
    let tables_size = get32(&header, 44)? as usize;
    let size = header_size
        .checked_add(tables_size)
        .ok_or(Error("metadata size overflow"))?;
    if size > geometry.metadata_max_size as usize {
        return Err(Error("metadata exceeds slot size"));
    }
    let blob = source.read(metadata_offset, size)?;
    let metadata = parse_metadata(geometry, &blob)?;
    if !metadata_only {
        if source.len != metadata.block_devices[0].size {
            return Err(Error("expanded image size differs from super size"));
        }
        if source.read(2 * u64::from(BLOCK_SIZE), BLOCK_SIZE as usize)? != geometry_bytes {
            return Err(Error("geometry copies differ"));
        }
        for slot in 0..2 * u64::from(metadata.geometry.metadata_slot_count) {
            let offset = metadata_offset + slot * u64::from(metadata.geometry.metadata_max_size);
            if source.read(offset, size)? != blob {
                return Err(Error("metadata copies differ"));
            }
        }
    }
    Ok(metadata)
}

fn parse_geometry(bytes: &[u8]) -> Result<Geometry> {
    if get32(bytes, 0)? != GEOMETRY_MAGIC || get32(bytes, 4)? != 52 {
        return Err(Error("invalid geometry magic or structure size"));
    }
    verify_checksum(&bytes[..52], 8)?;
    let geometry = Geometry {
        metadata_max_size: get32(bytes, 40)?,
        metadata_slot_count: get32(bytes, 44)?,
        logical_block_size: get32(bytes, 48)?,
    };
    validate_geometry(&geometry)?;
    Ok(geometry)
}

fn parse_metadata(geometry: Geometry, blob: &[u8]) -> Result<Metadata> {
    let major_version = get16(blob, 4)?;
    let minor_version = get16(blob, 6)?;
    let header_size = if minor_version >= 2 { 256 } else { 128 };
    if get32(blob, 0)? != HEADER_MAGIC
        || major_version != 10
        || minor_version > 2
        || get32(blob, 8)? as usize != header_size
        || blob.len() < header_size
    {
        return Err(Error("unsupported metadata header"));
    }
    verify_checksum(&blob[..header_size], 12)?;
    if Sha256::digest(&blob[header_size..]).as_slice() != &blob[48..80] {
        return Err(Error("invalid tables checksum"));
    }
    if header_size == 256 && blob[132..256].iter().any(|b| *b != 0) {
        return Err(Error("nonzero reserved header fields"));
    }
    let mut tables = Vec::with_capacity(4);
    for (i, size) in ENTRY_SIZES.into_iter().enumerate() {
        let offset = get32(blob, 80 + 12 * i)? as usize;
        let count = get32(blob, 84 + 12 * i)? as usize;
        if get32(blob, 88 + 12 * i)? as usize != size {
            return Err(Error("invalid table entry size"));
        }
        let end = count
            .checked_mul(size)
            .and_then(|n| n.checked_add(offset))
            .and_then(|n| n.checked_add(header_size))
            .ok_or(Error("table size overflow"))?;
        let start = header_size
            .checked_add(offset)
            .ok_or(Error("table offset overflow"))?;
        tables.push(
            blob.get(start..end)
                .ok_or(Error("table outside metadata"))?,
        );
    }
    let mut metadata = Metadata {
        geometry,
        major_version,
        minor_version,
        flags: if header_size == 256 {
            get32(blob, 128)?
        } else {
            0
        },
        partitions: Vec::new(),
        extents: Vec::new(),
        groups: Vec::new(),
        block_devices: Vec::new(),
    };
    for p in tables[0].chunks_exact(52) {
        metadata.partitions.push(Partition {
            name: parse_name(&p[..36])?,
            attributes: get32(p, 36)?,
            first_extent_index: get32(p, 40)?,
            num_extents: get32(p, 44)?,
            group_index: get32(p, 48)?,
        });
    }
    for e in tables[1].chunks_exact(24) {
        metadata.extents.push(Extent {
            num_sectors: get64(e, 0)?,
            target_type: get32(e, 8)?,
            target_data: get64(e, 12)?,
            target_source: get32(e, 20)?,
        });
    }
    for g in tables[2].chunks_exact(48) {
        metadata.groups.push(Group {
            name: parse_name(&g[..36])?,
            flags: get32(g, 36)?,
            maximum_size: get64(g, 40)?,
        });
    }
    for d in tables[3].chunks_exact(64) {
        metadata.block_devices.push(BlockDevice {
            first_logical_sector: get64(d, 0)?,
            alignment: get32(d, 8)?,
            alignment_offset: get32(d, 12)?,
            size: get64(d, 16)?,
            partition_name: parse_name(&d[24..60])?,
            flags: get32(d, 60)?,
        });
    }
    validate(&metadata)?;
    Ok(metadata)
}

fn validate_geometry(g: &Geometry) -> Result<()> {
    if g.metadata_max_size < 128
        || g.metadata_max_size > METADATA_MAX_SIZE
        || g.metadata_max_size % 512 != 0
        || g.metadata_slot_count == 0
        || g.logical_block_size == 0
        || g.logical_block_size % 512 != 0
    {
        return Err(Error("unsupported geometry dimensions"));
    }
    Ok(())
}

fn validate(m: &Metadata) -> Result<()> {
    validate_geometry(&m.geometry)?;
    if m.major_version != 10 || m.minor_version > 2 || (m.minor_version < 2 && m.flags != 0) {
        return Err(Error("unsupported metadata version or header flags"));
    }
    let header_size = if m.minor_version >= 2 { 256 } else { 128 };
    let counts = [
        m.partitions.len(),
        m.extents.len(),
        m.groups.len(),
        m.block_devices.len(),
    ];
    let mut size = header_size;
    for (count, entry_size) in counts.into_iter().zip(ENTRY_SIZES) {
        size = count
            .checked_mul(entry_size)
            .and_then(|n| n.checked_add(size))
            .ok_or(Error("metadata size overflow"))?;
    }
    if size > m.geometry.metadata_max_size as usize || m.block_devices.is_empty() {
        return Err(Error("metadata too large or missing block device"));
    }
    unique_names(m.partitions.iter().map(|p| p.name.as_str()))?;
    unique_names(m.groups.iter().map(|g| g.name.as_str()))?;
    unique_names(m.block_devices.iter().map(|d| d.partition_name.as_str()))?;
    let reserved = 3 * u64::from(BLOCK_SIZE)
        + 2 * u64::from(m.geometry.metadata_max_size) * u64::from(m.geometry.metadata_slot_count);
    for (i, d) in m.block_devices.iter().enumerate() {
        if d.size % 512 != 0
            || d.first_logical_sector >= d.size / 512
            || d.alignment % 512 != 0
            || d.alignment_offset % 512 != 0
            || (i == 0 && d.first_logical_sector < reserved.div_ceil(512))
        {
            return Err(Error("invalid block device bounds or alignment"));
        }
    }
    for p in &m.partitions {
        if p.attributes & !(if m.minor_version == 0 { 3 } else { 15 }) != 0
            || p.group_index as usize >= m.groups.len()
            || u64::from(p.first_extent_index) + u64::from(p.num_extents) > m.extents.len() as u64
        {
            return Err(Error("invalid partition attributes or table reference"));
        }
    }
    for e in &m.extents {
        match e.target_type {
            0 => {
                let d = m
                    .block_devices
                    .get(e.target_source as usize)
                    .ok_or(Error("invalid extent block device"))?;
                if e.target_data < d.first_logical_sector
                    || e.target_data > d.size / 512
                    || e.num_sectors > d.size / 512 - e.target_data
                {
                    return Err(Error("extent outside block device"));
                }
            }
            1 if e.target_data == 0 && e.target_source == 0 => (),
            _ => return Err(Error("unsupported extent target")),
        }
    }
    Ok(())
}

fn unique_names<'a>(names: impl Iterator<Item = &'a str>) -> Result<()> {
    let mut seen = BTreeSet::new();
    for name in names {
        if name.is_empty()
            || name.len() > 36
            || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
            || !seen.insert(name)
        {
            return Err(Error("invalid or duplicate metadata name"));
        }
    }
    Ok(())
}
fn parse_name(bytes: &[u8]) -> Result<String> {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    if bytes[end..].iter().any(|b| *b != 0) {
        return Err(Error("nonzero name padding"));
    }
    Ok(std::str::from_utf8(&bytes[..end])
        .map_err(|_| Error("non-ASCII metadata name"))?
        .into())
}
fn put_name(bytes: &mut [u8], name: &str) {
    bytes[..name.len()].copy_from_slice(name.as_bytes());
}
fn put32(bytes: &mut [u8], pos: usize, n: u32) {
    bytes[pos..pos + 4].copy_from_slice(&n.to_le_bytes());
}
fn put64(bytes: &mut [u8], pos: usize, n: u64) {
    bytes[pos..pos + 8].copy_from_slice(&n.to_le_bytes());
}
fn get16(bytes: &[u8], pos: usize) -> Result<u16> {
    Ok(u16::from_le_bytes(
        bytes
            .get(pos..pos + 2)
            .ok_or(Error("truncated image"))?
            .try_into()
            .unwrap(),
    ))
}
fn get32(bytes: &[u8], pos: usize) -> Result<u32> {
    Ok(u32::from_le_bytes(
        bytes
            .get(pos..pos + 4)
            .ok_or(Error("truncated image"))?
            .try_into()
            .unwrap(),
    ))
}
fn get64(bytes: &[u8], pos: usize) -> Result<u64> {
    Ok(u64::from_le_bytes(
        bytes
            .get(pos..pos + 8)
            .ok_or(Error("truncated image"))?
            .try_into()
            .unwrap(),
    ))
}
fn verify_checksum(bytes: &[u8], offset: usize) -> Result<()> {
    let mut hash = Sha256::new();
    hash.update(&bytes[..offset]);
    hash.update([0; 32]);
    hash.update(&bytes[offset + 32..]);
    if hash.finalize().as_slice() != &bytes[offset..offset + 32] {
        return Err(Error("invalid metadata checksum"));
    }
    Ok(())
}

struct Chunk<'a> {
    start: u64,
    len: u64,
    kind: u16,
    data: &'a [u8],
}
struct Image<'a> {
    raw: &'a [u8],
    chunks: Vec<Chunk<'a>>,
    len: u64,
}
impl<'a> Image<'a> {
    fn new(raw: &'a [u8]) -> Result<Self> {
        if get32(raw, 0)? != SPARSE_MAGIC {
            return Ok(Self {
                raw,
                chunks: Vec::new(),
                len: raw.len() as u64,
            });
        }
        let file_header = get16(raw, 8)? as usize;
        let chunk_header = get16(raw, 10)? as usize;
        let block_size = get32(raw, 12)?;
        if get16(raw, 4)? != 1
            || get16(raw, 6)? != 0
            || file_header < 28
            || chunk_header < 12
            || block_size == 0
            || block_size % 512 != 0
            || get32(raw, 24)? != 0
        {
            return Err(Error("unsupported sparse header"));
        }
        let len = u64::from(get32(raw, 16)?) * u64::from(block_size);
        let mut chunks = Vec::new();
        let mut pos = file_header;
        let mut start = 0u64;
        for _ in 0..get32(raw, 20)? {
            let header = raw
                .get(pos..)
                .and_then(|r| r.get(..chunk_header))
                .ok_or(Error("truncated sparse chunk"))?;
            let kind = get16(header, 0)?;
            let chunk_len = u64::from(get32(header, 4)?) * u64::from(block_size);
            let total = get32(header, 8)? as usize;
            let payload = total
                .checked_sub(chunk_header)
                .ok_or(Error("invalid sparse chunk size"))?;
            if !match kind {
                0xcac1 => payload as u64 == chunk_len,
                0xcac2 => payload == 4,
                0xcac3 => payload == 0,
                _ => false,
            } {
                return Err(Error("unsupported sparse chunk or payload size"));
            }
            let end = pos
                .checked_add(total)
                .ok_or(Error("sparse offset overflow"))?;
            let data = raw
                .get(pos + chunk_header..end)
                .ok_or(Error("truncated sparse payload"))?;
            if chunk_len == 0 || chunk_len > len - start {
                return Err(Error("sparse chunk outside expanded image"));
            }
            chunks.push(Chunk {
                start,
                len: chunk_len,
                kind,
                data,
            });
            start += chunk_len;
            pos = end;
        }
        if pos != raw.len() || start != len {
            return Err(Error("sparse image size mismatch"));
        }
        Ok(Self { raw, chunks, len })
    }
    fn read(&self, offset: u64, size: usize) -> Result<Vec<u8>> {
        if offset > self.len || size as u64 > self.len - offset {
            return Err(Error("image region out of bounds"));
        }
        if self.chunks.is_empty() {
            return Ok(self.raw[offset as usize..offset as usize + size].to_vec());
        }
        let mut out = vec![0; size];
        let end = offset + size as u64;
        for c in &self.chunks {
            let from = offset.max(c.start);
            let to = end.min(c.start + c.len);
            if from >= to {
                continue;
            }
            let dest = &mut out[(from - offset) as usize..(to - offset) as usize];
            match c.kind {
                0xcac1 => dest
                    .copy_from_slice(&c.data[(from - c.start) as usize..(to - c.start) as usize]),
                0xcac2 => {
                    for (i, byte) in dest.iter_mut().enumerate() {
                        *byte = c.data[((from - c.start + i as u64) % 4) as usize];
                    }
                }
                _ => return Err(Error("metadata region is DONT_CARE")),
            }
        }
        Ok(out)
    }
}
