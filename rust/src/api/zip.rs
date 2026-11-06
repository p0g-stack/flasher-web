//! Reading ZIP metadata for a large archive the caller holds elsewhere.
//!
//! The core reads only slices of an OTA: [`zip_entries`] looks at the last
//! bytes for the end-of-central-directory record and, when the directory is
//! not inside that tail, asks for it explicitly. Layout follows the ZIP
//! APPNOTE 6.3.10, including the ZIP64 records real OnePlus OTAs use.

use anyhow::{bail, ensure, Context};
use flutter_rust_bridge::frb;

/// Errors are plain messages; callers show them next to the failing step.
type Result<T, E = anyhow::Error> = std::result::Result<T, E>;

const EOCD_SIG: &[u8; 4] = b"PK\x05\x06";
const ZIP64_EOCD_SIG: &[u8; 4] = b"PK\x06\x06";
const ZIP64_LOCATOR_SIG: &[u8; 4] = b"PK\x06\x07";
const CENTRAL_SIG: &[u8; 4] = b"PK\x01\x02";
const CENTRAL_DIGITAL_SIG: &[u8; 4] = b"PK\x05\x05";
const LOCAL_SIG: &[u8; 4] = b"PK\x03\x04";
const SENTINEL_U16: u16 = 0xffff;
const SENTINEL_U32: u32 = 0xffff_ffff;

/// One central-directory entry, sizes and offsets as stored (ZIP64 resolved).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ZipEntry {
    pub name: String,
    pub method: u16,
    pub compressed_size: u64,
    pub uncompressed_size: u64,
    pub crc32: u32,
    pub local_header_offset: u64,
    pub unix_mode: u32,
}

/// A central directory, or the absolute range to read and parse next.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ZipDirectory {
    /// `(offset, length)` of the central directory when it is not in the tail.
    pub needs: Option<(u64, u64)>,
    pub entries: Vec<ZipEntry>,
}

fn slice(buf: &[u8], offset: usize, len: usize) -> Result<&[u8]> {
    let end = offset.checked_add(len).context("ZIP offset overflow")?;
    buf.get(offset..end).context("truncated ZIP structure")
}

fn u16_at(buf: &[u8], offset: usize) -> Result<u16> {
    Ok(u16::from_le_bytes(
        slice(buf, offset, 2)?.try_into().expect("two bytes"),
    ))
}

fn u32_at(buf: &[u8], offset: usize) -> Result<u32> {
    Ok(u32::from_le_bytes(
        slice(buf, offset, 4)?.try_into().expect("four bytes"),
    ))
}

fn u64_at(buf: &[u8], offset: usize) -> Result<u64> {
    Ok(u64::from_le_bytes(
        slice(buf, offset, 8)?.try_into().expect("eight bytes"),
    ))
}

fn signature_is(buf: &[u8], offset: usize, sig: &[u8; 4]) -> bool {
    buf.get(offset..offset.saturating_add(4)) == Some(&sig[..])
}

/// Find the EOCD record that ends at the end of `tail`.
///
/// A comment may contain the signature, so only a record whose comment length
/// reaches the end of the tail counts.
fn find_eocd(tail: &[u8]) -> Result<usize> {
    if tail.len() < 22 {
        bail!("ZIP end-of-central-directory record not found");
    }
    for offset in (0..=tail.len() - 22).rev() {
        if !signature_is(tail, offset, EOCD_SIG) {
            continue;
        }
        let comment_len = u16_at(tail, offset + 20)? as usize;
        if offset + 22 + comment_len == tail.len() {
            return Ok(offset);
        }
    }
    bail!("ZIP end-of-central-directory record not found")
}

/// Resolve the central-directory size and offset, through ZIP64 when asked.
fn directory_span(tail: &[u8], eocd: usize, tail_base: u64) -> Result<(u64, u64)> {
    let cd_size = u32_at(tail, eocd + 12)? as u64;
    let cd_offset = u32_at(tail, eocd + 16)? as u64;
    let entries = u16_at(tail, eocd + 10)?;
    if cd_size != SENTINEL_U32 as u64 && cd_offset != SENTINEL_U32 as u64 && entries != SENTINEL_U16 {
        return Ok((cd_size, cd_offset));
    }

    let locator = eocd.checked_sub(20).context("missing ZIP64 end locator")?;
    ensure!(
        signature_is(tail, locator, ZIP64_LOCATOR_SIG),
        "missing ZIP64 end-of-central-directory locator"
    );
    ensure!(u32_at(tail, locator + 4)? == 0, "multi-disk ZIP archives are unsupported");
    ensure!(u32_at(tail, locator + 16)? == 1, "multi-disk ZIP archives are unsupported");
    let record_offset = u64_at(tail, locator + 8)?;
    let record = record_offset
        .checked_sub(tail_base)
        .context("ZIP64 end-of-central-directory record is outside the tail")?;
    let record = usize::try_from(record).context("ZIP64 offset too large")?;
    ensure!(
        signature_is(tail, record, ZIP64_EOCD_SIG),
        "invalid ZIP64 end-of-central-directory record"
    );
    ensure!(u64_at(tail, record + 4)? >= 44, "short ZIP64 end-of-central-directory record");
    ensure!(u32_at(tail, record + 16)? == 0, "multi-disk ZIP archives are unsupported");
    ensure!(u32_at(tail, record + 20)? == 0, "multi-disk ZIP archives are unsupported");
    Ok((u64_at(tail, record + 40)?, u64_at(tail, record + 48)?))
}

/// Read the directory from the tail, or say which absolute range to read.
#[frb(sync)]
pub fn zip_entries(tail: Vec<u8>, file_len: u64) -> Result<ZipDirectory> {
    let tail_len = tail.len() as u64;
    ensure!(tail_len <= file_len, "the ZIP tail is longer than the file");
    let tail_base = file_len - tail_len;

    let eocd = find_eocd(&tail)?;
    ensure!(
        u16_at(&tail, eocd + 4)? == 0 && u16_at(&tail, eocd + 6)? == 0,
        "multi-disk ZIP archives are unsupported"
    );
    let (cd_size, cd_offset) = directory_span(&tail, eocd, tail_base)?;
    if cd_size == 0 {
        return Ok(ZipDirectory { needs: None, entries: Vec::new() });
    }

    let cd_end = cd_offset.checked_add(cd_size).context("ZIP range overflow")?;
    ensure!(cd_end <= file_len, "central directory extends past the end of the file");
    if cd_offset < tail_base {
        return Ok(ZipDirectory { needs: Some((cd_offset, cd_size)), entries: Vec::new() });
    }

    let start = usize::try_from(cd_offset - tail_base).context("ZIP64 offset too large")?;
    let len = usize::try_from(cd_size).context("central directory too large")?;
    let entries = zip_parse_central(slice(&tail, start, len)?.to_vec())?;
    Ok(ZipDirectory { needs: None, entries })
}

fn entry_name(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(name) => name.to_owned(),
        // ZIP names are CP437 without the UTF-8 flag; keep them lossless enough
        // to match the paths an OTA actually contains (all ASCII today).
        Err(_) => bytes.iter().map(|&byte| byte as char).collect(),
    }
}

/// Parse the bytes [`zip_entries`] asked for into entries.
#[frb(sync)]
pub fn zip_parse_central(cd: Vec<u8>) -> Result<Vec<ZipEntry>> {
    let mut offset = 0;
    let mut entries = Vec::new();
    while offset < cd.len() {
        if signature_is(&cd, offset, CENTRAL_DIGITAL_SIG) {
            // Records after the last entry: a digital signature, then padding.
            let len = u16_at(&cd, offset + 4)? as usize;
            offset += 6 + len;
            continue;
        }
        ensure!(
            signature_is(&cd, offset, CENTRAL_SIG),
            "invalid ZIP central-directory entry at offset {offset}"
        );
        ensure!(u16_at(&cd, offset + 8)? & 1 == 0, "encrypted ZIP entries are unsupported");

        let name_len = u16_at(&cd, offset + 28)? as usize;
        let extra_len = u16_at(&cd, offset + 30)? as usize;
        let comment_len = u16_at(&cd, offset + 32)? as usize;
        let name = entry_name(slice(&cd, offset + 46, name_len)?);
        let mut compressed_size = u32_at(&cd, offset + 20)? as u64;
        let mut uncompressed_size = u32_at(&cd, offset + 24)? as u64;
        let mut local_header_offset = u32_at(&cd, offset + 42)? as u64;
        let disk = u16_at(&cd, offset + 34)?;

        let mut zip64_seen = false;
        let extra = slice(&cd, offset + 46 + name_len, extra_len)?;
        let mut pos = 0;
        while pos < extra.len() {
            let tag = u16_at(extra, pos)?;
            let len = u16_at(extra, pos + 2)? as usize;
            let data = slice(extra, pos + 4, len)?;
            if tag == 1 {
                zip64_seen = true;
                let mut at = 0;
                for value in [&mut uncompressed_size, &mut compressed_size, &mut local_header_offset] {
                    if *value == SENTINEL_U32 as u64 {
                        *value = u64_at(data, at)?;
                        at += 8;
                    }
                }
                if disk == SENTINEL_U16 {
                    ensure!(u32_at(data, at)? == 0, "multi-disk ZIP archives are unsupported");
                }
            }
            pos += 4 + len;
        }
        let needs_zip64 = compressed_size == SENTINEL_U32 as u64
            || uncompressed_size == SENTINEL_U32 as u64
            || local_header_offset == SENTINEL_U32 as u64
            || disk == SENTINEL_U16;
        ensure!(
            zip64_seen || !needs_zip64,
            "ZIP64 fields without a ZIP64 extra field"
        );
        ensure!(
            disk == 0 || disk == SENTINEL_U16,
            "multi-disk ZIP archives are unsupported"
        );

        let create_system = u16_at(&cd, offset + 4)? >> 8;
        let unix_mode = if create_system == 3 { u32_at(&cd, offset + 38)? >> 16 } else { 0 };
        entries.push(ZipEntry {
            name,
            method: u16_at(&cd, offset + 10)?,
            compressed_size,
            uncompressed_size,
            crc32: u32_at(&cd, offset + 16)?,
            local_header_offset,
            unix_mode,
        });
        offset = offset
            .checked_add(46 + name_len + extra_len + comment_len)
            .context("ZIP offset overflow")?;
    }
    Ok(entries)
}

/// Absolute offset of a local entry's data, from its 30-byte fixed header.
#[frb(sync)]
pub fn zip_data_offset(local_header_30_bytes: Vec<u8>, local_header_offset: u64) -> Result<u64> {
    ensure!(
        signature_is(&local_header_30_bytes, 0, LOCAL_SIG),
        "invalid ZIP local header"
    );
    let name_len = u16_at(&local_header_30_bytes, 26)? as u64;
    let extra_len = u16_at(&local_header_30_bytes, 28)? as u64;
    local_header_offset
        .checked_add(30 + name_len + extra_len)
        .context("ZIP offset overflow")
}

/// Expand one raw deflate stream (method 8) to exactly `expected_len` bytes.
#[frb(sync)]
pub fn inflate_raw(data: Vec<u8>, expected_len: u64) -> Result<Vec<u8>> {
    use std::io::Read;

    let limit = expected_len.checked_add(1).context("ZIP entry size overflow")?;
    let mut out = Vec::with_capacity(expected_len.min(1 << 20) as usize);
    flate2::read::DeflateDecoder::new(&data[..])
        .take(limit)
        .read_to_end(&mut out)
        .context("invalid deflate stream")?;
    ensure!(
        out.len() as u64 == expected_len,
        "deflated entry is {} bytes, the directory says {expected_len}",
        out.len()
    );
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn central_entry(name: &str) -> Vec<u8> {
        let mut cd = vec![0u8; 46];
        cd[0..4].copy_from_slice(CENTRAL_SIG);
        cd[4..6].copy_from_slice(&((3u16 << 8) | 45).to_le_bytes());
        cd[6..8].copy_from_slice(&45u16.to_le_bytes());
        cd[10..12].copy_from_slice(&8u16.to_le_bytes());
        cd[16..20].copy_from_slice(&0x1234_5678u32.to_le_bytes());
        cd[20..24].copy_from_slice(&42u32.to_le_bytes());
        cd[24..28].copy_from_slice(&99u32.to_le_bytes());
        cd[28..30].copy_from_slice(&(name.len() as u16).to_le_bytes());
        cd[30..32].copy_from_slice(&0u16.to_le_bytes());
        cd[38..42].copy_from_slice(&(0o100644u32 << 16).to_le_bytes());
        cd.extend_from_slice(name.as_bytes());
        cd
    }

    fn zip64_extra(uncompressed: u64, compressed: u64, offset: u64) -> Vec<u8> {
        let mut extra = Vec::new();
        extra.extend_from_slice(&1u16.to_le_bytes());
        extra.extend_from_slice(&24u16.to_le_bytes());
        for value in [uncompressed, compressed, offset] {
            extra.extend_from_slice(&value.to_le_bytes());
        }
        extra
    }

    fn archive(entries: &[(&str, &[u8], bool)]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut directory = Vec::new();
        for (name, data, deflate) in entries {
            let stored = if *deflate {
                use std::io::Write;
                let mut encoder = flate2::write::DeflateEncoder::new(
                    Vec::new(),
                    flate2::Compression::fast(),
                );
                encoder.write_all(data).unwrap();
                encoder.finish().unwrap()
            } else {
                data.to_vec()
            };
            let local_offset = out.len() as u64;
            out.extend_from_slice(LOCAL_SIG);
            out.extend_from_slice(&45u16.to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(&(if *deflate { 8u16 } else { 0 }).to_le_bytes());
            out.extend_from_slice(&[0, 0, 0, 0]);
            out.extend_from_slice(&(if *deflate { 0u32 } else { crc_of(data) }).to_le_bytes());
            out.extend_from_slice(&(stored.len() as u32).to_le_bytes());
            out.extend_from_slice(&(data.len() as u32).to_le_bytes());
            out.extend_from_slice(&(name.len() as u16).to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(name.as_bytes());
            out.extend_from_slice(&stored);

            let mut cd = vec![0u8; 46];
            cd[0..4].copy_from_slice(CENTRAL_SIG);
            cd[4..6].copy_from_slice(&(((3u16) << 8) | 45).to_le_bytes());
            cd[10..12].copy_from_slice(&(if *deflate { 8u16 } else { 0 }).to_le_bytes());
            cd[38..42].copy_from_slice(&(0o100644u32 << 16).to_le_bytes());
            cd[16..20].copy_from_slice(&(if *deflate { 0u32 } else { crc_of(data) }).to_le_bytes());
            cd[20..24].copy_from_slice(&(stored.len() as u32).to_le_bytes());
            cd[24..28].copy_from_slice(&(data.len() as u32).to_le_bytes());
            cd[28..30].copy_from_slice(&(name.len() as u16).to_le_bytes());
            cd[42..46].copy_from_slice(&(local_offset as u32).to_le_bytes());
            cd.extend_from_slice(name.as_bytes());
            directory.extend_from_slice(&cd);
        }
        let directory_offset = out.len() as u64;
        out.extend_from_slice(&directory);
        out.extend_from_slice(EOCD_SIG);
        out.extend_from_slice(&[0, 0, 0, 0]);
        out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        out.extend_from_slice(&(directory.len() as u32).to_le_bytes());
        out.extend_from_slice(&(directory_offset as u32).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out
    }

    fn crc_of(data: &[u8]) -> u32 {
        let mut crc = crc32fast::Hasher::new();
        crc.update(data);
        crc.finalize()
    }

    #[test]
    fn reads_stored_and_deflated_entries() {
        let bytes = archive(&[("payload.bin", b"payload", false), ("meta.txt", b"hello meta", true)]);
        let tail_len = bytes.len();
        let directory = zip_entries(bytes.clone(), tail_len as u64).unwrap();
        assert!(directory.needs.is_none());
        assert_eq!(directory.entries.len(), 2);
        assert_eq!(directory.entries[0].name, "payload.bin");
        assert_eq!(directory.entries[0].method, 0);
        assert_eq!(directory.entries[0].uncompressed_size, 7);
        assert_eq!(directory.entries[1].method, 8);
        assert_eq!(directory.entries[1].unix_mode, 0o100644);

        let local = directory.entries[1].local_header_offset;
        let header = bytes[local as usize..local as usize + 30].to_vec();
        let data_at = zip_data_offset(header, local).unwrap() as usize;
        assert_eq!(data_at, local as usize + 30 + "meta.txt".len());
        let compressed = bytes
            [data_at..data_at + directory.entries[1].compressed_size as usize]
            .to_vec();
        let inflated = inflate_raw(compressed.clone(), 10).unwrap();
        assert_eq!(inflated, b"hello meta");
        assert!(inflate_raw(compressed, 11).is_err());
    }

    #[test]
    fn asks_for_a_directory_outside_the_tail() {
        let bytes = archive(&[("payload.bin", b"0123456789", false)]);
        let tail = bytes[bytes.len() - 22 - 16..].to_vec();
        let directory = zip_entries(tail, bytes.len() as u64).unwrap();
        let (offset, len) = directory.needs.expect("directory range");
        let parsed = zip_parse_central(bytes[offset as usize..(offset + len) as usize].to_vec()).unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].name, "payload.bin");
    }

    #[test]
    fn parses_zip64_fields() {
        let mut cd = central_entry("payload.bin");
        for offset in [20, 24, 42] {
            cd[offset..offset + 4].fill(0xff);
        }
        let extra = zip64_extra(100, 80, 7);
        cd[30..32].copy_from_slice(&(extra.len() as u16).to_le_bytes());
        let name_len = 11;
        cd.splice(46 + name_len..46 + name_len, extra);
        let entries = zip_parse_central(cd.clone()).unwrap();
        assert_eq!(entries[0].uncompressed_size, 100);
        assert_eq!(entries[0].compressed_size, 80);
        assert_eq!(entries[0].local_header_offset, 7);

        let mut zip64_end = vec![0u8; 56];
        zip64_end[0..4].copy_from_slice(ZIP64_EOCD_SIG);
        zip64_end[4..12].copy_from_slice(&44u64.to_le_bytes());
        zip64_end[40..48].copy_from_slice(&(cd.len() as u64).to_le_bytes());
        let mut locator = vec![0u8; 20];
        locator[0..4].copy_from_slice(ZIP64_LOCATOR_SIG);
        locator[8..16].copy_from_slice(&(cd.len() as u64).to_le_bytes());
        locator[16..20].copy_from_slice(&1u32.to_le_bytes());
        let mut eocd = vec![0u8; 22];
        eocd[0..4].copy_from_slice(EOCD_SIG);
        eocd[10..12].fill(0xff);
        eocd[12..20].fill(0xff);

        let mut file = cd.clone();
        file.extend_from_slice(&zip64_end);
        file.extend_from_slice(&locator);
        file.extend_from_slice(&eocd);
        let entries = zip_entries(file.clone(), file.len() as u64).unwrap().entries;
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].local_header_offset, 7);
    }

    #[test]
    fn rejects_malformed_input() {
        assert!(zip_entries(vec![0; 8], 8).is_err());
        assert!(zip_parse_central(vec![0; 46]).is_err());
        let mut bytes = archive(&[("a", b"b", false)]);
        let last = bytes.len() - 1;
        bytes[last] = 1; // comment length no longer ends the record
        assert!(zip_entries(bytes.clone(), bytes.len() as u64).is_err());
    }
}
