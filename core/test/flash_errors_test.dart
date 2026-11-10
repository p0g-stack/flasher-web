import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

import 'flash_fixture.dart';

Matcher throwsPlanError(String messagePart) => throwsA(
  isA<FlashPlanException>().having(
    (error) => error.message,
    'message',
    contains(messagePart),
  ),
);

void main() {
  group('flash plan errors', () {
    test('a missing mandatory image stops the plan', () {
      final package = flashPackage(
        folder: 'OOS_FILES_HERE',
        omit: ['OOS_FILES_HERE/vendor_boot.img'],
      );
      expect(
        () => planFlash(
          package,
          selectionOf('13'),
          answersFor({'root': 'prepare-root', 'wipe': 'reboot'}),
        ),
        throwsPlanError('vendor_boot.img'),
      );
    });

    test('a missing selected branch image stops the plan', () {
      final package = flashPackage(folder: 'COS_FILES_HERE');
      expect(
        () => planFlash(
          package,
          selectionOf('13', region: 'CN'),
          answersFor({'bloat': 'debloat', 'wipe': 'reboot'}),
        ),
        throwsPlanError('OOS_FILES_HERE/my_preload.img'),
      );
    });

    test('an unselected branch image is not required', () {
      final package = flashPackage(folder: 'COS_FILES_HERE');
      final plan = planFlash(
        package,
        selectionOf('13', region: 'CN'),
        answersFor({'bloat': 'keep-bloat', 'wipe': 'reboot'}),
      );
      expect(plan.isResolved, isTrue);
      expect(flashPartitions(plan), isNot(contains('my_preload_a')));
    });

    test('an unknown template family is refused', () {
      expect(
        () => planFlash(
          flashPackage(folder: 'COS_FILES_HERE'),
          selectionOf('15R', region: 'CN'),
          answersFor(),
        ),
        throwsPlanError('No flasher family'),
      );
    });

    test('an unknown device is refused', () {
      expect(
        () => planFlash(
          flashPackage(folder: 'OOS_FILES_HERE'),
          selectionOf('NotADevice'),
          const {},
        ),
        throwsPlanError('No flasher family'),
      );
    });

    test('the confirmation names the device and the exact serial', () {
      final plan = planFlash(
        flashPackage(folder: 'OOS_FILES_HERE'),
        selectionOf('15'),
        const {},
      );
      expect(plan.confirmationText('SERIAL').first, 'Flash 15, serial SERIAL');
    });

    test('an invalid prompt choice is refused', () {
      expect(
        () => planFlash(
          flashPackage(folder: 'COS_FILES_HERE'),
          selectionOf('13', region: 'CN'),
          answersFor({'bloat': 'maybe', 'wipe': 'reboot'}),
        ),
        throwsPlanError('is not valid for "bloat"'),
      );
    });

    test('an answer for a prompt this plan does not have is refused', () {
      expect(
        () => planFlash(
          flashPackage(folder: 'OOS_FILES_HERE'),
          selectionOf('15'),
          answersFor({'root': 'prepare-root'}),
        ),
        throwsPlanError('No step in this plan uses the answer "root"'),
      );
    });

    test(
      'unanswered batch prompts block execution but still produce a plan',
      () {
        final package = flashPackage(folder: 'OOS_FILES_HERE');
        final plan = planFlash(package, selectionOf('13'), answersFor());
        expect(plan.isResolved, isFalse);
        expect(promptOf(plan, 'root').defaultChoice, isNull);
        expect(promptOf(plan, 'wipe').defaultChoice, isNull);
        expect(() => plan.executionSteps, throwsPlanError('Answer required'));
      },
    );

    test('X9U super package without super.img is refused', () {
      expect(
        () => planFlash(
          flashPackage(folder: 'OTA_FILES_HERE', superImage: false),
          selectionOf('X9U'),
          answersFor(),
        ),
        throwsPlanError('requires super.img'),
      );
    });

    test('X9U package without boot.img is refused', () {
      expect(
        () => planFlash(
          flashPackage(
            folder: 'OTA_FILES_HERE',
            omit: ['OTA_FILES_HERE/boot.img'],
          ),
          selectionOf('X9U', kind: 'Regional Flasher'),
          answersFor(),
        ),
        throwsPlanError('boot.img is missing'),
      );
    });

    test('NEO8 requires super.img and boot.img', () {
      expect(
        () => planFlash(
          flashPackage(folder: 'COS_FILES_HERE', superImage: false),
          selectionOf('NEO8', region: 'CN'),
          answersFor(),
        ),
        throwsPlanError('super.img is required'),
      );
      expect(
        () => planFlash(
          flashPackage(folder: 'COS_FILES_HERE', boot: const []),
          selectionOf('NEO8', region: 'CN'),
          answersFor(),
        ),
        throwsPlanError('boot.img is required'),
      );
    });
  });

  group('PackageIndex', () {
    test('normalizes separators and skips directory records', () {
      final package = PackageIndex.fromEntries([
        './OOS_FILES_HERE\\boot.img',
        'OOS_FILES_HERE/',
        'build.json',
      ]);
      expect(package.has('OOS_FILES_HERE/boot.img'), isTrue);
      expect(package.has('build.json'), isTrue);
      expect(package.has('OOS_FILES_HERE/'), isFalse);
      expect(package.imagesIn('OOS_FILES_HERE').single.stem, 'boot');
    });

    test('keeps package order and only top-level images', () {
      final package = PackageIndex.fromEntries([
        'D/z.img',
        'D/a.img',
        'D/nested/b.img',
        'D/notes.txt',
      ]);
      expect(package.imagesIn('D').map((image) => image.stem), ['z', 'a']);
    });

    test('refuses unsafe or duplicate entries', () {
      expect(
        () => PackageIndex.fromEntries(['../outside.img']),
        throwsPlanError('Unsafe'),
      );
      expect(
        () => PackageIndex.fromEntries(['/absolute.img']),
        throwsPlanError('not relative'),
      );
      expect(
        () => PackageIndex.fromEntries(['a//b.img']),
        throwsPlanError('Unsafe'),
      );
      expect(
        () => PackageIndex.fromEntries(['a.img', 'a.img']),
        throwsPlanError('Duplicate'),
      );
    });
  });
}
