@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flasher_web_core/src/native/native.dart';
import 'package:flasher_web_core/src/pipeline/errors.dart';
import 'package:flasher_web_core/src/pipeline/package.dart';
import 'package:flasher_web_core/src/rust/api/lp.dart';
import 'package:flasher_web_core/src/rust/api/payload.dart' show Sha256Hasher;
import 'package:flasher_web_core/src/rust/api/sparse.dart';
import 'package:flasher_web_core/src/rust/api/zip.dart';
import 'package:flasher_web_core/src/storage/storage.dart';
import 'package:test/test.dart';

const int block = 4096;
const int imageSize = 4 * block;
const int superSize = 8 * 1024 * 1024;

List<int> rawImage(int seed) =>
    List<int>.generate(imageSize, (index) => (index * seed + seed) & 0xff);

/// Four blocks: RAW, FILL, DONT_CARE; the expanded size is [imageSize].
Uint8List sparseImage() {
  final out = BytesBuilder();
  final header = ByteData(28);
  header.setUint32(0, 0xed26ff3a, Endian.little);
  header.setUint16(4, 1, Endian.little);
  header.setUint16(6, 0, Endian.little);
  header.setUint16(8, 28, Endian.little);
  header.setUint16(10, 12, Endian.little);
  header.setUint32(12, block, Endian.little);
  header.setUint32(16, 4, Endian.little);
  header.setUint32(20, 3, Endian.little);
  header.setUint32(24, 0, Endian.little);
  out.add(header.buffer.asUint8List());

  out.add(_chunk(0xcac1, 1, block, List<int>.filled(block, 0x11)));
  out.add(_chunk(0xcac2, 2, 4, [0x55, 0x44, 0x33, 0x22]));
  out.add(_chunk(0xcac3, 1, 0, const []));
  return out.takeBytes();
}

Uint8List _chunk(int kind, int blocks, int dataLength, List<int> data) {
  final header = ByteData(12);
  header.setUint16(0, kind, Endian.little);
  header.setUint16(2, 0, Endian.little);
  header.setUint32(4, blocks, Endian.little);
  header.setUint32(8, 12 + dataLength, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...data]);
}

SuperSpec spec() => SuperSpec(
  deviceSize: BigInt.from(superSize),
  superName: 'super',
  metadataSize: 65536,
  metadataSlots: 3,
  virtualAb: true,
  logicalBlockSize: 4096,
  alignment: 1 << 20,
  groups: [
    SuperGroup(
      name: 'qti_dynamic_partitions_a',
      size: BigInt.from(superSize - 4 * 1024 * 1024),
    ),
    SuperGroup(
      name: 'qti_dynamic_partitions_b',
      size: BigInt.from(superSize - 4 * 1024 * 1024),
    ),
  ],
  partitions: [
    // `pack_super` walks SUPER_PARTS, where product precedes system and
    // vendor, so that is also the LP allocation order.
    for (final name in ['product', 'system', 'vendor'])
      SuperPartition(
        name: '${name}_a',
        size: BigInt.from(imageSize),
        group: 'qti_dynamic_partitions_a',
        readonly: true,
        hasImage: true,
      ),
    for (final name in ['product', 'system', 'vendor'])
      SuperPartition(
        name: '${name}_b',
        size: BigInt.zero,
        group: 'qti_dynamic_partitions_b',
        readonly: true,
        hasImage: false,
      ),
  ],
);

/// Expands a sparse image with the Rust parser.
List<int> expand(List<int> file) {
  final header = sparseHeader(bytes28: file.sublist(0, 28))!;
  final out = BytesBuilder();
  var offset = header.fileHeaderSize;
  for (var index = 0; index < header.totalChunks; index++) {
    final chunk = sparseChunk(bytes12: file.sublist(offset, offset + 12));
    final data = file.sublist(offset + 12, offset + chunk.totalSize);
    switch (chunk.kind) {
      case 0xcac1:
        out.add(data);
      case 0xcac2:
        final blockBytes = BytesBuilder();
        for (var index = 0; index < header.blockSize; index += data.length) {
          blockBytes.add(data);
        }
        final filled = blockBytes.takeBytes();
        for (var block = 0; block < chunk.blocks; block++) {
          out.add(filled);
        }
      case 0xcac3:
        out.add(Uint8List(chunk.blocks * header.blockSize));
      case 0xcac4:
        break;
    }
    offset += chunk.totalSize;
  }
  return out.takeBytes();
}

Future<void> writeFile(
  Workspace workspace,
  String path,
  List<int> bytes,
) async {
  final sink = await workspace.create(path);
  await sink.write(Uint8List.fromList(bytes), 0);
  await sink.close();
}

Future<Uint8List> readFile(Workspace workspace, String path) async {
  final source = await workspace.open(path);
  try {
    return await source.read(0, source.length);
  } finally {
    if (source is FileSource) await source.close();
  }
}

List<ZipEntry> zipEntriesOf(Uint8List file) {
  const tailLimit = 65557 + 20 + 56;
  final tail = file.length <= tailLimit
      ? file
      : file.sublist(file.length - tailLimit);
  final directory = zipEntries(tail: tail, fileLen: BigInt.from(file.length));
  final needs = directory.needs;
  if (needs == null) return directory.entries;
  final (offset, length) = needs;
  return zipParseCentral(
    cd: file.sublist(offset.toInt(), offset.toInt() + length.toInt()),
  );
}

void main() {
  late Directory temp;
  late IoWorkspace workspace;

  setUpAll(() async {
    expect(await loadNative(), isTrue);
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('flasher_package_');
    workspace = IoWorkspace(temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> stage() async {
    await writeFile(workspace, 'result/Super/system.img', sparseImage());
    await writeFile(workspace, 'result/Super/vendor.img', rawImage(7));
    await writeFile(workspace, 'result/Super/product.img', rawImage(13));
    await writeFile(workspace, 'result/OOS_FILES_HERE/boot.img', rawImage(3));
    await writeFile(
      workspace,
      'result/run.sh',
      utf8.encode('#!/bin/sh\necho flasher\n'),
    );
    await writeFile(workspace, 'result/update-binary', utf8.encode('binary'));
  }

  test('folder: sparse super, moved tree and no staged images', () async {
    await stage();
    final layout = superLayout(spec: spec());
    // `lpmake --sparse` expands to the physical device size, not to the end
    // of the last extent; upstream's selftest asserts this for X9U and NEO8.
    final expandedSize = superSize;

    final result = await packageFlasher(
      workspace,
      'result',
      destination: 'out/Super Flasher 13 GLO',
      zip: false,
      superSize: superSize,
      superSizeFile: true,
    );
    expect(result.format, 'folder');
    expect(result.sha256, isNull);
    expect(await workspace.exists('result/Super'), isFalse);
    expect(await workspace.exists('out/Super Flasher 13 GLO/Super'), isFalse);
    expect(
      await workspace.exists(
        'out/Super Flasher 13 GLO/OOS_FILES_HERE/boot.img',
      ),
      isTrue,
    );
    expect(await workspace.exists('result/OOS_FILES_HERE/boot.img'), isFalse);

    final superFile = await readFile(
      workspace,
      'out/Super Flasher 13 GLO/super.img',
    );
    final header = sparseHeader(bytes28: superFile.sublist(0, 28))!;
    expect(header.blockSize, block);
    expect(header.totalBlocks * block, expandedSize);

    final sizeFile = await readFile(
      workspace,
      'out/Super Flasher 13 GLO/META-INF/com/google/android/super-size',
    );
    expect(utf8.decode(sizeFile), '$superSize\n');

    final image = expand(superFile);
    expect(image.length, expandedSize);
    expect(
      ByteData.sublistView(Uint8List.fromList(image))
          .getUint32(4096, Endian.little),
      0x616c4467,
    );

    final system = layout.extents
        .firstWhere((e) => e.name == 'system_a')
        .offset
        .toInt();
    expect(image.sublist(system, system + block), List.filled(block, 0x11));
    final fill = image.sublist(system + block, system + 3 * block);
    for (var index = 0; index < fill.length; index += 4) {
      expect(fill.sublist(index, index + 4), [0x55, 0x44, 0x33, 0x22]);
    }
    expect(
      image.sublist(system + 3 * block, system + 4 * block),
      List.filled(block, 0),
    );

    final vendor = layout.extents
        .firstWhere((e) => e.name == 'vendor_a')
        .offset
        .toInt();
    expect(image.sublist(vendor, vendor + imageSize), rawImage(7));
    final product = layout.extents
        .firstWhere((e) => e.name == 'product_a')
        .offset
        .toInt();
    expect(image.sublist(product, product + imageSize), rawImage(13));
  });

  test('ZIP: streams the super and writes the checksum beside it', () async {
    await stage();
    final layout = superLayout(spec: spec());
    // `lpmake --sparse` expands to the physical device size, not to the end
    // of the last extent; upstream's selftest asserts this for X9U and NEO8.
    final expandedSize = superSize;

    final result = await packageFlasher(
      workspace,
      'result',
      destination: 'out/Super Flasher 13 GLO.zip',
      zip: true,
      superSize: superSize,
      superSizeFile: true,
    );
    expect(result.format, 'zip');
    expect(result.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(await workspace.exists('result/Super'), isFalse);
    expect(await workspace.exists('result/super.img'), isFalse);

    final archive = await readFile(workspace, 'out/Super Flasher 13 GLO.zip');
    final checksum = utf8.decode(
      await readFile(workspace, 'out/Super Flasher 13 GLO.zip.sha256'),
    );
    expect(checksum, '${result.sha256}  Super Flasher 13 GLO.zip\n');
    final hasher = Sha256Hasher()..update(bytes: archive);
    expect(hasher.finishHex(), result.sha256);

    final entries = zipEntriesOf(archive);
    final names = entries.map((entry) => entry.name).toList();
    expect(names, contains('super.img'));
    expect(names, contains('OOS_FILES_HERE/boot.img'));
    expect(names, contains('run.sh'));
    expect(names, contains('META-INF/com/google/android/super-size'));
    expect(names.any((name) => name.startsWith('Super/')), isFalse);

    final superEntry = entries.firstWhere((entry) => entry.name == 'super.img');
    expect(superEntry.method, 8);
    expect(
      entries.firstWhere((entry) => entry.name == 'run.sh').unixMode,
      0x81ed,
    );
    expect(
      entries
          .firstWhere((entry) => entry.name == 'OOS_FILES_HERE/boot.img')
          .unixMode,
      0x81a4,
    );

    final localOffset = superEntry.localHeaderOffset.toInt();
    final dataOffset = zipDataOffset(
      localHeader30Bytes: archive.sublist(localOffset, localOffset + 30),
      localHeaderOffset: superEntry.localHeaderOffset,
    ).toInt();
    final compressed = archive.sublist(
      dataOffset,
      dataOffset + superEntry.compressedSize.toInt(),
    );
    final superFile = inflateRaw(
      data: compressed,
      expectedLen: superEntry.uncompressedSize,
    );
    final sparse = sparseHeader(bytes28: superFile.sublist(0, 28))!;
    expect(sparse.totalBlocks * block, expandedSize);
    final image = expand(superFile);
    expect(image.length, expandedSize);
    final system = layout.extents
        .firstWhere((e) => e.name == 'system_a')
        .offset
        .toInt();
    expect(image.sublist(system, system + block), List.filled(block, 0x11));
  });

  test('requires system, vendor and product', () async {
    await writeFile(workspace, 'result/Super/vendor.img', rawImage(7));
    await writeFile(workspace, 'result/Super/product.img', rawImage(13));
    await expectLater(
      packageFlasher(
        workspace,
        'result',
        destination: 'out/package',
        zip: false,
        superSize: superSize,
      ),
      throwsA(
        isA<BuildException>().having(
          (error) => error.message,
          'message',
          'Required partition missing: system.img',
        ),
      ),
    );
  });

  test('rejects a super partition too small for its groups', () async {
    await writeFile(workspace, 'result/Super/system.img', rawImage(7));
    await writeFile(workspace, 'result/Super/vendor.img', rawImage(7));
    await writeFile(workspace, 'result/Super/product.img', rawImage(13));
    await expectLater(
      packageFlasher(
        workspace,
        'result',
        destination: 'out/package',
        zip: false,
        superSize: 4 * 1024 * 1024,
      ),
      throwsA(
        isA<BuildException>().having(
          (error) => error.message,
          'message',
          'Invalid physical super partition size.',
        ),
      ),
    );
  });
}
