/// The normal packer's LP layout and sparse bytes, backed only by input sources.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../pipeline/errors.dart';
import '../rust/api/lp.dart';
import '../rust/api/payload.dart' show Sha256Hasher;
import '../rust/api/sparse.dart' show SparseWriter;
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
  'dtbo.img', 'dtbo_patched.img', 'dtbo_patcher.sh', 'dtbo_patcher.py', 'dtbo_patcher',
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

/// A prepared super owns its input handles, not any materialized image.
/// The preparation pass records five bytes per populated 4096-byte block
/// plus rank checkpoints (32 MiB maximum), never the encoded image itself.
final class VirtualSuperImage {
  VirtualSuperImage._(this._regions, this.expandedLength, this._inputs);
  final List<_Region> _regions;
  final int expandedLength;
  final Map<String, FlashSource> _inputs;
  late final int length;
  late final SparseScan scan;
  Future<void>? _preparation;
  bool _ready = false;
  String? get preparedDigest => _ready ? scan.digest : null;
  late final String layoutHeadSha256 =
      (Sha256Hasher()..update(bytes: (_regions.first.source! as _MemorySource).bytes)).finishHex();
  Future<void> prepare() => _preparation ??= _prepare();

  static Future<VirtualSuperImage> create(Map<String, FlashSource> sources, int size,
      {Map<String, String> expectedHashes = const {}, VirtualSuperImage? prepared}) async {
    final inputs = <String, FlashSource>{};
    var sparseInputChunks = 0;
    try {
      for (final entry in sources.entries) {
        final previous = prepared?._inputs[entry.key];
        inputs[entry.key] = await _ExpandedImage.open(entry.value, previous: previous);
        final image = inputs[entry.key]!;
        if (image is _ExpandedImage) {
          sparseInputChunks += image.scan.chunks.length;
          if (sparseInputChunks > 262144) {
            throw const FlashException('Sparse super inputs exceed the combined 262144-chunk index limit.');
          }
        }
        if (image is _ExpandedImage && expectedHashes[entry.key] != null &&
            image.scan.digest != expectedHashes[entry.key]) {
          throw FlashException('${entry.key}.img does not match its manifest SHA-256.');
        }
      }
      final layout = flasherSuperLayout({for (final e in inputs.entries) e.key: e.value.length}, size);
      final regions = <_Region>[_Region(0, layout.head.length, _MemorySource(layout.head))];
      var position = layout.head.length;
      final extents = [...layout.extents]..sort((a, b) => a.offset.compareTo(b.offset));
      for (final extent in extents) {
        final offset = extent.offset.toInt();
        final extentLength = extent.size.toInt();
        final name = extent.name.endsWith('_a') ? extent.name.substring(0, extent.name.length - 2) : extent.name;
        final image = inputs[name];
        if (offset < position || image == null || image.length <= 0) {
          throw const FlashException('Invalid virtual super layout.');
        }
        if (offset > position) regions.add(_Region(position, offset - position, null));
        final padded = (image.length + 4095) ~/ 4096 * 4096;
        if (padded > extentLength) throw const FlashException('Invalid virtual super extent.');
        regions.add(_Region(offset, padded, image,
          expectedHash: image is _ExpandedImage ? null : expectedHashes[name]));
        if (extentLength > padded) regions.add(_Region(offset + padded, extentLength - padded, null));
        position = offset + extentLength;
      }
      if (position > size) throw const FlashException('Virtual super exceeds its device.');
      if (position < size) regions.add(_Region(position, size - position, null));
      final result = VirtualSuperImage._(regions, size, inputs);
      if (prepared != null) result._reuse(prepared);
      return result;
    } on Object {
      // Expanded wrappers own the same handles as the original sources.
      for (final source in sources.values) { await source.close(); }
      rethrow;
    }
  }

  void _reuse(VirtualSuperImage prepared) {
    if (expandedLength != prepared.expandedLength || _regions.length != prepared._regions.length ||
        _inputs.keys.join('/') != prepared._inputs.keys.join('/')) {
      throw const FlashException('The confirmed super layout changed. Prepare again.');
    }
    for (var i = 0; i < _regions.length; i++) {
      final current = _regions[i];
      final old = prepared._regions[i];
      if (current.offset != old.offset || current.length != old.length ||
          current.expectedHash != old.expectedHash || current.source?.length != old.source?.length ||
          (current.source is _ExpandedImage) != (old.source is _ExpandedImage)) {
        throw const FlashException('A confirmed super input changed. Prepare again.');
      }
      if (current.source is _MemorySource &&
          !_equal((current.source! as _MemorySource).bytes, (old.source! as _MemorySource).bytes)) {
        throw const FlashException('The confirmed LP metadata changed. Prepare again.');
      }
      if (prepared._ready) {
        current.firstChunk = old.firstChunk;
        current.encodedOffset = old.encodedOffset;
        current.encodedLength = old.encodedLength;
        current.fills = old.fills;
        current.fillValues = old.fillValues;
        current.ranks = old.ranks;
      }
    }
    if (!prepared._ready) return;
    _header = prepared._header;
    length = prepared.length;
    scan = SparseScan(blockSize: 4096, totalBlocks: expandedLength ~/ 4096,
      chunks: _Chunks(_regions, prepared.scan.chunks.length), digest: prepared.scan.digest, splitter: _split);
    _ready = true;
    _preparation = Future.value();
  }

  late final Uint8List _header;
  Future<void> _prepare() async {
    var chunks = 0;
    var indexBytes = 0;
    for (final region in _regions) {
      if (region.length % 4096 != 0) throw const FlashException('Unaligned virtual super region.');
      region.firstChunk = chunks;
      chunks += region.source == null ? 1 : region.blocks;
      if (region.source != null) indexBytes += region.blocks * 5 + ((region.blocks + 255) ~/ 256 + 1) * 4;
    }
    if (chunks > 0xffffffff || expandedLength ~/ 4096 > 0xffffffff) {
      throw const FlashException('Virtual super exceeds Android sparse geometry.');
    }
    if (indexBytes > 32 << 20) throw const FlashException('Virtual super index exceeds its 32 MiB memory limit.');
    _header = _sparseHeader(expandedLength ~/ 4096, chunks);
    final hasher = Sha256Hasher()..update(bytes: _header);
    var encoded = 28;
    final writer = SparseWriter(blockSize: 4096, totalBlocks: expandedLength ~/ 4096);
    for (final region in _regions) {
      region.encodedOffset = encoded;
      if (region.source == null) {
        final bytes = writer.skip(len: BigInt.from(region.length));
        hasher.update(bytes: bytes);
        encoded += bytes.length;
      } else {
        region.fills = Uint8List(region.blocks);
        region.fillValues = Uint32List(region.blocks);
        region.ranks = Uint32List((region.blocks + 255) ~/ 256 + 1);
        final imageHasher = region.expectedHash == null ? null : Sha256Hasher();
        var fills = 0;
        for (var offset = 0; offset < region.length; offset += 4 << 20) {
          final raw = await region.readRaw(offset, math.min(4 << 20, region.length - offset));
          if (offset == 0 && region.source is OtaPartitionSource &&
              region.source!.length >= 4 &&
              ByteData.sublistView(raw).getUint32(0, Endian.little) == sparseMagic) {
            throw const FlashException(
              'A sparse-encoded OTA partition cannot be represented by virtual super.',
            );
          }
          if (imageHasher != null && offset < region.source!.length) {
            imageHasher.update(bytes: Uint8List.sublistView(raw, 0, math.min(raw.length, region.source!.length - offset)));
          }
          final bytes = writer.push(bytes: raw);
          hasher.update(bytes: bytes);
          encoded += bytes.length;
          var cursor = 0;
          for (var block = offset ~/ 4096; block < (offset + raw.length) ~/ 4096; block++) {
            if (block % 256 == 0) region.ranks![block ~/ 256] = fills;
            final header = ByteData.sublistView(bytes, cursor, cursor + 12);
            if (header.getUint16(0, Endian.little) == sparseFill) {
              region.fills![block] = 1;
              region.fillValues![block] = ByteData.sublistView(bytes, cursor + 12, cursor + 16).getUint32(0, Endian.little);
              fills++;
            }
            cursor += header.getUint32(8, Endian.little);
          }
        }
        region.ranks![region.ranks!.length - 1] = fills;
        if (imageHasher != null && imageHasher.finishHex() != region.expectedHash) {
          throw const FlashException('A super input does not match its manifest SHA-256.');
        }
      }
      region.encodedLength = encoded - region.encodedOffset;
    }
    final tail = writer.finish();
    if (tail.trailer.isNotEmpty || !_equal(tail.header, _header)) {
      throw const FlashException('Virtual sparse encoding differs from the normal packer.');
    }
    length = encoded;
    scan = SparseScan(blockSize: 4096, totalBlocks: expandedLength ~/ 4096,
      chunks: _Chunks(_regions, chunks), digest: hasher.finishHex(), splitter: _split);
    _ready = true;
  }

  List<SparsePart> _split(int limit) {
    // Keep only part boundaries, never millions of per-block piece objects.
    if (limit < 28 + 24 + 4108) {
      throw const FlashException('max-download-size cannot hold a virtual super block.');
    }
    final chunks = scan.chunks;
    final parts = <SparsePart>[];
    var first = 0;
    var firstBlock = 0;
    var block = 0;
    var bytes = 28;
    var i = 0;
    for (final chunk in chunks) {
      final encoded = 12 + chunk.dataSize;
      final tail = block + chunk.blocks < scan.totalBlocks ? 12 : 0;
      if (bytes + encoded + tail > limit) {
        parts.add(SparsePart(pieces: _PartPieces(chunks, first, i, firstBlock, scan.totalBlocks - block),
          blockSize: 4096, totalBlocks: scan.totalBlocks));
        first = i;
        firstBlock = block;
        bytes = 28 + (block == 0 ? 0 : 12);
      }
      bytes += encoded;
      block += chunk.blocks;
      i++;
    }
    if (first < chunks.length) {
      parts.add(SparsePart(pieces: _PartPieces(chunks, first, chunks.length, firstBlock, 0),
        blockSize: 4096, totalBlocks: scan.totalBlocks));
    }
    return List.unmodifiable(parts);
  }

  /// Sparse is byte-for-byte the normal ZIP and folder super.img. Raw expands
  /// DONT_CARE to zero for parity checks, never for the fastboot write path.
  Future<FlashSource> open({bool sparse = true}) async {
    await prepare();
    return _SuperSource(this, sparse);
  }
  Future<void> close() async { for (final source in _inputs.values) { await source.close(); } }

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
      final region = _regions.firstWhere((r) => sparse
        ? position >= r.encodedOffset && position < r.encodedOffset + r.encodedLength
        : position >= r.offset && position < r.offset + r.length);
      if (!sparse) {
        final n = math.min(count - done, region.offset + region.length - position);
        output.setRange(done, done + n, await region.readRaw(position - region.offset, n));
        done += n;
        continue;
      }
      var low = 0;
      var high = region.source == null ? 1 : region.blocks;
      final within = position - region.encodedOffset;
      while (low + 1 < high) {
        final mid = (low + high) ~/ 2;
        if (region.blockOffset(mid) <= within) { low = mid; } else { high = mid; }
      }
      final block = low;
      final fill = region.source != null && region.fills![block] != 0;
      final bytes = region.source == null ? Uint8List(0) : await region.readRaw(block * 4096, fill ? 4 : 4096);
      final chunk = _chunkHeader(region.source == null ? sparseDontCare : fill ? sparseFill : sparseRaw,
        region.source == null ? region.blocks : 1, bytes.length);
      final start = within - region.blockOffset(block);
      final n = math.min(count - done, 12 + bytes.length - start);
      for (var i = 0; i < n; i++) {
        final p = start + i;
        output[done + i] = p < 12 ? chunk[p] : bytes[p - 12];
      }
      done += n;
    }
    return output;
  }
}

final class _Region {
  _Region(this.offset, this.length, this.source, {this.expectedHash});
  final int offset;
  final int length;
  final FlashSource? source;
  final String? expectedHash;
  int get blocks => length ~/ 4096;
  late int firstChunk;
  late int encodedOffset;
  late int encodedLength;
  Uint8List? fills;
  Uint32List? fillValues;
  Uint32List? ranks;
  int blockOffset(int block) {
    if (source == null) return 0;
    final group = block ~/ 256;
    var count = ranks![group];
    for (var b = group * 256; b < block; b++) { count += fills![b]; }
    return block * 4108 - count * 4092;
  }
  Future<Uint8List> readRaw(int offset, int count) async {
    final input = source;
    if (input != null && offset + count <= input.length) return input.read(offset, count);
    final result = Uint8List(count);
    if (input != null && offset < input.length) {
      final n = math.min(count, input.length - offset);
      result.setRange(0, n, await input.read(offset, n));
    }
    return result;
  }
}

/// Lazily materializes parser descriptors; millions of blocks need no millions
/// of heap objects. The splitter consumes this just like a parsed sparse file.
final class _Chunks extends ListBase<SparseChunk> {
  _Chunks(this.regions, this.length);
  final List<_Region> regions;
  @override final int length;
  @override set length(int value) => throw UnsupportedError('immutable');
  @override Iterator<SparseChunk> get iterator => getRange(0, length).iterator;
  @override Iterable<SparseChunk> getRange(int start, int end) sync* {
    RangeError.checkValidRange(start, end, length);
    for (final r in regions) {
      final hole = r.source == null;
      final from = math.max(0, start - r.firstChunk);
      final until = math.min(hole ? 1 : r.blocks, end - r.firstChunk);
      if (from >= until) continue;
      var offset = r.encodedOffset + r.blockOffset(from);
      for (var block = from; block < until; block++) {
        final fill = !hole && r.fills![block] != 0;
        final size = hole ? 0 : fill ? 4 : 4096;
        yield SparseChunk(type: hole ? sparseDontCare : fill ? sparseFill : sparseRaw,
          blocks: hole ? r.blocks : 1, dataOffset: offset + 12,
          dataSize: size, fill: fill ? r.fillValues![block] : 0);
        offset += 12 + size;
      }
    }
  }
  @override SparseChunk operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final r = regions.lastWhere((r) => r.firstChunk <= index);
    final block = index - r.firstChunk;
    final hole = r.source == null;
    final fill = !hole && r.fills![block] != 0;
    return SparseChunk(type: hole ? sparseDontCare : fill ? sparseFill : sparseRaw,
      blocks: hole ? r.blocks : 1, dataOffset: r.encodedOffset + r.blockOffset(block) + 12,
      dataSize: hole ? 0 : fill ? 4 : 4096, fill: fill ? r.fillValues![block] : 0);
  }
  @override void operator []=(int index, SparseChunk value) => throw UnsupportedError('immutable');
}

final class _PartPieces extends ListBase<SparsePiece> {
  _PartPieces(this.chunks, this.start, this.end, this.leading, this.trailing);
  final List<SparseChunk> chunks;
  final int start;
  final int end;
  final int leading;
  final int trailing;
  @override int get length => end - start + (leading > 0 ? 1 : 0) + (trailing > 0 ? 1 : 0);
  @override set length(int value) => throw UnsupportedError('immutable');
  @override Iterator<SparsePiece> get iterator => _iterate().iterator;
  Iterable<SparsePiece> _iterate() sync* {
    if (leading > 0) yield SparsePiece(type: sparseDontCare, blocks: leading);
    for (final c in chunks.getRange(start, end)) {
      yield SparsePiece(type: c.type, blocks: c.blocks, dataOffset: c.dataOffset, dataSize: c.dataSize, fill: c.fill);
    }
    if (trailing > 0) yield SparsePiece(type: sparseDontCare, blocks: trailing);
  }
  @override SparsePiece operator [](int index) {
    RangeError.checkValidIndex(index, this);
    if (leading > 0) {
      if (index == 0) return SparsePiece(type: sparseDontCare, blocks: leading);
      index--;
    }
    if (index == end - start) return SparsePiece(type: sparseDontCare, blocks: trailing);
    final c = chunks[start + index];
    return SparsePiece(type: c.type, blocks: c.blocks, dataOffset: c.dataOffset, dataSize: c.dataSize, fill: c.fill);
  }
  @override void operator []=(int index, SparsePiece value) => throw UnsupportedError('immutable');
}

final class _SuperSource implements PreScannedFlashSource {
  _SuperSource(this.image, this.sparse);
  final VirtualSuperImage image;
  final bool sparse;
  bool _taken = false;
  @override SparseScan? takeSparseScan() {
    if (!sparse || _taken) return null;
    _taken = true;
    return image.scan;
  }
  @override int get length => sparse ? image.length : image.expandedLength;
  @override Future<Uint8List> read(int offset, int length) => image._read(offset, length, sparse);
  @override Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    if (chunkSize <= 0 || chunkSize > 8 << 20) throw ArgumentError.value(chunkSize);
    if (!sparse) {
      for (var offset = 0; offset < length; offset += chunkSize) {
        yield await read(offset, math.min(chunkSize, length - offset));
      }
      return;
    }
    final writer = SparseWriter(blockSize: 4096, totalBlocks: image.expandedLength ~/ 4096);
    for (var p = 0; p < image._header.length; p += chunkSize) {
      yield Uint8List.sublistView(image._header, p, math.min(p + chunkSize, image._header.length));
    }
    for (final region in image._regions) {
      if (region.source == null) {
        final bytes = writer.skip(len: BigInt.from(region.length));
        for (var p = 0; p < bytes.length; p += chunkSize) {
          yield Uint8List.sublistView(bytes, p, math.min(p + chunkSize, bytes.length));
        }
      } else {
        for (var offset = 0; offset < region.length; offset += 4 << 20) {
          final bytes = writer.push(bytes: await region.readRaw(offset, math.min(4 << 20, region.length - offset)));
          var cursor = 0;
          final blockEnd = math.min(offset + (4 << 20), region.length) ~/ 4096;
          for (var block = offset ~/ 4096; block < blockEnd; block++) {
            final chunk = ByteData.sublistView(bytes, cursor, cursor + 12);
            final fill = region.fills![block] != 0;
            if (chunk.getUint16(0, Endian.little) != (fill ? sparseFill : sparseRaw) ||
                (fill && ByteData.sublistView(bytes, cursor + 12, cursor + 16)
                    .getUint32(0, Endian.little) != region.fillValues![block])) {
              throw const FlashException('Virtual super sparse encoding changed after preparation.');
            }
            cursor += chunk.getUint32(8, Endian.little);
          }
          if (cursor != bytes.length) {
            throw const FlashException('Virtual super sparse chunk count changed after preparation.');
          }
          for (var p = 0; p < bytes.length; p += chunkSize) {
            yield Uint8List.sublistView(bytes, p, math.min(p + chunkSize, bytes.length));
          }
        }
      }
    }
    final tail = writer.finish();
    if (tail.trailer.isNotEmpty || !_equal(tail.header, image._header)) {
      throw const FlashException('Virtual super changed while streaming.');
    }
  }
  @override Future<FlashCursor> cursor() async => _StreamCursor(stream(), length);
  @override Future<void> close() async {}
}

final class _StreamCursor implements FlashCursor {
  _StreamCursor(Stream<Uint8List> stream, this.length) : iterator = StreamIterator(stream);
  final StreamIterator<Uint8List> iterator;
  final int length;
  Uint8List _chunk = Uint8List(0);
  int _within = 0;
  int _position = 0;
  Future<void> _consume(int count, Uint8List? output) async {
    var done = 0;
    if (count < 0 || count > length - _position) throw RangeError('Invalid virtual super cursor range.');
    while (done < count) {
      if (_within == _chunk.length) {
        if (!await iterator.moveNext()) throw const FlashException('Virtual super ended early.');
        _chunk = iterator.current;
        _within = 0;
      }
      final n = math.min(count - done, _chunk.length - _within);
      output?.setRange(done, done + n, _chunk, _within);
      _within += n;
      done += n;
    }
    _position += count;
  }
  @override Future<Uint8List> readExact(int length) async {
    if (length < 0 || length > 8 << 20) throw RangeError('Virtual cursor reads are limited to 8 MiB.');
    final result = Uint8List(length);
    await _consume(length, result);
    return result;
  }
  @override Future<void> skipTo(int offset) => _consume(offset - _position, null);
  @override Future<void> close() => iterator.cancel();
}

final class _MemorySource implements FlashSource {
  _MemorySource(this.bytes);
  final Uint8List bytes;
  @override int get length => bytes.length;
  @override Future<Uint8List> read(int offset, int length) async => Uint8List.sublistView(bytes, offset, offset + length);
  @override Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    for (var p = 0; p < length; p += chunkSize) { yield await read(p, math.min(chunkSize, length - p)); }
  }
  @override Future<FlashCursor> cursor() async => RandomFlashCursor(this);
  @override Future<void> close() async {}
}

/// An input sparse bloat file is expanded, exactly as the normal packer does.
final class _ExpandedImage implements FlashSource {
  _ExpandedImage(this.source, this.scan) {
    _ends = Float64List(scan.chunks.length + 1);
    for (var i = 0; i < scan.chunks.length; i++) {
      _ends[i + 1] = _ends[i] + scan.chunks[i].blocks * scan.blockSize;
    }
  }
  static Future<FlashSource> open(FlashSource source, {FlashSource? previous}) async {
    // Payload destinations are raw partition contents. Probing four bytes
    // here would decode the whole covering operation during package loading.
    // The preparation pass rejects unexpected sparse-encoded OTA inputs.
    if (source is OtaPartitionSource) return source;
    if (previous is _ExpandedImage) {
      if (source.length != previous.source.length) throw const FlashException('A confirmed sparse input changed size.');
      return _ExpandedImage(source, previous.scan);
    }
    if (previous != null || !await isSparseSource(source)) return source;
    final header = ByteData.sublistView(await source.read(0, 28));
    if (header.getUint32(20, Endian.little) > 262144) {
      throw const FlashException('Sparse super input exceeds the 262144-chunk index limit.');
    }
    return _ExpandedImage(source, await scanSparse(source));
  }
  final FlashSource source;
  final SparseScan scan;
  late final Float64List _ends;
  @override int get length => scan.expandedBytes;
  @override Future<Uint8List> read(int offset, int count) async {
    if (offset < 0 || count < 0 || offset + count > length) throw RangeError('Invalid expanded input range.');
    final output = Uint8List(count);
    var low = 0;
    var high = scan.chunks.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_ends[mid + 1] <= offset) { low = mid + 1; } else { high = mid; }
    }
    for (var i = low; i < scan.chunks.length; i++) {
      final chunk = scan.chunks[i];
      final position = _ends[i].toInt();
      final end = _ends[i + 1].toInt();
      final start = math.max(offset, position);
      final stop = math.min(offset + count, end);
      if (stop > start) {
        if (chunk.type == sparseRaw) {
          output.setRange(start - offset, stop - offset, await source.read(chunk.dataOffset + start - position, stop - start));
        } else if (chunk.type == sparseFill) {
          for (var p = start; p < stop; p++) { output[p - offset] = chunk.fill >> (((p - position) % 4) * 8) & 255; }
        }
      }
      if (end >= offset + count) break;
    }
    return output;
  }
  @override Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    for (var p = 0; p < length; p += chunkSize) { yield await read(p, math.min(chunkSize, length - p)); }
  }
  @override Future<FlashCursor> cursor() async => RandomFlashCursor(this);
  @override Future<void> close() => source.close();
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
bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) { if (a[i] != b[i]) return false; }
  return true;
}
