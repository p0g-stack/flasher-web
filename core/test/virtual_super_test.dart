import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flasher_web_core/flasher_web_core.dart';
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
        0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0, ...List<int>.filled(24, 0),
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

/// A loopback stand-in for the edge worker's `/api/catalog`, `/api/resolve`
/// and `/api/ota` routes, serving fixture OTA ZIPs with HTTP ranges.
final class FakeCatalogServer {
  FakeCatalogServer._(this._server, this._catalog, this._otas);

  final HttpServer _server;
  final Map<String, dynamic> _catalog;
  final Map<String, Uint8List> _otas;

  /// Request lines the server answered, in order.
  final requests = <String>[];

  static Future<FakeCatalogServer> start({
    required Map<String, dynamic> catalog,
    required Map<String, Uint8List> otas,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = FakeCatalogServer._(server, catalog, otas);
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
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/api/catalog') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(_catalog));
      } else if (request.method == 'POST' && path == '/api/resolve') {
        final body = await utf8.decoder.bind(request).join();
        final entry = jsonDecode(body) as Map<String, dynamic>;
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({'url': '$apiBase/ota/${entry['id']}.zip'}),
        );
      } else if (request.method == 'GET' && path.startsWith('/ota/')) {
        final id = path.substring('/ota/'.length);
        final bytes = _otas[id.endsWith('.zip')
            ? id.substring(0, id.length - 4)
            : id];
        if (bytes == null) {
          response.statusCode = HttpStatus.notFound;
        } else {
          await _range(request, response, bytes);
          return;
        }
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    } on Object {
      response.statusCode = HttpStatus.internalServerError;
      await response.close();
    }
  }

  Future<void> _range(
    HttpRequest request,
    HttpResponse response,
    Uint8List bytes,
  ) async {
    final total = bytes.length;
    final header = request.headers.value(HttpHeaders.rangeHeader);
    if (header == null) {
      response.statusCode = HttpStatus.ok;
      response.headers.contentLength = total;
      response.add(bytes);
      await response.close();
      return;
    }
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
    if (match == null) {
      response.statusCode = HttpStatus.badRequest;
      await response.close();
      return;
    }
    final start = int.parse(match.group(1)!);
    final requestedEnd = match.group(2)!.isEmpty
        ? total - 1
        : int.parse(match.group(2)!);
    if (start >= total || requestedEnd < start) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set('content-range', 'bytes */$total');
      await response.close();
      return;
    }
    final end = math.min(requestedEnd, total - 1);
    response.statusCode = HttpStatus.partialContent;
    response.headers.set('content-range', 'bytes $start-$end/$total');
    response.headers.contentLength = end - start + 1;
    response.add(Uint8List.sublistView(bytes, start, end + 1));
    await response.close();
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
  );
  try {
    // The virtual super digest is lazy: it exists only after the first pass,
    // and the load-time manifest advertises the other images instead.
    expect(package.imageHash('super.img'), isNull);
    expect(package.buildJson.containsKey('image_sha256'), isFalse);
    final available = (package.buildJson['available_image_sha256']! as Map)
        .cast<String, String>();
    expect(available.keys.toSet(), {
      for (final path in package.index.entries)
        if (path.endsWith('.img') && path != 'super.img') path,
    });
    for (final entry in available.entries) {
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
    );
    final package = await fixture.open(
      selection,
      superSize: fixture.superSize('X9U', 'EU'),
    );
    try {
      // The staged bloat image replaces the OTA copy inside the super.
      expect(
        package.index.has('OTA_FILES_HERE/abl.img'),
        isFalse,
        reason: 'no ABL when the stock ABL is kept',
      );
      final export = await exportEntries(fixture, package, label: '_X9U');
      expect(
        utf8.decode(
          export['META-INF/com/google/android/super-size']!.bytes,
        ),
        '${fixture.superSize('X9U', 'EU')}\n',
      );
    } finally {
      await package.close();
    }
  });

  test('Ace 6 IN conversion: BASE and TARGET with regenerated vbmeta', () async {
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
        'bloat/Ace6/OOS_BLOAT/my_company.img': pattern(fixtureBlock, seed: 61),
        'bloat/Ace6/OOS_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 62),
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
  });

  test(
    'Ace 6T Super IN/GLO: the catalog-matched donor ODM',
    () async {
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
              'bloat/Ace6T/$folder/$name.img': pattern(
                fixtureBlock,
                seed: seed,
              ),
        },
        templates: {'Ace6T': fixtureSuperTemplate('oos')},
        builders: const [
          ('Super Flasher', 'Ace6T', 'IN', 'BUILD_SUPER.sh'),
          ('Super Flasher', 'Ace6T', 'GLO', 'BUILD_SUPER.sh'),
        ],
      );
      addTearDown(fixture.dispose);
      final donorBytes = await File(
        '${fixture.root.path}/ota/donor.zip',
      ).readAsBytes();
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
        otas: {'donor-cn': donorBytes},
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
            blocks.values.any((block) => _same(block, fixture.donorImages['odm']!)),
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
    },
  );

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
          reason: 'loading 13 SuperHybrid reads only OTA metadata, never '
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
          reason: 'an unresolved plan inspects no image, so the super is never '
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
    'the super index is built once, memoized, and the snapshot never changes',
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
        final digest = package.imageHash('super.img')!;
        expect(digest, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(
          ota.reads + bloat.reads,
          greaterThan(0),
          reason: 'the first pass reads every super input once',
        );
        // Every populated super input is one 4096-byte block here.
        expect(ota.bytesRead + bloat.bytesRead, 4096 * (ota.reads + bloat.reads));

        ota.reset();
        bloat.reset();
        expect(await package.size('super.img'), length);
        final source = await package.open('super.img');
        try {
          final scan = await scanSparse(source);
          expect(scan.digest, digest);
          expect(scan.expandedBytes, fixture.superSize('13', 'GLO'));
        } finally {
          await source.close();
        }
        expect(ota.reads + bloat.reads, 0, reason: 'the pass is memoized');
        expect(ota.bytesRead + bloat.bytesRead, 0);
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
        answers: const {'wipe': 'reboot', 'product': 'canoe'},
        product: 'canoe',
        superSize: fixture.superSize('Ace6', 'IN'),
        withBase: true,
      );
    },
  );

  test(
    'a bloat block that changes shape mid-stream fails in the download phase',
    () async {
      final fill = Uint8List(fixtureBlock)..fillRange(0, fixtureBlock, 0x22);
      final fixture = await super13Fixture(
        bloatFiles: {
          ...bloat13(),
          'bloat/13/GLO_BLOAT/my_company.img': fill,
        },
      );
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

        // The prepared index says FILL; the file now holds a RAW block.
        final sink = await fixture.bloatWorkspace.create(
          '13/GLO_BLOAT/my_company.img',
        );
        await sink.write(pattern(fixtureBlock, seed: 999), 0);
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
          contains('sparse encoding changed after preparation'),
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
          answers: const {'wipe': 'reboot', 'product': 'canoe'},
          serial: 'SERIAL-A',
          transport: FixtureTransport(FixtureDevice(product: 'canoe')),
          job: package.job,
        );
        expect(prepared.resolved, isTrue);

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
        await refused(
          () async => fixture.open(
            selectionAce6,
            superSize: fixture.superSize('Ace6', 'IN'),
            base: await fixture.openOta('base.zip'),
            baseIdentity: fixture.identityOf('base.zip'),
            sourceIdentity: {
              ...fixture.identity,
              'lastModified': 1,
            },
            preparedPackage: prepared.package as VirtualFlashPackage,
          ),
          'confirmed OTA identity',
        );

        // A changed BASE identity.
        await refused(
          () async => fixture.open(
            selectionAce6,
            superSize: fixture.superSize('Ace6', 'IN'),
            base: await fixture.openOta('base.zip'),
            baseIdentity: {'kind': 'file', 'name': 'base.zip', 'size': 0},
            preparedPackage: prepared.package as VirtualFlashPackage,
          ),
          'confirmed OTA identity',
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
            preparedPackage: prepared.package as VirtualFlashPackage,
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
            answers: const {'wipe': 'reboot', 'product': 'canoe'},
            serial: 'SERIAL-A',
            transport: FixtureTransport(FixtureDevice(product: 'canoe')),
            job: donorPackage.job,
          );
          expect(donorPrepared.resolved, isTrue);
          await refused(
            () async => fixture.open(
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
              preparedPackage: donorPrepared.package as VirtualFlashPackage,
            ),
            'confirmed OTA identity',
          );
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

  test('a super index above 32 MiB fails closed before it is built', () async {
    const blocks = 8388608; // 32 GiB in one FILL chunk.
    final fixture = await super13Fixture(
      regionSizes: const {'13': (40 << 30, 40 << 30)},
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
      await expectLater(
        package.size('super.img'),
        throwsA(
          isA<FlashException>().having(
            (error) => error.message,
            'message',
            contains('index exceeds its 32 MiB memory limit'),
          ),
        ),
      );
    } finally {
      await package.close();
    }
  });

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
      expect(package.cache.peakBytes, greaterThan(0));
      expect(package.cache.peakBytes, lessThanOrEqualTo(64 << 20));
      expect(package.cache.bytes, lessThanOrEqualTo(64 << 20));
      expect(package.imageHash('super.img'), isNotNull);
    } finally {
      await package.close();
    }
  });

  test('the service probes the product before it opens a virtual package', () async {
    final fixture = await super13Fixture(
      builders: const [
        ('SuperHybrid Flasher', '13', 'GLO', 'BUILD_SUPER.sh'),
        ('Super Flasher', 'Ace5', 'GLO', 'BUILD_SUPER.sh'),
      ],
    );
    addTearDown(fixture.dispose);
    final device = FixtureDevice(product: 'canoe');
    final service = FlasherService(
      transportFactory: () => FixtureTransport(device),
    );
    final result = await service.prepareFlash({
      'selection': {
        'device': 'Oneplus Ace 5',
        'kind': 'Super Flasher',
        'region': 'GLO',
      },
      'serial': device.serial,
      'upstreamBase': fixture.upstreamPath,
      'virtual': {
        'ota': {
          'kind': 'file',
          'file': '${fixture.root.path}/missing-ota.zip',
        },
        'bloat': {'kind': 'path', 'path': '${fixture.root.path}/missing'},
      },
    });
    expect(result['productRequired'], isTrue);
    expect(result['observedProduct'], 'canoe');
    expect(result['serial'], device.serial);
    expect(device.commands, ['getvar:product']);
    expect(device.flashCommands, isEmpty);
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
          contains('unknown, expired or already used'),
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
        'ota': {
          'kind': 'file',
          'file': '${fixture.root.path}/ota/ota.zip',
        },
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
          : const [
              ('SuperHybrid Flasher', 'Ace6', 'IN', 'BUILD_ACE6_OOS.sh'),
            ],
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

void expectSameBlocks(Map<int, Uint8List> actual, Map<int, Uint8List> expected) {
  expect(actual.keys.toSet(), expected.keys.toSet());
  for (final entry in expected.entries) {
    expect(
      actual[entry.key],
      entry.value,
      reason: 'super block ${entry.key}',
    );
  }
}

int counterReads(CountingWorkspace ota, CountingWorkspace bloat) =>
    ota.reads + bloat.reads;

int counterBytes(CountingWorkspace ota, CountingWorkspace bloat) =>
    ota.bytesRead + bloat.bytesRead;

/// Prepares, reopens and executes a virtual super on a fake transport, then
/// proves the delivered parts expand to the folder build's super and that the
/// flash decoded no super input a second time.
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
    // Preparation decodes the super exactly once.
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
    final prepareReads = counterReads(ota, bloat);
    final prepareBytes = counterBytes(ota, bloat);

    // Reopening for the confirmed flash reuses the completed index, so a
    // second preparation reads every other image again but never the super.
    final reopened = await fixture.open(
      selection,
      ota: ota,
      bloat: bloat,
      superSize: superSize,
      base: withBase ? await fixture.openOta('base.zip', workspace: ota) : null,
      baseIdentity: withBase ? fixture.identityOf('base.zip') : null,
      preparedPackage: prepared.package as VirtualFlashPackage,
    );
    try {
      expect(reopened.imageHash('super.img'), prepared.images['super.img']!.digest);
      ota.reset();
      bloat.reset();
      final second = await prepareFlash(
        package: reopened,
        selection: selection,
        answers: answers,
        serial: 'SERIAL-A',
        transport: FixtureTransport(FixtureDevice(product: product)),
        job: reopened.job,
      );
      expect(second.resolved, isTrue);
      expect(
        second.images['super.img']!.digest,
        prepared.images['super.img']!.digest,
      );
      final secondReads = counterReads(ota, bloat);
      final secondBytes = counterBytes(ota, bloat);

      expect(
        prepareReads - secondReads,
        greaterThan(0),
        reason: 'the first preparation decoded the super, the second reused it',
      );
      expect(prepareBytes, greaterThan(secondBytes));

      // The pre-write ticket check rechecks sizes only.
      ota.reset();
      bloat.reset();
      await verifyPreparedImages(second, package: reopened);
      expect(counterReads(ota, bloat), 0);
      expect(counterBytes(ota, bloat), 0);

      // Execution reads only the blocks it sends.
      ota.reset();
      bloat.reset();
      final device = FixtureDevice(product: product);
      final receipt = await executePreparedFlash(
        second,
        FixtureTransport(device),
        emit: (_) {},
      );
      expect(receipt['status'], 'succeeded', reason: '${receipt['failure']}');
      expect(receipt['job'], reopened.job);
      // Execution streams the prepared index; the counters prove it read the
      // inputs it sent (the prepared scan is reused, not rebuilt).
      expect(counterReads(ota, bloat), greaterThan(0));
      expect(counterBytes(ota, bloat), greaterThan(0));

      final parts = device.parts['super']!;
      expect(parts.length, greaterThan(1), reason: 'the image is split');
      for (final part in parts) {
        expect(part.length, lessThanOrEqualTo(0x4000));
      }
      expectSameBlocks(
        expandParts(parts),
        expandSparse(await bytesOf(package, 'super.img')).blocks,
      );
      final writes = (receipt['writes'] as List)
          .cast<Map<String, Object?>>()
          .where((write) => write['partition'] == 'super')
          .toList();
      expect(writes, hasLength(parts.length));
      for (final write in writes) {
        expect(write['status'], 'ok');
        expect(write['parts'], parts.length);
      }
      expect(device.flashCommands.where((name) => name == 'super'), hasLength(parts.length));
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
