import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

import 'flash_fixture.dart';

const _x9uBoot = <String>[
  'boot_a',
  'boot_b',
  'dtbo_a',
  'dtbo_b',
  'init_boot_a',
  'init_boot_b',
  'modem_a',
  'modem_b',
  'recovery_a',
  'recovery_b',
  'vbmeta_a',
  'vbmeta_b',
  'vbmeta_system_a',
  'vbmeta_system_b',
  'vbmeta_vendor_a',
  'vbmeta_vendor_b',
  'vendor_boot_a',
  'vendor_boot_b',
];

void main() {
  group('X9U family', () {
    test('super flash keeps ABL and excludes it from the extra loop', () {
      final package = flashPackage(
        folder: 'OTA_FILES_HERE',
        logical: const [],
        extras: ['abl', 'pdp'],
      );
      final plan = planFlash(package, selectionOf('X9U'), answersFor('X9U'));

      expect(plan.family, 'x9u');
      expect(promptOf(plan, 'abl').defaultChoice, 'keep-abl');
      expect(flashPartitions(plan), [..._x9uBoot, 'super', 'pdp_a', 'pdp_b']);
      expect(flashPartitions(plan), isNot(contains('abl_a')));
      final steps = execution(plan);
      expect(steps.whereType<RebootTo>().map((step) => step.mode), [
        FlashMode.fastbootd,
        FlashMode.fastbootd,
        FlashMode.android,
      ]);
      final setActiveIndex = steps.indexWhere((step) => step is SetActive);
      expect(setActiveIndex, greaterThan(indexOfFlash(steps, 'pdp_b')));
      expect(
        steps.whereType<DeleteLogical>(),
        isEmpty,
        reason: 'a packaged super needs no logical reconstruction',
      );
      expect(
        flashes(plan).where((flash) => flash.partition.startsWith('abl')),
        isEmpty,
        reason: 'abl.img is excluded from the extra loop and kept by default',
      );
    });

    test('ABL choice flashes both slots before activating slot A', () {
      final package = flashPackage(
        folder: 'OTA_FILES_HERE',
        logical: const [],
        extras: ['abl', 'pdp'],
      );
      final plan = planFlash(
        package,
        selectionOf('X9U'),
        answersFor('X9U', {'abl': 'flash-abl'}),
      );
      final steps = execution(plan);
      final partitions = flashPartitions(plan);
      expect(partitions.sublist(partitions.length - 2), ['abl_a', 'abl_b']);
      expect(
        indexOfFlash(steps, 'abl_b'),
        lessThan(steps.indexWhere((step) => step is SetActive)),
      );
      expect(partitions.where((p) => p == 'abl_a'), hasLength(1));
      expect(
        flashes(plan).where((flash) => flash.partition == 'abl_a').single.image,
        'OTA_FILES_HERE/abl.img',
      );
    });

    test('regional no-super rebuilds in two guarded passes', () {
      final package = flashPackage(
        folder: 'OTA_FILES_HERE',
        superImage: false,
        logical: ['system', 'system_dlkm_oki', 'vendor'],
        extras: ['pdp'],
      );
      final plan = planFlash(
        package,
        selectionOf('X9U', kind: 'Regional Flasher'),
        answersFor('X9U'),
      );
      final steps = execution(plan);
      expect(plan.template, 'cos/regional');
      final prepareNames = steps
          .whereType<DeleteLogical>()
          .where((step) => step.name.endsWith('_a'))
          .map((step) => step.name)
          .toList();
      expect(prepareNames, ['system_a', 'system_dlkm_oki_a', 'vendor_a']);
      final lastCreate = steps.lastIndexWhere((step) => step is CreateLogical);
      final firstLogicalFlash = indexOfFlash(steps, 'system_a');
      expect(firstLogicalFlash, greaterThan(lastCreate));
      expect(
        [
          for (final step in steps.skip(lastCreate + 1))
            if (step is Flash) step.partition,
        ].take(3),
        ['system_a', 'system_dlkm_oki_a', 'vendor_a'],
      );
      expect(flashPartitions(plan), isNot(contains('system_dlkm_gki_a')));
      expect(
        steps.whereType<CreateLogical>().map((step) => step.name),
        isNot(contains('system_dlkm_gki_a')),
        reason: 'the launcher skips logical partitions without an image',
      );
      expect(flashPartitions(plan), isNot(contains('vendor_b')));
      expect(promptOf(plan, 'abl').defaultChoice, 'keep-abl');
      expect(promptOf(plan, 'wipe').defaultChoice, 'reboot');
    });

    test('super packages still flash the boot list and require boot.img', () {
      final package = flashPackage(folder: 'OTA_FILES_HERE', logical: const []);
      final plan = planFlash(package, selectionOf('X9U'), answersFor('X9U'));
      expect(flashPartitions(plan).take(2), ['boot_a', 'boot_b']);
      expect(
        (execution(
          plan,
        ).firstWhere((step) => step is GetvarCheck) as GetvarCheck).expected,
        'test-X9U',
      );
    });
  });
}
