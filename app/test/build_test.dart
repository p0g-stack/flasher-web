import 'dart:async';

import 'package:flasher_web/api/platform_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake.dart';

Map<String, Object?> inspection() => {
  'version': 'CPH2647_11.A.30',
  'fields': {
    'pre-device': 'CPH2647',
    'post-build': 'CPH2647_11.A.30(EX01)',
    'post-security-patch-level': '2025-09-01',
  },
  'partitions': {'system': 100, 'boot': 50, 'vendor': 25},
  'length': 16 * 1024 * 1024 * 1024,
  'stored': false,
  'device': 'CPH2647',
  'securityPatch': '2025-09-01',
  'arb': {'major': 1, 'minor': 2, 'index': 3},
};

Future<void> pickOta(WidgetTester tester, Harness harness) async {
  harness.bridge.otaFile = const PickedFile(
    handle: Object(),
    name: 'full-ota.zip',
    size: 16 * 1024 * 1024 * 1024,
  );
  await tester.tap(find.byKey(const ValueKey('chooseOtaFile')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('local OTA inspection and build output show the result', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.inspectResult = inspection();
    harness.api.buildStream = (_) => Stream.fromIterable([
      {'type': 'step', 'index': 1, 'total': 5, 'title': 'Prepare OTA'},
      {'type': 'log', 'text': 'Selected Oneplus 13 / GLO.'},
      {'type': 'log', 'text': 'Extracting system.img.'},
      {'type': 'progress', 'label': 'system.img', 'done': 50, 'total': 100},
      {'type': 'step', 'index': 4, 'total': 5, 'title': 'Package ZIP'},
      {
        'type': 'result',
        'job': '20260101-000000-abcdef',
        'artifact': 'SuperHybrid Flasher 13 GLO CPH2647.zip',
        'format': 'zip',
        'sha256': 'abc123def456',
        'manifest': {
          'device': 'Oneplus 13',
          'arb': {'major': 1, 'minor': 2, 'index': 3},
        },
      },
    ]);
    await pumpApp(tester, harness: harness);
    await pickOta(tester, harness);

    expect(find.byKey(const ValueKey('otaInspection')), findsOneWidget);
    expect(find.textContaining('CPH2647_11.A.30'), findsWidgets);
    expect(find.textContaining('index 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('gatingError')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('buildButton')));
    await tester.pumpAndSettle();

    expect(
      find.text('Package complete · ready in your output folder'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('buildResult')), findsOneWidget);
    expect(find.text('SuperHybrid Flasher 13 GLO CPH2647.zip'), findsWidgets);
    expect(find.text('abc123def456'), findsOneWidget);
    expect(find.textContaining('1.2 · 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('downloadZip')), findsOneWidget);
    expect(harness.api.lastBuildRequest?['zip'], isTrue);
    expect(harness.api.lastBuildRequest?['output'], {'kind': 'opfs'});
    expect(harness.bridge.keepAwake, 0);

    await tester.ensureVisible(find.byKey(const ValueKey('downloadZip')));
    await tester.tap(find.byKey(const ValueKey('downloadZip')));
    await tester.pumpAndSettle();
    expect(
      harness.bridge.downloads,
      contains(
        '20260101-000000-abcdef/'
        'SuperHybrid Flasher 13 GLO CPH2647.zip',
      ),
    );
  });

  testWidgets('cancel ends the subscription and releases the wake lock', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.inspectResult = inspection();
    final controller = StreamController<Map<String, Object?>>(
      onCancel: () {
        harness.api.buildCanceled = true;
      },
    );
    harness.api.buildStream = (_) => controller.stream;
    addTearDown(controller.close);
    await pumpApp(tester, harness: harness);
    await pickOta(tester, harness);

    await tester.tap(find.byKey(const ValueKey('buildButton')));
    await tester.pump();
    expect(harness.bridge.keepAwake, 1);
    expect(find.text('Preparing your build'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cancelBuild')));
    await tester.pumpAndSettle();

    expect(harness.api.buildCanceled, isTrue);
    expect(harness.bridge.keepAwake, 0);
    expect(find.text('Build cancelled · output cleaned.'), findsOneWidget);
  });
}
