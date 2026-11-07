import 'dart:io';

import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late IoWorkspace workspace;

  setUpAll(() async {
    expect(await loadNative(), isTrue);
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('flasher_web_pipeline_');
    workspace = IoWorkspace(temp);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Future<void> touch(String path) async {
    final sink = await workspace.create(path);
    await sink.close();
  }

  test('extracts payload ZERO operations and hashes the resulting image', () async {
    final fixtures = IoWorkspace(Directory('test/fixtures'));
    final source = await fixtures.open('mixed-ota.zip');
    try {
      final ota = await OtaArchive.open(source);
      final hashes = await extractPartitions(
        ota,
        workspace,
        'images',
        names: ['zeroed'],
      );
      final bytes = await File('${temp.path}/images/zeroed.img').readAsBytes();
      expect(bytes.length, 12288);
      expect(bytes.take(4096).any((byte) => byte != 0), isTrue);
      expect(bytes.skip(4096).every((byte) => byte == 0), isTrue);
      expect(
        hashes['zeroed'],
        'e0344ebcd41cd3bc1833bdd346852fb2e54edd6d79f9e411c93df208b26f6b4e',
      );
    } finally {
      await closeByteSource(source);
    }
  });

  group('extractionPlan', () {
    test('skips the ODM a non-CN Ace5 Super flasher discards', () async {
      final plan = await extractionPlan(
        selection: const Selection(
          dev: 'Ace5',
          kind: 'Super Flasher',
          region: 'GLO',
        ),
        workspace: workspace,
        result: 'stage/Super Flasher Ace5 GLO',
        available: ['boot', 'odm', 'system'],
      );
      expect(plan, ['boot', 'system']);
    });

    test('keeps the ODM for CN and for regional kinds', () async {
      final cn = await extractionPlan(
        selection: const Selection(
          dev: 'Ace5',
          kind: 'Super Flasher',
          region: 'CN',
        ),
        workspace: workspace,
        result: 'stage/Super Flasher Ace5 CN',
        available: ['boot', 'odm'],
      );
      expect(cn, isNull);
      final regional = await extractionPlan(
        selection: const Selection(
          dev: 'Ace5',
          kind: 'Regional Flasher',
          region: 'GLO',
        ),
        workspace: workspace,
        result: 'stage/Regional Flasher Ace5 GLO',
        available: ['boot', 'odm'],
      );
      expect(regional, isNull);
    });

    test('staged X9U bloat wins over the OTA image', () async {
      await touch('stage/X9U Super IN/Super/system.img');
      await touch('stage/X9U Super IN/Super/vendor.img');
      final plan = await extractionPlan(
        selection: const Selection(
          dev: 'X9U',
          kind: 'Super Flasher',
          region: 'IN',
        ),
        workspace: workspace,
        result: 'stage/X9U Super IN',
        available: ['boot', 'system', 'vendor', 'product'],
      );
      expect(plan, ['boot', 'product']);
    });

    test('X9U regional looks in the image folder only', () async {
      await touch('stage/X9U Regional EU/Super/system.img');
      final plan = await extractionPlan(
        selection: const Selection(
          dev: 'X9U',
          kind: 'Regional Flasher',
          region: 'EU',
        ),
        workspace: workspace,
        result: 'stage/X9U Regional EU',
        available: ['boot', 'system'],
      );
      expect(plan, isNull);
    });

    test('rejects an OTA whose every partition is discarded', () async {
      await touch('stage/X9U Super IN/OTA_FILES_HERE/boot.img');
      await expectLater(
        extractionPlan(
          selection: const Selection(
            dev: 'X9U',
            kind: 'Super Flasher',
            region: 'IN',
          ),
          workspace: workspace,
          result: 'stage/X9U Super IN',
          available: ['boot'],
        ),
        throwsA(
          isA<BuildException>().having(
            (error) => error.message,
            'message',
            'The OTA contains no partitions this flasher uses.',
          ),
        ),
      );
    });
  });
}
