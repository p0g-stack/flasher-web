//! Anti-rollback metadata in a Qualcomm `xbl_config` image.
//!
//! A port of otaripper (Apache-2.0) `src/cmd/arbscan.rs`: read the ELF64
//! program headers, pick the first non-executable segment that holds a hash
//! header, and report the OEM metadata that follows its common and QTI data.

use anyhow::{bail, ensure, Context};
use flutter_rust_bridge::frb;

/// Errors are plain messages; callers show them next to the failing step.
type Result<T, E = anyhow::Error> = std::result::Result<T, E>;

/// OEM metadata: versions and the anti-rollback index.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ArbInfo {
    pub major: u32,
    pub minor: u32,
    pub index: u32,
}

/// Size of the hash header before the common/QTI/table payloads.
const HASH_HEADER_SIZE: usize = 36;
const HASH_SCAN_MAX: usize = 0x1000;
const MAX_SEGMENT_SIZE: u64 = 20 * 1024 * 1024;
const MAX_PROGRAM_HEADER_TABLE: usize = 65536;
const ELF_HEADER_SIZE: usize = 64;
const PROGRAM_HEADER_SIZE: usize = 56;

fn read_u16(bytes: &[u8], offset: usize) -> Option<u16> {
    Some(u16::from_le_bytes(bytes.get(offset..offset + 2)?.try_into().ok()?))
}

fn read_u32(bytes: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_le_bytes(bytes.get(offset..offset + 4)?.try_into().ok()?))
}

fn read_u64(bytes: &[u8], offset: usize) -> Option<u64> {
    Some(u64::from_le_bytes(bytes.get(offset..offset + 8)?.try_into().ok()?))
}

/// Offset of a plausible hash header, found on the 4-byte grid otaripper uses.
fn hash_header(segment: &[u8]) -> Option<usize> {
    for offset in (0..HASH_SCAN_MAX.min(segment.len())).step_by(4) {
        if offset + HASH_HEADER_SIZE > segment.len() {
            break;
        }
        let version = read_u32(segment, offset)?;
        let common_size = read_u32(segment, offset + 4)? as usize;
        let qti_size = read_u32(segment, offset + 8)? as usize;
        let oem_size = read_u32(segment, offset + 12)? as usize;
        let table_size = read_u32(segment, offset + 16)? as usize;

        if !(1..=10).contains(&version) {
            continue;
        }
        if common_size > 0x1000 || qti_size > 0x1000 || oem_size > 0x4000 {
            continue;
        }
        // SHA-256 tables are multiples of 32 and SHA-384 of 48; 16 covers both.
        if table_size == 0 || table_size % 16 != 0 {
            continue;
        }
        if offset + HASH_HEADER_SIZE + common_size + qti_size + oem_size > segment.len() {
            continue;
        }
        return Some(offset);
    }
    None
}

/// Major/minor version and ARB index of an `xbl_config` image.
///
/// Fails for anything that is not a little-endian ELF64 image carrying the
/// expected OEM metadata; the caller skips ARB then, as upstream does.
#[frb(sync)]
pub fn arb_scan(image: Vec<u8>) -> Result<ArbInfo> {
    ensure!(
        image.len() >= ELF_HEADER_SIZE,
        "xbl_config is too small to be an ELF64 image"
    );
    ensure!(&image[0..4] == b"\x7fELF", "xbl_config is not an ELF image");
    ensure!(image[4] == 2, "xbl_config is not a 64-bit ELF image");
    ensure!(image[5] == 1, "xbl_config is not a little-endian ELF image");

    let program_headers = read_u64(&image, 0x20).context("truncated ELF header")?;
    let entry_size = read_u16(&image, 0x36).unwrap_or(0) as usize;
    let count = read_u16(&image, 0x38).unwrap_or(0) as usize;
    ensure!(
        entry_size >= PROGRAM_HEADER_SIZE && count > 0,
        "unexpected ELF program header layout"
    );
    let table_size = count
        .checked_mul(entry_size)
        .context("program header table overflows")?;
    ensure!(
        table_size <= MAX_PROGRAM_HEADER_TABLE,
        "program header table too large"
    );
    let table_start = usize::try_from(program_headers)
        .ok()
        .filter(|start| start.checked_add(table_size).is_some_and(|end| end <= image.len()))
        .context("program header table is outside the image")?;
    let table = &image[table_start..table_start + table_size];

    for index in 0..count {
        let entry = &table[index * entry_size..(index + 1) * entry_size];
        let flags = read_u32(entry, 4).unwrap_or(0);
        let offset = read_u64(entry, 8).unwrap_or(u64::MAX);
        let size = read_u64(entry, 32).unwrap_or(0);

        // Only non-executable segments of a sane size can hold the metadata.
        if flags & 1 != 0 || size < HASH_HEADER_SIZE as u64 || size > MAX_SEGMENT_SIZE {
            continue;
        }
        let Some(end) = offset.checked_add(size) else {
            continue;
        };
        if end > image.len() as u64 {
            continue;
        }
        let start = offset as usize;
        let segment = &image[start..end as usize];

        let Some(header) = hash_header(segment) else {
            continue;
        };
        let common_size = read_u32(segment, header + 4).unwrap_or(0) as usize;
        let qti_size = read_u32(segment, header + 8).unwrap_or(0) as usize;
        let oem = header + HASH_HEADER_SIZE + common_size + qti_size;
        if oem + 12 > segment.len() {
            continue;
        }
        let major = read_u32(segment, oem).unwrap_or(0);
        let minor = read_u32(segment, oem + 4).unwrap_or(0);
        let arb = read_u32(segment, oem + 8).unwrap_or(0);

        // ARB index 0 is valid; anything wild means this is not the segment.
        if major < 1000 && minor < 1000 && arb < 128 {
            return Ok(ArbInfo { major, minor, index: arb });
        }
    }
    bail!("valid OEM ARB metadata not found in xbl_config")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn elf_with_segment(segment: &[u8], executable: bool, trailing: &[u8]) -> Vec<u8> {
        let header = ELF_HEADER_SIZE + PROGRAM_HEADER_SIZE;
        let mut image = vec![0u8; header];
        image[0..4].copy_from_slice(b"\x7fELF");
        image[4] = 2;
        image[5] = 1;
        image[6] = 1;
        image[0x20..0x28].copy_from_slice(&(ELF_HEADER_SIZE as u64).to_le_bytes());
        image[0x36..0x38].copy_from_slice(&(PROGRAM_HEADER_SIZE as u16).to_le_bytes());
        image[0x38..0x3a].copy_from_slice(&1u16.to_le_bytes());

        let ph = ELF_HEADER_SIZE;
        let flags: u32 = if executable { 1 } else { 4 };
        image[ph + 4..ph + 8].copy_from_slice(&flags.to_le_bytes());
        image[ph + 8..ph + 16].copy_from_slice(&(header as u64).to_le_bytes());
        image[ph + 32..ph + 40].copy_from_slice(&(segment.len() as u64).to_le_bytes());
        image.extend_from_slice(segment);
        image.extend_from_slice(trailing);
        image
    }

    fn metadata(major: u32, minor: u32, index: u32) -> (Vec<u8>, usize) {
        let mut segment = vec![0u8; 12];
        let header = segment.len();
        let mut hash = vec![0u8; HASH_HEADER_SIZE];
        hash[0..4].copy_from_slice(&1u32.to_le_bytes());
        hash[4..8].copy_from_slice(&8u32.to_le_bytes());
        hash[8..12].copy_from_slice(&4u32.to_le_bytes());
        hash[12..16].copy_from_slice(&12u32.to_le_bytes());
        hash[16..20].copy_from_slice(&32u32.to_le_bytes());
        segment.extend_from_slice(&hash);
        segment.extend_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8]);
        segment.extend_from_slice(&[9, 10, 11, 12]);
        segment.extend_from_slice(&major.to_le_bytes());
        segment.extend_from_slice(&minor.to_le_bytes());
        segment.extend_from_slice(&index.to_le_bytes());
        (segment, header)
    }

    #[test]
    fn reads_oem_metadata() {
        let (segment, _) = metadata(1, 0, 1);
        let info = arb_scan(elf_with_segment(&segment, false, &[])).unwrap();
        assert_eq!(info, ArbInfo { major: 1, minor: 0, index: 1 });
    }

    #[test]
    fn skips_executable_and_short_segments() {
        let (segment, _) = metadata(2, 3, 0);
        assert!(arb_scan(elf_with_segment(&segment, true, &[])).is_err());
        assert!(arb_scan(elf_with_segment(&segment[..HASH_HEADER_SIZE], false, &[])).is_err());
    }

    #[test]
    fn rejects_bad_images_cleanly() {
        let (segment, _) = metadata(1, 0, 1);
        let mut elf = elf_with_segment(&segment, false, &[]);
        assert!(arb_scan(elf.clone()).is_ok());

        assert!(arb_scan(b"not an elf".to_vec()).is_err());
        assert!(arb_scan(vec![0u8; 64]).is_err());
        assert!(arb_scan(vec![]).is_err());

        elf[5] = 2;
        assert!(arb_scan(elf.clone()).is_err());
        elf[5] = 1;

        elf[4] = 1;
        assert!(arb_scan(elf.clone()).is_err());
        elf[4] = 2;

        // Program header table points past the end of the image.
        elf[0x20..0x28].copy_from_slice(&u64::MAX.to_le_bytes());
        assert!(arb_scan(elf.clone()).is_err());
        elf[0x20..0x28].copy_from_slice(&(ELF_HEADER_SIZE as u64).to_le_bytes());

        // Metadata values that do not look like an OEM header.
        let (mut wild, _) = metadata(5000, 0, 1);
        let wild_at = wild.len() - 12;
        wild[wild_at..wild_at + 4].copy_from_slice(&5000u32.to_le_bytes());
        assert!(arb_scan(elf_with_segment(&wild, false, &[])).is_err());
    }
}
