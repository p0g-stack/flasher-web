import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:flasher_web_core/src/rust/api/zip.dart'
    show inflateRaw, zipDataOffset;
import 'package:test/test.dart';

import 'ota_fixture.dart' show fixtureBlock, pattern;
import 'virtual_fixture.dart';

const Selection fixtureSelection = Selection(
  dev: '13',
  kind: 'RegionalHybrid Flasher',
  region: 'GLO',
  device: 'Oneplus 13',
  builder: 'BUILD_REGIONAL.sh',
);

const List<String> fixtureBoot = [
  'boot',
  'dtbo',
  'init_boot',
  'modem',
  'recovery',
  'vbmeta',
  'vbmeta_system',
  'vbmeta_vendor',
  'vendor_boot',
];

const List<String> fixtureLogicalFromOta = [
  'my_bigball',
  'my_carrier',
  'my_engineering',
  'my_heytap',
  'my_manifest',
  'my_product',
  'my_region',
  'my_stock',
  'odm',
  'product',
  'system',
  'system_dlkm',
  'system_ext',
  'vendor',
  'vendor_dlkm',
];

/// Every entry of a ZIP with its bytes and Unix mode.
Future<Map<String, ({Uint8List bytes, int mode})>> zipEntriesOf(
  Workspace workspace,
  String path,
) async {
  final source = await workspace.open(path);
  try {
    final entries = await parseZipEntries(source);
    final result = <String, ({Uint8List bytes, int mode})>{};
    for (final entry in entries.values) {
      final header = await source.read(entry.localHeaderOffset.toInt(), 30);
      final dataOffset = zipDataOffset(
        localHeader30Bytes: header,
        localHeaderOffset: entry.localHeaderOffset,
      ).toInt();
      final compressed = await source.read(
        dataOffset,
        entry.compressedSize.toInt(),
      );
      final size = entry.uncompressedSize.toInt();
      final bytes = switch (entry.method) {
        0 => compressed,
        8 => inflateRaw(data: compressed, expectedLen: BigInt.from(size)),
        _ => throw StateError('unexpected method ${entry.method}'),
      };
      expect(bytes.length, size, reason: entry.name);
      result[entry.name] = (bytes: bytes, mode: entry.unixMode);
    }
    return result;
  } finally {
    await closeByteSource(source);
  }
}

/// Every byte [package] serves for [path].
Future<Uint8List> packageBytes(FlashPackage package, String path) async {
  final source = await package.open(path);
  try {
    final builder = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < source.length) {
      final chunk = await source.read(
        offset,
        math.min(1 << 20, source.length - offset),
      );
      builder.add(chunk);
      offset += chunk.length;
    }
    return builder.takeBytes();
  } finally {
    await source.close();
  }
}

void main() {
  setUpAll(() async {
    expect(await loadNative(), isTrue);
  });

  test(
    'the exported ZIP carries the template, Platform-Tools and every package '
    'image, entry for entry',
    () async {
      final fixture = await VirtualFixture.create(
        partitions: [...fixtureBoot, ...fixtureLogicalFromOta],
        bloatFiles: {
          'bloat/13/GLO_BLOAT/my_company.img': pattern(fixtureBlock, seed: 71),
          'bloat/13/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 72),
          'bloat/13/GLO_BLOAT/vendor_boot.img': pattern(fixtureBlock, seed: 73),
        },
        templates: {'13': fixtureTemplate13()},
      );
      addTearDown(fixture.dispose);

      final package = await fixture.open(fixtureSelection);
      // The tree the export must assemble: the selected template subtree,
      // Platform-Tools over the template copy, and the package's own entries.
      const prefix = 'oos/regional/';
      final expectedNames = <String>{
        for (final name in fixtureTemplate13().keys)
          if (name.startsWith(prefix)) name.substring(prefix.length),
        for (final name in fixturePlatformTools().keys) 'Platform-Tools/$name',
        ...package.index.entries,
      };

      final exportWorkspace = IoWorkspace(
        await Directory('${fixture.root.path}/export').create(),
      );
      final sink = await exportWorkspace.create('virtual.zip');
      final events = <Map<String, Object?>>[];
      try {
        await for (final event in exportVirtualZip(
          package: package,
          upstream: fixture.upstream,
          sink: sink,
        )) {
          events.add(event);
        }
      } finally {
        await sink.close();
      }

      final result = events.last;
      expect(result['type'], 'result');
      final exported = await zipEntriesOf(exportWorkspace, 'virtual.zip');
      final archive = await exportWorkspace.open('virtual.zip');
      final Uint8List archiveBytes;
      try {
        archiveBytes = await archive.read(0, archive.length);
      } finally {
        await closeByteSource(archive);
      }
      expect(result['bytes'], archiveBytes.length);
      expect(result['sha256'], sha256.convert(archiveBytes).toString());
      expect(result['job'], package.job);
      expect(result['entries'], expectedNames.length);
      expect(
        events.where((event) => event['type'] == 'progress'),
        isEmpty,
        reason: 'every fixture entry is far below the 64 MiB report step',
      );

      // Exactly the template subtree, Platform-Tools and the package entries.
      expect(exported.keys.toSet(), expectedNames);
      expect(exported, isNot(contains('oos/regional/notes.txt')));
      expect(exported, isNot(contains('oos/super/updater-script')));
      expect(exported, isNot(contains('build.json')));

      // Every image is the byte range the package serves under that path.
      for (final path in package.index.entries) {
        expect(
          exported[path]!.bytes,
          await packageBytes(package, path),
          reason: '$path equals the package image',
        );
      }

      // The template and Platform-Tools bytes, with line endings normalized.
      expect(
        utf8.decode(exported['updater-script']!.bytes),
        '#!/sbin/sh\nui_print "hello"\n',
        reason: 'updater-script line endings are normalized',
      );
      expect(
        utf8.decode(exported['notes.txt']!.bytes),
        'keep\r\nme\r\n',
        reason: 'only updater-script and *.sh files are normalized',
      );
      expect(
        utf8.decode(exported['Platform-Tools/fastboot.txt']!.bytes),
        'tools\n',
        reason: 'Platform-Tools overwrite the template copy',
      );
      expect(
        exported['Platform-Tools/fastboot']!.mode,
        0x81ed,
        reason: 'an ELF entry is executable',
      );
      for (final entry in fixturePlatformTools().entries) {
        expect(
          exported['Platform-Tools/${entry.key}']!.bytes,
          entry.value,
          reason: entry.key,
        );
      }

      // Images use the mode of a plain file and never probe for an ELF header.
      for (final path in package.index.entries) {
        expect(exported[path]!.mode, 0x81a4, reason: '$path mode');
      }
      expect(exported, contains('OOS_FILES_HERE/boot.img'));

      // No temporary files: the export writes only the destination.
      expect(await exportWorkspace.list('', recursive: true), ['virtual.zip']);

      await package.close();
    },
  );
}
