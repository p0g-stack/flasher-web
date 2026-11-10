import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

import 'flash_fixture.dart';

void main() {
  group('NEO8 family', () {
    test('guarded boot list, no reconstruction, exact extra exclusions', () {
      final package = flashPackage(
        folder: 'COS_FILES_HERE',
        boot: ['boot', 'dtbo', 'vbmeta'],
        logical: const [],
        extras: ['pdp'],
        otherFiles: [
          'COS_FILES_HERE/my_preload.img',
          'COS_FILES_HERE/system_dlkm_gki.img',
        ],
      );
      final plan = planFlash(
        package,
        selectionOf('NEO8', region: 'CN'),
        answersFor(),
      );

      expect(plan.family, 'neo8');
      expect(flashPartitions(plan), [
        'boot_a',
        'boot_b',
        'dtbo_a',
        'dtbo_b',
        'vbmeta_a',
        'vbmeta_b',
        'super',
        'pdp_a',
        'pdp_b',
      ]);
      expect(flashPartitions(plan), isNot(contains('modem_a')));
      expect(execution(plan).whereType<DeleteLogical>(), isEmpty);
      expect(execution(plan).whereType<CreateLogical>(), isEmpty);
      expect(flashPartitions(plan), isNot(contains('my_preload_a')));
      expect(flashPartitions(plan), isNot(contains('system_dlkm_gki_a')));
      expect(promptOf(plan, 'wipe').defaultChoice, 'reboot');
      final steps = execution(plan);
      expect(steps.whereType<RebootTo>().map((step) => step.mode), [
        FlashMode.fastbootd,
        FlashMode.android,
      ]);
      expect(
        steps.whereType<Instruct>().any(
          (step) => step.text.contains('unlocked Realme NEO8'),
        ),
        isTrue,
      );
      expect((steps.last as RebootTo).mode, FlashMode.android);
    });

    test('only present boot images are flashed to both slots', () {
      final package = flashPackage(
        folder: 'COS_FILES_HERE',
        boot: ['boot', 'modem'],
        logical: const [],
      );
      final plan = planFlash(
        package,
        selectionOf('NEO8', region: 'CN'),
        answersFor(),
      );
      expect(flashPartitions(plan), [
        'boot_a',
        'boot_b',
        'modem_a',
        'modem_b',
        'super',
      ]);
      expect(flashes(plan).first.image, 'COS_FILES_HERE/boot.img');
    });
  });
}
