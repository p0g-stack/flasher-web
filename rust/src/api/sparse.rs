//! Android sparse v1.0. Reserve 28 output bytes, append returned chunks, then
//! write finish().header at offset zero. Hint lengths are logical byte counts.
use anyhow::Result;
use flutter_rust_bridge::frb;
#[derive(Debug, Clone)]
pub struct SparseHeader {
    pub block_size: u32,
    pub total_blocks: u32,
    pub total_chunks: u32,
    pub file_header_size: u16,
    pub chunk_header_size: u16,
}
#[derive(Debug, Clone)]
pub struct SparseChunk {
    pub kind: u16,
    pub blocks: u32,
    pub total_size: u32,
}
fn u16le(b: &[u8], p: usize) -> u16 {
    u16::from_le_bytes(b[p..p + 2].try_into().unwrap())
}
fn u32le(b: &[u8], p: usize) -> u32 {
    u32::from_le_bytes(b[p..p + 4].try_into().unwrap())
}
#[frb(sync)]
pub fn sparse_header(bytes28: Vec<u8>) -> Option<SparseHeader> {
    let b = bytes28;
    if b.len() < 28
        || u32le(&b, 0) != 0xed26ff3a
        || u16le(&b, 4) != 1
        || u16le(&b, 8) < 28
        || u16le(&b, 10) < 12
        || u32le(&b, 12) == 0
        || u32le(&b, 12) % 4 != 0
    {
        return None;
    }
    Some(SparseHeader {
        block_size: u32le(&b, 12),
        total_blocks: u32le(&b, 16),
        total_chunks: u32le(&b, 20),
        file_header_size: u16le(&b, 8),
        chunk_header_size: u16le(&b, 10),
    })
}
#[frb(sync)]
pub fn sparse_chunk(bytes12: Vec<u8>) -> Result<SparseChunk> {
    let b = bytes12;
    if b.len() < 12 {
        return Err(anyhow::anyhow!("Truncated sparse chunk"));
    }
    let kind = u16le(&b, 0);
    let blocks = u32le(&b, 4);
    let total_size = u32le(&b, 8);
    if !matches!(kind, 0xcac1..=0xcac4)
        || total_size < 12
        || (kind == 0xcac2 && total_size != 16)
        || (kind == 0xcac3 && total_size != 12)
        || (kind == 0xcac4 && (total_size != 16 || blocks != 0))
    {
        return Err(anyhow::anyhow!("Invalid sparse chunk"));
    }
    Ok(SparseChunk {
        kind,
        blocks,
        total_size,
    })
}
pub struct SparseTail {
    pub header: Vec<u8>,
    pub trailer: Vec<u8>,
}
#[frb(opaque)]
pub struct SparseWriter {
    block_size: u32,
    total_blocks: u32,
    blocks: u32,
    chunks: u32,
    pending: Vec<u8>,
    finished: bool,
}
impl SparseWriter {
    #[frb(sync)]
    pub fn new(block_size: u32, total_blocks: u32) -> Self {
        Self {
            block_size,
            total_blocks,
            blocks: 0,
            chunks: 0,
            pending: Vec::new(),
            finished: false,
        }
    }
    fn emit(&mut self, kind: u16, blocks: u32, data: &[u8], out: &mut Vec<u8>) -> Result<()> {
        if self.finished || blocks > self.total_blocks - self.blocks {
            return Err(anyhow::anyhow!(
                "Sparse stream exceeds declared size or is finished"
            ));
        }
        self.chunks = self
            .chunks
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("Too many sparse chunks"))?;
        self.blocks += blocks;
        out.extend(kind.to_le_bytes());
        out.extend(0u16.to_le_bytes());
        out.extend(blocks.to_le_bytes());
        out.extend(((12 + data.len()) as u32).to_le_bytes());
        out.extend(data);
        Ok(())
    }
    #[frb(sync)]
    pub fn push(&mut self, bytes: Vec<u8>) -> Result<Vec<u8>> {
        if self.block_size == 0 || self.block_size % 4 != 0 {
            return Err(anyhow::anyhow!(
                "Sparse block size must be a nonzero multiple of four"
            ));
        }
        if self.finished
            || (self.blocks as u64 * self.block_size as u64
                + self.pending.len() as u64
                + bytes.len() as u64)
                > self.total_blocks as u64 * self.block_size as u64
        {
            return Err(anyhow::anyhow!(
                "Sparse stream exceeds declared size or is finished"
            ));
        }
        let mut out = Vec::new();
        let mut pos = 0;
        let bs = self.block_size as usize;
        if !self.pending.is_empty() {
            let n = (bs - self.pending.len()).min(bytes.len());
            self.pending.extend_from_slice(&bytes[..n]);
            pos = n;
            if self.pending.len() == bs {
                let block = std::mem::take(&mut self.pending);
                self.block(&block, &mut out)?;
            }
        }
        while bytes.len() - pos >= bs {
            self.block(&bytes[pos..pos + bs], &mut out)?;
            pos += bs;
        }
        self.pending.extend_from_slice(&bytes[pos..]);
        Ok(out)
    }
    fn block(&mut self, b: &[u8], out: &mut Vec<u8>) -> Result<()> {
        if b.chunks_exact(4).all(|w| w == &b[..4]) {
            self.emit(0xcac2, 1, &b[..4], out)
        } else {
            self.emit(0xcac1, 1, b, out)
        }
    }
    fn hint(&mut self, len: u64, kind: u16, data: &[u8]) -> Result<Vec<u8>> {
        if self.block_size == 0 || self.block_size % 4 != 0 {
            return Err(anyhow::anyhow!(
                "Sparse block size must be a nonzero multiple of four"
            ));
        }
        if !self.pending.is_empty()
            || len % self.block_size as u64 != 0
            || len / self.block_size as u64 > u32::MAX as u64
        {
            return Err(anyhow::anyhow!("Sparse hint must be block aligned"));
        }
        let mut out = Vec::new();
        if len != 0 {
            self.emit(kind, (len / self.block_size as u64) as u32, data, &mut out)?;
        }
        Ok(out)
    }
    #[frb(sync)]
    pub fn push_fill(&mut self, value: u32, len: u64) -> Result<Vec<u8>> {
        self.hint(len, 0xcac2, &value.to_le_bytes())
    }
    #[frb(sync)]
    pub fn skip(&mut self, len: u64) -> Result<Vec<u8>> {
        self.hint(len, 0xcac3, &[])
    }
    #[frb(sync)]
    pub fn finish(&mut self) -> Result<SparseTail> {
        if self.block_size == 0 || self.block_size % 4 != 0 {
            return Err(anyhow::anyhow!(
                "Sparse block size must be a nonzero multiple of four"
            ));
        }
        if self.finished || !self.pending.is_empty() || self.blocks != self.total_blocks {
            return Err(anyhow::anyhow!("Incomplete or finished sparse stream"));
        }
        self.finished = true;
        let mut h = Vec::new();
        h.extend(0xed26ff3au32.to_le_bytes());
        for n in [1u16, 0, 28, 12] {
            h.extend(n.to_le_bytes())
        }
        for n in [self.block_size, self.total_blocks, self.chunks, 0] {
            h.extend(n.to_le_bytes())
        }
        Ok(SparseTail {
            header: h,
            trailer: Vec::new(),
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mixed_roundtrip() {
        let mut w = SparseWriter::new(16, 4);
        let mut body = w.push(vec![7; 3]).unwrap();
        body.extend(w.push(vec![7; 13]).unwrap());
        body.extend(w.push((0..16).collect()).unwrap());
        body.extend(w.push_fill(0x12345678, 16).unwrap());
        body.extend(w.skip(16).unwrap());
        let h = w.finish().unwrap();
        assert_eq!(sparse_header(h.header).unwrap().total_chunks, 4);
        let mut p = 0;
        let mut raw = Vec::new();
        while p < body.len() {
            let c = sparse_chunk(body[p..p + 12].to_vec()).unwrap();
            match c.kind {
                0xcac1 => raw.extend_from_slice(&body[p + 12..p + c.total_size as usize]),
                0xcac2 => {
                    for _ in 0..c.blocks * 4 {
                        raw.extend_from_slice(&body[p + 12..p + 16])
                    }
                }
                0xcac3 => raw.resize(raw.len() + c.blocks as usize * 16, 0),
                _ => unreachable!(),
            }
            p += c.total_size as usize;
        }
        assert_eq!(&raw[..16], &[7; 16]);
        assert_eq!(&raw[16..32], &(0..16).collect::<Vec<_>>());
        assert_eq!(&raw[48..], &[0; 16]);
    }
}
