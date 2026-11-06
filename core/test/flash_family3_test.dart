import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

import 'flash_fixture.dart';

void main() {
  group('legacy shell family', () {
    test('Pad3 without a super reboots by default and uses slot A', () {
      final package = flashPackage(
        folder: 'OOS_FILES_HERE',
        superImage: false,
      );
      final plan = planFlash(
        package,
        selectionOf('Pad3'),
        answersFor('Pad3'),
      );

      expect(plan.family, 'legacyShell');
      expect(plan.isResolved, isTrue);
      expect(promptOf(plan, 'wipe').defaultChoice, 'reboot');
      final steps = execution(plan);
      expect(
        steps.whereType<RebootTo>().map((step) => step.mode),
        [FlashMode.fastbootd, FlashMode.android],
        reason: 'Pad3 has one reboot to fastbootd and no second one',
      );
      expect(flashPartitions(plan), containsAll(['system_a', 'vendor_a']));
      expect(flashPartitions(plan), isNot(contains('system_b')));
      final setActiveIndex = steps.indexWhere((step) => step is SetActive);
      expect(setActiveIndex, greaterThan(indexOfFlash(steps, 'vendor_a')));
      expect((steps.last as RebootTo).mode, FlashMode.android);
    });

    test('Pad3 with a super treats every non-N answer as a manual wipe', () {
      final package = flashPackage(
        folder: 'OOS_FILES_HERE',
        extras: ['pdp'],
      );
      final plan = planFlash(
        package,
        selectionOf('Pad3'),
        answersFor('Pad3'),
      );
      expect(promptOf(plan, 'wipe').defaultChoice, 'wipe');
      final steps = execution(plan);
      expect(steps.last, isA<Instruct>());
      expect(steps.whereType<RebootTo>().map((step) => step.mode), [
        FlashMode.fastbootd,
      ]);
      expect(flashPartitions(plan), isNot(contains('system_a')));
      expect(
        steps
            .whereType<Instruct>()
            .any((step) => step.text.contains('Format Data')),
        isTrue,
      );
    });

    test('Ace6 shell list adds GKI then OKI', () {
      final package = flashPackage(
        folder: 'OOS_FILES_HERE',
        superImage: false,
        logical: [...testBaselineLogical, 'system_dlkm_gki', 'system_dlkm_oki'],
      );
      final plan = planFlash(
        package,
        selectionOf('Ace6'),
        answersFor('Ace6'),
      );
      expect(plan.family, 'legacyShell');
      final steps = execution(plan);
      expect(
        indexOfFlash(steps, 'system_dlkm_gki_a'),
        lessThan(indexOfFlash(steps, 'system_dlkm_oki_a')),
      );
      expect(
        indexOfFlash(steps, 'system_dlkm_a'),
        lessThan(indexOfFlash(steps, 'system_dlkm_gki_a')),
      );
      expect(promptOf(plan, 'wipe').defaultChoice, 'reboot');
    });
  });
}
