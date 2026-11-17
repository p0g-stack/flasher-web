/// Android sparse v1.0 parsing and bounded re-splitting.
///
/// `fastboot` limits one download to `max-download-size`. A raw image larger
/// than that limit is converted to sparse parts; a sparse image is split at
/// chunk boundaries. Every part repeats the image's full block geometry and
/// begins with a DONT_CARE chunk covering the blocks already sent, so each
/// part writes at the same partition offsets as the original image.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'model.dart';
import 'package.dart';

const int sparseMagic = 0xed26ff3a;
const int sparseRaw = 0xcac1;
const int sparseFill = 0xcac2;
const int sparseDontCare = 0xcac3;
const int sparseCrc32 = 0xcac4;
const int sparseHeaderBytes = 28;
const int sparseChunkHeaderBytes = 12;
const int sparseBlockBytes = 4096;

/// One parsed sparse chunk. [dataOffset] is absolute in the source image.
final class SparseChunk {
  const SparseChunk({
    required this.type,
    required this.blocks,
    required this.dataOffset,
    required this.dataSize,
    this.fill = 0,
  });

  final int type;
  final int blocks;
  final int dataOffset;
  final int dataSize;
  final int fill;
}

final class SparseScan {
  const SparseScan({
    required this.blockSize,
    required this.totalBlocks,
    required this.chunks,
    required this.digest,
  });

  final int blockSize;
  final int totalBlocks;
  final List<SparseChunk> chunks;

  /// Lowercase SHA-256, or empty for layout-only producers until streamed.
  final String digest;

  int get expandedBytes => blockSize * totalBlocks;
}

/// Completes the generator's hash checks before returning the final bytes.
final class StreamingFlashCursor implements FlashCursor {
  StreamingFlashCursor(Stream<Uint8List> stream, this.length)
    : _iterator = StreamIterator(stream);
  final StreamIterator<Uint8List> _iterator;
  final int length;
  Uint8List _chunk = Uint8List(0);
  int _within = 0;
  int _position = 0;
  Future<void> _consume(int count, Uint8List? output) async {
    if (count < 0 || count > length - _position) {
      throw RangeError('Invalid streaming cursor range.');
    }
    var done = 0;
    while (done < count) {
      if (_within == _chunk.length) {
        if (!await _iterator.moveNext()) {
          throw const FlashException('Image stream ended early.');
        }
        _chunk = _iterator.current;
        _within = 0;
      }
      final n = math.min(count - done, _chunk.length - _within);
      output?.setRange(done, done + n, _chunk, _within);
      done += n;
      _within += n;
    }
    _position += count;
    if (_position == length &&
        (_within != _chunk.length || await _iterator.moveNext())) {
      throw const FlashException('Image stream has trailing bytes.');
    }
  }

  @override
  Future<Uint8List> readExact(int length) async {
    if (length < 0 || length > 8 << 20) {
      throw RangeError('Cursor read exceeds 8 MiB.');
    }
    final bytes = Uint8List(length);
    await _consume(length, bytes);
    return bytes;
  }

  @override
  Future<void> skipTo(int offset) => _consume(offset - _position, null);
  @override
  Future<void> close() => _iterator.cancel();
}

/// Whether [source] starts with the sparse magic.
Future<bool> isSparseSource(FlashSource source) async {
  if (source.length < 4) return false;
  final head = await source.read(0, 4);
  final value = ByteData.sublistView(head).getUint32(0, Endian.little);
  return value == sparseMagic;
}

/// Validates the whole sparse image and hashes it. This reads the image in
/// bounded pieces; a truncated image, an unknown chunk, or trailing bytes is
/// rejected before any device write.
Future<SparseScan> scanSparse(FlashSource source) async {
  if (source.length < sparseHeaderBytes) {
    throw const FlashException('Sparse image is shorter than its header.');
  }
  final header = await source.read(0, sparseHeaderBytes);
  final data = ByteData.sublistView(header);
  if (data.getUint32(0, Endian.little) != sparseMagic) {
    throw const FlashException('Image is not an Android sparse image.');
  }
  final major = data.getUint16(4, Endian.little);
  final minor = data.getUint16(6, Endian.little);
  final fileHeaderSize = data.getUint16(8, Endian.little);
  final chunkHeaderSize = data.getUint16(10, Endian.little);
  final blockSize = data.getUint32(12, Endian.little);
  final totalBlocks = data.getUint32(16, Endian.little);
  final totalChunks = data.getUint32(20, Endian.little);
  if (major != 1 || minor != 0) {
    throw FlashException('Unsupported sparse version $major.$minor.');
  }
  if (fileHeaderSize < sparseHeaderBytes ||
      chunkHeaderSize < sparseChunkHeaderBytes ||
      blockSize == 0 ||
      blockSize % 4 != 0) {
    throw const FlashException('Sparse header has invalid geometry.');
  }
  if (totalBlocks == 0 || totalChunks == 0) {
    throw const FlashException('Sparse image has no chunks.');
  }
  if (totalChunks > 100000000) {
    throw const FlashException('Sparse image declares too many chunks.');
  }

  final digestSink = _DigestSink();
  final hash = sha256.startChunkedConversion(digestSink);
  final cursor = _Cursor(source.stream(), hash);
  var covered = 0;
  final chunks = <SparseChunk>[];
  try {
    await cursor.readExact(sparseHeaderBytes);
    await cursor.skip(fileHeaderSize - sparseHeaderBytes);
    for (var index = 0; index < totalChunks; index++) {
      final raw = await cursor.readExact(sparseChunkHeaderBytes);
      await cursor.skip(chunkHeaderSize - sparseChunkHeaderBytes);
      final chunk = ByteData.sublistView(raw);
      final type = chunk.getUint16(0, Endian.little);
      final blocks = chunk.getUint32(4, Endian.little);
      final totalSize = chunk.getUint32(8, Endian.little);
      if (totalSize < chunkHeaderSize) {
        throw FlashException('Sparse chunk $index has an invalid size.');
      }
      final payload = totalSize - chunkHeaderSize;
      final dataOffset = cursor.position;
      switch (type) {
        case sparseRaw:
          if (payload != blocks * blockSize) {
            throw FlashException(
              'Sparse RAW chunk $index size does not match its blocks.',
            );
          }
          chunks.add(
            SparseChunk(
              type: type,
              blocks: blocks,
              dataOffset: dataOffset,
              dataSize: payload,
            ),
          );
          covered += blocks;
          await cursor.skip(payload);
        case sparseFill:
          if (payload != 4 || blocks == 0) {
            throw FlashException('Sparse FILL chunk $index is invalid.');
          }
          final fill = ByteData.sublistView(await cursor.readExact(4))
              .getUint32(0, Endian.little);
          chunks.add(
            SparseChunk(
              type: type,
              blocks: blocks,
              dataOffset: dataOffset,
              dataSize: 4,
              fill: fill,
            ),
          );
          covered += blocks;
        case sparseDontCare:
          if (payload != 0) {
            throw FlashException('Sparse DONT_CARE chunk $index has data.');
          }
          chunks.add(
            SparseChunk(
              type: type,
              blocks: blocks,
              dataOffset: dataOffset,
              dataSize: 0,
            ),
          );
          covered += blocks;
        case sparseCrc32:
          if (payload != 4 || blocks != 0) {
            throw FlashException('Sparse CRC32 chunk $index is invalid.');
          }
          await cursor.skip(payload);
        default:
          throw FlashException(
            'Unsupported sparse chunk type 0x${type.toRadixString(16)}.',
          );
      }
      if (covered > totalBlocks) {
        throw const FlashException(
          'Sparse chunks cover more blocks than the header declares.',
        );
      }
    }
    if (cursor.position != source.length) {
      throw const FlashException('Sparse image has trailing bytes.');
    }
    if (covered != totalBlocks) {
      throw const FlashException(
        'Sparse image is truncated: its chunks do not cover every block.',
      );
    }
  } finally {
    await cursor.close();
  }
  hash.close();
  final digest = digestSink.value;
  if (digest == null) {
    throw const FlashException('Could not hash the sparse image.');
  }
  return SparseScan(
    blockSize: blockSize,
    totalBlocks: totalBlocks,
    chunks: List.unmodifiable(chunks),
    digest: digest.toString(),
  );
}

/// Hashes a raw image in bounded pieces.
Future<String> hashRawSource(FlashSource source) async {
  final sink = _DigestSink();
  final hash = sha256.startChunkedConversion(sink);
  await for (final chunk in source.stream()) {
    hash.add(chunk);
  }
  hash.close();
  final digest = sink.value;
  if (digest == null) throw const FlashException('Could not hash the image.');
  return digest.toString();
}

/// One chunk of a part. DONT_CARE has no data.
final class SparsePiece {
  const SparsePiece({
    required this.type,
    required this.blocks,
    this.dataOffset = 0,
    this.dataSize = 0,
    this.fill = 0,
  });

  final int type;
  final int blocks;
  final int dataOffset;
  final int dataSize;
  final int fill;

  int get encodedSize =>
      sparseChunkHeaderBytes +
      switch (type) {
        sparseRaw => dataSize,
        sparseFill => 4,
        _ => 0,
      };
}

final class SparsePart {
  SparsePart({
    required this.pieces,
    required this.blockSize,
    required this.totalBlocks,
  });

  final List<SparsePiece> pieces;
  final int blockSize;
  final int totalBlocks;

  int get length =>
      sparseHeaderBytes +
      pieces.fold<int>(0, (sum, piece) => sum + piece.encodedSize);

  int get totalChunks => pieces.length;
}

/// Splits a validated sparse image into parts no larger than [limit].
List<SparsePart> splitSparseScan(SparseScan scan, int limit) {
  if (limit < sparseHeaderBytes + 2 * sparseChunkHeaderBytes + scan.blockSize) {
    throw FlashException(
      'max-download-size $limit is too small for a sparse image part.',
    );
  }
  final parts = <SparsePart>[];
  var pieces = <SparsePiece>[];
  var partBytes = 0;
  var partStartBlock = 0;
  var blockCursor = 0;

  void flush() {
    if (pieces.isEmpty) return;
    parts.add(
      SparsePart(
        pieces: List.unmodifiable([
          ...pieces,
          if (blockCursor < scan.totalBlocks)
            SparsePiece(
              type: sparseDontCare,
              blocks: scan.totalBlocks - blockCursor,
            ),
        ]),
        blockSize: scan.blockSize,
        totalBlocks: scan.totalBlocks,
      ),
    );
    pieces = <SparsePiece>[];
    partBytes = 0;
    partStartBlock = blockCursor;
  }

  void leading() {
    if (pieces.isNotEmpty || partStartBlock == 0) return;
    if (sparseHeaderBytes + partBytes + sparseChunkHeaderBytes > limit) {
      throw FlashException(
        'max-download-size $limit cannot hold a part header.',
      );
    }
    pieces.add(SparsePiece(type: sparseDontCare, blocks: partStartBlock));
    partBytes += sparseChunkHeaderBytes;
  }

  for (final chunk in scan.chunks) {
    if (chunk.type == sparseCrc32) continue;
    if (chunk.type == sparseDontCare) {
      leading();
      final tail = blockCursor + chunk.blocks < scan.totalBlocks
          ? sparseChunkHeaderBytes
          : 0;
      if (sparseHeaderBytes + partBytes + sparseChunkHeaderBytes + tail >
          limit) {
        flush();
        leading();
      }
      pieces.add(SparsePiece(type: sparseDontCare, blocks: chunk.blocks));
      partBytes += sparseChunkHeaderBytes;
      blockCursor += chunk.blocks;
      continue;
    }
    if (chunk.type == sparseFill) {
      leading();
      final tail = blockCursor + chunk.blocks < scan.totalBlocks
          ? sparseChunkHeaderBytes
          : 0;
      if (sparseHeaderBytes + partBytes + sparseChunkHeaderBytes + 4 + tail >
          limit) {
        flush();
        leading();
      }
      pieces.add(
        SparsePiece(
          type: sparseFill,
          blocks: chunk.blocks,
          dataOffset: chunk.dataOffset,
          dataSize: 4,
          fill: chunk.fill,
        ),
      );
      partBytes += sparseChunkHeaderBytes + 4;
      blockCursor += chunk.blocks;
      continue;
    }
    var remaining = chunk.blocks;
    var offset = chunk.dataOffset;
    while (remaining > 0) {
      leading();
      final available =
          limit - sparseHeaderBytes - partBytes - sparseChunkHeaderBytes;
      final needsTail =
          blockCursor + remaining < scan.totalBlocks ||
          remaining * scan.blockSize > available;
      final maxBlocks =
          (available - (needsTail ? sparseChunkHeaderBytes : 0)) ~/
          scan.blockSize;
      if (maxBlocks <= 0) {
        if (pieces.length == 1 &&
            pieces.single.type == sparseDontCare &&
            partBytes == sparseChunkHeaderBytes) {
          throw FlashException(
            'max-download-size $limit cannot hold one sparse block after '
            'the leading DONT_CARE chunk.',
          );
        }
        flush();
        continue;
      }
      final take = math.min(remaining, maxBlocks);
      pieces.add(
        SparsePiece(
          type: sparseRaw,
          blocks: take,
          dataOffset: offset,
          dataSize: take * scan.blockSize,
        ),
      );
      partBytes += sparseChunkHeaderBytes + take * scan.blockSize;
      offset += take * scan.blockSize;
      remaining -= take;
      blockCursor += take;
      if (remaining > 0) flush();
    }
  }
  flush();
  if (blockCursor != scan.totalBlocks) {
    throw const FlashException('Sparse split did not cover every block.');
  }
  for (final part in parts) {
    if (part.length > limit) {
      throw FlashException(
        'Sparse part of ${part.length} bytes exceeds max-download-size '
        '$limit.',
      );
    }
  }
  return List.unmodifiable(parts);
}

/// Splits a raw, block-aligned image into sparse parts no larger than
/// [limit]. The last partial block is never sent; callers reject unaligned
/// images when they must be split.
List<SparsePart> splitRawImage(int length, int limit) {
  if (length % sparseBlockBytes != 0) {
    throw const FlashException(
      'A raw image larger than max-download-size must be a multiple of 4096 '
      'bytes.',
    );
  }
  final totalBlocks = length ~/ sparseBlockBytes;
  if (totalBlocks == 0) {
    throw const FlashException('The image is empty.');
  }
  if (limit <
      sparseHeaderBytes + 2 * sparseChunkHeaderBytes + sparseBlockBytes) {
    throw FlashException(
      'max-download-size $limit is too small for a sparse part.',
    );
  }
  final parts = <SparsePart>[];
  var block = 0;
  while (block < totalBlocks) {
    final pieces = <SparsePiece>[];
    var bytes = sparseHeaderBytes;
    if (block > 0) {
      pieces.add(SparsePiece(type: sparseDontCare, blocks: block));
      bytes += sparseChunkHeaderBytes;
    }
    var partBlocks = 0;
    while (block + partBlocks < totalBlocks) {
      final available = limit - bytes - sparseChunkHeaderBytes;
      final remainingBlocks = totalBlocks - block - partBlocks;
      final needsTail = remainingBlocks * sparseBlockBytes > available;
      final maxBlocks =
          (available - (needsTail ? sparseChunkHeaderBytes : 0)) ~/
          sparseBlockBytes;
      if (maxBlocks <= 0) break;
      // One MiB per RAW chunk keeps the chunk count modest.
      final take = math.min(
        math.min(maxBlocks, 256),
        totalBlocks - block - partBlocks,
      );
      final dataOffset = (block + partBlocks) * sparseBlockBytes;
      pieces.add(
        SparsePiece(
          type: sparseRaw,
          blocks: take,
          dataOffset: dataOffset,
          dataSize: take * sparseBlockBytes,
        ),
      );
      bytes += sparseChunkHeaderBytes + take * sparseBlockBytes;
      partBlocks += take;
    }
    if (partBlocks == 0) {
      throw FlashException(
        'max-download-size $limit cannot hold a sparse block.',
      );
    }
    parts.add(
      SparsePart(
        pieces: List.unmodifiable([
          ...pieces,
          if (block + partBlocks < totalBlocks)
            SparsePiece(
              type: sparseDontCare,
              blocks: totalBlocks - block - partBlocks,
            ),
        ]),
        blockSize: sparseBlockBytes,
        totalBlocks: totalBlocks,
      ),
    );
    block += partBlocks;
  }
  for (final part in parts) {
    if (part.length > limit) {
      throw FlashException(
        'Sparse part of ${part.length} bytes exceeds max-download-size '
        '$limit.',
      );
    }
  }
  return List.unmodifiable(parts);
}

/// The 28-byte sparse file header.
Uint8List sparseFileHeader({
  required int blockSize,
  required int totalBlocks,
  required int totalChunks,
}) {
  final bytes = Uint8List(sparseHeaderBytes);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, sparseMagic, Endian.little);
  data.setUint16(4, 1, Endian.little);
  data.setUint16(6, 0, Endian.little);
  data.setUint16(8, sparseHeaderBytes, Endian.little);
  data.setUint16(10, sparseChunkHeaderBytes, Endian.little);
  data.setUint32(12, blockSize, Endian.little);
  data.setUint32(16, totalBlocks, Endian.little);
  data.setUint32(20, totalChunks, Endian.little);
  data.setUint32(24, 0, Endian.little);
  return bytes;
}

/// The 12-byte chunk header; [totalSize] includes this header.
Uint8List sparseChunkHeader({
  required int type,
  required int blocks,
  required int totalSize,
}) {
  final bytes = Uint8List(sparseChunkHeaderBytes);
  final data = ByteData.sublistView(bytes);
  data.setUint16(0, type, Endian.little);
  data.setUint16(2, 0, Endian.little);
  data.setUint32(4, blocks, Endian.little);
  data.setUint32(8, totalSize, Endian.little);
  return bytes;
}

Uint8List fillBytes(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
  return bytes;
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

final class _Cursor {
  _Cursor(Stream<Uint8List> stream, ByteConversionSink hash)
    : _iterator = StreamIterator<Uint8List>(stream),
      _hash = hash;

  final StreamIterator<Uint8List> _iterator;
  final ByteConversionSink _hash;
  Uint8List _current = Uint8List(0);
  var _offset = 0;
  var position = 0;

  Future<bool> _advance() async {
    if (!await _iterator.moveNext()) {
      _current = Uint8List(0);
      _offset = 0;
      return false;
    }
    _current = _iterator.current;
    _offset = 0;
    return true;
  }

  Future<Uint8List> readExact(int length) async {
    final out = BytesBuilder(copy: false);
    var left = length;
    while (left > 0) {
      if (_offset >= _current.length) {
        if (!await _advance()) {
          throw const FlashException('Sparse image ended unexpectedly.');
        }
        if (_current.isEmpty) continue;
      }
      final take = math.min(left, _current.length - _offset);
      final piece = Uint8List.sublistView(_current, _offset, _offset + take);
      out.add(piece);
      _hash.add(piece);
      _offset += take;
      position += take;
      left -= take;
    }
    return out.takeBytes();
  }

  Future<void> skip(int length) async {
    var left = length;
    while (left > 0) {
      if (_offset >= _current.length) {
        if (!await _advance()) {
          throw const FlashException('Sparse image ended unexpectedly.');
        }
        if (_current.isEmpty) continue;
      }
      final take = math.min(left, _current.length - _offset);
      _hash.add(Uint8List.sublistView(_current, _offset, _offset + take));
      _offset += take;
      position += take;
      left -= take;
    }
  }

  Future<void> close() => _iterator.cancel();
}
