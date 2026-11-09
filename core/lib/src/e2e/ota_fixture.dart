/// Deterministic full-OTA fixtures for the virtual-flash tests.
///
/// The payload is written field by field (AOSP `update_metadata.proto`), so a
/// test can place destination extents out of operation order, use several
/// extents per operation, omit an operation hash or leave a region zeroed.
/// The OTA ZIP stores `payload.bin` uncompressed, as a full OTA must.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'compression_fixture.dart' show crc32, xzStore, zstdStore;

export 'compression_fixture.dart' show crc32;

/// The fixture payload block size, as every real full OTA uses.
const int fixtureBlock = 4096;

/// A destination range of one operation, in blocks.
final class FixtureExtent {
  const FixtureExtent(this.startBlock, this.blocks);

  final int startBlock;
  final int blocks;

  int get bytes => blocks * fixtureBlock;
}

/// REPLACE: the operation's data fills its extents.
const int fixtureReplace = 0;

/// REPLACE_XZ: the operation's data is an XZ stream that fills its extents.
const int fixtureReplaceXz = 8;

/// ZERO: the extents read as zero and carry no payload data.
const int fixtureZero = 6;

/// REPLACE_ZSTD: the operation's data is a Zstandard frame.
const int fixtureReplaceZstd = 14;

final Uint8List _noBytes = Uint8List(0);

/// One install operation.
final class FixtureOp {
  FixtureOp({
    required this.kind,
    required this.dst,
    Uint8List? data,
    Uint8List? decoded,
    this.hash = true,
  }) : data = data ?? _noBytes,
       decoded = decoded ?? data ?? _noBytes;

  /// A REPLACE operation; [data] fills the [dst] extents in order.
  FixtureOp.replace(List<FixtureExtent> dst, Uint8List data, {bool hash = true})
    : this(kind: fixtureReplace, dst: dst, data: data, hash: hash);

  /// A REPLACE_XZ or REPLACE_ZSTD operation over [decoded].
  ///
  /// The payload carries the compressed stream; the extents read as the
  /// decoded bytes, so the manifest hashes and the partition image differ
  /// from the operation data exactly as they do in a real OTA.
  FixtureOp.coded(int kind, List<FixtureExtent> dst, Uint8List decoded, {bool hash = true})
    : this(
        kind: kind,
        dst: dst,
        data: kind == fixtureReplaceXz
            ? xzStore(decoded)
            : zstdStore(decoded),
        decoded: decoded,
        hash: hash,
      );

  /// A ZERO operation: no payload data, extents read as zero.
  FixtureOp.zero(List<FixtureExtent> dst) : this(kind: fixtureZero, dst: dst);

  final int kind;
  final List<FixtureExtent> dst;

  /// The operation's payload bytes, as the payload carries them.
  final Uint8List data;

  /// The bytes the extents read after decoding.
  final Uint8List decoded;

  /// Whether the manifest records the operation's data SHA-256.
  final bool hash;
}

/// One payload partition.
final class FixturePartition {
  FixturePartition({required this.name, required this.ops, this.hash = true});

  final String name;
  final List<FixtureOp> ops;

  /// Whether the partition records its whole-image SHA-256.
  final bool hash;

  int get blocks => ops.fold<int>(
    0,
    (end, op) => op.dst.fold<int>(
      end,
      (inner, extent) => math.max(inner, extent.startBlock + extent.blocks),
    ),
  );

  int get size => blocks * fixtureBlock;

  /// The image the operations produce, in destination order.
  Uint8List image() {
    final bytes = Uint8List(size);
    for (final op in ops) {
      if (op.kind == fixtureZero) continue;
      var position = 0;
      for (final extent in op.dst) {
        bytes.setRange(
          extent.startBlock * fixtureBlock,
          extent.startBlock * fixtureBlock + extent.bytes,
          op.decoded,
          position,
        );
        position += extent.bytes;
      }
    }
    return bytes;
  }

  /// The image's SHA-256, lowercase hex.
  String get sha256Hex => sha256.convert(image()).toString();
}

/// A full AB OTA over [partitions].
final class OtaFixture {
  OtaFixture(
    this.partitions, {
    this.versionName = 'TEST_1.2.3.4',
    this.preDevice = 'TEST-ONLY',
    this.fields = const {},
  });

  final List<FixturePartition> partitions;
  final String versionName;
  final String preDevice;

  /// Additional `META-INF/com/android/metadata` keys, in insertion order.
  final Map<String, String> fields;

  /// `payload.bin` as [build] writes it.
  Uint8List payload = _noBytes;

  /// Offset of `payload.bin`'s first byte inside the OTA ZIP.
  int payloadZipOffset = 0;

  /// Payload offset where operation data starts.
  int payloadDataStart = 0;

  /// Per partition, each operation's data offset relative to the data start.
  final Map<String, List<int>> opDataOffsets = {};

  /// Absolute offset in [build]'s bytes of a partition operation's data.
  int dataOffsetInZip(String partition, int opIndex) =>
      payloadZipOffset + payloadDataStart + opDataOffsets[partition]![opIndex];

  /// The OTA ZIP.
  Uint8List build() {
    final opOffsets = <String, List<int>>{};
    final data = BytesBuilder(copy: false);
    final manifest = BytesBuilder(copy: false);
    _fieldVarint(manifest, 3, fixtureBlock);
    _fieldVarint(manifest, 12, 10);
    for (final partition in partitions) {
      final info = BytesBuilder(copy: false);
      _fieldVarint(info, 1, partition.size);
      if (partition.hash) {
        _fieldBytes(info, 2, sha256.convert(partition.image()).bytes);
      }
      final part = BytesBuilder(copy: false);
      _fieldBytes(part, 1, utf8.encode(partition.name));
      _fieldBytes(part, 7, info.takeBytes());
      final offsets = <int>[];
      for (final op in partition.ops) {
        offsets.add(data.length);
        final message = BytesBuilder(copy: false);
        _fieldVarint(message, 1, op.kind);
        _fieldVarint(message, 2, data.length);
        _fieldVarint(message, 3, op.data.length);
        for (final extent in op.dst) {
          final encoded = BytesBuilder(copy: false);
          _fieldVarint(encoded, 1, extent.startBlock);
          _fieldVarint(encoded, 2, extent.blocks);
          _fieldBytes(message, 6, encoded.takeBytes());
        }
        if (op.hash && op.data.isNotEmpty) {
          _fieldBytes(message, 8, sha256.convert(op.data).bytes);
        }
        _fieldBytes(part, 8, message.takeBytes());
        data.add(op.data);
      }
      opOffsets[partition.name] = offsets;
      _fieldBytes(manifest, 13, part.takeBytes());
    }
    final manifestBytes = manifest.takeBytes();
    final header = BytesBuilder(copy: false)
      ..add(const [0x43, 0x72, 0x41, 0x55]) // CrAU
      ..add(_u64be(2))
      ..add(_u64be(manifestBytes.length))
      ..add(_u32be(0));
    payloadDataStart = header.length + manifestBytes.length;
    header
      ..add(manifestBytes)
      ..add(data.takeBytes());
    payload = header.takeBytes();
    opDataOffsets
      ..clear()
      ..addAll(opOffsets);

    final metadata = Uint8List.fromList(
      utf8.encode(
        'ota-type=AB\n'
        'pre-device=$preDevice\n'
        'version_name=$versionName\n'
        '${[
          for (final entry in fields.entries) '${entry.key}=${entry.value}',
        ].join('\n')}${fields.isEmpty ? '' : '\n'}',
      ),
    );
    payloadZipOffset = 30 + utf8.encode('payload.bin').length;
    return buildZip([
      (name: 'payload.bin', bytes: payload),
      (name: 'META-INF/com/android/metadata', bytes: metadata),
    ]);
  }
}

Uint8List _u64be(int value) {
  final bytes = Uint8List(8);
  ByteData.sublistView(bytes).setUint64(0, value, Endian.big);
  return bytes;
}

Uint8List _u32be(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value, Endian.big);
  return bytes;
}

void _varint(BytesBuilder out, int value) {
  var rest = value;
  while (true) {
    final byte = rest & 0x7f;
    rest >>= 7;
    if (rest == 0) {
      out.addByte(byte);
      return;
    }
    out.addByte(byte | 0x80);
  }
}

void _fieldVarint(BytesBuilder out, int field, int value) {
  _varint(out, field << 3);
  _varint(out, value);
}

void _fieldBytes(BytesBuilder out, int field, List<int> bytes) {
  _varint(out, (field << 3) | 2);
  _varint(out, bytes.length);
  out.add(bytes);
}

// ---------------------------------------------------------------------------
// ZIP

/// A stored (uncompressed) ZIP over [entries], in order.
///
/// OTA reading needs only the central directory and stored data, so the
/// fixture keeps the archive simple: no ZIP64, no data descriptors.
Uint8List buildZip(List<({String name, Uint8List bytes})> entries) {
  final out = BytesBuilder(copy: false);
  final centrals = BytesBuilder(copy: false);
  for (final entry in entries) {
    final name = utf8.encode(entry.name);
    final offset = out.length;
    final crc = crc32(entry.bytes);
    out
      ..add(const [0x50, 0x4b, 0x03, 0x04])
      ..add(_le16(20)) // version needed
      ..add(_le16(0x0800)) // UTF-8 names
      ..add(_le16(0)) // stored
      ..add(_le16(0)) // time
      ..add(_le16(0x21)) // 1980-01-01
      ..add(_le32(crc))
      ..add(_le32(entry.bytes.length))
      ..add(_le32(entry.bytes.length))
      ..add(_le16(name.length))
      ..add(_le16(0)) // extra
      ..add(name)
      ..add(entry.bytes);
    centrals
      ..add(const [0x50, 0x4b, 0x01, 0x02])
      ..add(_le16((3 << 8) | 20)) // made by Unix
      ..add(_le16(20))
      ..add(_le16(0x0800))
      ..add(_le16(0))
      ..add(_le16(0))
      ..add(_le16(0x21))
      ..add(_le32(crc))
      ..add(_le32(entry.bytes.length))
      ..add(_le32(entry.bytes.length))
      ..add(_le16(name.length))
      ..add(_le16(0)) // extra
      ..add(_le16(0)) // comment
      ..add(_le16(0)) // disk
      ..add(_le16(0)) // internal attributes
      ..add(_le32(0x81a4 << 16)) // 0o100644
      ..add(_le32(offset))
      ..add(name);
  }
  final central = centrals.takeBytes();
  final localSize = out.length;
  out
    ..add(central)
    ..add(const [0x50, 0x4b, 0x05, 0x06])
    ..add(_le16(0))
    ..add(_le16(0))
    ..add(_le16(entries.length))
    ..add(_le16(entries.length))
    ..add(_le32(central.length))
    ..add(_le32(localSize))
    ..add(_le16(0));
  return out.takeBytes();
}

Uint8List _le16(int value) {
  final bytes = Uint8List(2);
  ByteData.sublistView(bytes).setUint16(0, value, Endian.little);
  return bytes;
}

Uint8List _le32(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
  return bytes;
}

/// [length] deterministic bytes derived from [seed].
Uint8List pattern(int length, {int seed = 0}) {
  final bytes = Uint8List(length);
  var value = seed * 2654435761 + 1;
  for (var index = 0; index < length; index++) {
    value = (value * 1103515245 + 12345) & 0x7fffffff;
    bytes[index] = (value >> 16) & 0xff;
  }
  return bytes;
}
