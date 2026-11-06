import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

import 'flash_fixture.dart';

void main() {
  group('newer family', () {
    test('15 OOS super reboots twice and asks to wipe without a super', () {
      final package = flashPackage(
        folder: 'OOS_FILES_HERE',
        extras: ['pdp'],
        logical: [...testBaselineLogical, 'system_dlkm_oki'],
      );
      final plan = planFlash(package, selectionOf('15'), answersFor('15'));

      expect(plan.family, 'newer');
      expect(plan.isResolved, isTrue);
      final steps = execution(plan);
      expect(steps.whereType<RebootTo>().map((step) => step.mode), [
        FlashMode.fastbootd,
        FlashMode.fastbootd,
        FlashMode.android,
      ]);
      expect(steps.whereType<RequireMode>().map((s) => s.mode), [
        FlashMode.bootloader,
        FlashMode.fastbootd,
        FlashMode.fastbootd,
      ]);
      final setActiveIndex = steps.indexWhere((step) => step is SetActive);
      expect(
        flashPartitions(plan),
        isNot(contains('system_a')),
        reason: 'a packaged super replaces logical reconstruction',
      );
      expect(flashPartitions(plan), contains('pdp_a'));
      expect(setActiveIndex, greaterThan(indexOfFlash(steps, 'pdp_b')));
      expect(
        steps.skip(setActiveIndex).whereType<RebootTo>().first.mode,
        FlashMode.fastbootd,
      );
      expect((steps.last as RebootTo).mode, FlashMode.android);
      expect(flashes(plan).last.partition, 'pdp_b');
    });

    test('15 regional rebuilds logical partitions with explicit slot A', () {
      final package = flashPackage(
        folder: 'OOS_FILES_HERE',
        superImage: false,
        logical: [...testBaselineLogical, 'system_dlkm_oki'],
        extras: ['pdp'],
      );
      final plan = planFlash(
        package,
        selectionOf('15', kind: 'Regional Flasher'),
        answersFor('15'),
      );
      final steps = execution(plan);
      expect(plan.template, 'oos/regional');
      expect(
        flashPartitions(plan),
        containsAll([
          'system_a',
          'system_dlkm_oki_a',
          'vendor_a',
          'my_preload_a',
        ]),
      );
      expect(flashPartitions(plan), isNot(contains('system_b')));
      final systemPrepare = steps.indexWhere(
        (step) => step is DeleteLogical && step.name == 'system_a',
      );
      expect(indexOfFlash(steps, 'system_a'), greaterThan(systemPrepare));
      expect(
        steps.whereType<DeleteLogical>().map((step) => step.name),
        isNot(contains('system_dlkm_gki_a')),
      );
      expect(flashes(plan).last.partition, 'my_preload_a');
    });

    test('15 COS default debloats before activating slot A', () {
      final package = flashPackage(
        folder: 'COS_FILES_HERE',
        logical: [...testBaselineLogical, 'system_dlkm_oki'],
        otherFiles: ['OOS_FILES_HERE/my_preload.img'],
        extras: ['pdp'],
      );
      final plan = planFlash(
        package,
        selectionOf('15', region: 'CN'),
        answersFor('15'),
      );
      expect(promptOf(plan, 'bloat').defaultChoice, 'debloat');
      final steps = execution(plan);
      expect(
        indexOfFlash(steps, 'my_preload_a'),
        lessThan(steps.indexWhere((step) => step is SetActive)),
      );
      final preload = flashes(plan)
          .singleWhere((flash) => flash.partition == 'my_preload_a');
      expect(preload.image, 'OOS_FILES_HERE/my_preload.img');
      expect(
        steps.whereType<DeleteLogical>().map((step) => step.name),
        containsAll(['my_preload_a', 'my_preload_a-cow']),
      );
      expect((steps.last as RebootTo).mode, FlashMode.android);
    });

    test('15R regional belongs to the newer family', () {
      expect(
        flashFamily(selectionOf('15R', kind: 'Regional Flasher')),
        FlashFamily.newer,
      );
    });
  });
}
