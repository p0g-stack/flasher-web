//! `avbtool make_vbmeta_image --include_descriptors_from_image … --flags …
//! --rollback_index …` with the NONE algorithm and no key.
//!
//! Ported from AOSP `external/avb/avbtool.py` (Apache-2.0), the subset the
//! upstream Ace 6 conversion uses. The output is byte-identical to avbtool.
use flutter_rust_bridge::frb;

use anyhow::Result;

pub const VBMETA_MAGIC: &[u8; 4] = b"AVB0";
pub const FOOTER_MAGIC: &[u8; 4] = b"AVBf";
pub const HEADER_SIZE: usize = 256;
pub const FOOTER_SIZE: usize = 64;
pub const VERSION_MAJOR: u32 = 1;
pub const VERSION_MINOR: u32 = 0;
pub const RELEASE_STRING: &str = "avbtool 1.3.0";

const TAG_PROPERTY: u64 = 0;
const TAG_HASHTREE: u64 = 1;
const TAG_HASH: u64 = 2;
const TAG_KERNEL_CMDLINE: u64 = 3;
const TAG_CHAIN_PARTITION: u64 = 4;

fn be_u32(data: &[u8], offset: usize) -> Result<u32> {
    data.get(offset..offset + 4)
        .map(|bytes| u32::from_be_bytes(bytes.try_into().unwrap()))
        .ok_or_else(|| anyhow::anyhow!("Truncated vbmeta image"))
}

fn be_u64(data: &[u8], offset: usize) -> Result<u64> {
    data.get(offset..offset + 8)
        .map(|bytes| u64::from_be_bytes(bytes.try_into().unwrap()))
        .ok_or_else(|| anyhow::anyhow!("Truncated vbmeta image"))
}

fn round_up(value: usize, alignment: usize) -> usize {
    value.div_ceil(alignment) * alignment
}

/// The class name avbtool uses for a descriptor tag, part of its dedupe key
/// (`type(desc).__name__ + '_' + desc.partition_name`).
fn class_name(tag: u64) -> &'static str {
    match tag {
        TAG_PROPERTY => "AvbPropertyDescriptor",
        TAG_HASHTREE => "AvbHashtreeDescriptor",
        TAG_HASH => "AvbHashDescriptor",
        TAG_KERNEL_CMDLINE => "AvbKernelCmdlineDescriptor",
        TAG_CHAIN_PARTITION => "AvbChainPartitionDescriptor",
        _ => "AvbDescriptor",
    }
}

/// Offset of the fixed descriptor header, the name length field and the
/// partition name inside the encoded descriptor, for the tags that carry a
/// partition name (`SIZE` in avbtool).
fn partition_name_offset(tag: u64) -> Option<(usize, usize)> {
    match tag {
        TAG_HASHTREE => Some((180, 104)),
        TAG_HASH => Some((132, 56)),
        TAG_CHAIN_PARTITION => Some((92, 20)),
        _ => None,
    }
}

struct Descriptor {
    tag: u64,
    bytes: Vec<u8>,
    partition_name: Option<String>,
}

fn parse_descriptors(blob: &[u8]) -> Result<Vec<Descriptor>> {
    let mut offset = 0usize;
    let mut descriptors = Vec::new();
    while offset < blob.len() {
        let (tag, following) = (be_u64(blob, offset)?, be_u64(blob, offset + 8)?);
        let end = offset
            .checked_add(16)
            .and_then(|start| start.checked_add(following as usize))
            .ok_or_else(|| anyhow::anyhow!("Descriptor size overflows"))?;
        if end > blob.len() {
            return Err(anyhow::anyhow!("Truncated vbmeta descriptor"));
        }
        let bytes = blob[offset..end].to_vec();
        let partition_name = match partition_name_offset(tag) {
            Some((fixed, length_offset)) => {
                if following as usize + 16 < fixed {
                    return Err(anyhow::anyhow!("Truncated partition descriptor"));
                }
                let length = be_u32(&bytes, length_offset)? as usize;
                let start = fixed;
                let name = bytes
                    .get(start..start + length)
                    .ok_or_else(|| anyhow::anyhow!("Truncated partition name"))?;
                Some(
                    String::from_utf8(name.to_vec())
                        .map_err(|_| anyhow::anyhow!("Partition name is not UTF-8"))?,
                )
            }
            None => None,
        };
        descriptors.push(Descriptor {
            tag,
            bytes,
            partition_name,
        });
        offset = end;
    }
    Ok(descriptors)
}

/// Parses one image: a bare vbmeta, or an image with an `AVBf` footer.
fn parse_image(image: &[u8]) -> Result<(u32, Vec<Descriptor>)> {
    if image.len() >= 4 && u32::from_le_bytes(image[..4].try_into().unwrap()) == 0xed26_ff3a {
        return Err(anyhow::anyhow!(
            "Sparse images are not supported as descriptor sources"
        ));
    }
    let mut vbmeta_offset = 0usize;
    if image.len() >= FOOTER_SIZE {
        let footer = &image[image.len() - FOOTER_SIZE..];
        if footer[..4] == *FOOTER_MAGIC {
            vbmeta_offset = be_u64(footer, 20)? as usize;
        }
    }
    let header = image
        .get(vbmeta_offset..vbmeta_offset + HEADER_SIZE)
        .ok_or_else(|| anyhow::anyhow!("Given image does not look like a vbmeta image"))?;
    if &header[..4] != VBMETA_MAGIC {
        return Err(anyhow::anyhow!(
            "Given image does not look like a vbmeta image"
        ));
    }
    let minor = be_u32(header, 8)?;
    let auth_size = be_u64(header, 12)? as usize;
    let descriptors_offset = be_u64(header, 96)? as usize;
    let descriptors_size = be_u64(header, 104)? as usize;
    let start = vbmeta_offset
        .checked_add(HEADER_SIZE)
        .and_then(|value| value.checked_add(auth_size))
        .and_then(|value| value.checked_add(descriptors_offset))
        .ok_or_else(|| anyhow::anyhow!("Descriptor offset overflows"))?;
    let blob = image
        .get(start..start + descriptors_size)
        .ok_or_else(|| anyhow::anyhow!("Truncated vbmeta descriptors"))?;
    Ok((minor, parse_descriptors(blob)?))
}

/// The bytes `avbtool make_vbmeta_image --include_descriptors_from_image
/// <each of include_descriptors_from> --flags <flags> --rollback_index
/// <rollback_index>` writes, with `--algorithm NONE` and no key.
#[frb(sync)]
pub fn make_vbmeta(
    include_descriptors_from: Vec<Vec<u8>>,
    flags: u32,
    rollback_index: u64,
) -> Result<Vec<u8>> {
    let mut minor = VERSION_MINOR;
    let mut encoded = Vec::new();
    let mut keyed: Vec<(String, Vec<u8>)> = Vec::new();
    for image in &include_descriptors_from {
        let (image_minor, descriptors) = parse_image(image)?;
        minor = minor.max(image_minor);
        for descriptor in descriptors {
            match descriptor.partition_name {
                Some(name) => {
                    let key = format!("{}_{}", class_name(descriptor.tag), name);
                    // avbtool keeps only the last descriptor for a partition.
                    keyed.retain(|(existing, _)| *existing != key);
                    keyed.push((key, descriptor.bytes));
                }
                None => encoded.extend_from_slice(&descriptor.bytes),
            }
        }
    }
    keyed.sort_by(|left, right| left.0.cmp(&right.0));
    for (_, descriptor) in keyed {
        encoded.extend_from_slice(&descriptor);
    }

    // NONE: no authentication block, no public key, no public key metadata.
    let auxiliary_size = round_up(encoded.len(), 64);
    let mut header = vec![0u8; HEADER_SIZE];
    header[..4].copy_from_slice(VBMETA_MAGIC);
    header[4..8].copy_from_slice(&VERSION_MAJOR.to_be_bytes());
    header[8..12].copy_from_slice(&minor.to_be_bytes());
    header[12..20].copy_from_slice(&0u64.to_be_bytes()); // authentication block size
    header[20..28].copy_from_slice(&(auxiliary_size as u64).to_be_bytes());
    header[28..32].copy_from_slice(&0u32.to_be_bytes()); // algorithm type NONE
    header[96..104].copy_from_slice(&0u64.to_be_bytes()); // descriptors offset
    header[104..112].copy_from_slice(&(encoded.len() as u64).to_be_bytes());
    // avbtool places the (empty) key and key metadata after the descriptors.
    header[64..72].copy_from_slice(&(encoded.len() as u64).to_be_bytes());
    header[80..88].copy_from_slice(&(encoded.len() as u64).to_be_bytes());
    header[112..120].copy_from_slice(&rollback_index.to_be_bytes());
    header[120..124].copy_from_slice(&flags.to_be_bytes());
    header[124..128].copy_from_slice(&0u32.to_be_bytes()); // rollback index location
    let release = RELEASE_STRING.as_bytes();
    let release_len = release.len().min(47);
    header[128..128 + release_len].copy_from_slice(&release[..release_len]);

    let mut blob = header;
    blob.extend_from_slice(&encoded);
    blob.resize(HEADER_SIZE + auxiliary_size, 0);
    Ok(blob)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hashtree(partition: &str, marker: u8) -> Vec<u8> {
        let following = round_up(164 + partition.len(), 8);
        let mut descriptor = vec![0u8; 180];
        descriptor[..8].copy_from_slice(&TAG_HASHTREE.to_be_bytes());
        descriptor[8..16].copy_from_slice(&(following as u64).to_be_bytes());
        descriptor[20..28].copy_from_slice(&(marker as u64).to_be_bytes());
        descriptor[104..108].copy_from_slice(&(partition.len() as u32).to_be_bytes());
        descriptor.extend_from_slice(partition.as_bytes());
        descriptor.resize(16 + following, 0);
        descriptor
    }

    fn property(key: &str) -> Vec<u8> {
        let following = round_up(16 + key.len(), 8);
        let mut descriptor = vec![0u8; 32];
        descriptor[..8].copy_from_slice(&TAG_PROPERTY.to_be_bytes());
        descriptor[8..16].copy_from_slice(&(following as u64).to_be_bytes());
        descriptor[24..32].copy_from_slice(&(key.len() as u64).to_be_bytes());
        descriptor.extend_from_slice(key.as_bytes());
        descriptor.resize(16 + following, 0);
        descriptor
    }

    fn vbmeta(descriptors: &[Vec<u8>], minor: u32) -> Vec<u8> {
        let encoded: Vec<u8> = descriptors.iter().flatten().copied().collect();
        let mut header = vec![0u8; HEADER_SIZE];
        header[..4].copy_from_slice(VBMETA_MAGIC);
        header[4..8].copy_from_slice(&1u32.to_be_bytes());
        header[8..12].copy_from_slice(&minor.to_be_bytes());
        header[20..28].copy_from_slice(&(round_up(encoded.len(), 64) as u64).to_be_bytes());
        header[104..112].copy_from_slice(&(encoded.len() as u64).to_be_bytes());
        header.extend_from_slice(&encoded);
        header.resize(HEADER_SIZE + round_up(encoded.len(), 64), 0);
        header
    }

    #[test]
    fn copies_descriptors_and_sets_header_fields() {
        let first = hashtree("vbmeta_system", 1);
        let second = property("com.android.build.boot.security_patch");
        let blob = make_vbmeta(vec![vbmeta(&[first.clone(), second.clone()], 2)], 3, 0).unwrap();
        assert_eq!(&blob[..4], VBMETA_MAGIC);
        assert_eq!(be_u32(&blob, 4).unwrap(), 1);
        assert_eq!(be_u32(&blob, 8).unwrap(), 2);
        assert_eq!(be_u64(&blob, 12).unwrap(), 0);
        assert_eq!(be_u32(&blob, 28).unwrap(), 0);
        assert_eq!(be_u64(&blob, 112).unwrap(), 0);
        assert_eq!(be_u32(&blob, 120).unwrap(), 3);
        assert_eq!(&blob[128..128 + RELEASE_STRING.len()], b"avbtool 1.3.0");
        let descriptor_size = be_u64(&blob, 104).unwrap() as usize;
        assert_eq!(
            be_u64(&blob, 20).unwrap() as usize,
            round_up(descriptor_size, 64)
        );
        assert_eq!(&blob[HEADER_SIZE..HEADER_SIZE + second.len()], &second[..]);
        assert_eq!(
            &blob[HEADER_SIZE + second.len()..HEADER_SIZE + descriptor_size],
            &first[..]
        );
    }

    #[test]
    fn keeps_last_descriptor_per_partition_and_sorts_by_key() {
        let blob = make_vbmeta(
            vec![
                vbmeta(&[hashtree("system", 1), hashtree("vendor", 2)], 0),
                vbmeta(&[hashtree("system", 9)], 0),
            ],
            3,
            0,
        )
        .unwrap();
        let size = be_u64(&blob, 104).unwrap() as usize;
        let descriptors = parse_descriptors(&blob[HEADER_SIZE..HEADER_SIZE + size]).unwrap();
        let names: Vec<&str> = descriptors
            .iter()
            .map(|d| d.partition_name.as_deref().unwrap())
            .collect();
        assert_eq!(names, vec!["system", "vendor"]);
        assert_eq!(descriptors[0].bytes, hashtree("system", 9));
    }

    #[test]
    fn reads_descriptors_behind_a_footer() {
        let inner = vbmeta(&[hashtree("boot", 0)], 0);
        let mut image = b"payload".to_vec();
        let vbmeta_offset = image.len() as u64;
        image.extend_from_slice(&inner);
        let mut footer = vec![0u8; FOOTER_SIZE];
        footer[..4].copy_from_slice(FOOTER_MAGIC);
        footer[20..28].copy_from_slice(&vbmeta_offset.to_be_bytes());
        image.extend_from_slice(&footer);
        let blob = make_vbmeta(vec![image], 3, 0).unwrap();
        assert_eq!(be_u32(&blob, 8).unwrap(), 0);
        assert_eq!(
            be_u64(&blob, 104).unwrap(),
            hashtree("boot", 0).len() as u64
        );
    }

    #[test]
    fn rejects_non_vbmeta_input() {
        assert!(make_vbmeta(vec![vec![0u8; 512]], 3, 0).is_err());
    }
}
