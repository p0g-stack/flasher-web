//! LP (logical partition) metadata, laid out exactly the way Android's
//! `liblp` MetadataBuilder and `lpmake` write a super image.
//!
//! `super_layout` returns the bytes from offset 0 up to the first partition
//! extent, and each partition's physical extent, so a caller can stream the
//! partition images into place. Everything else in the image is zero.
//!
//! Ported from AOSP `system/core/fs_mgr/liblp` (builder.cpp, images.cpp,
//! writer.cpp, metadata_format.h), Apache-2.0.
use flutter_rust_bridge::frb;
use sha2::{Digest, Sha256};

use anyhow::Result;

pub const GEOMETRY_MAGIC: u32 = 0x616c_4467;
pub const HEADER_MAGIC: u32 = 0x414c_5030;
pub const METADATA_MAJOR_VERSION: u16 = 10;
pub const METADATA_MINOR_VERSION: u16 = 2;
pub const HEADER_FLAG_VIRTUAL_AB: u32 = 1;
pub const PARTITION_ATTR_READONLY: u32 = 1;
pub const RESERVED_BYTES: u64 = 4096;
pub const GEOMETRY_SIZE: u64 = 4096;
pub const SECTOR_SIZE: u64 = 512;
pub const PARTITION_ENTRY_SIZE: u32 = 52;
pub const EXTENT_ENTRY_SIZE: u32 = 24;
pub const GROUP_ENTRY_SIZE: u32 = 48;
pub const BLOCK_DEVICE_ENTRY_SIZE: u32 = 64;
pub const DEFAULT_METADATA_SIZE: u32 = 65536;
pub const DEFAULT_METADATA_SLOTS: u32 = 3;
pub const DEFAULT_LOGICAL_BLOCK_SIZE: u32 = 4096;
pub const DEFAULT_ALIGNMENT: u32 = 1 << 20;
pub const DEFAULT_SUPER_NAME: &str = "super";
pub const DEFAULT_GROUP: &str = "default";

/// A partition group and its maximum size in bytes (0 = unlimited).
#[derive(Clone, Debug)]
pub struct SuperGroup {
    pub name: String,
    pub size: u64,
}

/// A logical partition. `size` is the expanded image size; it is aligned up
/// to the logical block size exactly as `lpmake` does.
#[derive(Clone, Debug)]
pub struct SuperPartition {
    pub name: String,
    pub size: u64,
    pub group: String,
    pub readonly: bool,
    /// `lpmake --image` was passed for this partition. Partitions without an
    /// image still get metadata, but no data.
    pub has_image: bool,
}

/// Everything `native_pipeline.pack_super` passes to `lpmake`:
/// metadata size 65536, three slots, virtual A/B, super device name `super`,
/// two qti groups, and `<name>_a` readonly partitions with `<name>_b` empty.
#[derive(Clone, Debug)]
pub struct SuperSpec {
    pub device_size: u64,
    /// Empty means `super`.
    pub super_name: String,
    /// 0 means 65536.
    pub metadata_size: u32,
    /// 0 means 3.
    pub metadata_slots: u32,
    pub virtual_ab: bool,
    /// 0 means 4096.
    pub logical_block_size: u32,
    /// 0 means 1 MiB.
    pub alignment: u32,
    pub groups: Vec<SuperGroup>,
    pub partitions: Vec<SuperPartition>,
}

/// Where a partition image goes in the super image.
#[derive(Clone, Debug)]
pub struct PartitionExtent {
    pub name: String,
    pub offset: u64,
    pub size: u64,
}

/// `head` is the super image bytes from offset 0 up to the first extent (or
/// the end of the metadata area when no partition has an image). Each extent
/// follows `head` in the caller's image; gaps are zero.
#[derive(Clone, Debug)]
pub struct SuperLayout {
    pub head: Vec<u8>,
    pub extents: Vec<PartitionExtent>,
}

fn align_up(value: u64, alignment: u64) -> Result<u64> {
    if alignment == 0 {
        return Err(anyhow::anyhow!("Alignment must not be zero"));
    }
    let remainder = value % alignment;
    if remainder == 0 {
        Ok(value)
    } else {
        value
            .checked_add(alignment - remainder)
            .ok_or_else(|| anyhow::anyhow!("Integer overflow computing alignment"))
    }
}

fn sha256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().into()
}

fn write_name(table: &mut [u8], name: &str) -> Result<()> {
    if name.len() > 36 {
        return Err(anyhow::anyhow!("Name is longer than 36 bytes: {name}"));
    }
    table[..name.len()].copy_from_slice(name.as_bytes());
    Ok(())
}

/// 52 bytes of geometry, padded with zeros to the 4096-byte geometry block.
fn geometry_blob(metadata_size: u32, metadata_slots: u32, logical_block_size: u32) -> Vec<u8> {
    let mut geometry = vec![0u8; 52];
    geometry[0..4].copy_from_slice(&GEOMETRY_MAGIC.to_le_bytes());
    geometry[4..8].copy_from_slice(&52u32.to_le_bytes());
    geometry[40..44].copy_from_slice(&metadata_size.to_le_bytes());
    geometry[44..48].copy_from_slice(&metadata_slots.to_le_bytes());
    geometry[48..52].copy_from_slice(&logical_block_size.to_le_bytes());
    let checksum = sha256(&geometry);
    geometry[8..40].copy_from_slice(&checksum);
    geometry.resize(GEOMETRY_SIZE as usize, 0);
    geometry
}

struct Metadata {
    blob: Vec<u8>,
}

fn metadata_blob(
    spec: &SuperSpec,
    metadata_size: u32,
    logical_block_size: u32,
    groups: &[SuperGroup],
    partitions: &[SuperPartition],
    extents: &[(u64, u64)],
) -> Result<Metadata> {
    let header_size: u32 = if spec.virtual_ab { 256 } else { 128 };
    let minor = if spec.virtual_ab {
        METADATA_MINOR_VERSION
    } else {
        0
    };

    let mut partitions_table = Vec::with_capacity(partitions.len() * 52);
    let mut extents_table = Vec::with_capacity(extents.len() * 24);
    let mut groups_table = Vec::with_capacity(groups.len() * 48);
    let mut devices_table = Vec::with_capacity(64);

    let mut extent_index = 0u32;
    for partition in partitions {
        let extent_count: u32 = if partition.size == 0 { 0 } else { 1 };
        let mut entry = vec![0u8; 52];
        write_name(&mut entry[..36], &partition.name)?;
        let attributes = if partition.readonly {
            PARTITION_ATTR_READONLY
        } else {
            0
        };
        entry[36..40].copy_from_slice(&attributes.to_le_bytes());
        entry[40..44].copy_from_slice(&extent_index.to_le_bytes());
        entry[44..48].copy_from_slice(&extent_count.to_le_bytes());
        extent_index += extent_count;
        let group_index = groups
            .iter()
            .position(|group| group.name == partition.group)
            .ok_or_else(|| anyhow::anyhow!("Unknown partition group: {}", partition.group))?;
        entry[48..52].copy_from_slice(&(group_index as u32).to_le_bytes());
        partitions_table.extend_from_slice(&entry);
    }
    for &(sector, sectors) in extents {
        extents_table.extend_from_slice(&sectors.to_le_bytes());
        extents_table.extend_from_slice(&0u32.to_le_bytes()); // LP_TARGET_TYPE_LINEAR
        extents_table.extend_from_slice(&sector.to_le_bytes());
        extents_table.extend_from_slice(&0u32.to_le_bytes()); // block device 0
    }
    for group in groups {
        let mut entry = vec![0u8; 48];
        write_name(&mut entry[..36], &group.name)?;
        entry[36..40].copy_from_slice(&0u32.to_le_bytes());
        entry[40..48].copy_from_slice(&group.size.to_le_bytes());
        groups_table.extend_from_slice(&entry);
    }
    let mut device = vec![0u8; 64];
    let reserved = RESERVED_BYTES
        + (GEOMETRY_SIZE + u64::from(metadata_size) * u64::from(spec.metadata_slots)) * 2;
    let alignment = if spec.alignment != 0 {
        u64::from(spec.alignment)
    } else {
        u64::from(logical_block_size)
    };
    let first_logical_sector = align_up(reserved, alignment)? / SECTOR_SIZE;
    device[0..8].copy_from_slice(&first_logical_sector.to_le_bytes());
    device[8..12].copy_from_slice(&spec.alignment.to_le_bytes());
    device[12..16].copy_from_slice(&0u32.to_le_bytes());
    device[16..24].copy_from_slice(&spec.device_size.to_le_bytes());
    write_name(
        &mut device[24..60],
        if spec.super_name.is_empty() {
            DEFAULT_SUPER_NAME
        } else {
            &spec.super_name
        },
    )?;
    device[60..64].copy_from_slice(&0u32.to_le_bytes());
    devices_table.extend_from_slice(&device);

    let partitions_offset = 0u32;
    let extents_offset = partitions_offset + partitions_table.len() as u32;
    let groups_offset = extents_offset + extents_table.len() as u32;
    let devices_offset = groups_offset + groups_table.len() as u32;
    let tables_size = devices_offset + devices_table.len() as u32;

    let mut tables = Vec::with_capacity(tables_size as usize);
    tables.extend_from_slice(&partitions_table);
    tables.extend_from_slice(&extents_table);
    tables.extend_from_slice(&groups_table);
    tables.extend_from_slice(&devices_table);
    let tables_checksum = sha256(&tables);

    let mut header = vec![0u8; header_size as usize];
    header[0..4].copy_from_slice(&HEADER_MAGIC.to_le_bytes());
    header[4..6].copy_from_slice(&METADATA_MAJOR_VERSION.to_le_bytes());
    header[6..8].copy_from_slice(&minor.to_le_bytes());
    header[8..12].copy_from_slice(&header_size.to_le_bytes());
    header[44..48].copy_from_slice(&tables_size.to_le_bytes());
    header[48..80].copy_from_slice(&tables_checksum);
    let descriptors = [
        (
            partitions_offset,
            partitions.len() as u32,
            PARTITION_ENTRY_SIZE,
        ),
        (extents_offset, extents.len() as u32, EXTENT_ENTRY_SIZE),
        (groups_offset, groups.len() as u32, GROUP_ENTRY_SIZE),
        (devices_offset, 1, BLOCK_DEVICE_ENTRY_SIZE),
    ];
    for (index, (offset, count, entry_size)) in descriptors.iter().enumerate() {
        let base = 80 + index * 12;
        header[base..base + 4].copy_from_slice(&offset.to_le_bytes());
        header[base + 4..base + 8].copy_from_slice(&count.to_le_bytes());
        header[base + 8..base + 12].copy_from_slice(&entry_size.to_le_bytes());
    }
    if spec.virtual_ab {
        header[128..132].copy_from_slice(&HEADER_FLAG_VIRTUAL_AB.to_le_bytes());
    }
    let header_checksum = sha256(&header);
    header[12..44].copy_from_slice(&header_checksum);

    let mut blob = header;
    blob.extend_from_slice(&tables);
    if blob.len() > metadata_size as usize {
        return Err(anyhow::anyhow!(
            "Logical partition metadata is too large: {} > {}",
            blob.len(),
            metadata_size
        ));
    }
    Ok(Metadata { blob })
}

/// The exact LP geometry and metadata `lpmake` writes for `--metadata-size
/// --metadata-slots --virtual-ab --super-name --device --group … --partition
/// name:readonly:size:group`.
#[frb(sync)]
pub fn super_layout(spec: SuperSpec) -> Result<SuperLayout> {
    if spec.device_size == 0 {
        return Err(anyhow::anyhow!("Invalid physical super partition size"));
    }
    let metadata_size = if spec.metadata_size == 0 {
        DEFAULT_METADATA_SIZE
    } else {
        spec.metadata_size
    };
    let metadata_size = align_up(u64::from(metadata_size), SECTOR_SIZE)? as u32;
    let metadata_slots = if spec.metadata_slots == 0 {
        DEFAULT_METADATA_SLOTS
    } else {
        spec.metadata_slots
    };
    let logical_block_size = if spec.logical_block_size == 0 {
        DEFAULT_LOGICAL_BLOCK_SIZE
    } else {
        spec.logical_block_size
    };
    if logical_block_size == 0 || logical_block_size % SECTOR_SIZE as u32 != 0 {
        return Err(anyhow::anyhow!(
            "Logical block size must be a multiple of 512"
        ));
    }
    let alignment = if spec.alignment == 0 {
        DEFAULT_ALIGNMENT
    } else {
        spec.alignment
    };
    if alignment % SECTOR_SIZE as u32 != 0 {
        return Err(anyhow::anyhow!("Alignment must be a multiple of 512"));
    }
    let effective_spec = SuperSpec {
        alignment,
        metadata_size,
        metadata_slots,
        logical_block_size,
        ..spec.clone()
    };

    let mut groups = vec![SuperGroup {
        name: DEFAULT_GROUP.to_string(),
        size: 0,
    }];
    for group in &spec.groups {
        if groups.iter().any(|existing| existing.name == group.name) {
            return Err(anyhow::anyhow!("Group already exists: {}", group.name));
        }
        groups.push(group.clone());
    }
    for (index, partition) in spec.partitions.iter().enumerate() {
        if partition.name.is_empty() {
            return Err(anyhow::anyhow!("Partition must have a non-empty name"));
        }
        if spec.partitions[..index]
            .iter()
            .any(|other| other.name == partition.name)
        {
            return Err(anyhow::anyhow!("Duplicate partition: {}", partition.name));
        }
    }

    let reserved =
        RESERVED_BYTES + (GEOMETRY_SIZE + u64::from(metadata_size) * u64::from(metadata_slots)) * 2;
    let first_logical_sector = align_up(reserved, u64::from(alignment))? / SECTOR_SIZE;
    let logical_start = first_logical_sector * SECTOR_SIZE;
    if spec.device_size
        < logical_start
            .checked_add(u64::from(logical_block_size))
            .ok_or_else(|| anyhow::anyhow!("Integer overflow computing device size"))?
    {
        return Err(anyhow::anyhow!(
            "Device must be at least {} bytes, only has {}",
            logical_start + u64::from(logical_block_size),
            spec.device_size
        ));
    }

    // Allocate extents in partition order. `liblp` takes the first free
    // region and aligns the next free region up to the block device's
    // alignment (1 MiB by default).
    let mut extents: Vec<(u64, u64)> = Vec::new();
    let mut extent_lookup = Vec::with_capacity(spec.partitions.len());
    let mut cursor = logical_start;
    let mut group_usage = vec![0u64; groups.len()];
    for partition in &spec.partitions {
        let aligned_size = align_up(partition.size, u64::from(logical_block_size))?;
        if aligned_size == 0 {
            extent_lookup.push(None);
            continue;
        }
        let sectors = aligned_size / SECTOR_SIZE;
        let end = cursor
            .checked_add(aligned_size)
            .ok_or_else(|| anyhow::anyhow!("Integer overflow allocating partition"))?;
        if end > spec.device_size {
            return Err(anyhow::anyhow!(
                "Not enough free space to expand partition: {}",
                partition.name
            ));
        }
        let group_index = groups
            .iter()
            .position(|group| group.name == partition.group)
            .ok_or_else(|| {
                anyhow::anyhow!("Could not find partition group: {}", partition.group)
            })?;
        group_usage[group_index] += aligned_size;
        extents.push((cursor / SECTOR_SIZE, sectors));
        extent_lookup.push(Some(extents.len() - 1));
        cursor = align_up(end, u64::from(alignment))?;
    }
    for (index, group) in groups.iter().enumerate() {
        if group.size > 0 && group_usage[index] > group.size {
            return Err(anyhow::anyhow!(
                "Partition group {} does not have enough space ({} used out of {})",
                group.name,
                group_usage[index],
                group.size
            ));
        }
    }

    let metadata = metadata_blob(
        &effective_spec,
        metadata_size,
        logical_block_size,
        &groups,
        &spec.partitions,
        &extents,
    )?;
    let geometry = geometry_blob(metadata_size, metadata_slots, logical_block_size);

    let partition_extents: Vec<PartitionExtent> = spec
        .partitions
        .iter()
        .zip(extent_lookup.iter())
        .filter_map(|(partition, lookup)| {
            lookup.map(|index| PartitionExtent {
                name: partition.name.clone(),
                offset: extents[index].0 * SECTOR_SIZE,
                size: extents[index].1 * SECTOR_SIZE,
            })
        })
        .collect();

    let has_images = spec.partitions.iter().any(|partition| partition.has_image);
    let head = if !has_images {
        // `lpmake` writes a compact super_empty image when no --image is
        // given: geometry first, then the metadata without slot padding.
        let mut head = geometry;
        head.extend_from_slice(&metadata.blob);
        head
    } else {
        let head_len = partition_extents
            .first()
            .map(|extent| extent.offset)
            .unwrap_or(logical_start);
        let mut head = vec![0u8; head_len as usize];
        head[RESERVED_BYTES as usize..RESERVED_BYTES as usize + GEOMETRY_SIZE as usize]
            .copy_from_slice(&geometry);
        let backup = (RESERVED_BYTES + GEOMETRY_SIZE) as usize;
        head[backup..backup + GEOMETRY_SIZE as usize].copy_from_slice(&geometry);
        let mut slot = (RESERVED_BYTES + GEOMETRY_SIZE * 2) as usize;
        for _ in 0..metadata_slots * 2 {
            head[slot..slot + metadata.blob.len()].copy_from_slice(&metadata.blob);
            slot += metadata_size as usize;
        }
        head
    };
    Ok(SuperLayout {
        head,
        extents: partition_extents,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(virtual_ab: bool) -> SuperSpec {
        SuperSpec {
            device_size: 16 * 1024 * 1024,
            super_name: "super".into(),
            metadata_size: 65536,
            metadata_slots: 3,
            virtual_ab,
            logical_block_size: 4096,
            alignment: 1 << 20,
            groups: vec![
                SuperGroup {
                    name: "qti_dynamic_partitions_a".into(),
                    size: 12 * 1024 * 1024,
                },
                SuperGroup {
                    name: "qti_dynamic_partitions_b".into(),
                    size: 12 * 1024 * 1024,
                },
            ],
            partitions: vec![
                SuperPartition {
                    name: "system_a".into(),
                    size: 1024 * 1024,
                    group: "qti_dynamic_partitions_a".into(),
                    readonly: true,
                    has_image: true,
                },
                SuperPartition {
                    name: "system_b".into(),
                    size: 0,
                    group: "qti_dynamic_partitions_b".into(),
                    readonly: true,
                    has_image: false,
                },
            ],
        }
    }

    fn u16_at(bytes: &[u8], offset: usize) -> u16 {
        u16::from_le_bytes(bytes[offset..offset + 2].try_into().unwrap())
    }

    fn u32_at(bytes: &[u8], offset: usize) -> u32 {
        u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
    }

    fn u64_at(bytes: &[u8], offset: usize) -> u64 {
        u64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap())
    }

    #[test]
    fn geometry_and_header_match_lpmake() {
        let layout = super_layout(sample(true)).unwrap();
        assert_eq!(layout.head.len(), 1024 * 1024);
        assert_eq!(layout.extents.len(), 1);
        assert_eq!(layout.extents[0].name, "system_a");
        assert_eq!(layout.extents[0].offset, 1024 * 1024);
        assert_eq!(layout.extents[0].size, 1024 * 1024);
        let geometry = &layout.head[4096..8192];
        assert_eq!(u32_at(geometry, 0), GEOMETRY_MAGIC);
        assert_eq!(u32_at(geometry, 4), 52);
        assert_eq!(u32_at(geometry, 40), 65536);
        assert_eq!(u32_at(geometry, 44), 3);
        assert_eq!(u32_at(geometry, 48), 4096);
        let mut check = geometry[..52].to_vec();
        check[8..40].fill(0);
        assert_eq!(&check[8..40], &[0u8; 32]);
        let checksum = sha256(&check);
        assert_eq!(&checksum[..], &geometry[8..40]);
        assert_eq!(&layout.head[4096..8192], &layout.head[8192..12288]);

        let header = &layout.head[12288..12544];
        assert_eq!(u32_at(header, 0), HEADER_MAGIC);
        assert_eq!(u16_at(header, 4), 10);
        assert_eq!(u16_at(header, 6), 2);
        assert_eq!(u32_at(header, 8), 256);
        assert_eq!(u32_at(header, 44), 336);
        assert_eq!(u32_at(header, 128), HEADER_FLAG_VIRTUAL_AB);
        let mut check = header.to_vec();
        check[12..44].fill(0);
        let checksum = sha256(&check);
        assert_eq!(&checksum[..], &header[12..44]);
        let tables = &layout.head[12544..12544 + 336];
        assert_eq!(&sha256(tables)[..], &header[48..80]);

        let device = &layout.head[12288 + 256 + 272..12288 + 256 + 336];
        assert_eq!(u64_at(device, 0), 2048);
        assert_eq!(u32_at(device, 8), 1 << 20);
        assert_eq!(u64_at(device, 16), 16 * 1024 * 1024);
        assert_eq!(&device[24..29], b"super");
        assert_eq!(u32_at(header, 80), 0);
        assert_eq!(u32_at(header, 84), 2);
        assert_eq!(u32_at(header, 88), 52);
        assert_eq!(u32_at(header, 92), 104);
        assert_eq!(u32_at(header, 96), 1);
        assert_eq!(u32_at(header, 100), 24);
        assert_eq!(u32_at(header, 104), 128);
        assert_eq!(u32_at(header, 108), 3);
        assert_eq!(u32_at(header, 112), 48);
        assert_eq!(u32_at(header, 116), 272);
        assert_eq!(u32_at(header, 120), 1);
        assert_eq!(u32_at(header, 124), 64);

        let partitions = &tables[..104];
        assert_eq!(&partitions[..8], b"system_a");
        assert_eq!(u32_at(partitions, 36), PARTITION_ATTR_READONLY);
        assert_eq!(u32_at(partitions, 40), 0);
        assert_eq!(u32_at(partitions, 44), 1);
        assert_eq!(u32_at(partitions, 48), 1);
        let second = &partitions[52..];
        assert_eq!(&second[..8], b"system_b");
        assert_eq!(u32_at(second, 44), 0);
        assert_eq!(u32_at(second, 48), 2);
        let extent = &tables[104..128];
        assert_eq!(u64_at(extent, 0), 2048);
        assert_eq!(u32_at(extent, 8), 0);
        assert_eq!(u32_at(extent, 12), 2048);
        assert_eq!(u32_at(extent, 16), 0);
        assert_eq!(&tables[128..135], b"default");
        assert_eq!(u64_at(tables, 168), 0);
        assert_eq!(&tables[176..200], b"qti_dynamic_partitions_a");
        assert_eq!(u64_at(tables, 216), 12 * 1024 * 1024);
    }

    #[test]
    fn unaligned_sizes_and_alignment_gaps() {
        let mut spec = sample(true);
        spec.partitions = vec![
            SuperPartition {
                name: "system_a".into(),
                size: 12345,
                group: "qti_dynamic_partitions_a".into(),
                readonly: true,
                has_image: true,
            },
            SuperPartition {
                name: "vendor_a".into(),
                size: 1048576,
                group: "qti_dynamic_partitions_a".into(),
                readonly: true,
                has_image: true,
            },
        ];
        let layout = super_layout(spec).unwrap();
        assert_eq!(layout.extents[0].offset, 1024 * 1024);
        assert_eq!(layout.extents[0].size, 16384);
        assert_eq!(layout.extents[1].offset, 2 * 1024 * 1024);
        assert_eq!(layout.extents[1].size, 1024 * 1024);
        assert_eq!(layout.head.len(), 1024 * 1024);
    }

    #[test]
    fn v1_0_header_without_virtual_ab() {
        let layout = super_layout(sample(false)).unwrap();
        let header = &layout.head[12288..12416];
        assert_eq!(u16_at(header, 6), 0);
        assert_eq!(u32_at(header, 8), 128);
    }

    #[test]
    fn compact_image_without_images() {
        let mut spec = sample(true);
        for partition in &mut spec.partitions {
            partition.has_image = false;
        }
        let layout = super_layout(spec).unwrap();
        assert_eq!(layout.extents.len(), 1);
        assert_eq!(layout.head.len(), 4096 + 592);
        assert_eq!(u32_at(&layout.head, 0), GEOMETRY_MAGIC);
        assert_eq!(u32_at(&layout.head[4096..], 0), HEADER_MAGIC);
    }

    #[test]
    fn rejects_group_overflow_and_bad_names() {
        let mut spec = sample(true);
        spec.groups[0].size = 4096;
        assert!(super_layout(spec).is_err());
        let mut spec = sample(true);
        spec.partitions[0].name = "x".repeat(37);
        assert!(super_layout(spec).is_err());
    }
}
