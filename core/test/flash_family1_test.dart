import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

import 'flash_fixture.dart';

const _bootFlashes = <String>[
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
  group('legacy batch family', () {
    test('13 OOS super follows the script order', () {
      final package = flashPackage(
        folder: 'OOS_FILES_HERE',
        extras: ['pdp'],
      );
      final plan = planFlash(
        package,
        selectionOf('13'),
        answersFor('13', {'root': 'prepare-root', 'wipe': 'reboot'}),
      );

      expect(plan.family, 'legacyBatch');
      expect(plan.template, 'oos/super');
      expect(plan.identity.product, 'sun');
      expect(plan.isResolved, isTrue);

      final steps = execution(plan);
      expect(steps.first, isA<RequireMode>());
      expect((steps[0] as RequireMode).mode, FlashMode.bootloader);
      expect(steps[1], isA<GetvarCheck>());
      expect((steps[1] as GetvarCheck).name, 'product');
      expect((steps[1] as GetvarCheck).expected, 'sun');

      expect(flashPartitions(plan), [
        ..._bootFlashes,
        'super',
        'pdp_a',
        'pdp_b',
      ]);
      for (final flash in flashes(plan)) {
        if (flash.partition == 'super') {
          expect(flash.image, 'super.img');
          expect(flash.sparse, isTrue);
        } else if (flash.partition.startsWith('pdp')) {
          expect(flash.image, 'OOS_FILES_HERE/pdp.img');
        } else {
          final partition = flash.partition.substring(
            0,
            flash.partition.lastIndexOf('_'),
          );
          expect(flash.image, 'OOS_FILES_HERE/$partition.img');
        }
      }

      final rebootIndex = steps.indexWhere(
        (step) => step is RebootTo && step.mode == FlashMode.fastbootd,
      );
      expect(rebootIndex, greaterThan(indexOfFlash(steps, 'super')));
      expect(steps[rebootIndex + 1], isA<RequireMode>());
      expect(
        (steps[rebootIndex + 1] as RequireMode).mode,
        FlashMode.fastbootd,
      );
      expect(indexOfFlash(steps, 'pdp_a'), greaterThan(rebootIndex));

      final setActiveIndex = steps.indexWhere((step) => step is SetActive);
      expect((steps[setActiveIndex] as SetActive).slot, FlashSlot.a);
      expect(setActiveIndex, greaterThan(indexOfFlash(steps, 'pdp_b')));
      expect((steps.last as RebootTo).mode, FlashMode.android);
      expect(flashPartitions(plan), isNot(contains('system_a')));

      final confirmation = plan.confirmationText('SERIAL-13');
      expect(confirmation.first, contains('13'));
      expect(confirmation.first, contains('SERIAL-13'));
      expect(confirmation.first, contains('sun'));
      expect(
        () => plan.confirmationText('  '),
        throwsA(isA<FlashPlanException>()),
      );
    });

    test('13 COS bloat branch debloats before the wipe decision', () {
      final package = flashPackage(
        folder: 'COS_FILES_HERE',
        otherFiles: ['OOS_FILES_HERE/my_preload.img'],
        extras: ['pdp'],
      );
      final plan = planFlash(
        package,
        selectionOf('13', region: 'CN'),
        answersFor('13', {'bloat': 'debloat', 'wipe': 'wipe'}),
      );

      expect(plan.family, 'legacyBatch');
      final steps = execution(plan);
      expect(flashPartitions(plan), contains('my_preload_a'));
      final preload = flashes(
        plan,
      ).singleWhere((flash) => flash.partition == 'my_preload_a');
      expect(preload.image, 'OOS_FILES_HERE/my_preload.img');
      expect(
        steps.whereType<DeleteLogical>().map((step) => step.name),
        containsAll([
          'my_preload_a',
          'my_preload_b',
          'my_preload_a-cow',
          'my_preload_b-cow',
        ]),
      );
      final setActiveIndex = steps.indexWhere((step) => step is SetActive);
      expect(
        indexOfFlash(steps, 'my_preload_a'),
        greaterThan(setActiveIndex),
      );
      expect(steps.last, isA<Instruct>());
      expect(
        steps.skip(setActiveIndex).whereType<RebootTo>(),
        isEmpty,
        reason: 'the manual wipe path does not reboot from the host',
      );
    });

    test('13 COS keeps the bloated preload when asked', () {
      final package = flashPackage(
        folder: 'COS_FILES_HERE',
        otherFiles: ['OOS_FILES_HERE/my_preload.img'],
      );
      final plan = planFlash(
        package,
        selectionOf('13', region: 'CN'),
        answersFor('13', {'bloat': 'keep-bloat', 'wipe': 'reboot'}),
      );
      expect(flashPartitions(plan), isNot(contains('my_preload_a')));
      expect(flashes(plan).last.partition, 'super');
      expect((execution(plan).last as RebootTo).mode, FlashMode.android);
    });

    test('13 COS batch prompts require an explicit answer', () {
      final package = flashPackage(folder: 'COS_FILES_HERE');
      final plan = planFlash(
        package,
        selectionOf('13', region: 'CN'),
        answersFor('13', {'wipe': 'reboot'}),
      );
      expect(promptOf(plan, 'bloat').defaultChoice, isNull);
      expect(promptOf(plan, 'bloat').selectedSteps, isNull);
      expect(plan.isResolved, isFalse);
      expect(
        () => plan.executionSteps,
        throwsA(isA<FlashPlanException>()),
      );
    });

    test('13T signal branch prepares ODM and writes explicit slot A', () {
      final package = flashPackage(
        folder: 'OOS_FILES_HERE',
        otherFiles: [
          'COS_FILES_HERE/oplusstanvbk.img',
          'COS_FILES_HERE/my_region.img',
          'COS_FILES_HERE/odm.img',
        ],
        extras: ['pdp'],
      );
      final plan = planFlash(
        package,
        selectionOf('13T'),
        answersFor('13T', {'root': 'flash-signal', 'wipe': 'reboot'}),
      );
      final steps = execution(plan);
      final setActiveIndex = steps.indexWhere((step) => step is SetActive);
      final after = steps.sublist(setActiveIndex + 1);
      expect(
        [
          for (final step in after)
            if (step is Flash) step.partition,
        ],
        ['oplusstanvbk_a', 'my_region_a', 'odm_a'],
      );
      expect(
        steps
            .whereType<DeleteLogical>()
            .map((step) => step.name)
            .where((name) => name.startsWith('odm')),
        ['odm_a', 'odm_b', 'odm_a-cow', 'odm_b-cow'],
      );
      expect(
        indexOfFlash(steps, 'my_region_a'),
        lessThan(indexOfFlash(steps, 'odm_a')),
      );
      expect(flashPartitions(plan), isNot(contains('odm_b')));
      expect(flashPartitions(plan), isNot(contains('oplusstanvbk_b')));
    });

    test('13 regional signal images get the explicit _a mapping', () {
      final package = flashPackage(
        folder: 'OOS_FILES_HERE',
        otherFiles: [
          'COS_FILES_HERE/oplusstanvbk.img',
          'COS_FILES_HERE/my_region.img',
        ],
        extras: ['pdp'],
      );
      final plan = planFlash(
        package,
        selectionOf('13', kind: 'Regional Flasher'),
        answersFor('13', {'root': 'flash-signal', 'wipe': 'reboot'}),
      );
      final steps = execution(plan);
      final setActiveIndex = steps.indexWhere((step) => step is SetActive);
      expect(
        [
          for (final step in steps.skip(setActiveIndex + 1))
            if (step is Flash) step.partition,
        ],
        ['oplusstanvbk_a', 'my_region_a'],
      );
    });

    test('Ace6 COS logical list adds GKI then OKI', () {
      final package = flashPackage(
        folder: 'COS_FILES_HERE',
        superImage: false,
        logical: [...testBaselineLogical, 'system_dlkm_gki', 'system_dlkm_oki'],
      );
      final plan = planFlash(
        package,
        selectionOf('Ace6', region: 'CN'),
        answersFor('Ace6', {'bloat': 'keep-bloat', 'wipe': 'reboot'}),
      );
      final partitions = flashPartitions(plan);
      expect(
        indexOfFlash(execution(plan), 'system_dlkm_a'),
        lessThan(indexOfFlash(execution(plan), 'system_dlkm_gki_a')),
      );
      expect(
        indexOfFlash(execution(plan), 'system_dlkm_gki_a'),
        lessThan(indexOfFlash(execution(plan), 'system_dlkm_oki_a')),
      );
      expect(
        indexOfFlash(execution(plan), 'system_dlkm_oki_a'),
        lessThan(indexOfFlash(execution(plan), 'system_ext_a')),
      );
      expect(partitions.where((p) => p == 'system_dlkm_gki_a'), hasLength(1));
      expect(partitions.where((p) => p.startsWith('boot_')), hasLength(2));
      expect(partitions, isNot(contains('system_b')));
    });
  });
}
