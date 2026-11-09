import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:flasher_web_core/src/rust/api/zip.dart' show inflateRaw, zipDataOffset;
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
      final header = await source.read(
        entry.localHeaderOffset.toInt(),
        30,
      );
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

void main() {
  setUpAll(() async {
    expect(await loadNative(), isTrue);
  });

  test(
    'the exported ZIP equals the ZIP the normal build packages, entry for '
    'entry',
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

      // The normal build path: stage the template, Platform-Tools and images,
      // then package the same tree a folder build would contain.
      final output = await Directory('${fixture.root.path}/output').create();
      final built = await _build(fixture, output);
      final job = built['job']! as String;
      final artifact = built['artifact']! as String;
      expect(built['format'], 'zip');
      final outputWorkspace = IoWorkspace(output);
      final reference = await zipEntriesOf(outputWorkspace, '$job/$artifact');
      expect(reference, isNotEmpty);

      final package = await fixture.open(fixtureSelection);
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
        await package.close();
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
      expect(result['entries'], reference.length);
      expect(
        events.where((event) => event['type'] == 'progress'),
        isEmpty,
        reason: 'every fixture entry is far below the 64 MiB report step',
      );

      // Same names, modes and bytes as the packaged build, including the
      // CRLF-normalized scripts and the Platform-Tools override.
      expect(exported.keys.toList()..sort(), reference.keys.toList()..sort());
      for (final entry in reference.entries) {
        expect(exported[entry.key], isNotNull, reason: entry.key);
        expect(
          exported[entry.key]!.mode,
          entry.value.mode,
          reason: '${entry.key} mode',
        );
        expect(
          exported[entry.key]!.bytes,
          entry.value.bytes,
          reason: '${entry.key} bytes',
        );
      }

      // The tree itself is unchanged; the template subtree, not the whole
      // device package, is what the build stages.
      expect(exported, contains('OOS_FILES_HERE/boot.img'));
      expect(exported, contains('Platform-Tools/fastboot.txt'));
      expect(exported, contains('updater-script'));
      expect(exported, contains('META-INF/com/google/android/update-binary'));
      expect(exported, isNot(contains('oos/super/updater-script')));
      expect(exported, isNot(contains('build.json')));
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
      expect(
        exported['OOS_FILES_HERE/boot.img']!.mode,
        0x81a4,
        reason: 'images are never probed for an ELF header',
      );

      // No temporary files: the export writes only the destination.
      expect(await exportWorkspace.list('', recursive: true), ['virtual.zip']);
    },
  );
}

Future<Map<String, Object?>> _build(
  VirtualFixture fixture,
  Directory output,
) async {
  final events = await buildFlasher({
    'selection': {
      'device': 'Oneplus 13',
      'kind': 'RegionalHybrid Flasher',
      'region': 'GLO',
    },
    'ota': {'kind': 'file', 'file': '${fixture.root.path}/ota/ota.zip'},
    'zip': true,
    'bloat': {'kind': 'path', 'path': '${fixture.root.path}/bloat'},
    'output': {'kind': 'path', 'path': output.path},
    'apiBase': '',
    'upstreamBase': fixture.upstreamPath,
  }).toList();
  return events.lastWhere((event) => event['type'] == 'result');
}
