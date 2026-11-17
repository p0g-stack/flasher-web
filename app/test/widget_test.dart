import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake.dart';

void main() {
  testWidgets(
    'selection filters device, kind and region and updates OS badge',
    (tester) async {
      await pumpApp(tester);

      expect(find.text('OXYGEN OS'), findsOneWidget);
      expect(find.byKey(const ValueKey('region-CN')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('region-CN')));
      await tester.pumpAndSettle();
      expect(find.text('COLOR OS'), findsOneWidget);

      await chooseDevice(tester, 'OnePlus Ace 6T');
      final kind = tester.widget<DropdownButton<String>>(
        find.descendant(
          of: find.byKey(const ValueKey('kindDropdown')),
          matching: find.byType(DropdownButton<String>),
        ),
      );
      expect(kind.value, 'Super Flasher');
      expect(find.byKey(const ValueKey('region-GLO')), findsOneWidget);
      expect(find.byKey(const ValueKey('region-IN')), findsOneWidget);
      expect(find.byKey(const ValueKey('region-EU')), findsNothing);
      expect(find.byKey(const ValueKey('region-CN')), findsNothing);
      expect(find.text('OXYGEN OS'), findsOneWidget);
    },
  );

  testWidgets('build gating reports missing bloat first', (tester) async {
    final harness = Harness();
    harness.api.bloatStatusResult = const {
      'total': 2,
      'downloaded': 0,
      'bytes': 1024,
      'ready': false,
    };
    await pumpApp(tester, harness: harness);

    expect(
      gating(tester),
      'Required bloat files must be downloaded and verified before '
      'continuing.',
    );
    expect(tooltip(tester), gating(tester));
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('flashDirectButton')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Not downloaded'), findsOneWidget);
  });

  testWidgets('bloat stream errors stay visible in the panel', (tester) async {
    final harness = Harness();
    harness.api.bloatStatusResult = const {
      'total': 2,
      'downloaded': 0,
      'bytes': 1024,
      'ready': false,
    };
    harness.api.bloatStream = (_) =>
        Stream.error(StateError('download exploded'));
    await pumpApp(tester, harness: harness);

    await tester.tap(find.byKey(const ValueKey('downloadBloat')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'Bloat download failed: Bad state: download exploded',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('downloadBloat')), findsOneWidget);
  });

  testWidgets('build gating reports a missing OTA when bloat is ready', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(gating(tester), 'Select a full TARGET OTA ZIP before continuing.');
    expect(tooltip(tester), gating(tester));
  });

  testWidgets('X9U requires an ABL choice before building', (tester) async {
    await pumpApp(tester);
    await chooseDevice(tester, 'OPPO Find X9 Ultra');

    expect(find.text('Vulnerable ABL'), findsOneWidget);
    expect(
      gating(tester),
      'Step 4: choose Yes or No for vulnerable ABL before continuing.',
    );

    await tester.tap(find.byKey(const ValueKey('ablYes')));
    await tester.pumpAndSettle();
    expect(find.text('ABL 16.0.6 will be packed.'), findsOneWidget);
    expect(gating(tester), 'Select a full TARGET OTA ZIP before continuing.');

    await tester.tap(find.byKey(const ValueKey('ablNo')));
    await tester.pumpAndSettle();
    expect(find.text('The OTA’s ABL will be kept.'), findsOneWidget);
  });

  testWidgets('Ace 6T catalog gating shows the exact ODM patch error', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.catalog = {
      'api_version': '1',
      'releases': [
        {
          'id': 'target-1',
          'device': 'OP 15R',
          'region': 'GLO',
          'version': 'CPH2649_11.A.30',
          'source_url': 'https://example.test/target.zip',
          'security_patch': '2025-10-01',
          'model': 'CPH2649',
          'size': 16 * 1024 * 1024 * 1024,
          'is_latest': true,
        },
      ],
    };
    await pumpApp(tester, harness: harness);
    await chooseDevice(tester, 'OnePlus Ace 6T');
    await tester.tap(find.text('Version catalog'));
    await tester.pumpAndSettle();

    expect(
      gating(tester),
      'No Ace 6T CN OTA has security patch 2025-10-01. Choose a target with '
      'an exact patch match; a different ODM will not be substituted.',
    );
    expect(
      find.textContaining('ODM unavailable: no exact patch match.'),
      findsWidgets,
    );
  });

  testWidgets('catalog lists versions newest first with details', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.catalog = {
      'api_version': '1',
      'releases': [
        {
          'id': 'older',
          'device': 'OP 13',
          'region': 'GLO',
          'version': 'CPH2647_11.A.20',
          'source_url': 'https://example.test/older.zip',
          'security_patch': '2025-08-01',
          'model': 'CPH2647',
          'size': 14 * 1024 * 1024 * 1024,
        },
        {
          'id': 'newest',
          'device': 'OP 13',
          'region': 'GLO',
          'version': 'CPH2647_11.A.30',
          'source_url': 'https://example.test/newest.zip',
          'security_patch': '2025-09-01',
          'model': 'CPH2647',
          'size': 15 * 1024 * 1024 * 1024,
          'is_latest': true,
        },
      ],
    };
    await pumpApp(tester, harness: harness);
    await tester.tap(find.text('Version catalog'));
    await tester.pumpAndSettle();

    expect(find.textContaining('OP 13 / GLO: 2 versions'), findsOneWidget);
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byKey(const ValueKey('catalog-ota')),
    );
    expect(dropdown.value, 'newest');
    final newest = dropdown.items!.first.child as Text;
    expect(newest.data, 'CPH2647_11.A.30 · Latest');

    final detail = tester.widget<Text>(
      find.byKey(const ValueKey('catalogDetail-ota')),
    );
    expect(detail.data, contains('OP 13 / GLO'));
    expect(detail.data, contains('CPH2647'));
    expect(detail.data, contains('15.00 GiB'));
    expect(detail.data, contains('Patch 2025-09-01'));

    await tester.tap(find.byKey(const ValueKey('fetchVersions')));
    await tester.pumpAndSettle();
  });
}
