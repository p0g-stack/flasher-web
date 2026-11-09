//! Streaming ZIP writer for the flasher package.
//!
//! Every entry is written with a data descriptor (bit 3) and a ZIP64 extra
//! field, so sizes and offsets are never truncated: entries and the archive
//! may exceed 4 GiB. Deflate is raw (method 8, level 1); `deflate=false`
//! stores the bytes. Unix permissions go in the external attributes with
//! `create_system = 3` (Unix).
//!
//! The API is a byte pump: `start_file` returns the local header, `write`
//! returns compressed bytes, `finish_file` returns the final bytes and the
//! data descriptor, and `finish` returns the central directory and end
//! records. A misuse (writing without a file) returns no bytes and is
//! reported by the next `finish_file`/`finish` call.
use flate2::write::DeflateEncoder;
use flate2::Compression;
use flutter_rust_bridge::frb;
use sha2::{Digest, Sha256};
use std::io::Write;

use anyhow::Result;

const LOCAL_HEADER_SIGNATURE: u32 = 0x0403_4b50;
const CENTRAL_HEADER_SIGNATURE: u32 = 0x0201_4b50;
const END_OF_CENTRAL_DIRECTORY_SIGNATURE: u32 = 0x0605_4b50;
const ZIP64_END_OF_CENTRAL_DIRECTORY_SIGNATURE: u32 = 0x0606_4b50;
const ZIP64_LOCATOR_SIGNATURE: u32 = 0x0706_4b50;
const DATA_DESCRIPTOR_SIGNATURE: u32 = 0x0807_4b50;
const ZIP64_EXTRA_ID: u16 = 0x0001;
const FLAG_DATA_DESCRIPTOR: u16 = 0x0008;
const FLAG_UTF8: u16 = 0x0800;
const VERSION_NEEDED: u16 = 45;
const VERSION_MADE_BY: u16 = (3 << 8) | 45;
const DOS_TIME: u16 = 0;
const DOS_DATE: u16 = 0x0021; // 1980-01-01

struct Entry {
    name: Vec<u8>,
    flags: u16,
    method: u16,
    crc: u32,
    compressed: u64,
    uncompressed: u64,
    offset: u64,
    external_attributes: u32,
}

struct OpenFile {
    entry: Entry,
    hasher: crc32fast::Hasher,
    image_hasher: Option<Sha256>,
    encoder: Option<DeflateEncoder<Vec<u8>>>,
}

/// A streaming ZIP writer. Push the returned bytes to the output in order.
#[frb(opaque)]
pub struct ZipWriter {
    offset: u64,
    entries: Vec<Entry>,
    open: Option<OpenFile>,
    finished: bool,
    error: Option<String>,
    finished_image_sha256: Option<String>,
}

fn push_u16(buffer: &mut Vec<u8>, value: u16) {
    buffer.extend_from_slice(&value.to_le_bytes());
}

fn push_u32(buffer: &mut Vec<u8>, value: u32) {
    buffer.extend_from_slice(&value.to_le_bytes());
}

fn push_u64(buffer: &mut Vec<u8>, value: u64) {
    buffer.extend_from_slice(&value.to_le_bytes());
}

impl Default for ZipWriter {
    fn default() -> Self {
        Self::new()
    }
}

impl ZipWriter {
    #[frb(sync)]
    pub fn new() -> Self {
        Self {
            offset: 0,
            entries: Vec::new(),
            open: None,
            finished: false,
            error: None,
            finished_image_sha256: None,
        }
    }

    /// Starts an entry and returns its local header. The header declares
    /// ZIP64 sizes and a data descriptor; the real sizes follow the data.
    #[frb(sync)]
    pub fn start_file(&mut self, name: String, unix_mode: u32, deflate: bool) -> Vec<u8> {
        if self.finished || self.open.is_some() {
            self.error = Some("start_file called while another entry is open".into());
            return Vec::new();
        }
        if name.is_empty() {
            self.error = Some("ZIP entry name must not be empty".into());
            return Vec::new();
        }
        if name.len() > u16::MAX as usize {
            self.error = Some("ZIP entry name is longer than 65535 bytes".into());
            return Vec::new();
        }
        let image_hasher = name.ends_with(".img").then(Sha256::new);
        self.finished_image_sha256 = None;
        let name = name.into_bytes();
        let flags = FLAG_DATA_DESCRIPTOR | FLAG_UTF8;
        let method = if deflate { 8 } else { 0 };
        let mut header = Vec::with_capacity(30 + name.len() + 20);
        push_u32(&mut header, LOCAL_HEADER_SIGNATURE);
        push_u16(&mut header, VERSION_NEEDED);
        push_u16(&mut header, flags);
        push_u16(&mut header, method);
        push_u16(&mut header, DOS_TIME);
        push_u16(&mut header, DOS_DATE);
        push_u32(&mut header, 0); // CRC-32 follows the data
        push_u32(&mut header, u32::MAX); // ZIP64 placeholder
        push_u32(&mut header, u32::MAX); // ZIP64 placeholder
        push_u16(&mut header, name.len() as u16);
        push_u16(&mut header, 20); // ZIP64 extra field
        header.extend_from_slice(&name);
        push_u16(&mut header, ZIP64_EXTRA_ID);
        push_u16(&mut header, 16);
        push_u64(&mut header, 0);
        push_u64(&mut header, 0);

        self.offset += header.len() as u64;
        self.open = Some(OpenFile {
            entry: Entry {
                name,
                flags,
                method,
                crc: 0,
                compressed: 0,
                uncompressed: 0,
                offset: self.offset - (header.len() as u64),
                external_attributes: unix_mode << 16,
            },
            hasher: crc32fast::Hasher::new(),
            image_hasher,
            encoder: if deflate {
                // Level 1: on OTA images (mostly erofs) it deflates 4x faster
                // than level 3 in wasm for about 1.5 % more output.
                Some(DeflateEncoder::new(Vec::new(), Compression::new(1)))
            } else {
                None
            },
        });
        header
    }

    /// Consumes file data and returns the bytes to write to the output
    /// (deflated when the entry uses deflate, otherwise unchanged).
    #[frb(sync)]
    pub fn write(&mut self, data: Vec<u8>) -> Vec<u8> {
        let Some(open) = self.open.as_mut() else {
            self.error = Some("write called without an open entry".into());
            return Vec::new();
        };
        open.hasher.update(&data);
        if let Some(hasher) = open.image_hasher.as_mut() {
            hasher.update(&data);
        }
        open.entry.uncompressed += data.len() as u64;
        match open.encoder.as_mut() {
            Some(encoder) => {
                if encoder.write_all(&data).is_err() {
                    self.error = Some("Deflate compression failed".into());
                    return Vec::new();
                }
                let produced = std::mem::take(encoder.get_mut());
                open.entry.compressed += produced.len() as u64;
                self.offset += produced.len() as u64;
                produced
            }
            None => {
                open.entry.compressed += data.len() as u64;
                self.offset += data.len() as u64;
                data
            }
        }
    }

    /// Ends the entry: returns any remaining compressed bytes plus the ZIP64
    /// data descriptor.
    #[frb(sync)]
    pub fn finish_file(&mut self) -> Result<Vec<u8>> {
        if let Some(error) = self.error.take() {
            return Err(anyhow::anyhow!(error));
        }
        let Some(mut open) = self.open.take() else {
            return Err(anyhow::anyhow!("finish_file called without an open entry"));
        };
        let mut output = Vec::new();
        if let Some(encoder) = open.encoder.take() {
            let produced = encoder
                .finish()
                .map_err(|error| anyhow::anyhow!("Deflate compression failed: {error}"))?;
            open.entry.compressed += produced.len() as u64;
            output.extend_from_slice(&produced);
        }
        open.entry.crc = open.hasher.finalize();
        self.finished_image_sha256 = open.image_hasher
            .map(|hasher| format!("{:x}", hasher.finalize()));
        push_u32(&mut output, DATA_DESCRIPTOR_SIGNATURE);
        push_u32(&mut output, open.entry.crc);
        push_u64(&mut output, open.entry.compressed);
        push_u64(&mut output, open.entry.uncompressed);
        self.offset += output.len() as u64;
        self.entries.push(open.entry);
        Ok(output)
    }

    /// Final image digest, accumulated in the existing write pass without a
    /// second copy of image buffers across the bridge.
    #[frb(sync)]
    pub fn finished_image_sha256(&self) -> Option<String> {
        self.finished_image_sha256.clone()
    }

    /// Ends the archive: returns the central directory, the ZIP64 end of
    /// central directory record and locator, and the end of central
    /// directory record.
    #[frb(sync)]
    pub fn finish(&mut self) -> Result<Vec<u8>> {
        if let Some(error) = self.error.take() {
            return Err(anyhow::anyhow!(error));
        }
        if self.open.is_some() {
            return Err(anyhow::anyhow!("finish called while an entry is open"));
        }
        if self.finished {
            return Err(anyhow::anyhow!("finish called twice"));
        }
        let central_offset = self.offset;
        let mut central = Vec::new();
        for entry in &self.entries {
            push_u32(&mut central, CENTRAL_HEADER_SIGNATURE);
            push_u16(&mut central, VERSION_MADE_BY);
            push_u16(&mut central, VERSION_NEEDED);
            push_u16(&mut central, entry.flags);
            push_u16(&mut central, entry.method);
            push_u16(&mut central, DOS_TIME);
            push_u16(&mut central, DOS_DATE);
            push_u32(&mut central, entry.crc);
            push_u32(&mut central, u32::MAX);
            push_u32(&mut central, u32::MAX);
            push_u16(&mut central, entry.name.len() as u16);
            push_u16(&mut central, 28); // ZIP64 extra: sizes and offset
            push_u16(&mut central, 0); // comment length
            push_u16(&mut central, 0); // disk number start
            push_u16(&mut central, 0); // internal attributes
            push_u32(&mut central, entry.external_attributes);
            push_u32(&mut central, u32::MAX);
            central.extend_from_slice(&entry.name);
            push_u16(&mut central, ZIP64_EXTRA_ID);
            push_u16(&mut central, 24);
            push_u64(&mut central, entry.uncompressed);
            push_u64(&mut central, entry.compressed);
            push_u64(&mut central, entry.offset);
        }
        let central_size = central.len() as u64;
        let zip64_offset = central_offset + central_size;

        let mut tail = central;
        push_u32(&mut tail, ZIP64_END_OF_CENTRAL_DIRECTORY_SIGNATURE);
        push_u64(&mut tail, 44);
        push_u16(&mut tail, VERSION_MADE_BY);
        push_u16(&mut tail, VERSION_NEEDED);
        push_u32(&mut tail, 0); // this disk
        push_u32(&mut tail, 0); // disk with the central directory
        push_u64(&mut tail, self.entries.len() as u64);
        push_u64(&mut tail, self.entries.len() as u64);
        push_u64(&mut tail, central_size);
        push_u64(&mut tail, central_offset);
        push_u32(&mut tail, ZIP64_LOCATOR_SIGNATURE);
        push_u32(&mut tail, 0); // disk with the ZIP64 end record
        push_u64(&mut tail, zip64_offset);
        push_u32(&mut tail, 1); // total disks
        push_u32(&mut tail, END_OF_CENTRAL_DIRECTORY_SIGNATURE);
        push_u16(&mut tail, 0);
        push_u16(&mut tail, 0);
        let count = u16::try_from(self.entries.len()).unwrap_or(u16::MAX);
        let size = u32::try_from(central_size).unwrap_or(u32::MAX);
        let offset = u32::try_from(central_offset).unwrap_or(u32::MAX);
        push_u16(&mut tail, count);
        push_u16(&mut tail, count);
        push_u32(&mut tail, size);
        push_u32(&mut tail, offset);
        push_u16(&mut tail, 0); // comment length

        self.offset += tail.len() as u64;
        self.finished = true;
        Ok(tail)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u16_at(bytes: &[u8], offset: usize) -> u16 {
        u16::from_le_bytes(bytes[offset..offset + 2].try_into().unwrap())
    }

    fn u32_at(bytes: &[u8], offset: usize) -> u32 {
        u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
    }

    fn u64_at(bytes: &[u8], offset: usize) -> u64 {
        u64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap())
    }

    fn build(deflate: bool, data: &[u8]) -> (Vec<u8>, Vec<u8>) {
        let mut writer = ZipWriter::new();
        let mut archive = writer.start_file("dir/file.bin".into(), 0o100644, deflate);
        archive.extend_from_slice(&writer.write(data.to_vec()));
        let descriptor = writer.finish_file().unwrap();
        archive.extend_from_slice(&descriptor);
        let tail = writer.finish().unwrap();
        (archive, tail)
    }

    #[test]
    fn stored_entry_layout_and_attributes() {
        let data = b"flasher".repeat(10);
        let (archive, tail) = build(false, &data);
        assert_eq!(u32_at(&archive, 0), LOCAL_HEADER_SIGNATURE);
        assert_eq!(u16_at(&archive, 6), FLAG_DATA_DESCRIPTOR | FLAG_UTF8);
        assert_eq!(u16_at(&archive, 8), 0);
        assert_eq!(u32_at(&archive, 18), u32::MAX);
        assert_eq!(&archive[30..42], b"dir/file.bin");
        assert_eq!(u16_at(&archive, 42), ZIP64_EXTRA_ID);
        assert_eq!(u16_at(&archive, 44), 16);
        let name_len = 12;
        let data_start = 30 + name_len + 20;
        assert_eq!(&archive[data_start..data_start + data.len()], &data[..]);
        let descriptor = data_start + data.len();
        assert_eq!(u32_at(&archive, descriptor), DATA_DESCRIPTOR_SIGNATURE);
        assert_eq!(u32_at(&archive, descriptor + 4), crc32fast::hash(&data));
        assert_eq!(u64_at(&archive, descriptor + 8), data.len() as u64);
        assert_eq!(u64_at(&archive, descriptor + 16), data.len() as u64);

        assert_eq!(u32_at(&tail, 0), CENTRAL_HEADER_SIGNATURE);
        assert_eq!(u16_at(&tail, 4), VERSION_MADE_BY);
        assert_eq!(u32_at(&tail, 38), 0o100644 << 16);
        let extra = 46 + name_len;
        assert_eq!(u16_at(&tail, extra), ZIP64_EXTRA_ID);
        assert_eq!(u64_at(&tail, extra + 4), data.len() as u64);
        assert_eq!(u64_at(&tail, extra + 12), data.len() as u64);
        assert_eq!(u64_at(&tail, extra + 20), 0);
        let zip64 = 46 + name_len + 28;
        assert_eq!(
            u32_at(&tail, zip64),
            ZIP64_END_OF_CENTRAL_DIRECTORY_SIGNATURE
        );
        assert_eq!(u64_at(&tail, zip64 + 24), 1);
        let locator = zip64 + 56;
        assert_eq!(u32_at(&tail, locator), ZIP64_LOCATOR_SIGNATURE);
        assert_eq!(u64_at(&tail, locator + 8), archive.len() as u64 + 86);
        let eocd = locator + 20;
        assert_eq!(u32_at(&tail, eocd), END_OF_CENTRAL_DIRECTORY_SIGNATURE);
        assert_eq!(u16_at(&tail, eocd + 10), 1);
    }

    #[test]
    fn deflated_entry_round_trips() {
        let data = b"aaaaabbbbbccccccdddddddd".repeat(1000);
        let (archive, _) = build(true, &data);
        assert_eq!(u16_at(&archive, 8), 8);
        let start = 30 + 12 + 20;
        let descriptor = archive.len() - 24;
        let compressed = &archive[start..descriptor];
        assert!(compressed.len() < data.len());
        let mut reader = flate2::read::DeflateDecoder::new(compressed);
        let mut decoded = Vec::new();
        std::io::Read::read_to_end(&mut reader, &mut decoded).unwrap();
        assert_eq!(decoded, data);
        assert_eq!(u32_at(&archive, descriptor + 4), crc32fast::hash(&data));
        assert_eq!(u64_at(&archive, descriptor + 8), compressed.len() as u64);
        assert_eq!(u64_at(&archive, descriptor + 16), data.len() as u64);
    }

    #[test]
    fn misuse_is_reported() {
        let mut writer = ZipWriter::new();
        assert!(writer.write(vec![1]).is_empty());
        assert!(writer.finish_file().is_err());
        let mut writer = ZipWriter::new();
        writer.start_file("a".into(), 0o100644, false);
        assert!(writer.finish().is_err());
    }

    #[test]
    fn multiple_entries_keep_offsets() {
        let mut writer = ZipWriter::new();
        let mut archive = Vec::new();
        let mut starts = Vec::new();
        for (index, name) in ["one", "two", "three"].iter().enumerate() {
            starts.push(archive.len() as u64);
            archive.extend(writer.start_file((*name).into(), 0o100644, index != 1));
            archive.extend(writer.write(vec![index as u8; 100]));
            archive.extend(writer.finish_file().unwrap());
        }
        let tail = writer.finish().unwrap();
        let mut offset = 0usize;
        for (index, name) in ["one", "two", "three"].iter().enumerate() {
            assert_eq!(u32_at(&tail, offset), CENTRAL_HEADER_SIGNATURE);
            let name_len = u16_at(&tail, offset + 28) as usize;
            assert_eq!(&tail[offset + 46..offset + 46 + name_len], name.as_bytes());
            let extra = offset + 46 + name_len;
            assert_eq!(u64_at(&tail, extra + 20), starts[index]);
            assert_eq!(u64_at(&tail, extra + 4), 100);
            offset = extra + 28;
        }
    }
}
