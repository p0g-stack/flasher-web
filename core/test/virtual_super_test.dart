import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:flasher_web_core/src/flash/virtual_super.dart'
    show flasherSuperLayout;
import 'package:flasher_web_core/src/rust/api/zip.dart'
    show inflateRaw, zipDataOffset;
import 'package:test/test.dart';

import 'ota_fixture.dart' show fixtureBlock, pattern;
import 'virtual_fixture.dart';

/// The nine boot images every template flashes.
const List<String> bootPartitions = [
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

/// Every logical partition a fixture OTA carries beside the boot images.
const List<String> logicalPartitions = [
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

/// A template subtree for `<subtree>/super`, with CRLF files and META-INF.
Map<String, Uint8List> fixtureSuperTemplate(String subtree) => {
  '$subtree/super/updater-script': Uint8List.fromList(
    '#!/sbin/sh\r\nui_print "super"\r\n'.codeUnits,
  ),
  '$subtree/super/META-INF/com/google/android/update-binary':
      Uint8List.fromList([
        0x7f,
        0x45,
        0x4c,
        0x46,
        2,
        1,
        1,
        0,
        ...List<int>.filled(24, 0),
      ]),
  '$subtree/super/flash.sh': Uint8List.fromList(
    '#!/bin/sh\r\nfastboot flash super super.img\r\n'.codeUnits,
  ),
  '$subtree/super/notes.txt': Uint8List.fromList('keep\r\nme\r\n'.codeUnits),
  '$subtree/super/Platform-Tools/fastboot.txt': Uint8List.fromList(
    'template\n'.codeUnits,
  ),
  '$subtree/regional/updater-script': Uint8List.fromList(
    '#!/sbin/sh\n'.codeUnits,
  ),
};

Future<Uint8List> bytesOf(FlashPackage package, String path) async {
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

Future<Uint8List> readAll(ByteSource source) async {
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
}

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

/// Streams the virtual package into `virtual.zip` under [fixture] and returns
/// its entries.
Future<Map<String, ({Uint8List bytes, int mode})>> exportEntries(
  VirtualFixture fixture,
  VirtualFlashPackage package, {
  String label = '',
}) async {
  final workspace = IoWorkspace(
    await Directory('${fixture.root.path}/export$label').create(),
  );
  final sink = await workspace.create('virtual.zip');
  try {
    await for (final _ in exportVirtualZip(
      package: package,
      upstream: fixture.upstream,
      sink: sink,
    )) {}
  } finally {
    await sink.close();
  }
  return zipEntriesOf(workspace, 'virtual.zip');
}

/// A loopback stand-in for the edge worker's `/api/catalog` proxy, so the
/// catalog client runs over real HTTP.
final class FakeCatalogServer {
  FakeCatalogServer._(this._server, this._catalog);

  final HttpServer _server;
  final Map<String, dynamic> _catalog;

  /// Request lines the server answered, in order.
  final requests = <String>[];

  static Future<FakeCatalogServer> start({
    required Map<String, dynamic> catalog,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = FakeCatalogServer._(server, catalog);
    server.listen(result._handle);
    return result;
  }

  /// The `apiBase` a build request uses.
  String get apiBase => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    requests.add('${request.method} ${request.uri}');
    try {
      if (request.method == 'GET' && request.uri.path == '/api/catalog') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(_catalog));
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    } on Object {
      response.statusCode = HttpStatus.internalServerError;
      await response.close();
    }
  }
}

/// The blocks an Android sparse image defines, keyed by absolute block index.
///
/// RAW chunks keep their bytes, FILL chunks are expanded to one block of the
/// repeated 32-bit value, and DONT_CARE blocks stay absent, so a sparse image
/// and its parts compare block for block.
({int blockSize, Map<int, Uint8List> blocks}) expandSparse(Uint8List sparse) {
  final data = ByteData.sublistView(sparse);
  expect(data.getUint32(0, Endian.little), 0xed26ff3a);
  final blockSize = data.getUint32(12, Endian.little);
  final totalBlocks = data.getUint32(16, Endian.little);
  final chunks = data.getUint32(20, Endian.little);
  final blocks = <int, Uint8List>{};
  var offset = 28;
  var block = 0;
  for (var index = 0; index < chunks; index++) {
    final kind = data.getUint16(offset, Endian.little);
    final count = data.getUint32(offset + 4, Endian.little);
    final total = data.getUint32(offset + 8, Endian.little);
    final payload = total - 12;
    switch (kind) {
      case 0xcac1: // RAW
        expect(payload, count * blockSize);
        for (var within = 0; within < count; within++) {
          final start = offset + 12 + within * blockSize;
          blocks[block + within] = Uint8List.fromList(
            Uint8List.sublistView(sparse, start, start + blockSize),
          );
        }
      case 0xcac2: // FILL
        expect(payload, 4);
        final value = data.getUint32(offset + 12, Endian.little);
        final fill = Uint8List(blockSize);
        for (var p = 0; p < blockSize; p++) {
          fill[p] = (value >> ((p % 4) * 8)) & 0xff;
        }
        for (var within = 0; within < count; within++) {
          blocks[block + within] = Uint8List.fromList(fill);
        }
      case 0xcac3: // DONT_CARE
        expect(payload, 0);
      default:
        fail('unexpected sparse chunk 0x${kind.toRadixString(16)}');
    }
    block += count;
    offset += total;
  }
  expect(block, totalBlocks);
  expect(offset, sparse.length, reason: 'no trailing bytes');
  return (blockSize: blockSize, blocks: blocks);
}

/// The super's expanded blocks, built from the LP layout and the fixture's
/// input images instead of the package's sparse encoder.
///
/// [manifest] is the package's `image_sha256`: each `Super/<name>.img` entry
/// names the decoded image digest, which identifies its bytes among the
/// fixture's OTA, BASE, donor and bloat images.
Map<int, Uint8List> expectedSuperBlocks(
  VirtualFixture fixture,
  Map<String, String> manifest,
  int superSize,
) {
  final inputs = <String, Uint8List>{};
  for (final entry in manifest.entries) {
    if (!entry.key.startsWith('Super/')) continue;
    final file = entry.key.substring('Super/'.length);
    final name = file.substring(0, file.length - '.img'.length);
    final candidates = <Uint8List>[
      ?fixture.images[name],
      ?fixture.baseImages[name],
      ?fixture.donorImages[name],
      for (final bloat in fixture.bloatFiles.entries)
        if (bloat.key.endsWith('/$file')) bloat.value,
    ];
    final matching = candidates
        .where((bytes) => sha256.convert(bytes).toString() == entry.value)
        .toList();
    expect(matching, isNotEmpty, reason: '${entry.key} names a fixture image');
    inputs[name] = matching.first;
  }
  final layout = flasherSuperLayout({
    for (final entry in inputs.entries) entry.key: entry.value.length,
  }, superSize);
  expect(layout.head.length % sparseBlockBytes, 0);
  final blocks = <int, Uint8List>{};
  for (
    var offset = 0;
    offset < layout.head.length;
    offset += sparseBlockBytes
  ) {
    blocks[offset ~/ sparseBlockBytes] = Uint8List.fromList(
      layout.head.sublist(offset, offset + sparseBlockBytes),
    );
  }
  for (final extent in layout.extents) {
    final name = extent.name.endsWith('_a')
        ? extent.name.substring(0, extent.name.length - 2)
        : extent.name;
    final image = inputs[name];
    if (image == null) continue;
    final start = extent.offset.toInt();
    for (var offset = 0; offset < image.length; offset += sparseBlockBytes) {
      final end = math.min(offset + sparseBlockBytes, image.length);
      blocks[(start + offset) ~/ sparseBlockBytes] = Uint8List(sparseBlockBytes)
        ..setRange(0, end - offset, image, offset);
    }
  }
  return blocks;
}

/// The super image as `read`, `stream` and `cursor` produce it.
Future<void> expectSuperReadModes(
  VirtualFlashPackage package,
  Uint8List expected,
) async {
  expect(
    await bytesOf(package, 'super.img'),
    expected,
    reason: 'super.img read',
  );
  final source = await package.open('super.img');
  try {
    final streamed = BytesBuilder(copy: false);
    await for (final chunk in source.stream(chunkSize: 4096)) {
      expect(chunk.length, lessThanOrEqualTo(4096));
      streamed.add(chunk);
    }
    expect(streamed.takeBytes(), expected, reason: 'super.img stream');
    final cursor = await source.cursor();
    try {
      final built = BytesBuilder(copy: false);
      var offset = 0;
      while (offset < expected.length) {
        final take = math.min(4096, expected.length - offset);
        built.add(await cursor.readExact(take));
        offset += take;
      }
      expect(built.takeBytes(), expected, reason: 'super.img cursor');
    } finally {
      await cursor.close();
    }
  } finally {
    await source.close();
  }
}

/// Opens the virtual package over [fixture] and checks that the export ZIP
/// carries exactly the package's tree, entry for entry, that every image
/// equals the bytes the package serves, and that the advertised digests match
/// those bytes.
Future<void> verifyParity(
  VirtualFixture fixture,
  Selection selection, {
  required int superSize,
  bool withBase = false,
  OtaArchive? donor,
  Map<String, Object?>? donorIdentity,
  bool? vulnerableAbl,
}) async {
  final label = '_${selection.region}';
  final baseArchive = withBase ? await fixture.openOta('base.zip') : null;
  final package = await fixture.open(
    selection,
    superSize: superSize,
    base: baseArchive,
    baseIdentity: withBase ? fixture.identityOf('base.zip') : null,
    donor: donor,
    donorIdentity: donorIdentity,
    vulnerableAbl: vulnerableAbl,
  );
  try {
    // The virtual super digest is lazy: it appears only after a complete
    // stream, so the load-time manifest advertises the super inputs by their
    // decoded-image digests and every other image by its path.
    expect(package.imageHash('super.img'), isNull);
    final manifest = (package.buildJson['image_sha256']! as Map)
        .cast<String, String>();
    final images = {
      for (final path in package.index.entries)
        if (path.endsWith('.img') && path != 'super.img') path,
    };
    expect(images, isNotEmpty);
    expect(
      manifest.keys.where(images.contains).toSet(),
      images,
      reason: 'every package image has a load-time digest',
    );
    expect(
      manifest.keys.where((path) => path.startsWith('Super/')),
      isNotEmpty,
      reason: 'the decoded super inputs are advertised',
    );
    expect(
      package.index.entries.where((path) => path.startsWith('Super/')),
      isEmpty,
      reason: 'the super inputs live inside super.img',
    );
    for (final entry in manifest.entries) {
      if (!images.contains(entry.key)) continue;
      expect(
        sha256.convert(await bytesOf(package, entry.key)).toString(),
        entry.value,
        reason: entry.key,
      );
    }

    final export = await exportEntries(fixture, package, label: label);

    // The exported tree: the selected template subtree, Platform-Tools over
    // the template copy, and the package's own entries.
    const prefix = 'Platform-Tools/';
    // The fixture writes `oos/super/...` (or `cos/super/...`); the selection
    // names which subtree the package stages.
    final template = fixtureSuperTemplate(selection.template.split('/').first);
    final expectedNames = <String>{
      for (final name in template.keys)
        if (name.startsWith('${selection.template}/'))
          name.substring(selection.template.length + 1),
      for (final name in fixturePlatformTools().keys) '$prefix$name',
      ...package.index.entries,
    };
    expect(export.keys.toSet(), expectedNames);

    // Every image is the byte range the package serves under that path.
    for (final path in package.index.entries) {
      expect(
        export[path]!.bytes,
        await bytesOf(package, path),
        reason: '$path equals the package image',
      );
    }

    // The super entry is the package's sparse image, read and streamed alike.
    final superBytes = await bytesOf(package, 'super.img');
    expect(export['super.img']!.bytes, superBytes);
    await expectSuperReadModes(package, superBytes);
    final expanded = expandSparse(superBytes);
    expect(expanded.blockSize, 4096);
    expect(expanded.blocks, isNotEmpty);
    expect(
      superBytes.length,
      lessThan(superSize),
      reason: 'a sparse super is far smaller than its device',
    );
    // The expanded super is the LP layout plus the input images, built here
    // from the fixture, not from the sparse encoder that produced the export.
    expect(
      expanded.blocks,
      expectedSuperBlocks(fixture, manifest, superSize),
      reason: 'the exported sparse super expands to the expected LP bytes',
    );
    // The streamed hash exists only after the complete first pass.
    expect(
      package.imageHash('super.img'),
      sha256.convert(superBytes).toString(),
    );
  } finally {
    await package.close();
    await baseArchive?.close();
    await donor?.close();
  }
}

void main() {
  setUpAll(() async {
    expect(await loadNative(), isTrue);
  });

  test('13 SuperHybrid GLO: export and package agree', () async {
    final fixture = await VirtualFixture.create(
      partitions: [...bootPartitions, ...logicalPartitions],
      bloatFiles: {
        'bloat/13/GLO_BLOAT/my_company.img': pattern(fixtureBlock, seed: 71),
        'bloat/13/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 72),
        'bloat/13/COS_FILES_HERE/my_region.img': pattern(
          fixtureBlock,
          seed: 73,
        ),
        'bloat/13/COS_FILES_HERE/oplusstanvbk.img': pattern(
          fixtureBlock,
          seed: 74,
        ),
      },
      templates: {'13': fixtureSuperTemplate('oos')},
      builders: const [('SuperHybrid Flasher', '13', 'GLO', 'BUILD_SUPER.sh')],
    );
    addTearDown(fixture.dispose);
    await verifyParity(
      fixture,
      const Selection(
        dev: '13',
        kind: 'SuperHybrid Flasher',
        region: 'GLO',
        device: 'Oneplus 13',
        builder: 'BUILD_SUPER.sh',
      ),
      superSize: fixture.superSize('13', 'GLO'),
    );
  });

  test('13 SuperHybrid GLO: measured encoded and expanded super', () async {
    final fixture = await super13Fixture();
    addTearDown(fixture.dispose);
    final superSize = fixture.superSize('13', 'GLO');
    final package = await fixture.open(selection13, superSize: superSize);
    try {
      final encoded = await package.size('super.img');
      final scan = package.superScan!;
      expect(scan.expandedBytes, superSize);
      // The region after the last LP extent is one DONT_CARE chunk: it costs
      // a 12-byte header and sends no data.
      final tail = scan.chunks.last;
      expect(tail.type, sparseDontCare);
      expect(tail.blocks, greaterThan(0));
      printOnFailure(
        'encoded=$encoded expanded=$superSize '
        'tail=${tail.blocks * sparseBlockBytes}',
      );

      final export = await exportEntries(fixture, package, label: '_measure');
      final exported = export['super.img']!.bytes;
      expect(exported.length, encoded);
      final expanded = expandSparse(exported);
      expect(expanded.blocks.length, greaterThan(0));
      final expected = expectedSuperBlocks(
        fixture,
        ((package.buildJson['image_sha256']!) as Map).cast<String, String>(),
        superSize,
      );
      expect(
        expanded.blocks,
        expected,
        reason: 'the exported sparse super equals the independent LP bytes',
      );
      expect(
        encoded,
        lessThan(superSize),
        reason: 'RAW plus DONT_CARE only: the export omits the tail',
      );
      // The tail of the expanded super is the DONT_CARE region after the last
      // LP extent: nothing is sent for it and the last block stays absent.
      expect(
        expanded.blocks.containsKey(superSize ~/ sparseBlockBytes - 1),
        isFalse,
      );
      expect(
        expanded.blocks.keys.reduce(math.max),
        lessThan(superSize ~/ sparseBlockBytes - 1),
      );
    } finally {
      await package.close();
    }
  });

  test('Ace 5 GLO Super: the discarded ODM is in neither output', () async {
    final fixture = await VirtualFixture.create(
      partitions: [...bootPartitions, ...logicalPartitions],
      bloatFiles: {
        'bloat/Ace5/GLO_BLOAT/my_company.img': pattern(fixtureBlock, seed: 81),
        'bloat/Ace5/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 82),
      },
      templates: {'Ace5': fixtureSuperTemplate('oos')},
      builders: const [('Super Flasher', 'Ace5', 'GLO', 'BUILD_SUPER.sh')],
    );
    addTearDown(fixture.dispose);
    const selection = Selection(
      dev: 'Ace5',
      kind: 'Super Flasher',
      region: 'GLO',
      device: 'Oneplus Ace 5',
      builder: 'BUILD_SUPER.sh',
    );
    await verifyParity(
      fixture,
      selection,
      superSize: fixture.superSize('Ace5', 'GLO'),
    );
    final package = await fixture.open(
      selection,
      superSize: fixture.superSize('Ace5', 'GLO'),
    );
    try {
      expect(
        package.index.entries.where((path) => path.endsWith('/odm.img')),
        isEmpty,
        reason: 'the non-CN Ace 5 Super flasher discards the OTA ODM',
      );
      expect(
        await bytesOf(package, 'super.img'),
        isNot(contains(pattern(fixtureBlock, seed: 5))),
        reason: 'the discarded ODM is not in the super',
      );
      final sparse = await bytesOf(package, 'super.img');
      expect(
        sparse.length,
        lessThan(fixture.superSize('Ace5', 'GLO')),
        reason: 'a sparse super is far smaller than its device',
      );
    } finally {
      await package.close();
    }
  });

  test('X9U Super: staged bloat wins and super-size is packaged', () async {
    final fixture = await VirtualFixture.create(
      partitions: [...bootPartitions, ...logicalPartitions],
      bloatFiles: {
        'bloat/X9U/EU_BLOAT/system.img': pattern(fixtureBlock, seed: 91),
        'bloat/X9U/EU_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 92),
      },
      templates: {'X9U': fixtureSuperTemplate('cos')},
      builders: const [('Super Flasher', 'X9U', 'EU', 'BUILD_SUPER.sh')],
    );
    addTearDown(fixture.dispose);
    const selection = Selection(
      dev: 'X9U',
      kind: 'Super Flasher',
      region: 'EU',
      device: 'OPPO Find X9 Ultra',
      builder: 'BUILD_SUPER.sh',
    );
    await verifyParity(
      fixture,
      selection,
      superSize: fixture.superSize('X9U', 'EU'),
      vulnerableAbl: false,
    );
    final package = await fixture.open(
      selection,
      superSize: fixture.superSize('X9U', 'EU'),
      vulnerableAbl: false,
    );
    try {
      // The staged bloat image replaces the OTA copy inside the super.
      expect(
        package.index.has('OTA_FILES_HERE/abl.img'),
        isFalse,
        reason: 'no ABL when the stock ABL is kept',
      );
      expect(package.buildJson['vulnerableAbl'], isFalse);
      expect(package.buildJson.containsKey('abl_source'), isFalse);
      final export = await exportEntries(fixture, package, label: '_X9U');
      expect(
        utf8.decode(export['META-INF/com/google/android/super-size']!.bytes),
        '${fixture.superSize('X9U', 'EU')}\n',
      );
    } finally {
      await package.close();
    }

    // The fixture has no verified 16.0.6 ABL asset, so asking for the
    // vulnerable one must fail closed rather than flash an unverified image.
    await expectLater(
      fixture.open(
        selection,
        superSize: fixture.superSize('X9U', 'EU'),
        vulnerableAbl: true,
      ),
      throwsA(
        isA<FlashException>().having(
          (error) => error.message,
          'message',
          contains('ABL 16.0.6'),
        ),
      ),
    );
    // X9U never inherits a default: the choice is part of the request.
    await expectLater(
      fixture.open(selection, superSize: fixture.superSize('X9U', 'EU')),
      throwsA(
        isA<FlashException>().having(
          (error) => error.message,
          'message',
          contains('Choose vulnerableAbl'),
        ),
      ),
    );
  });

  test(
    'Ace 6 IN conversion: BASE and TARGET with regenerated vbmeta',
    () async {
      final fixture = await VirtualFixture.create(
        partitions: [
          ...bootPartitions,
          'my_bigball',
          'my_carrier',
          'my_engineering',
          'my_heytap',
          'my_manifest',
          'my_product',
          'my_region',
          'my_stock',
          'product',
          'system',
          'system_ext',
          'vendor',
          'vendor_dlkm',
          'odm',
        ],
        basePartitions: [
          ...bootPartitions,
          'odm',
          'system_dlkm',
          'vendor',
          'vendor_dlkm',
          'my_company',
          'my_preload',
        ],
        baseBytes: {
          'vbmeta': fixtureVbmeta(),
          'vbmeta_system': fixtureVbmeta(),
          'vbmeta_vendor': fixtureVbmeta(),
        },
        bloatFiles: {
          'bloat/Ace6/OOS_BLOAT/my_company.img': pattern(
            fixtureBlock,
            seed: 61,
          ),
          'bloat/Ace6/OOS_BLOAT/my_preload.img': pattern(
            fixtureBlock,
            seed: 62,
          ),
        },
        templates: {'Ace6': fixtureSuperTemplate('oos')},
        builders: const [
          ('SuperHybrid Flasher', 'Ace6', 'IN', 'BUILD_ACE6_OOS.sh'),
        ],
      );
      addTearDown(fixture.dispose);
      await verifyParity(
        fixture,
        const Selection(
          dev: 'Ace6',
          kind: 'SuperHybrid Flasher',
          region: 'IN',
          device: 'Oneplus Ace 6',
          builder: 'BUILD_ACE6_OOS.sh',
        ),
        superSize: fixture.superSize('Ace6', 'IN'),
        withBase: true,
      );
    },
  );

  test('Ace 6T Super IN/GLO: the catalog-matched donor ODM', () async {
    final fixture = await VirtualFixture.create(
      partitions: [...bootPartitions, ...logicalPartitions],
      donorPartitions: const ['odm'],
      otaFields: const {'post-security-patch-level': '2026-02-01'},
      donorFields: const {
        'version_name': 'TEST_DONOR_1.0.0',
        'post-security-patch-level': '2026-02-01',
      },
      bloatFiles: {
        for (final folder in const ['IN_BLOAT', 'GLO_BLOAT'])
          for (final (name, seed) in const [
            ('my_company', 41),
            ('my_preload', 42),
          ])
            'bloat/Ace6T/$folder/$name.img': pattern(fixtureBlock, seed: seed),
      },
      templates: {'Ace6T': fixtureSuperTemplate('oos')},
      builders: const [
        ('Super Flasher', 'Ace6T', 'IN', 'BUILD_SUPER.sh'),
        ('Super Flasher', 'Ace6T', 'GLO', 'BUILD_SUPER.sh'),
      ],
    );
    addTearDown(fixture.dispose);
    final server = await FakeCatalogServer.start(
      catalog: {
        'api_version': '1',
        'releases': [
          for (final region in const ['IN', 'GLO'])
            {
              'id': 'target-${region.toLowerCase()}',
              'device': 'OP 15R',
              'region': region,
              'version': 'CPH2745_16.0.1.100(${region}01)',
              'ota_version': 'TEST_1.2.3.4',
              'security_patch': '2026-02-01',
              'model': 'CPH2745',
              'source_url': 'https://example.invalid/target.zip',
            },
          {
            'id': 'donor-cn',
            'device': 'OP ACE 6T',
            'region': 'CN',
            'version': 'PJE110_16.0.1.200(CN01)',
            'ota_version': 'TEST_DONOR_1.0.0',
            'security_patch': '2026-02-01',
            'model': 'PJE110',
            'source_url': 'https://example.invalid/donor.zip',
          },
        ],
      },
    );
    addTearDown(server.close);

    // The catalog decides the donor, exactly as the flash service does.
    final transport = HttpCatalogTransport();
    final catalog = await CatalogClient(
      transport: transport,
      base: Uri.parse('${server.apiBase}/'),
    ).loadCatalog();
    transport.close();
    final target = await fixture.openOta('ota.zip');
    final Map<String, dynamic> targetRelease;
    try {
      targetRelease = releaseFromMetadata(
        catalog,
        'OP 15R',
        'IN',
        target.fields,
      );
    } finally {
      await target.close();
    }
    expect(targetRelease['id'], 'target-in');
    final donorEntry = matchingOdm(catalog, targetRelease);
    expect(donorEntry['id'], 'donor-cn');
    expect(donorEntry['security_patch'], '2026-02-01');
    final donorIdentity = <String, Object?>{
      'kind': 'catalog',
      'entry': donorEntry,
    };

    for (final region in const ['IN', 'GLO']) {
      final donor = await fixture.openOta('donor.zip');
      await verifyParity(
        fixture,
        Selection(
          dev: 'Ace6T',
          kind: 'Super Flasher',
          region: region,
          device: 'Oneplus Ace 6T',
          builder: 'BUILD_SUPER.sh',
        ),
        superSize: fixture.superSize('Ace6T', region),
        donor: donor,
        donorIdentity: donorIdentity,
      );
      // The donor replaces the discarded static ODM inside the super.
      final package = await fixture.open(
        Selection(
          dev: 'Ace6T',
          kind: 'Super Flasher',
          region: region,
          device: 'Oneplus Ace 6T',
          builder: 'BUILD_SUPER.sh',
        ),
        superSize: fixture.superSize('Ace6T', region),
        donor: await fixture.openOta('donor.zip'),
        donorIdentity: donorIdentity,
      );
      try {
        final blocks = expandSparse(await bytesOf(package, 'super.img')).blocks;
        expect(
          blocks.values.any(
            (block) => _same(block, fixture.donorImages['odm']!),
          ),
          isTrue,
          reason: 'the donor odm is inside the super',
        );
        expect(
          blocks.values.any((block) => _same(block, fixture.images['odm']!)),
          isFalse,
          reason: 'the discarded OTA odm is not inside the super',
        );
        expect(
          package.index.entries.where((path) => path.endsWith('/odm.img')),
          isEmpty,
        );
      } finally {
        await package.close();
      }
    }
  });

  test(
    'an unresolved preparation decodes no super and confirms no token',
    () async {
      final fixture = await super13Fixture();
      addTearDown(fixture.dispose);
      final counting = CountingWorkspace(fixture.otaWorkspace);
      final package = await fixture.open(
        selection13,
        ota: counting,
        superSize: fixture.superSize('13', 'GLO'),
      );
      try {
        expect(
          package.cache.peakBytes,
          isZero,
          reason:
              'loading 13 SuperHybrid reads only OTA metadata, never '
              'decoding an operation to probe a super input header',
        );
        expect(package.cache.bytes, isZero);
        final snapshot = await package.snapshot();
        final metadataReads = counting.bytesRead;
        expect(package.imageHash('super.img'), isNull);
        final device = FixtureDevice(product: 'sun');
        final prepared = await prepareFlash(
          package: package,
          selection: selection13,
          // The root prompt has no default: the plan stays unresolved.
          answers: const {'wipe': 'reboot'},
          serial: 'SERIAL-A',
          transport: FixtureTransport(device),
          job: package.job,
        );
        expect(prepared.resolved, isFalse);
        expect(prepared.toMap()['token'], isEmpty);
        expect(
          counting.bytesRead,
          metadataReads,
          reason:
              'an unresolved plan inspects no image, so the super is never '
              'decoded',
        );
        expect(package.imageHash('super.img'), isNull);
        expect(package.cache.peakBytes, isZero);
        expect(package.cache.bytes, isZero);
        expect(device.flashCommands, isEmpty);
        expect(
          device.commands.where((command) => command.startsWith('download:')),
          isEmpty,
        );
        expect(await package.snapshot(), snapshot);
        expect(snapshot['superSize'], fixture.superSize('13', 'GLO'));
        expect(
          snapshot['superLayoutSha256'],
          matches(RegExp(r'^[0-9a-f]{64}$')),
        );
      } finally {
        await package.close();
      }
    },
  );

  test(
    'the super geometry is layout-only and its digest appears after streaming',
    () async {
      final fixture = await super13Fixture();
      addTearDown(fixture.dispose);
      final ota = CountingWorkspace(fixture.otaWorkspace);
      final bloat = CountingWorkspace(fixture.bloatWorkspace);
      final package = await fixture.open(
        selection13,
        ota: ota,
        bloat: bloat,
        superSize: fixture.superSize('13', 'GLO'),
      );
      try {
        final snapshot = await package.snapshot();
        expect(package.imageHash('super.img'), isNull);

        ota.reset();
        bloat.reset();
        final length = await package.size('super.img');
        expect(length, greaterThan(sparseHeaderBytes));
        expect(
          ota.reads + bloat.reads,
          0,
          reason: 'the sparse geometry derives from the LP extents alone',
        );
        expect(ota.bytesRead + bloat.bytesRead, 0);
        expect(
          package.imageHash('super.img'),
          isNull,
          reason: 'no data has been streamed, so there is no digest yet',
        );

        final scan = package.superScan!;
        expect(scan.expandedBytes, fixture.superSize('13', 'GLO'));
        expect(
          scan.digest,
          isEmpty,
          reason: 'a layout-only sparse image has no digest until streamed',
        );

        ota.reset();
        bloat.reset();
        final builder = BytesBuilder(copy: false);
        final source = await package.open('super.img');
        try {
          await for (final chunk in source.stream(chunkSize: 4096)) {
            builder.add(chunk);
          }
        } finally {
          await source.close();
        }
        final streamed = builder.takeBytes();
        expect(streamed, hasLength(length));
        expect(
          ota.reads + bloat.reads,
          greaterThan(0),
          reason: 'the one pass reads the super inputs',
        );
        final digest = package.imageHash('super.img');
        expect(digest, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(digest, sha256.convert(streamed).toString());
        expect(
          await bytesOf(package, 'super.img'),
          streamed,
          reason: 'read and stream agree',
        );
        expect(package.imageHash('super.img'), digest);
        expect(await package.snapshot(), snapshot);
      } finally {
        await package.close();
      }
    },
  );

  test(
    '13 SuperHybrid flash: delivered parts expand to the folder super',
    () async {
      final fixture = await super13Fixture();
      addTearDown(fixture.dispose);
      await expectSuperFlash(
        fixture,
        selection13,
        answers: const {'root': 'flash-signal', 'wipe': 'reboot'},
        product: 'sun',
        superSize: fixture.superSize('13', 'GLO'),
      );
    },
  );

  test(
    'Ace 6 conversion flash: BASE and TARGET images inside one super',
    () async {
      final fixture = await ace6Fixture();
      addTearDown(fixture.dispose);
      await expectSuperFlash(
        fixture,
        selectionAce6,
        answers: const {'wipe': 'reboot'},
        product: 'canoe',
        superSize: fixture.superSize('Ace6', 'IN'),
        withBase: true,
      );
    },
  );

  test(
    'a sparse bloat input that changes after preparation fails in the download',
    () async {
      final fixture = await super13Fixture(
        bloatFiles: {
          ...bloat13(),
          'bloat/13/GLO_BLOAT/my_company.img': sparseFillImage(
            totalBlocks: 1,
            value: 0x22222222,
          ),
        },
      );
      addTearDown(fixture.dispose);
      final package = await fixture.open(
        selection13,
        superSize: fixture.superSize('13', 'GLO'),
      );
      final device = FixtureDevice(
        product: 'sun',
        maxDownloadSize: '0x10000000',
      );
      try {
        final prepared = await prepareFlash(
          package: package,
          selection: selection13,
          answers: const {'root': 'flash-signal', 'wipe': 'reboot'},
          serial: 'SERIAL-A',
          transport: FixtureTransport(device),
          job: package.job,
        );
        expect(prepared.resolved, isTrue);

        // The verified sparse file is rewritten with the same geometry but a
        // different fill value after the package recorded its digest.
        final sink = await fixture.bloatWorkspace.create(
          '13/GLO_BLOAT/my_company.img',
        );
        await sink.write(sparseFillImage(totalBlocks: 1, value: 0x33333333), 0);
        await sink.close();
        device.commands.clear();

        final receipt = await executePreparedFlash(
          prepared,
          FixtureTransport(device),
          emit: (_) {},
        );
        expect(receipt['status'], 'failed', reason: '${receipt['failure']}');
        expect(receipt['uncertain'], isFalse);
        expect(
          (receipt['failure'] as Map)['message'],
          contains('Sparse super input changed while streaming'),
        );
        expect(device.flashCommands, isNot(contains('super')));
        final writes = (receipt['writes'] as List).cast<Map>();
        expect(writes.last['partition'], 'super');
        expect(writes.last['status'], 'failed');
      } finally {
        await package.close();
      }
    },
  );

  test('a super input that no longer matches its manifest SHA-256 fails the download', () async {
    final fixture = await super13Fixture();
    addTearDown(fixture.dispose);
    final package = await fixture.open(
      selection13,
      superSize: fixture.superSize('13', 'GLO'),
    );
    final device = FixtureDevice(product: 'sun', maxDownloadSize: '0x10000000');
    try {
      final prepared = await prepareFlash(
        package: package,
        selection: selection13,
        answers: const {'root': 'flash-signal', 'wipe': 'reboot'},
        serial: 'SERIAL-A',
        transport: FixtureTransport(device),
        job: package.job,
      );
      expect(prepared.resolved, isTrue);
      expect(
        prepared.images['super.img']!.digest,
        isEmpty,
        reason: 'the super digest only exists after a complete stream',
      );

      // Same length, different content: the manifest digest must catch it
      // while the super streams, before the super write is acknowledged.
      final sink = await fixture.bloatWorkspace.create(
        '13/GLO_BLOAT/my_company.img',
      );
      await sink.write(pattern(fixtureBlock, seed: 555), 0);
      await sink.close();
      device.commands.clear();

      final receipt = await executePreparedFlash(
        prepared,
        FixtureTransport(device),
        emit: (_) {},
      );
      expect(receipt['status'], 'failed', reason: '${receipt['failure']}');
      expect(receipt['uncertain'], isFalse);
      expect(
        (receipt['failure'] as Map)['message'],
        contains('my_company.img does not match its manifest SHA-256'),
      );
      expect(device.flashCommands, isNot(contains('super')));
      final writes = (receipt['writes'] as List).cast<Map>();
      expect(writes.last['partition'], 'super');
      expect(writes.last['status'], 'failed');
      expect(
        (receipt['image_sha256'] as Map).containsKey('super.img'),
        isFalse,
        reason: 'a stream that failed has no completed digest',
      );
    } finally {
      await package.close();
    }
  });

  test(
    'changed target, base, donor or bloat identity refuses a confirmed super',
    () async {
      final fixture = await ace6Fixture(donor: true);
      addTearDown(fixture.dispose);
      final base = await fixture.openOta('base.zip');
      final package = await fixture.open(
        selectionAce6,
        superSize: fixture.superSize('Ace6', 'IN'),
        base: base,
        baseIdentity: fixture.identityOf('base.zip'),
      );
      try {
        final prepared = await prepareFlash(
          package: package,
          selection: selectionAce6,
          answers: const {'wipe': 'reboot'},
          serial: 'SERIAL-A',
          transport: FixtureTransport(FixtureDevice(product: 'canoe')),
          job: package.job,
        );
        expect(prepared.resolved, isTrue);

        // Reopens the same selection and refuses the prepared ticket, which
        // is what the service does before its first device write.
        Future<void> changed(
          Future<VirtualFlashPackage> Function() open,
        ) async {
          final reopened = await open();
          try {
            await expectLater(
              verifyPreparedImages(prepared, package: reopened),
              throwsA(
                isA<FlashException>().having(
                  (error) => error.message,
                  'message',
                  contains('virtual OTA or bloat identity changed'),
                ),
              ),
            );
          } finally {
            await reopened.close();
          }
        }

        Future<void> refused(
          Future<VirtualFlashPackage> Function() open,
          String message,
        ) async {
          await expectLater(
            open(),
            throwsA(
              isA<FlashException>().having(
                (error) => error.message,
                'message',
                contains(message),
              ),
            ),
          );
        }

        // A changed TARGET identity.
        await changed(
          () async => fixture.open(
            selectionAce6,
            superSize: fixture.superSize('Ace6', 'IN'),
            base: await fixture.openOta('base.zip'),
            baseIdentity: fixture.identityOf('base.zip'),
            sourceIdentity: {...fixture.identity, 'lastModified': 1},
          ),
        );

        // A changed BASE identity.
        await changed(
          () async => fixture.open(
            selectionAce6,
            superSize: fixture.superSize('Ace6', 'IN'),
            base: await fixture.openOta('base.zip'),
            baseIdentity: {'kind': 'file', 'name': 'base.zip', 'size': 0},
          ),
        );

        // A changed bloat file is refused by the manifest hash.
        final sink = await fixture.bloatWorkspace.create(
          'Ace6/OOS_BLOAT/my_company.img',
        );
        await sink.write(pattern(fixtureBlock, seed: 555), 0);
        await sink.close();
        await refused(
          () async => fixture.open(
            selectionAce6,
            superSize: fixture.superSize('Ace6', 'IN'),
            base: await fixture.openOta('base.zip'),
            baseIdentity: fixture.identityOf('base.zip'),
          ),
          'SHA-256 mismatch',
        );

        // A changed DONOR identity.
        final donor = await fixture.openOta('donor.zip');
        final donorPackage = await fixture.open(
          selectionAce6T,
          superSize: fixture.superSize('Ace6T', 'IN'),
          donor: donor,
          donorIdentity: {
            'kind': 'catalog',
            'entry': {'id': 'donor-cn', 'device': 'OP ACE 6T', 'region': 'CN'},
          },
        );
        try {
          final donorPrepared = await prepareFlash(
            package: donorPackage,
            selection: selectionAce6T,
            answers: const {'wipe': 'reboot'},
            serial: 'SERIAL-A',
            transport: FixtureTransport(FixtureDevice(product: 'canoe')),
            job: donorPackage.job,
          );
          expect(donorPrepared.resolved, isTrue);
          final reopened = await fixture.open(
            selectionAce6T,
            superSize: fixture.superSize('Ace6T', 'IN'),
            donor: await fixture.openOta('donor.zip'),
            donorIdentity: {
              'kind': 'catalog',
              'entry': {
                'id': 'other-donor',
                'device': 'OP ACE 6T',
                'region': 'CN',
              },
            },
          );
          try {
            await expectLater(
              verifyPreparedImages(donorPrepared, package: reopened),
              throwsA(
                isA<FlashException>().having(
                  (error) => error.message,
                  'message',
                  contains('virtual OTA or bloat identity changed'),
                ),
              ),
            );
          } finally {
            await reopened.close();
          }
        } finally {
          await donorPackage.close();
        }
      } finally {
        await package.close();
      }
    },
  );

  test('a sparse super input above the chunk limit fails closed', () async {
    final fixture = await super13Fixture(
      bloatFiles: {
        'bloat/13/GLO_BLOAT/my_company.img': sparseHeaderOnly(
          totalBlocks: 1,
          totalChunks: 262145,
        ),
        'bloat/13/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 72),
      },
    );
    addTearDown(fixture.dispose);
    await expectLater(
      fixture.open(selection13, superSize: fixture.superSize('13', 'GLO')),
      throwsA(
        isA<FlashException>().having(
          (error) => error.message,
          'message',
          contains('262144-chunk index limit'),
        ),
      ),
    );
  });

  test(
    'a 32 GiB super input is a layout-only sparse image with a bounded split',
    () async {
      const blocks = 8388608; // 32 GiB in one FILL chunk.
      const superBytes = 40 << 30;
      final fixture = await super13Fixture(
        regionSizes: const {'13': (superBytes, superBytes)},
        bloatFiles: {
          'bloat/13/GLO_BLOAT/my_company.img': sparseFillImage(
            totalBlocks: blocks,
            value: 0,
          ),
          'bloat/13/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 72),
        },
      );
      addTearDown(fixture.dispose);
      final package = await fixture.open(
        selection13,
        superSize: fixture.superSize('13', 'GLO'),
      );
      try {
        final scan = package.superScan!;
        expect(scan.expandedBytes, superBytes);
        expect(
          scan.chunks.length,
          lessThan(64),
          reason: 'the index is one entry per LP extent, not per data block',
        );
        final length = await package.size('super.img');
        expect(length, greaterThan(32 << 30));
        expect(
          length,
          lessThan(superBytes),
          reason: 'only populated extents are RAW chunks',
        );
        final parts = splitSparseScan(scan, 1 << 30);
        expect(parts.length, lessThanOrEqualTo(64));
        expect(parts.every((part) => part.length <= 1 << 30), isTrue);
        expect(
          parts.every((part) => part.totalBlocks == scan.totalBlocks),
          isTrue,
          reason: 'every part repeats the full block geometry',
        );
        final rawBlocks = scan.chunks
            .where((chunk) => chunk.type == sparseRaw)
            .fold<int>(0, (sum, chunk) => sum + chunk.blocks);
        final sentBlocks = parts.fold<int>(
          0,
          (sum, part) =>
              sum +
              part.pieces
                  .where((piece) => piece.type == sparseRaw)
                  .fold<int>(0, (inner, piece) => inner + piece.blocks),
        );
        expect(sentBlocks, rawBlocks, reason: 'each data block is sent once');
      } finally {
        await package.close();
      }
    },
  );

  test('a super larger than the cache stays within the 64 MiB limit', () async {
    final fixture = await super13Fixture(
      otaBlocks: const {'system': 8448, 'vendor': 8448, 'product': 8448},
    );
    addTearDown(fixture.dispose);
    final package = await fixture.open(
      selection13,
      superSize: fixture.superSize('13', 'GLO'),
    );
    try {
      final length = await package.size('super.img');
      expect(length, greaterThan(64 << 20));
      expect(
        package.cache.peakBytes,
        isZero,
        reason: 'the layout-only geometry decodes no OTA operation',
      );
      expect(package.imageHash('super.img'), isNull);

      final source = await package.open('super.img');
      try {
        await for (final _ in source.stream()) {}
      } finally {
        await source.close();
      }
      expect(
        package.cache.peakBytes,
        greaterThan(0),
        reason: 'the one streaming pass decodes the OTA operations',
      );
      expect(package.cache.peakBytes, lessThanOrEqualTo(64 << 20));
      expect(package.cache.bytes, lessThanOrEqualTo(64 << 20));
      expect(
        package.imageHash('super.img'),
        matches(RegExp(r'^[0-9a-f]{64}$')),
      );
    } finally {
      await package.close();
    }
  });

  test('a second virtual preparation evicts the first ticket', () async {
    final fixture = await super13Fixture();
    addTearDown(fixture.dispose);
    final first = File('${fixture.root.path}/ota/ota.zip');
    final second = File('${fixture.root.path}/ota/ota-2.zip');
    await second.writeAsBytes(await first.readAsBytes());

    final device = FixtureDevice(product: 'sun');
    final transport = FixtureTransport(device);
    final service = FlasherService(transportFactory: () => transport);
    Map<String, Object?> request(String file) => {
      'selection': {
        'device': 'Oneplus 13',
        'kind': 'SuperHybrid Flasher',
        'region': 'GLO',
      },
      'serial': device.serial,
      'answers': {'root': 'flash-signal', 'wipe': 'reboot'},
      'upstreamBase': fixture.upstreamPath,
      'virtual': {
        'ota': {'kind': 'file', 'file': file},
        'bloat': {'kind': 'path', 'path': '${fixture.root.path}/bloat'},
      },
    };

    final a = await service.prepareFlash(request(first.path));
    expect(a['resolved'], isTrue, reason: '${a['error']}');
    final b = await service.prepareFlash(request(second.path));
    expect(b['resolved'], isTrue, reason: '${b['error']}');
    expect(b['job'], isNot(a['job']));

    device.commands.clear();
    final opened = transport.opened.length;
    final events = <Map<String, Object?>>[];
    await expectLater(
      () async {
        await for (final event in service.flash({
          ...request(first.path),
          'job': a['job'],
          'confirmationToken': a['token'],
        })) {
          events.add(event);
        }
      }(),
      throwsA(
        isA<FlashException>().having(
          (error) => error.message,
          'message',
          contains('expired or used'),
        ),
      ),
    );
    expect(events, isEmpty);
    expect(device.commands, isEmpty, reason: 'no device command is sent');
    expect(transport.opened.length, opened, reason: 'no device is opened');
  });

  test('a changed bloat store refuses the confirmed virtual flash', () async {
    final fixture = await super13Fixture();
    addTearDown(fixture.dispose);
    final other = await Directory('${fixture.root.path}/other').create();
    final device = FixtureDevice(product: 'sun');
    final service = FlasherService(
      transportFactory: () => FixtureTransport(device),
    );
    Map<String, Object?> request(String bloat) => {
      'selection': {
        'device': 'Oneplus 13',
        'kind': 'SuperHybrid Flasher',
        'region': 'GLO',
      },
      'serial': device.serial,
      'answers': {'root': 'flash-signal', 'wipe': 'reboot'},
      'upstreamBase': fixture.upstreamPath,
      'virtual': {
        'ota': {'kind': 'file', 'file': '${fixture.root.path}/ota/ota.zip'},
        'bloat': {'kind': 'path', 'path': bloat},
      },
    };
    final prepared = await service.prepareFlash(
      request('${fixture.root.path}/bloat'),
    );
    expect(prepared['resolved'], isTrue, reason: '${prepared['error']}');
    device.commands.clear();
    await expectLater(
      () async {
        await for (final _ in service.flash({
          ...request(other.path),
          'job': prepared['job'],
          'confirmationToken': prepared['token'],
        })) {}
      }(),
      throwsA(
        isA<FlashException>().having(
          (error) => error.message,
          'message',
          contains('no longer matches the confirmed plan'),
        ),
      ),
    );
    expect(device.commands, isEmpty);
  });

  test(
    'the service retries only the failed step and returns its receipt',
    () async {
      final fixture = await super13Fixture();
      addTearDown(fixture.dispose);
      final device = FixtureDevice(product: 'sun');
      final transport = FixtureTransport(device);
      final service = FlasherService(transportFactory: () => transport);
      Map<String, Object?> request() => {
        'selection': {
          'device': 'Oneplus 13',
          'kind': 'SuperHybrid Flasher',
          'region': 'GLO',
        },
        'serial': device.serial,
        'answers': {'root': 'flash-signal', 'wipe': 'reboot'},
        'upstreamBase': fixture.upstreamPath,
        'virtual': {
          'ota': {'kind': 'file', 'file': '${fixture.root.path}/ota/ota.zip'},
          'bloat': {'kind': 'path', 'path': '${fixture.root.path}/bloat'},
        },
      };

      final prepared = await service.prepareFlash(request());
      expect(prepared['resolved'], isTrue, reason: '${prepared['error']}');
      final total = (prepared['executionSteps'] as List).length;

      // The direct-flash signal image fails after the super was streamed.
      device.failFlash = 'my_region_a';
      final events = <Map<String, Object?>>[];
      await for (final event in service.flash({
        ...request(),
        'job': prepared['job'],
        'confirmationToken': prepared['token'],
      })) {
        events.add(event);
      }
      expect(events.first['type'], 'run');
      final runId = events.first['runId'] as String;
      final failure = events.singleWhere((event) => event['type'] == 'failure');
      expect(failure['status'], 'failed');
      final result = events.last;
      expect(result['type'], 'result');
      expect(result['runId'], runId);
      expect(result['status'], 'failed');
      expect(result['canRetry'], isTrue);
      final receipt = result['receipt'] as Map;
      expect(receipt['status'], 'failed');
      expect(receipt['stepIndex'], failure['stepIndex']);
      expect(receipt['reason'], failure['reason']);
      expect(
        (receipt['image_sha256'] as Map)['super.img'],
        matches(RegExp(r'^[0-9a-f]{64}$')),
        reason: 'the super streamed before the failed step',
      );
      final firstAttempt = [...device.flashCommands];
      expect(firstAttempt, contains('super'));
      expect(
        () => service.retryRead({'runId': runId}),
        throwsA(isA<FlashException>()),
      );
      expect(
        () => service.rewriteStep({'runId': runId, 'confirmedSerial': 'other'}),
        throwsA(isA<FlashException>()),
      );

      // Nothing is resent until the user asks; the retry starts at the
      // failed step and keeps the earlier steps.
      device.failFlash = null;
      final retried = <Map<String, Object?>>[];
      await for (final event in service.rewriteStep({
        'runId': runId,
        'confirmedSerial': device.serial,
      })) {
        retried.add(event);
      }
      expect(retried.first['type'], 'run');
      expect(retried.first['runId'], runId);
      expect(
        retried.last['status'],
        'succeeded',
        reason: '${(retried.last['receipt'] as Map)['failure']}',
      );
      expect(retried.last['canRetry'], isFalse);
      final again = device.flashCommands.sublist(firstAttempt.length);
      expect(again.first, 'my_region_a', reason: 'the retried step is resent');
      expect(again, isNot(contains('super')));
      expect(
        again.skip(1).toSet().intersection(firstAttempt.toSet()),
        isEmpty,
        reason: 'no earlier step is replayed',
      );
      final finalReceipt = retried.last['receipt'] as Map;
      expect(finalReceipt['stepIndex'], isNull);
      expect(finalReceipt['status'], 'succeeded');
      expect(finalReceipt['steps'] as List, hasLength(total));
      expect(
        finalReceipt['runId'],
        runId,
        reason: 'the retried receipt keeps the run identity',
      );
      expect(
        (finalReceipt['image_sha256'] as Map)['super.img'],
        receipt['image_sha256']!['super.img'],
        reason: 'the super digest survives the retry',
      );
    },
  );

  test('stop returns a stopped receipt and offers no retry', () async {
    final fixture = await super13Fixture();
    addTearDown(fixture.dispose);
    final device = FixtureDevice(product: 'sun');
    final transport = FixtureTransport(device);
    final service = FlasherService(transportFactory: () => transport);
    Map<String, Object?> request() => {
      'selection': {
        'device': 'Oneplus 13',
        'kind': 'SuperHybrid Flasher',
        'region': 'GLO',
      },
      'serial': device.serial,
      'answers': {'root': 'flash-signal', 'wipe': 'reboot'},
      'upstreamBase': fixture.upstreamPath,
      'virtual': {
        'ota': {'kind': 'file', 'file': '${fixture.root.path}/ota/ota.zip'},
        'bloat': {'kind': 'path', 'path': '${fixture.root.path}/bloat'},
      },
    };

    final prepared = await service.prepareFlash(request());
    expect(prepared['resolved'], isTrue, reason: '${prepared['error']}');
    final total = (prepared['executionSteps'] as List).length;
    final events = <Map<String, Object?>>[];
    final done = Completer<void>();
    final subscription = service
        .flash({
          ...request(),
          'job': prepared['job'],
          'confirmationToken': prepared['token'],
        })
        .listen(events.add, onError: done.completeError, onDone: done.complete);
    final runId = prepared['token'] as String;
    final stopped = await service.stopRun({'runId': runId});
    await done.future;
    await subscription.cancel();

    final receipt = stopped['receipt']! as Map;
    expect(receipt['status'], 'stopped');
    expect(receipt['runId'], runId);
    expect(events.first['type'], 'run');
    expect(events.first['runId'], runId);
    expect(events.last['type'], 'result');
    expect(events.last['status'], 'stopped');
    expect(events.last['canRetry'], isFalse, reason: 'stopping is not a pause');
    expect(receipt['steps'] as List, hasLength(lessThan(total)));
    expect(device.flashCommands, isEmpty, reason: 'stop precedes any write');
    await expectLater(
      service.stopRun({'runId': runId}),
      throwsA(
        isA<FlashException>().having(
          (error) => error.message,
          'message',
          contains('Unknown flash run'),
        ),
      ),
    );
  });
}

bool _same(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

const Selection selection13 = Selection(
  dev: '13',
  kind: 'SuperHybrid Flasher',
  region: 'GLO',
  device: 'Oneplus 13',
  builder: 'BUILD_SUPER.sh',
);

const Selection selectionAce6 = Selection(
  dev: 'Ace6',
  kind: 'SuperHybrid Flasher',
  region: 'IN',
  device: 'Oneplus Ace 6',
  builder: 'BUILD_ACE6_OOS.sh',
);

const Selection selectionAce6T = Selection(
  dev: 'Ace6T',
  kind: 'Super Flasher',
  region: 'IN',
  device: 'Oneplus Ace 6T',
  builder: 'BUILD_SUPER.sh',
);

/// The default bloat store of the 13 SuperHybrid fixture.
Map<String, Uint8List> bloat13() => {
  'bloat/13/GLO_BLOAT/my_company.img': pattern(fixtureBlock, seed: 71),
  'bloat/13/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 72),
  'bloat/13/COS_FILES_HERE/my_region.img': pattern(fixtureBlock, seed: 73),
  'bloat/13/COS_FILES_HERE/oplusstanvbk.img': pattern(fixtureBlock, seed: 74),
};

Future<VirtualFixture> super13Fixture({
  Map<String, Uint8List>? bloatFiles,
  Map<String, int> otaBlocks = const {},
  Map<String, (int, int)> regionSizes = const {},
  List<FixtureBuilder>? builders,
}) => VirtualFixture.create(
  partitions: [...bootPartitions, ...logicalPartitions],
  bloatFiles: bloatFiles ?? bloat13(),
  templates: {'13': fixtureSuperTemplate('oos')},
  builders:
      builders ??
      const [('SuperHybrid Flasher', '13', 'GLO', 'BUILD_SUPER.sh')],
  otaBlocks: otaBlocks,
  regionSizes: regionSizes,
);

/// The Ace 6 conversion fixture; [donor] adds the Ace 6T donor OTA too.
Future<VirtualFixture> ace6Fixture({bool donor = false}) =>
    VirtualFixture.create(
      partitions: [
        ...bootPartitions,
        'my_bigball',
        'my_carrier',
        'my_engineering',
        'my_heytap',
        'my_manifest',
        'my_product',
        'my_region',
        'my_stock',
        'product',
        'system',
        'system_ext',
        'vendor',
        'vendor_dlkm',
        'odm',
      ],
      basePartitions: [
        ...bootPartitions,
        'odm',
        'system_dlkm',
        'vendor',
        'vendor_dlkm',
        'my_company',
        'my_preload',
      ],
      baseBytes: {
        'vbmeta': fixtureVbmeta(),
        'vbmeta_system': fixtureVbmeta(),
        'vbmeta_vendor': fixtureVbmeta(),
      },
      donorPartitions: donor ? const ['odm'] : const [],
      donorFields: donor
          ? const {
              'version_name': 'TEST_DONOR_1.0.0',
              'post-security-patch-level': '2026-02-01',
            }
          : const {},
      bloatFiles: {
        'bloat/Ace6/OOS_BLOAT/my_company.img': pattern(fixtureBlock, seed: 61),
        'bloat/Ace6/OOS_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 62),
        if (donor)
          for (final folder in const ['IN_BLOAT', 'GLO_BLOAT'])
            for (final (name, seed) in const [
              ('my_company', 41),
              ('my_preload', 42),
            ])
              'bloat/Ace6T/$folder/$name.img': pattern(
                fixtureBlock,
                seed: seed,
              ),
      },
      templates: {
        'Ace6': fixtureSuperTemplate('oos'),
        if (donor) 'Ace6T': fixtureSuperTemplate('oos'),
      },
      builders: donor
          ? const [
              ('SuperHybrid Flasher', 'Ace6', 'IN', 'BUILD_ACE6_OOS.sh'),
              ('Super Flasher', 'Ace6T', 'IN', 'BUILD_SUPER.sh'),
            ]
          : const [('SuperHybrid Flasher', 'Ace6', 'IN', 'BUILD_ACE6_OOS.sh')],
    );

/// Per-chunk accounting for one sparse image.
///
/// The blocks before the first DONT_CARE chunk are the LP head, which the
/// virtual package generates in memory instead of reading from an input.
({int raw, int fill, int reads, int bytes}) sparseStats(Uint8List sparse) {
  final data = ByteData.sublistView(sparse);
  final blockSize = data.getUint32(12, Endian.little);
  final chunks = data.getUint32(20, Endian.little);
  var offset = sparseHeaderBytes;
  var raw = 0;
  var fill = 0;
  var head = true;
  for (var index = 0; index < chunks; index++) {
    final kind = data.getUint16(offset, Endian.little);
    final blocks = data.getUint32(offset + 4, Endian.little);
    final total = data.getUint32(offset + 8, Endian.little);
    if (kind == sparseDontCare) {
      head = false;
    } else if (!head) {
      if (kind == sparseRaw) raw += blocks;
      if (kind == sparseFill) fill += blocks;
    }
    offset += total;
  }
  return (
    raw: raw,
    fill: fill,
    reads: raw + fill,
    bytes: raw * blockSize + fill * 4,
  );
}

/// Expands every delivered part into one block map.
Map<int, Uint8List> expandParts(List<Uint8List> parts) {
  final blocks = <int, Uint8List>{};
  for (final part in parts) {
    blocks.addAll(expandSparse(part).blocks);
  }
  return blocks;
}

void expectSameBlocks(
  Map<int, Uint8List> actual,
  Map<int, Uint8List> expected,
) {
  expect(actual.keys.toSet(), expected.keys.toSet());
  for (final entry in expected.entries) {
    expect(actual[entry.key], entry.value, reason: 'super block ${entry.key}');
  }
}

int counterReads(CountingWorkspace ota, CountingWorkspace bloat) =>
    ota.reads + bloat.reads;

int counterBytes(CountingWorkspace ota, CountingWorkspace bloat) =>
    ota.bytesRead + bloat.bytesRead;

/// Prepares, reopens and executes a virtual super on a fake transport.
///
/// Proves preparation reads no super data, the single execution pass streams
/// every split position once, the delivered parts expand to the exported
/// super, and the receipt carries the super digest only after that pass.
Future<void> expectSuperFlash(
  VirtualFixture fixture,
  Selection selection, {
  required Map<String, String> answers,
  required String product,
  required int superSize,
  bool withBase = false,
}) async {
  final otaFiles = (await fixture.otaWorkspace.list('', recursive: true))
    ..sort();
  final bloatFiles = (await fixture.bloatWorkspace.list('', recursive: true))
    ..sort();

  final ota = CountingWorkspace(fixture.otaWorkspace);
  final bloat = CountingWorkspace(fixture.bloatWorkspace);
  final package = await fixture.open(
    selection,
    ota: ota,
    bloat: bloat,
    superSize: superSize,
    base: withBase ? await fixture.openOta('base.zip', workspace: ota) : null,
    baseIdentity: withBase ? fixture.identityOf('base.zip') : null,
  );
  try {
    // Preparation derives the super geometry from the LP extents alone: it
    // decodes no OTA operation and reads no bloat image.
    ota.reset();
    bloat.reset();
    final prepared = await prepareFlash(
      package: package,
      selection: selection,
      answers: answers,
      serial: 'SERIAL-A',
      transport: FixtureTransport(FixtureDevice(product: product)),
      job: package.job,
    );
    expect(prepared.resolved, isTrue);
    final manifest = (package.buildJson['image_sha256']! as Map)
        .cast<String, String>();
    final superDigests = {
      for (final entry in manifest.entries)
        if (entry.key.startsWith('Super/')) entry.value,
    };
    expect(superDigests, isNotEmpty);
    expect(
      [
        for (final path in bloat.opened)
          if (superDigests.contains(
            sha256.convert(fixture.bloatFiles['bloat/$path']!).toString(),
          ))
            path,
      ],
      isEmpty,
      reason: 'preparation decodes no super input',
    );
    expect(ota.opened, isEmpty, reason: 'preparation opens no OTA byte source');
    expect(package.imageHash('super.img'), isNull);
    final superInfo = prepared.images['super.img']!;
    expect(superInfo.sparse, isTrue);
    expect(superInfo.parts, greaterThan(1));
    expect(
      superInfo.digest,
      isEmpty,
      reason: 'a layout-only super has no digest before its first stream',
    );

    // The confirmed attempt reopens the same identity and passes the same
    // pre-write check the service runs before its first device command.
    final reopened = await fixture.open(
      selection,
      ota: ota,
      bloat: bloat,
      superSize: superSize,
      base: withBase ? await fixture.openOta('base.zip', workspace: ota) : null,
      baseIdentity: withBase ? fixture.identityOf('base.zip') : null,
    );
    try {
      ota.reset();
      bloat.reset();
      await verifyPreparedImages(prepared, package: reopened);
      expect(
        counterReads(ota, bloat),
        0,
        reason: 'the pre-write check compares sizes, not bytes',
      );

      // One execution pass streams the super once and reads exactly the
      // data it sends.
      ota.reset();
      bloat.reset();
      final device = FixtureDevice(product: product);
      final receipt = await executePreparedFlash(
        prepared.withPackage(reopened),
        FixtureTransport(device),
        emit: (_) {},
      );
      expect(receipt['status'], 'succeeded', reason: '${receipt['failure']}');
      expect(receipt['job'], reopened.job);
      expect(receipt['stepIndex'], isNull);
      expect(
        (receipt['steps'] as List).cast<Map>(),
        hasLength(prepared.plan.executionSteps.length),
      );
      expect(counterReads(ota, bloat), greaterThan(0));
      expect(counterBytes(ota, bloat), greaterThan(0));

      final parts = device.parts['super']!;
      expect(parts.length, greaterThan(1), reason: 'the image is split');
      for (final part in parts) {
        expect(part.length, lessThanOrEqualTo(0x4000));
      }
      expectSameBlocks(
        expandParts(parts),
        expandSparse(await bytesOf(reopened, 'super.img')).blocks,
      );
      final writes = (receipt['writes'] as List)
          .cast<Map<String, Object?>>()
          .where((write) => write['partition'] == 'super')
          .toList();
      expect(writes, hasLength(parts.length));
      expect(
        [for (final write in writes) write['part']],
        [for (var index = 0; index < parts.length; index++) index + 1],
        reason: 'the split positions are sent once, in order',
      );
      for (final write in writes) {
        expect(write['status'], 'ok');
        expect(write['parts'], parts.length);
      }
      expect(
        device.flashCommands.where((name) => name == 'super'),
        hasLength(parts.length),
      );
      // The super digest exists only after the complete stream succeeded.
      final hashes = (receipt['image_sha256']! as Map).cast<String, Object?>();
      expect(
        hashes['super.img'],
        sha256.convert(await bytesOf(reopened, 'super.img')).toString(),
      );
      expect(reopened.imageHash('super.img'), hashes['super.img']);
    } finally {
      await reopened.close();
    }
  } finally {
    await package.close();
    expect(
      await fixture.otaWorkspace.list('', recursive: true),
      otaFiles,
      reason: 'the flash writes nothing into the OTA store',
    );
    expect(
      await fixture.bloatWorkspace.list('', recursive: true),
      bloatFiles,
      reason: 'the flash writes nothing into the bloat store',
    );
  }
}

/// A sparse header with no chunks, for limit tests.
Uint8List sparseHeaderOnly({
  required int totalBlocks,
  required int totalChunks,
}) {
  final bytes = Uint8List(28);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, sparseMagic, Endian.little);
  data.setUint16(4, 1, Endian.little);
  data.setUint16(8, 28, Endian.little);
  data.setUint16(10, 12, Endian.little);
  data.setUint32(12, 4096, Endian.little);
  data.setUint32(16, totalBlocks, Endian.little);
  data.setUint32(20, totalChunks, Endian.little);
  return bytes;
}

/// One FILL chunk covering [totalBlocks] blocks.
Uint8List sparseFillImage({required int totalBlocks, required int value}) {
  final bytes = Uint8List(28 + 16);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, sparseMagic, Endian.little);
  data.setUint16(4, 1, Endian.little);
  data.setUint16(8, 28, Endian.little);
  data.setUint16(10, 12, Endian.little);
  data.setUint32(12, 4096, Endian.little);
  data.setUint32(16, totalBlocks, Endian.little);
  data.setUint32(20, 1, Endian.little);
  data.setUint16(28, sparseFill, Endian.little);
  data.setUint32(32, totalBlocks, Endian.little);
  data.setUint32(36, 16, Endian.little);
  data.setUint32(40, value, Endian.little);
  return bytes;
}
