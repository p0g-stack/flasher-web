import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

import 'ota_fixture.dart' show FixtureExtent, FixtureOp, FixturePartition, OtaFixture, fixtureBlock, pattern;
import 'virtual_fixture.dart';

/// The nine boot images every 13 template flashes.
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

/// The logical partitions the launcher reconstructs, minus the two the real
/// 13 bloat store supplies (`my_company`, `my_preload`).
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

const Selection fixtureSelection = Selection(
  dev: '13',
  kind: 'RegionalHybrid Flasher',
  region: 'GLO',
  device: 'Oneplus 13',
  builder: 'BUILD_REGIONAL.sh',
);

Future<Uint8List> _bytesOf(FlashPackage package, String path) async {
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
    'a RegionalHybrid 13 GLO package plans, prepares and flashes decoded '
    'images without writing a workspace',
    () async {
      final bloat = {
        'bloat/13/GLO_BLOAT/my_company.img': pattern(fixtureBlock, seed: 101),
        'bloat/13/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 102),
        // The OTA also ships vendor_boot: its copy must win.
        'bloat/13/GLO_BLOAT/vendor_boot.img': pattern(fixtureBlock, seed: 103),
      };
      final fixture = await VirtualFixture.create(
        partitions: [...fixtureBoot, ...fixtureLogicalFromOta],
        bloatFiles: bloat,
        templates: {'13': fixtureTemplate13()},
      );
      addTearDown(fixture.dispose);
      final bloatBefore = await fixture.bloatWorkspace.list('', recursive: true);
      final otaFile = File('${fixture.root.path}/ota/ota.zip');
      final otaBytes = await otaFile.length();
      final otaStamp = (await otaFile.stat()).modified;

      final package = await fixture.open(fixtureSelection);
      try {
        final expected = <String, Uint8List>{
          for (final entry in bloat.entries)
            'OOS_FILES_HERE/${entry.key.split('/').last}': entry.value,
          // A decoded OTA image replaces the staged bloat copy.
          for (final entry in fixture.images.entries)
            'OOS_FILES_HERE/${entry.key}.img': entry.value,
        };
        expect(package.format, 'virtual');
        expect(package.job, startsWith('virtual-'));
        expect(package.index.has('OOS_FILES_HERE/my_company.img'), isTrue);
        expect(package.isOtaImage('OOS_FILES_HERE/my_company.img'), isFalse);
        expect(package.isOtaImage('OOS_FILES_HERE/vendor_boot.img'), isTrue);
        expect(
          await _bytesOf(package, 'OOS_FILES_HERE/my_company.img'),
          bloat['bloat/13/GLO_BLOAT/my_company.img'],
        );
        expect(
          await _bytesOf(package, 'OOS_FILES_HERE/vendor_boot.img'),
          fixture.images['vendor_boot'],
          reason: 'the OTA copy wins over the staged bloat copy',
        );
        expect(
          package.imageHash('OOS_FILES_HERE/vendor_boot.img'),
          sha256.convert(fixture.images['vendor_boot']!).toString(),
        );

        final plan = planFlash(
          package.index,
          fixtureSelection,
          const {'wipe': 'reboot'},
        );
        expect(plan.isResolved, isTrue);
        final steps = plan.executionSteps.whereType<Flash>().toList();
        expect(steps, isNotEmpty);
        for (final step in steps) {
          expect(expected, contains(step.image));
        }

        final device = FixtureDevice(product: 'sun');
        final transport = FixtureTransport(device);
        final prepared = await prepareFlash(
          package: package,
          selection: fixtureSelection,
          answers: const {'wipe': 'reboot'},
          serial: 'SERIAL-A',
          transport: transport,
          job: package.job,
        );
        expect(prepared.resolved, isTrue);
        expect(prepared.modeOk, isTrue);
        expect(
          prepared.images['OOS_FILES_HERE/my_company.img']!.digest,
          sha256.convert(bloat['bloat/13/GLO_BLOAT/my_company.img']!).toString(),
          reason: 'preparation hashes the bloat image, not an OTA copy',
        );

        final receipt = await executePreparedFlash(
          prepared,
          transport,
          emit: (_) {},
        );
        expect(
          receipt['status'],
          'succeeded',
          reason: '${receipt['failure']}',
        );
        expect(receipt['job'], package.job);
        expect(receipt['writes'], hasLength(steps.length));
        expect(
          (receipt['verification'] as Map)['status'],
          'unverified',
        );

        // Every slot received exactly the image the step names.
        for (final step in steps) {
          expect(
            device.delivered[step.partition],
            expected[step.image],
            reason: '${step.partition} received ${step.image}',
          );
        }
        expect(
          device.flashCommands,
          containsAll(['boot_a', 'boot_b', 'system_a', 'my_preload_a']),
        );
        expect(device.android, isTrue);

        // The virtual path stages nothing: both stores are as they were.
        expect(
          await fixture.bloatWorkspace.list('', recursive: true),
          bloatBefore,
        );
        expect(await fixture.otaWorkspace.list('', recursive: true), [
          'ota.zip',
        ]);
        expect(await otaFile.length(), otaBytes);
        expect((await otaFile.stat()).modified, otaStamp);
      } finally {
        await package.close();
      }
    },
  );

  test('an X9U regional package keeps its staged boot image over the OTA', () async {
    const selection = Selection(
      dev: 'X9U',
      kind: 'Regional Flasher',
      region: 'EU',
      device: 'OPPO Find X9 Ultra',
      builder: 'BUILD_REGIONAL.sh',
    );
    final bloat = {
      'bloat/X9U/EU_BLOAT/boot.img': pattern(fixtureBlock, seed: 51),
      'bloat/X9U/EU_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 52),
    };
    final fixture = await VirtualFixture.create(
      partitions: [...fixtureBoot, 'system', 'vendor', 'my_company'],
      bloatFiles: bloat,
      builders: const [('Regional Flasher', 'X9U', 'EU', 'BUILD_REGIONAL.sh')],
    );
    addTearDown(fixture.dispose);
    final package = await fixture.open(selection, vulnerableAbl: false);
    try {
      expect(package.index.has('OTA_FILES_HERE/boot.img'), isTrue);
      expect(
        package.isOtaImage('OTA_FILES_HERE/boot.img'),
        isFalse,
        reason: 'X9U keeps the verified bloat image and drops the OTA copy',
      );
      expect(
        await _bytesOf(package, 'OTA_FILES_HERE/boot.img'),
        bloat['bloat/X9U/EU_BLOAT/boot.img'],
      );
      expect(
        package.imageHash('OTA_FILES_HERE/boot.img'),
        sha256.convert(bloat['bloat/X9U/EU_BLOAT/boot.img']!).toString(),
        reason: 'the staged bloat image carries its own recorded hash',
      );
      expect(
        await _bytesOf(package, 'OTA_FILES_HERE/system.img'),
        fixture.images['system'],
        reason: 'partitions the bloat does not replace come from the OTA',
      );

      final plan = planFlash(
        package.index,
        selection,
        const {'product': 'canoe'},
      );
      final bootStep = plan.executionSteps
          .whereType<Flash>()
          .firstWhere((step) => step.partition == 'boot_a');
      expect(bootStep.image, 'OTA_FILES_HERE/boot.img');

      final device = FixtureDevice(product: 'canoe');
      final prepared = await prepareFlash(
        package: package,
        selection: selection,
        answers: const {'product': 'canoe'},
        serial: 'SERIAL-A',
        transport: FixtureTransport(device),
        job: package.job,
      );
      expect(
        prepared.images['OTA_FILES_HERE/boot.img']!.digest,
        sha256.convert(bloat['bloat/X9U/EU_BLOAT/boot.img']!).toString(),
      );
    } finally {
      await package.close();
    }
  });

  test('CN places the GLO bloat preload in OOS_FILES_HERE', () async {
    const selection = Selection(
      dev: '13',
      kind: 'Regional Flasher',
      region: 'CN',
      device: 'Oneplus 13',
      builder: 'BUILD_REGIONAL.sh',
    );
    final bloat = {
      'bloat/13/CN_BLOAT/my_company.img': pattern(fixtureBlock, seed: 61),
      'bloat/13/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 62),
    };
    final fixture = await VirtualFixture.create(
      partitions: ['boot', 'my_preload'],
      bloatFiles: bloat,
      builders: const [('Regional Flasher', '13', 'CN', 'BUILD_REGIONAL.sh')],
    );
    addTearDown(fixture.dispose);
    final package = await fixture.open(selection);
    try {
      expect(
        await _bytesOf(package, 'COS_FILES_HERE/my_company.img'),
        bloat['bloat/13/CN_BLOAT/my_company.img'],
      );
      // The GLO preload goes to OOS_FILES_HERE, not the CN image folder.
      expect(package.index.has('OOS_FILES_HERE/my_preload.img'), isTrue);
      expect(package.isOtaImage('OOS_FILES_HERE/my_preload.img'), isFalse);
      expect(
        await _bytesOf(package, 'OOS_FILES_HERE/my_preload.img'),
        bloat['bloat/13/GLO_BLOAT/my_preload.img'],
      );
      expect(package.isOtaImage('COS_FILES_HERE/my_preload.img'), isTrue);
      expect(
        await _bytesOf(package, 'COS_FILES_HERE/my_preload.img'),
        fixture.images['my_preload'],
      );
    } finally {
      await package.close();
    }
  });

  test('a changed OTA identity or manifest refuses the confirmed flash', () async {
    final fixture = await VirtualFixture.create(
      partitions: [...fixtureBoot, ...fixtureLogicalFromOta],
      bloatFiles: {
        'bloat/13/GLO_BLOAT/my_company.img': pattern(fixtureBlock, seed: 201),
        'bloat/13/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 202),
      },
    );
    addTearDown(fixture.dispose);
    final package = await fixture.open(fixtureSelection);
    try {
      final prepared = await prepareFlash(
        package: package,
        selection: fixtureSelection,
        answers: const {'wipe': 'reboot'},
        serial: 'SERIAL-A',
        transport: FixtureTransport(FixtureDevice(product: 'sun')),
        job: package.job,
      );
      expect(prepared.resolved, isTrue);
      await verifyPreparedImages(prepared);

      // The same bytes at a different file identity.
      final moved = await fixture.open(
        fixtureSelection,
        sourceIdentity: {...fixture.identity, 'lastModified': 1},
      );
      try {
        expect(moved.job, isNot(package.job));
        await expectLater(
          verifyPreparedImages(prepared, package: moved),
          throwsA(
            isA<FlashException>().having(
              (error) => error.message,
              'message',
              contains('identity changed'),
            ),
          ),
        );
      } finally {
        await moved.close();
      }

      // A different manifest under the same identity.
      final changedOps = [
        ...fixture.images.keys.map(
          (name) => FixturePartition(
            name: name,
            ops: [
              FixtureOp.replace([const FixtureExtent(0, 1)], fixture.images[name]!),
            ],
          ),
        ),
        FixturePartition(
          name: 'extra',
          ops: [
            FixtureOp.replace(
              [const FixtureExtent(0, 1)],
              pattern(fixtureBlock, seed: 999),
            ),
          ],
        ),
      ];
      final sink = await fixture.otaWorkspace.create('ota-2.zip');
      await sink.write(OtaFixture(changedOps).build(), 0);
      await sink.close();
      final source = await fixture.otaWorkspace.open('ota-2.zip');
      final archive = await OtaArchive.open(source);
      final changed = await VirtualFlashPackage.load(
        ota: archive,
        selection: fixtureSelection,
        bloat: fixture.bloatWorkspace,
        bloatManifest: fixture.bloatManifest,
        sourceIdentity: fixture.identity,
      );
      try {
        await expectLater(
          verifyPreparedImages(prepared, package: changed),
          throwsA(
            isA<FlashException>().having(
              (error) => error.message,
              'message',
              contains('identity changed'),
            ),
          ),
        );
      } finally {
        await changed.close();
      }
    } finally {
      await package.close();
    }
  });

  test(
    'the ticket recheck does not rehash bloat, and a changed bloat file is '
    'still refused when the package is reopened',
    () async {
      final fixture = await VirtualFixture.create(
        partitions: [...fixtureBoot, ...fixtureLogicalFromOta],
        bloatFiles: {
          'bloat/13/GLO_BLOAT/my_company.img': pattern(fixtureBlock, seed: 401),
          'bloat/13/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 402),
        },
      );
      addTearDown(fixture.dispose);
      final counting = CountingWorkspace(fixture.bloatWorkspace);
      final package = await fixture.open(fixtureSelection, bloat: counting);
      try {
        final prepared = await prepareFlash(
          package: package,
          selection: fixtureSelection,
          answers: const {'wipe': 'reboot'},
          serial: 'SERIAL-A',
          transport: FixtureTransport(FixtureDevice(product: 'sun')),
          job: package.job,
        );
        // Preparation inspected every image, bloat included: the counter works.
        expect(counting.opens, greaterThanOrEqualTo(2));
        expect(counting.bytesRead, greaterThanOrEqualTo(2 * fixtureBlock));

        counting.reset();
        await verifyPreparedImages(prepared);
        // The virtual ticket binds the snapshot and re-verifies bloat in
        // `VirtualFlashPackage.load`, so the pre-write recheck reads nothing.
        expect(counting.opens, 0);
        expect(counting.reads, 0);
        expect(counting.bytesRead, 0);
      } finally {
        await package.close();
      }

      // A bloat file changed after preparation is refused by the reopened
      // package, before its snapshot digest is even compared.
      final sink = await fixture.bloatWorkspace.create(
        '13/GLO_BLOAT/my_company.img',
      );
      await sink.write(pattern(fixtureBlock, seed: 999), 0);
      await sink.close();
      await expectLater(
        fixture.open(fixtureSelection),
        throwsA(
          isA<FlashException>().having(
            (error) => error.message,
            'message',
            contains('SHA-256 mismatch'),
          ),
        ),
      );
    },
  );

  test('a Super selection is represented as one sparse super.img', () async {
    const selection = Selection(
      dev: '13',
      kind: 'SuperHybrid Flasher',
      region: 'GLO',
      device: 'Oneplus 13',
      builder: 'BUILD_SUPER.sh',
    );
    final fixture = await VirtualFixture.create(
      partitions: ['boot', 'my_company', 'product', 'system', 'vendor'],
      bloatFiles: {
        'bloat/13/GLO_BLOAT/my_company.img': pattern(fixtureBlock, seed: 501),
        'bloat/13/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 502),
      },
      builders: const [('SuperHybrid Flasher', '13', 'GLO', 'BUILD_SUPER.sh')],
    );
    addTearDown(fixture.dispose);
    final superSize = fixture.superSize('13', 'GLO');
    final package = await fixture.open(selection, superSize: superSize);
    try {
      expect(package.format, 'virtual');
      expect(package.job, startsWith('virtual-'));
      expect(package.index.has('super.img'), isTrue);
      expect(
        package.buildJson['image_sha256'],
        contains('OOS_FILES_HERE/boot.img'),
        reason: 'every image digest is in the load-time manifest',
      );
      expect(
        (package.buildJson['image_sha256']! as Map).keys,
        contains('Super/system.img'),
        reason: 'the decoded super inputs are advertised by digest',
      );
      expect(package.imageHash('super.img'), isNull);
      final length = await package.size('super.img');
      expect(length, greaterThan(0));
      expect(length, lessThan(superSize));
      final head = await _bytesOf(package, 'super.img');
      expect(head.length, length);
      expect(head.sublist(0, 4), [0x3a, 0xff, 0x26, 0xed]);
      expect(
        package.imageHash('super.img'),
        isNull,
        reason: 'reads and size reporting never complete a stream',
      );
      final source = await package.open('super.img');
      try {
        await for (final _ in source.stream()) {}
      } finally {
        await source.close();
      }
      expect(package.imageHash('super.img'), matches(RegExp(r'^[0-9a-f]{64}$')));
      final expanded = await package.openExpandedSuper();
      try {
        expect(expanded.length, superSize);
      } finally {
        await expanded.close();
      }
    } finally {
      await package.close();
    }
  });

  test('a package without bloat images for the selection is refused', () async {
    final fixture = await VirtualFixture.create(
      partitions: ['boot'],
      bloatFiles: {
        'bloat/13/EU_BLOAT/my_company.img': pattern(fixtureBlock, seed: 301),
      },
    );
    addTearDown(fixture.dispose);
    await expectLater(
      fixture.open(fixtureSelection),
      throwsA(
        isA<FlashException>().having(
          (error) => error.message,
          'message',
          contains('no images for this selection'),
        ),
      ),
    );
  });

  test('an OTA partition without a whole-image SHA-256 is refused', () async {
    final fixture = await VirtualFixture.create(
      partitions: [...fixtureBoot, ...fixtureLogicalFromOta],
      bloatFiles: {
        'bloat/13/GLO_BLOAT/my_company.img': pattern(fixtureBlock, seed: 111),
        'bloat/13/GLO_BLOAT/my_preload.img': pattern(fixtureBlock, seed: 112),
      },
      templates: {'13': fixtureTemplate13()},
    );
    addTearDown(fixture.dispose);
    // The fixture's own OTA is replaced by one whose `system` partition has
    // no whole-image digest: a virtual flash must not register it unverified.
    final ota = OtaFixture([
      for (final (index, name) in [
        ...fixtureBoot,
        ...fixtureLogicalFromOta,
      ].indexed)
        FixturePartition(
          name: name,
          hash: name != 'system',
          ops: [
            FixtureOp.replace(
              const [FixtureExtent(0, 1)],
              pattern(fixtureBlock, seed: 200 + index),
            ),
          ],
        ),
    ]);
    final sink = await fixture.otaWorkspace.create('ota.zip');
    await sink.write(ota.build(), 0);
    await sink.close();
    await expectLater(
      fixture.open(fixtureSelection),
      throwsA(
        predicate(
          (Object error) => '$error'.contains('SHA-256'),
          'an error naming the missing whole-image digest',
        ),
      ),
    );
  });
}
