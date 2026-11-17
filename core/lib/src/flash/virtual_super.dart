/// The normal packer's LP layout and sparse bytes, backed only by input sources.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../pipeline/errors.dart';
import '../rust/api/lp.dart';
import '../rust/api/payload.dart' show Sha256Hasher;
import 'model.dart';
import 'ota_source.dart';
import 'package.dart';
import 'sparse.dart';

/// Partitions `pack_super` may put in `super.img`, in `lpmake` order.
const List<String> superParts = [
  'my_bigball',
  'my_carrier',
  'my_company',
  'my_engineering',
  'my_heytap',
  'my_manifest',
  'my_preload',
  'my_product',
  'my_region',
  'my_stock',
  'odm',
  'product',
  'system',
  'system_dlkm',
  'system_dlkm_gki',
  'system_dlkm_oki',
  'system_ext',
  'vendor',
  'vendor_dlkm',
];

/// Partitions `build_images` moves into `Super/` for every device except X9U.
final List<String> extractToSuper = [
  for (final name in superParts)
    if (name != 'my_company' &&
        name != 'my_preload' &&
        name != 'system_dlkm_gki' &&
        name != 'system_dlkm_oki')
      name,
];

/// Root template files removed after every Super build.
const Set<String> superScrapFiles = {
  'dtbo.img',
  'dtbo_patched.img',
  'dtbo_patcher.sh',
  'dtbo_patcher.py',
  'dtbo_patcher',
};

/// The LP producer contract the normal and virtual packers share.
SuperLayout flasherSuperLayout(Map<String, int> images, int size) {
  if (size <= 4 * 1024 * 1024 || size % 4096 != 0) {
    throw const BuildException('Invalid physical super partition size.');
  }
  for (final name in const ['system', 'vendor', 'product']) {
    if ((images[name] ?? 0) <= 0) {
      throw BuildException('Required partition missing: $name.img');
    }
  }
  final included = [
    for (final name in superParts)
      if (images.containsKey(name)) name,
  ];
  try {
    return superLayout(
      spec: SuperSpec(
        deviceSize: BigInt.from(size),
        superName: 'super',
        metadataSize: 65536,
        metadataSlots: 3,
        virtualAb: true,
        logicalBlockSize: 4096,
        alignment: 1 << 20,
        groups: [
          for (final slot in const ['a', 'b'])
            SuperGroup(
              name: 'qti_dynamic_partitions_$slot',
              size: BigInt.from(size - 4 * 1024 * 1024),
            ),
        ],
        partitions: [
          for (final name in included)
            SuperPartition(
              name: '${name}_a',
              size: BigInt.from(images[name]!),
              group: 'qti_dynamic_partitions_a',
              readonly: true,
              hasImage: true,
            ),
          for (final name in included)
            SuperPartition(
              name: '${name}_b',
              size: BigInt.zero,
              group: 'qti_dynamic_partitions_b',
              readonly: true,
              hasImage: false,
            ),
        ],
      ),
    );
  } on Object catch (error) {
    throw BuildException('$error');
  }
}

const _maxRawChunk = 0xfffff000; // total_sz is a sparse v1 uint32.

/// Sparse geometry derives solely from LP extents; opening reads no OTA data.
final class VirtualSuperImage {
  VirtualSuperImage._(this._regions, this.expandedLength, this._inputs) {
    if (expandedLength ~/ 4096 > 0xffffffff) {
      throw const FlashException('Super exceeds sparse v1 geometry.');
    }
    var encoded = 28;
    final chunks = <SparseChunk>[];
    for (final region in _regions) {
      if (region.length % 4096 != 0) {
        throw const FlashException('Unaligned virtual super region.');
      }
      region.encodedOffset = encoded;
      for (
        var offset = 0;
        offset < region.length;
        offset += region.source == null ? region.length : _maxRawChunk
      ) {
        final count = math.min(_maxRawChunk, region.length - offset);
        chunks.add(
          SparseChunk(
            type: region.source == null ? sparseDontCare : sparseRaw,
            blocks: (region.source == null ? region.length : count) ~/ 4096,
            dataOffset: encoded + 12,
            dataSize: region.source == null ? 0 : count,
          ),
        );
        encoded += 12 + (region.source == null ? 0 : count);
      }
    }
    length = encoded;
    scan = SparseScan(
      blockSize: 4096,
      totalBlocks: expandedLength ~/ 4096,
      chunks: List.unmodifiable(chunks),
      digest: '',
    );
    _header = _sparseHeader(scan.totalBlocks, chunks.length);
  }
  final List<_Region> _regions;
  final int expandedLength;
  final Map<String, FlashSource> _inputs;
  late final int length;
  late final SparseScan scan;
  late final Uint8List _header;
  String? streamSha256;
  late final String layoutHeadSha256 =
      (Sha256Hasher()
            ..update(bytes: (_regions.first.source! as _MemorySource).bytes))
          .finishHex();

  static Future<VirtualSuperImage> create(
    Map<String, FlashSource> sources,
    int size, {
    Map<String, String> expectedHashes = const {},
  }) async {
    final inputs = <String, FlashSource>{};
    try {
      for (final entry in sources.entries) {
        inputs[entry.key] = await _ExpandedImage.open(entry.value);
        final expanded = inputs[entry.key];
        if (expanded is _ExpandedImage &&
            expectedHashes[entry.key] != null &&
            expanded.scan.digest != expectedHashes[entry.key]) {
          throw FlashException(
            '${entry.key}.img does not match its manifest SHA-256.',
          );
        }
      }
      final layout = flasherSuperLayout({
        for (final e in inputs.entries) e.key: e.value.length,
      }, size);
      final regions = <_Region>[
        _Region(0, layout.head.length, _MemorySource(layout.head)),
      ];
      var position = layout.head.length;
      final extents = [...layout.extents]
        ..sort((a, b) => a.offset.compareTo(b.offset));
      for (final extent in extents) {
        final offset = extent.offset.toInt();
        final extentLength = extent.size.toInt();
        final name = extent.name.endsWith('_a')
            ? extent.name.substring(0, extent.name.length - 2)
            : extent.name;
        final image = inputs[name];
        if (offset < position || image == null || image.length <= 0) {
          throw const FlashException('Invalid virtual super layout.');
        }
        if (offset > position) {
          regions.add(_Region(position, offset - position, null));
        }
        final padded = (image.length + 4095) ~/ 4096 * 4096;
        if (padded > extentLength) {
          throw const FlashException('Invalid virtual super extent.');
        }
        regions.add(
          _Region(
            offset,
            padded,
            image,
            expectedHash: image is _ExpandedImage ? null : expectedHashes[name],
            name: name,
          ),
        );
        if (extentLength > padded) {
          regions.add(_Region(offset + padded, extentLength - padded, null));
        }
        position = offset + extentLength;
      }
      if (position > size) {
        throw const FlashException('Virtual super exceeds its device.');
      }
      if (position < size) {
        regions.add(_Region(position, size - position, null));
      }
      return VirtualSuperImage._(regions, size, inputs);
    } on Object {
      for (final source in sources.values) {
        await source.close();
      }
      rethrow;
    }
  }

  Future<FlashSource> open({bool sparse = true}) async =>
      _SuperSource(this, sparse);
  Future<void> close() async {
    for (final source in _inputs.values) {
      await source.close();
    }
  }

  Future<Uint8List> _read(int offset, int count, bool sparse) async {
    final total = sparse ? length : expandedLength;
    if (offset < 0 || count < 0 || count > 8 << 20 || offset + count > total) {
      throw RangeError('Invalid bounded virtual super read.');
    }
    final output = Uint8List(count);
    var done = 0;
    if (sparse && offset < 28) {
      final n = math.min(count, 28 - offset);
      output.setRange(0, n, _header, offset);
      done = n;
    }
    while (done < count) {
      final position = offset + done;
      final region = _regions.firstWhere(
        (r) => sparse
            ? position >= r.encodedOffset &&
                  position < r.encodedOffset + r.encodedLength
            : position >= r.offset && position < r.offset + r.length,
      );
      if (!sparse) {
        final n = math.min(
          count - done,
          region.offset + region.length - position,
        );
        output.setRange(
          done,
          done + n,
          await region.readRaw(position - region.offset, n),
        );
        done += n;
      } else {
        final chunkIndex =
            (position - region.encodedOffset) ~/ (_maxRawChunk + 12);
        final within =
            position - region.encodedOffset - chunkIndex * (_maxRawChunk + 12);
        final chunkLength = math.min(
          _maxRawChunk,
          region.length - chunkIndex * _maxRawChunk,
        );
        if (within < 12) {
          final header = _chunkHeader(
            region.source == null ? sparseDontCare : sparseRaw,
            (region.source == null ? region.length : chunkLength) ~/ 4096,
            region.source == null ? 0 : chunkLength,
          );
          final n = math.min(count - done, 12 - within);
          output.setRange(done, done + n, header, within);
          done += n;
        } else {
          final rawOffset = chunkIndex * _maxRawChunk + within - 12;
          final n = math.min(count - done, chunkLength - (within - 12));
          output.setRange(done, done + n, await region.readRaw(rawOffset, n));
          done += n;
        }
      }
    }
    return output;
  }
}

final class _Region {
  _Region(
    this.offset,
    this.length,
    this.source, {
    this.expectedHash,
    this.name,
  });
  final int offset;
  final int length;
  final FlashSource? source;
  final String? expectedHash;
  final String? name;
  late int encodedOffset;
  int get encodedLength => source == null
      ? 12
      : length + ((length + _maxRawChunk - 1) ~/ _maxRawChunk) * 12;
  Future<Uint8List> readRaw(int offset, int count) async {
    final input = source;
    if (input != null && offset + count <= input.length) {
      return input.read(offset, count);
    }
    final result = Uint8List(count);
    if (input != null && offset < input.length) {
      final n = math.min(count, input.length - offset);
      result.setRange(0, n, await input.read(offset, n));
    }
    return result;
  }
}

final class _SuperSource implements FlashSource {
  _SuperSource(this.image, this.sparse);
  final VirtualSuperImage image;
  final bool sparse;
  @override
  int get length => sparse ? image.length : image.expandedLength;
  @override
  Future<Uint8List> read(int offset, int length) =>
      image._read(offset, length, sparse);
  @override
  Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    if (chunkSize <= 0 || chunkSize > 8 << 20) {
      throw ArgumentError.value(chunkSize);
    }
    final whole = Sha256Hasher();
    if (sparse) {
      whole.update(bytes: image._header);
      yield image._header;
    }
    for (final region in image._regions) {
      if (sparse && region.source == null) {
        final header = _chunkHeader(sparseDontCare, region.length ~/ 4096, 0);
        whole.update(bytes: header);
        yield header;
        continue;
      }
      final hasher = region.expectedHash == null ? null : Sha256Hasher();
      final cursor = await region.source?.cursor();
      try {
        var offset = 0;
        while (offset < region.length) {
          final segmentEnd = math.min(region.length, offset + _maxRawChunk);
          if (sparse) {
            final header = _chunkHeader(
              sparseRaw,
              (segmentEnd - offset) ~/ 4096,
              segmentEnd - offset,
            );
            whole.update(bytes: header);
            yield header;
          }
          while (offset < segmentEnd) {
            final count = math.min(chunkSize, segmentEnd - offset);
            final Uint8List bytes;
            if (cursor != null && offset + count <= region.source!.length) {
              bytes = await cursor.readExact(count);
            } else {
              bytes = Uint8List(count);
              if (cursor != null && offset < region.source!.length) {
                final raw = await cursor.readExact(
                  region.source!.length - offset,
                );
                bytes.setRange(0, raw.length, raw);
              }
            }
            if (offset == 0 &&
                region.source is OtaPartitionSource &&
                bytes.length >= 4 &&
                ByteData.sublistView(bytes).getUint32(0, Endian.little) ==
                    sparseMagic) {
              throw const FlashException(
                'A sparse-encoded OTA partition cannot be represented by virtual super.',
              );
            }
            if (hasher != null && offset < region.source!.length) {
              hasher.update(
                bytes: Uint8List.sublistView(
                  bytes,
                  0,
                  math.min(bytes.length, region.source!.length - offset),
                ),
              );
            }
            whole.update(bytes: bytes);
            yield bytes;
            offset += bytes.length;
          }
        }
        if (hasher != null && hasher.finishHex() != region.expectedHash) {
          throw FlashException(
            '${region.name}.img does not match its manifest SHA-256.',
          );
        }
      } finally {
        await cursor?.close();
      }
    }
    if (sparse) image.streamSha256 = whole.finishHex();
  }

  @override
  Future<FlashCursor> cursor() async => StreamingFlashCursor(stream(), length);
  @override
  Future<void> close() async {}
}

final class _MemorySource implements FlashSource {
  _MemorySource(this.bytes);
  final Uint8List bytes;
  @override
  int get length => bytes.length;
  @override
  Future<Uint8List> read(int offset, int length) async =>
      Uint8List.sublistView(bytes, offset, offset + length);
  @override
  Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    for (var p = 0; p < length; p += chunkSize) {
      yield await read(p, math.min(chunkSize, length - p));
    }
  }

  @override
  Future<FlashCursor> cursor() async => RandomFlashCursor(this);
  @override
  Future<void> close() async {}
}

/// An input sparse bloat file is expanded, exactly as the normal packer does.
final class _ExpandedImage implements FlashSource {
  _ExpandedImage(this.source, this.scan) {
    _ends = Float64List(scan.chunks.length + 1);
    for (var i = 0; i < scan.chunks.length; i++) {
      _ends[i + 1] = _ends[i] + scan.chunks[i].blocks * scan.blockSize;
    }
  }
  static Future<FlashSource> open(FlashSource source) async {
    if (source is OtaPartitionSource || !await isSparseSource(source)) {
      return source;
    }
    final header = ByteData.sublistView(await source.read(0, 28));
    if (header.getUint32(20, Endian.little) > 262144) {
      throw const FlashException(
        'Sparse super input exceeds the 262144-chunk index limit.',
      );
    }
    return _ExpandedImage(source, await scanSparse(source));
  }

  final FlashSource source;
  final SparseScan scan;
  late final Float64List _ends;
  @override
  int get length => scan.expandedBytes;
  @override
  Future<Uint8List> read(int offset, int count) async {
    if (offset < 0 || count < 0 || offset + count > length) {
      throw RangeError('Invalid expanded input range.');
    }
    final output = Uint8List(count);
    var low = 0;
    var high = scan.chunks.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_ends[mid + 1] <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    for (var i = low; i < scan.chunks.length; i++) {
      final chunk = scan.chunks[i];
      final position = _ends[i].toInt();
      final end = _ends[i + 1].toInt();
      final start = math.max(offset, position);
      final stop = math.min(offset + count, end);
      if (stop > start) {
        if (chunk.type == sparseRaw) {
          output.setRange(
            start - offset,
            stop - offset,
            await source.read(
              chunk.dataOffset + start - position,
              stop - start,
            ),
          );
        } else if (chunk.type == sparseFill) {
          for (var p = start; p < stop; p++) {
            output[p - offset] = chunk.fill >> (((p - position) % 4) * 8) & 255;
          }
        }
      }
      if (end >= offset + count) break;
    }
    return output;
  }

  Stream<Uint8List> _verifiedSparse() async* {
    final hash = Sha256Hasher();
    await for (final bytes in source.stream()) {
      hash.update(bytes: bytes);
      yield bytes;
    }
    if (hash.finishHex() != scan.digest) {
      throw const FlashException('Sparse super input changed while streaming.');
    }
  }

  @override
  Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    if (chunkSize <= 0 || chunkSize > 8 << 20) {
      throw ArgumentError.value(chunkSize);
    }
    final input = StreamingFlashCursor(_verifiedSparse(), source.length);
    try {
      for (final chunk in scan.chunks) {
        await input.skipTo(chunk.dataOffset);
        if (chunk.type == sparseFill) await input.readExact(4);
        final total = chunk.blocks * scan.blockSize;
        for (var offset = 0; offset < total; offset += chunkSize) {
          final count = math.min(chunkSize, total - offset);
          if (chunk.type == sparseRaw) {
            yield await input.readExact(count);
          } else {
            final bytes = Uint8List(count);
            if (chunk.type == sparseFill) {
              for (var p = 0; p < count; p++) {
                bytes[p] = chunk.fill >> (((offset + p) % 4) * 8) & 255;
              }
            }
            yield bytes;
          }
        }
      }
      await input.skipTo(source.length);
    } finally {
      await input.close();
    }
  }

  @override
  Future<FlashCursor> cursor() async => StreamingFlashCursor(stream(), length);
  @override
  Future<void> close() => source.close();
}

Uint8List _sparseHeader(int blocks, int chunks) {
  final b = Uint8List(28);
  final d = ByteData.sublistView(b);
  d.setUint32(0, sparseMagic, Endian.little);
  d.setUint16(4, 1, Endian.little);
  d.setUint16(8, 28, Endian.little);
  d.setUint16(10, 12, Endian.little);
  d.setUint32(12, 4096, Endian.little);
  d.setUint32(16, blocks, Endian.little);
  d.setUint32(20, chunks, Endian.little);
  return b;
}

Uint8List _chunkHeader(int kind, int blocks, int bytes) {
  final b = Uint8List(12);
  final d = ByteData.sublistView(b);
  d.setUint16(0, kind, Endian.little);
  d.setUint32(4, blocks, Endian.little);
  d.setUint32(8, 12 + bytes, Endian.little);
  return b;
}
