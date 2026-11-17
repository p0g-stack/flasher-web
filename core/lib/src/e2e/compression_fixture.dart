/// Store-only XZ and ZSTD encoders for OTA operation fixtures.
///
/// The virtual-flash fixtures need `REPLACE_XZ` and `REPLACE_ZSTD` operations
/// whose payload data really is a compressed stream. Both encoders emit a
/// valid container whose single block/segment is stored, so no compression
/// library is needed in the test process: only the container framing, the
/// LZMA2 uncompressed-chunk framing and the Zstandard raw-block framing.
library;

import 'dart:typed_data';

/// CRC-32 (IEEE) of [data].
int crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

final List<int> _crcTable = List<int>.generate(256, (index) {
  var value = index;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 1) == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1;
  }
  return value;
});

Uint8List _le32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

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

/// LZMA2 chunks that store [data] uncompressed.
///
/// The first chunk resets the dictionary; each chunk carries at most 65536
/// bytes, the LZMA2 uncompressed-chunk limit, and a 0x00 control byte ends
/// the stream.
void _lzma2Store(BytesBuilder out, Uint8List data) {
  var first = true;
  var offset = 0;
  while (offset < data.length) {
    final count = data.length - offset < 65536 ? data.length - offset : 65536;
    out
      ..addByte(first ? 0x01 : 0x02)
      ..addByte((count - 1) >> 8)
      ..addByte((count - 1) & 0xff)
      ..add(Uint8List.sublistView(data, offset, offset + count));
    first = false;
    offset += count;
  }
  out.addByte(0x00);
}

/// [data] as one XZ stream with a single LZMA2 block and a CRC32 check.
Uint8List xzStore(Uint8List data) {
  const flags = [0x00, 0x01]; // check id 1: CRC32
  final out = BytesBuilder(copy: false)
    ..add(const [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00])
    ..add(flags)
    ..add(_le32(crc32(flags)));

  final body = BytesBuilder(copy: false);
  _lzma2Store(body, data);
  final bodyBytes = body.takeBytes();

  // Block flags 0x00: one filter, no stored sizes. The block header includes
  // its own size byte and CRC32 and must be a multiple of four.
  final header = BytesBuilder(copy: false)
    ..addByte(0x00) // block flags
    ..addByte(0x21) // LZMA2 filter id
    ..addByte(0x01) // one property byte
    ..addByte(0x00); // dictionary size code
  final content = header.takeBytes();
  final padded = content.length + (4 - ((1 + content.length) % 4)) % 4;
  final blockHeader = BytesBuilder(copy: false)
    ..addByte((1 + padded + 4) ~/ 4 - 1)
    ..add(content)
    ..add(Uint8List(padded - content.length));
  final headerBytes = blockHeader.takeBytes();
  out
    ..add(headerBytes)
    ..add(_le32(crc32(headerBytes)))
    ..add(bodyBytes)
    ..add(Uint8List((4 - bodyBytes.length % 4) % 4))
    ..add(_le32(crc32(data)));

  final index = BytesBuilder(copy: false)..addByte(0x00); // index indicator
  _varint(index, 1); // one record
  _varint(index, headerBytes.length + bodyBytes.length + 4);
  _varint(index, data.length);
  final indexBytes = index.takeBytes();
  final indexPadded = indexBytes.length + (4 - (indexBytes.length + 4) % 4) % 4;
  final fullIndex = BytesBuilder(copy: false)
    ..add(indexBytes)
    ..add(Uint8List(indexPadded - indexBytes.length));
  final fullIndexBytes = fullIndex.takeBytes();
  final backwardSize = (fullIndexBytes.length + 4) ~/ 4 - 1;
  out
    ..add(fullIndexBytes)
    ..add(_le32(crc32(fullIndexBytes)))
    ..add(_le32(crc32([..._le32(backwardSize), ...flags])))
    ..add(_le32(backwardSize))
    ..add(flags)
    ..add(const [0x59, 0x5a]);
  return out.takeBytes();
}

/// [data] as one Zstandard frame of raw blocks, with the content size stored.
Uint8List zstdStore(Uint8List data) {
  final out = BytesBuilder(copy: false)
    ..add(const [0x28, 0xb5, 0x2f, 0xfd])
    // Single segment, frame content size present as eight bytes, no checksum.
    ..addByte(0xe0);
  final size = Uint8List(8)
    ..buffer.asByteData().setUint64(0, data.length, Endian.little);
  out.add(size);
  if (data.isEmpty) {
    out.add(const [0x01, 0x00, 0x00]);
    return out.takeBytes();
  }
  var offset = 0;
  while (offset < data.length) {
    final count = data.length - offset < 4096 ? data.length - offset : 4096;
    final last = offset + count == data.length ? 1 : 0;
    final header = (count << 3) | last;
    out
      ..addByte(header & 0xff)
      ..addByte((header >> 8) & 0xff)
      ..addByte((header >> 16) & 0xff)
      ..add(Uint8List.sublistView(data, offset, offset + count));
    offset += count;
  }
  return out.takeBytes();
}
