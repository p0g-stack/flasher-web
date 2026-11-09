/// The synthetic Super OTA and its inputs.
///
/// The fixture is the core test builders, extended with stored XZ and ZSTD
/// payload operations: the payload carries compressed streams while the
/// partition hashes and images decode to the raw bytes.
library;

import 'dart:typed_data';

import 'package:flasher_web_core/flasher_web_core.dart';

import 'package:flasher_web_core/e2e_fixtures.dart';

/// The device, flasher type and region the fixture tables offer.
const Selection e2eSelection = Selection(
  dev: '13',
  kind: 'SuperHybrid Flasher',
  region: 'GLO',
  device: 'Oneplus 13',
  builder: 'BUILD_SUPER.sh',
);

/// The nine boot images every Super template flashes.
const List<String> e2eBootPartitions = [
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

/// Every logical partition the synthetic OTA carries beside them.
const List<String> e2eLogicalPartitions = [
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
  'system_ext',
  'vendor',
  'vendor_dlkm',
];

/// Payload partitions carried as compressed operations.
const Map<String, String> e2eOps = {
  'boot': 'xz',
  'dtbo': 'zstd',
  'system': 'xz',
  'vendor': 'zstd',
  'product': 'xz',
};

/// The verified bloat store the Super layout consumes.
Map<String, Uint8List> e2eBloat() => {
  'bloat/13/GLO_BLOAT/my_company.img': pattern(fixtureBlock, seed: 71),
  'bloat/13/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 72),
  'bloat/13/COS_FILES_HERE/my_region.img': pattern(fixtureBlock, seed: 73),
  'bloat/13/COS_FILES_HERE/oplusstanvbk.img': pattern(fixtureBlock, seed: 74),
};

/// The `oos` template the super package stages.
Map<String, Uint8List> e2eTemplate() => {
  'oos/super/updater-script': Uint8List.fromList(
    '#!/sbin/sh\r\nui_print "super"\r\n'.codeUnits,
  ),
  'oos/super/flash.sh': Uint8List.fromList(
    '#!/bin/sh\r\nfastboot flash super super.img\r\n'.codeUnits,
  ),
  'oos/super/notes.txt': Uint8List.fromList('keep\r\nme\r\n'.codeUnits),
  'oos/regional/updater-script': Uint8List.fromList(
    '#!/sbin/sh\n'.codeUnits,
  ),
};

/// A saved fixture set with the paths the harness serves.
final class E2eFixture {
  E2eFixture(this.virtual);

  final VirtualFixture virtual;

  /// The OTA ZIP on disk.
  String get otaPath => '${virtual.otaWorkspace.root.path}/ota.zip';

  /// The bloat store directory (`<device>/...`).
  String get bloatDir => virtual.bloatWorkspace.root.path;

  /// The upstream snapshot directory.
  String get upstreamDir => virtual.upstreamPath;

  int get superSize => virtual.superSize('13', 'GLO');

  Future<void> dispose() => virtual.dispose();

  static Future<E2eFixture> create() async {
    if (!await loadNative()) {
      throw StateError('The Rust OTA decoder is not available.');
    }
    final fixture = await VirtualFixture.create(
      partitions: [...e2eBootPartitions, ...e2eLogicalPartitions],
      bloatFiles: e2eBloat(),
      templates: {'13': e2eTemplate()},
      builders: const [
        ('SuperHybrid Flasher', '13', 'GLO', 'BUILD_SUPER.sh'),
      ],
      otaOps: e2eOps,
    );
    return E2eFixture(fixture);
  }
}

/// The bloat manifest paths served from [E2eFixture.bloatDir] and written
/// into the page's OPFS store.
List<String> bloatManifestPaths(E2eFixture fixture) => [
  for (final path in fixture.virtual.bloatFiles.keys)
    path.substring('bloat/'.length),
];

/// Whole bytes of one package entry.
Future<Uint8List> packageBytes(FlashPackage package, String path) async {
  final source = await package.open(path);
  final builder = BytesBuilder(copy: false);
  try {
    var offset = 0;
    while (offset < source.length) {
      final chunk = await source.read(
        offset,
        source.length - offset < 1 << 20 ? source.length - offset : 1 << 20,
      );
      builder.add(chunk);
      offset += chunk.length;
    }
  } finally {
    await source.close();
  }
  return builder.takeBytes();
}
