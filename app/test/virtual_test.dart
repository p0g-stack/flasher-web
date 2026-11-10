import 'dart:async';

import 'package:flasher_web/api/platform_bridge.dart';
import 'package:flasher_web/flash/flash_controller.dart';
import 'package:flasher_web/flash/flash_page.dart';
import 'package:flasher_web/flash/flash_target.dart';
import 'package:flasher_web/setup/export_controller.dart';
import 'package:flasher_web/setup/setup_state.dart';
import 'package:flasher_web/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake.dart';

const _serial = 'SERIAL123';
const _virtualJob = 'virtual-0123456789abcdef';

Map<String, Object?> _inspection() => {
  'version': 'CPH2647_11.A.30',
  'length': 1024,
  'partitions': {'boot': 10},
  'fields': {'pre-device': 'CPH2647'},
};

Map<String, Object?> _virtualPrepare({String job = _virtualJob}) => {
  'token': 'token-virtual',
  'serial': _serial,
  'product': 'OP13',
  'expectedProduct': 'OP13',
  'productMatches': true,
  'mode': 'bootloader',
  'modeOk': true,
  'resolved': true,
  'job': job,
  'format': 'virtual',
  'version': 'CPH2647_11.A.30',
  'steps': ['Require bootloader', 'Flash boot from the OTA'],
  'executionSteps': ['Require bootloader', 'Flash boot from the OTA'],
  'confirmation': ['Flash Oneplus 13, serial $_serial'],
  'prompts': <Map<String, Object?>>[],
  'warnings': <String>[],
};

FlashTarget _virtualTarget(
  Object otaFile, {
  Map<String, Object?>? base,
  Map<String, Object?>? bloat,
}) => FlashTarget(
  ota: {'kind': 'file', 'file': otaFile},
  base: base,
  bloat: bloat ?? const {'kind': 'opfs'},
  selection: const {
    'device': 'Oneplus 13',
    'kind': 'Regional Flasher',
    'region': 'GLO',
  },
  label: 'Oneplus 13 / Regional Flasher',
);

Future<void> _chooseRegional(WidgetTester tester) async {
  await chooseKind(tester, 'Regional Flasher');
}

Future<void> _selectDevice(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('chooseDevice')));
  await tester.tap(find.byKey(const ValueKey('chooseDevice')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('granted-$_serial')));
  await tester.pumpAndSettle();
}

Future<void> _confirmAndFlash(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('confirmFlashDevice')));
  await tester.tap(find.byKey(const ValueKey('confirmFlashDevice')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const ValueKey('startFlash')));
  await tester.tap(find.byKey(const ValueKey('startFlash')));
  await tester.pump();
}

Future<FlashController> _pumpVirtualFlash(
  WidgetTester tester,
  Harness harness,
  FlashTarget target,
) async {
  await tester.binding.setSurfaceSize(const Size(1440, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = FlashController(
    api: harness.api,
    bridge: harness.bridge,
    environment: harness.environment,
    target: target,
    upstreamBase: 'upstream/',
  );
  addTearDown(controller.dispose);
  await controller.start();
  await tester.pumpWidget(
    MaterialApp(
      theme: themeFor(Brightness.light),
      home: Scaffold(
        body: FlashPage(controller: controller, onBack: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  test('a virtual target names no output or hosted source', () {
    final target = _virtualTarget(Object());
    expect(target.virtualOta['kind'], 'file');
    expect(target.virtualBloat, {'kind': 'opfs'});
    expect(target.virtualRequest, {
      'ota': {'kind': 'file', 'file': target.virtualOta['file']},
      'bloat': {'kind': 'opfs'},
    });
    expect(target.virtualRequest.containsKey('base'), isFalse);
  });

  test('a virtual conversion target carries its BASE OTA', () {
    final ota = Object();
    final base = Object();
    final target = _virtualTarget(ota, base: {'kind': 'file', 'file': base});
    expect(target.virtualBase, {'kind': 'file', 'file': base});
    expect(target.virtualRequest, {
      'ota': {'kind': 'file', 'file': ota},
      'base': {'kind': 'file', 'file': base},
      'bloat': {'kind': 'opfs'},
    });
  });

  test('direct flash gating supports Super kinds and needs bloat and an OTA', (
    // The gates are pure setup-state facts.
  ) async {
    final harness = Harness();
    harness.api.inspectResult = _inspection();
    final setup = SetupState(
      runtime: harness.runtime,
      tables: harness.tables,
      environment: harness.environment,
      preferences: harness.preferences,
    );
    addTearDown(setup.dispose);
    await setup.refreshBloat(force: true);

    // The default selection is SuperHybrid Flasher: preparation now packs the
    // same sparse super image the normal build writes.
    expect(setup.kind, 'SuperHybrid Flasher');
    expect(setup.isSuperKind, isTrue);
    expect(setup.directFlashSupported, isTrue);
    expect(setup.directFlashUnavailable, isEmpty);
    expect(setup.canFlashDirect, isFalse);
    expect(
      setup.directFlashRequirementsError,
      'Select a full TARGET OTA ZIP before flashing directly.',
    );
    expect(setup.directFlashHint, contains('decodes the whole super image'));
    expect(setup.directFlashHint, contains('several minutes'));

    setup.selectKind('Regional Flasher');
    await pumpEventQueue();
    expect(setup.directFlashSupported, isTrue);
    expect(
      setup.directFlashRequirementsError,
      'Select a full TARGET OTA ZIP before flashing directly.',
    );
    expect(setup.directFlashHint, isNot(contains('several minutes')));

    harness.api.bloatStatusResult = const {
      'total': 2,
      'downloaded': 0,
      'bytes': 1024,
      'ready': false,
    };
    await setup.refreshBloat();
    expect(
      setup.directFlashRequirementsError,
      'Required bloat files must be downloaded and verified before flashing '
      'directly.',
    );

    harness.api.bloatStatusResult = const {
      'total': 2,
      'downloaded': 2,
      'bytes': 1024,
      'ready': true,
    };
    await setup.refreshBloat();
    final handle = Object();
    await setup.setLocalFile(
      'ota',
      PickedFile(handle: handle, name: 'regional.zip', size: 4096),
    );

    expect(setup.directFlashRequirementsError, isEmpty);
    expect(setup.canFlashDirect, isTrue);
    expect(setup.directFlashOta, {'kind': 'file', 'file': handle});
    expect(setup.directFlashBase, isNull);
    expect(setup.directFlashBloat, {'kind': 'opfs'});
  });

  test('an Ace 6 conversion requires the BASE OTA and exposes it', () async {
    final harness = Harness();
    harness.api.inspectResult = _inspection();
    final setup = SetupState(
      runtime: harness.runtime,
      tables: harness.tables,
      environment: harness.environment,
      preferences: harness.preferences,
    );
    addTearDown(setup.dispose);
    setup.selectDevice('Oneplus Ace 6');
    await pumpEventQueue();
    await setup.refreshBloat(force: true);

    expect(setup.kind, 'SuperHybrid Flasher');
    expect(setup.region, 'IN');
    expect(setup.needsBase, isTrue);
    expect(setup.directFlashSupported, isTrue);

    final ota = Object();
    await setup.setLocalFile(
      'ota',
      PickedFile(handle: ota, name: 'target.zip', size: 4096),
    );
    expect(
      setup.directFlashRequirementsError,
      'Select a full BASE OTA ZIP before flashing directly.',
    );
    expect(setup.canFlashDirect, isFalse);
    expect(setup.directFlashBase, isNull);

    final base = Object();
    await setup.setLocalFile(
      'base',
      PickedFile(handle: base, name: 'base.zip', size: 4096),
    );
    expect(setup.directFlashRequirementsError, isEmpty);
    expect(setup.canFlashDirect, isTrue);
    expect(setup.directFlashOta, {'kind': 'file', 'file': ota});
    expect(setup.directFlashBase, {'kind': 'file', 'file': base});
  });

  test('catalog direct flash keeps the Ace 6T ODM patch gate', () async {
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
    final setup = SetupState(
      runtime: harness.runtime,
      tables: harness.tables,
      environment: harness.environment,
      preferences: harness.preferences,
    );
    addTearDown(setup.dispose);
    setup.selectDevice('Oneplus Ace 6T');
    await pumpEventQueue();
    await setup.refreshBloat(force: true);
    setup.setOtaMode(OtaMode.catalog);
    await pumpEventQueue();
    await setup.fetchCatalog(force: true);
    await pumpEventQueue();

    expect(setup.needsMatchedOdm, isTrue);
    expect(setup.directFlashSupported, isTrue);
    expect(setup.selectedRelease('ota'), isNotNull);
    expect(setup.odmDonor, isNull);
    expect(
      setup.directFlashRequirementsError,
      'No Ace 6T CN OTA has security patch 2025-10-01. Choose a target with '
      'an exact patch match; a different ODM will not be substituted.',
    );
    expect(setup.canFlashDirect, isFalse);
  });

  testWidgets(
    'a Super selection shows Flash directly and explains the decode',
    (tester) async {
      final harness = Harness();
      harness.api.inspectResult = _inspection();
      final handle = Object();
      harness.bridge.otaFile = PickedFile(
        handle: handle,
        name: 'super.zip',
        size: 4096,
      );
      await pumpApp(tester, harness: harness);

      expect(find.byKey(const ValueKey('flashDirectNotice')), findsNothing);
      final button = find.byKey(const ValueKey('flashDirectButton'));
      expect(button, findsOneWidget);

      final chooseOta = find.byKey(const ValueKey('chooseOtaFile'));
      await tester.ensureVisible(chooseOta);
      await tester.tap(chooseOta);
      await tester.pumpAndSettle();

      final tooltip = tester.widget<Tooltip>(
        find.byKey(const ValueKey('directFlashHint')),
      );
      expect(tooltip.message, contains('decodes the whole super image once'));
      expect(tooltip.message, contains('several minutes'));

      final kind = find.byKey(const ValueKey('kindDropdown'));
      await tester.ensureVisible(kind);
      await tester.pumpAndSettle();
      await _chooseRegional(tester);
      final regional = tester.widget<Tooltip>(
        find.byKey(const ValueKey('directFlashHint')),
      );
      expect(regional.message, isNot(contains('several minutes')));
    },
  );

  testWidgets('Flash directly opens the flash page with the OTA and bloat', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.inspectResult = _inspection();
    harness.api.prepareFlashResult = (_) => _virtualPrepare();
    harness.bridge.fastbootChoices.add((serial: _serial, label: 'Oneplus 13'));
    final handle = Object();
    harness.bridge.otaFile = PickedFile(
      handle: handle,
      name: 'regional.zip',
      size: 4096,
    );
    await pumpApp(tester, harness: harness);
    await _chooseRegional(tester);
    await tester.tap(find.byKey(const ValueKey('chooseOtaFile')));
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('flashDirectButton'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('flashStatus')), findsOneWidget);
    expect(find.textContaining('OTA read in place'), findsOneWidget);
    expect(find.textContaining('Back to setup'), findsWidgets);

    await _selectDevice(tester);
    final prepare = harness.api.lastPrepareRequest!;
    expect(prepare.containsKey('output'), isFalse);
    expect(prepare.containsKey('hosted'), isFalse);
    expect(prepare.containsKey('job'), isFalse);
    expect(prepare['selection'], {
      'device': 'Oneplus 13',
      'kind': 'Regional Flasher',
      'region': 'GLO',
    });
    final virtual = Map<String, Object?>.from(prepare['virtual']! as Map);
    expect(virtual['ota'], {'kind': 'file', 'file': handle});
    expect(virtual['bloat'], {'kind': 'opfs'});
    expect(find.text(_virtualJob), findsWidgets);
  });

  testWidgets('Ace 6 sends the BASE OTA as virtual.base', (tester) async {
    final harness = Harness();
    harness.api.inspectResult = _inspection();
    harness.api.prepareFlashResult = (_) => _virtualPrepare();
    harness.bridge.fastbootChoices.add((
      serial: _serial,
      label: 'Oneplus Ace 6',
    ));
    await pumpApp(tester, harness: harness);
    await chooseDevice(tester, 'OnePlus Ace 6');

    expect(find.byKey(const ValueKey('chooseBaseFile')), findsOneWidget);
    final baseHandle = Object();
    final targetHandle = Object();
    final chooseBase = find.byKey(const ValueKey('chooseBaseFile'));
    await tester.ensureVisible(chooseBase);
    harness.bridge.otaFile = PickedFile(
      handle: baseHandle,
      name: 'base.zip',
      size: 4096,
    );
    await tester.tap(chooseBase);
    await tester.pumpAndSettle();

    final chooseOta = find.byKey(const ValueKey('chooseOtaFile'));
    await tester.ensureVisible(chooseOta);
    harness.bridge.otaFile = PickedFile(
      handle: targetHandle,
      name: 'target.zip',
      size: 4096,
    );
    await tester.tap(chooseOta);
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('flashDirectButton'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    await _selectDevice(tester);
    final prepare = harness.api.lastPrepareRequest!;
    expect(prepare['selection'], {
      'device': 'Oneplus Ace 6',
      'kind': 'SuperHybrid Flasher',
      'region': 'IN',
    });
    final virtual = Map<String, Object?>.from(prepare['virtual']! as Map);
    expect(virtual['ota'], {'kind': 'file', 'file': targetHandle});
    expect(virtual['base'], {'kind': 'file', 'file': baseHandle});
    expect(virtual['bloat'], {'kind': 'opfs'});
    expect(virtual.containsKey('donor'), isFalse);
  });

  testWidgets('execution echoes the derived virtual job and the same source', (
    tester,
  ) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>();
    addTearDown(events.close);
    harness.api.prepareFlashResult = (_) => _virtualPrepare();
    harness.api.flashStream = (_) => events.stream;
    final handle = Object();
    final target = _virtualTarget(handle);
    final controller = await _pumpVirtualFlash(tester, harness, target);
    await _selectDevice(tester);

    final prepare = harness.api.lastPrepareRequest!;
    expect(prepare.containsKey('output'), isFalse);
    expect(Map<String, Object?>.from(prepare['virtual']! as Map)['ota'], {
      'kind': 'file',
      'file': handle,
    });

    await _confirmAndFlash(tester);
    final flash = harness.api.lastFlashRequest!;
    expect(flash['job'], _virtualJob);
    expect(flash['confirmationToken'], 'token-virtual');
    expect(flash.containsKey('output'), isFalse);
    final virtual = Map<String, Object?>.from(flash['virtual']! as Map);
    expect(identical((virtual['ota']! as Map)['file'], handle), isTrue);
    expect(virtual['bloat'], {'kind': 'opfs'});

    events.add({
      'type': 'result',
      'status': 'succeeded',
      'receipt': {
        'status': 'succeeded',
        'serial': _serial,
        'device': 'Oneplus 13',
        'job': _virtualJob,
        'persistenceWarnings': <String>[],
        'steps': <Map<String, Object?>>[],
      },
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('flashReceipt')), findsOneWidget);
    expect(find.textContaining('flashed in place'), findsWidgets);
    expect(controller.receiptPath, contains('browser download'));
  });

  test('a changed OTA invalidates the prepared token', () async {
    final harness = Harness();
    harness.api.prepareFlashResult = (_) => _virtualPrepare();
    final ota = <String, Object?>{'kind': 'file', 'file': Object()};
    final target = FlashTarget(
      ota: ota,
      bloat: const {'kind': 'opfs'},
      selection: const {
        'device': 'Oneplus 13',
        'kind': 'Regional Flasher',
        'region': 'GLO',
      },
      label: 'Oneplus 13 / Regional Flasher',
    );
    final controller = FlashController(
      api: harness.api,
      bridge: harness.bridge,
      environment: harness.environment,
      target: target,
      upstreamBase: 'upstream/',
    );
    addTearDown(controller.dispose);
    await controller.start();
    controller.selectDevice({
      'serial': _serial,
      'label': 'Oneplus 13',
      'transport': 'usb',
    });
    await pumpEventQueue();
    expect(controller.ready, isTrue);
    controller.setAcknowledged(true);
    expect(controller.canFlash, isTrue);

    ota['file'] = Object();
    await controller.flash();

    expect(harness.api.flashCalls, 0);
    expect(controller.errorText, contains('confirmed input changed'));
  });

  test('a changed BASE OTA invalidates the prepared token', () async {
    final harness = Harness();
    harness.api.prepareFlashResult = (_) => _virtualPrepare();
    final baseFile = Object();
    final base = <String, Object?>{'kind': 'file', 'file': baseFile};
    final target = _virtualTarget(Object(), base: base);
    final controller = FlashController(
      api: harness.api,
      bridge: harness.bridge,
      environment: harness.environment,
      target: target,
      upstreamBase: 'upstream/',
    );
    addTearDown(controller.dispose);
    await controller.start();
    controller.selectDevice({
      'serial': _serial,
      'label': 'Oneplus 13',
      'transport': 'usb',
    });
    await pumpEventQueue();
    expect(
      harness.api.lastPrepareRequest?['virtual'],
      containsPair('base', {'kind': 'file', 'file': baseFile}),
    );
    expect(controller.ready, isTrue);
    controller.setAcknowledged(true);
    expect(controller.canFlash, isTrue);

    base['file'] = Object();
    await controller.flash();

    expect(harness.api.flashCalls, 0);
    expect(controller.errorText, contains('confirmed input changed'));
  });

  test('execution echoes the same BASE OTA identity', () async {
    final harness = Harness();
    harness.api.prepareFlashResult = (_) => _virtualPrepare();
    final baseFile = Object();
    final target = _virtualTarget(
      Object(),
      base: {'kind': 'file', 'file': baseFile},
    );
    final controller = FlashController(
      api: harness.api,
      bridge: harness.bridge,
      environment: harness.environment,
      target: target,
      upstreamBase: 'upstream/',
    );
    addTearDown(controller.dispose);
    await controller.start();
    controller.selectDevice({
      'serial': _serial,
      'label': 'Oneplus 13',
      'transport': 'usb',
    });
    await pumpEventQueue();
    controller.setAcknowledged(true);
    expect(controller.canFlash, isTrue);

    await controller.flash();

    final virtual = Map<String, Object?>.from(
      harness.api.lastFlashRequest!['virtual']! as Map,
    );
    expect(identical((virtual['base']! as Map)['file'], baseFile), isTrue);
  });

  test('exporting a virtual package streams into the save handle', () async {
    final harness = Harness();
    harness.api.exportVirtualStream = (_) => Stream.fromIterable([
      {'type': 'progress', 'label': 'ZIP', 'done': 1, 'total': 2},
      {'type': 'result', 'job': _virtualJob, 'sha256': 'abc123', 'bytes': 10},
    ]);
    final controller = ExportController(
      api: harness.api,
      bridge: harness.bridge,
      upstreamBase: 'upstream/',
    );
    addTearDown(controller.dispose);
    final handle = Object();

    final message = await controller.export(
      virtual: {
        'ota': {'kind': 'file', 'file': handle},
        'bloat': {'kind': 'opfs'},
      },
      selection: const {
        'device': 'Oneplus 13',
        'kind': 'Regional Flasher',
        'region': 'GLO',
      },
      label: 'Oneplus 13 Regional Flasher Global',
    );

    expect(message, isNull);
    expect(harness.bridge.pickSaveFileCalls, 1);
    final request = harness.api.lastExportRequest!;
    expect(request['selection'], {
      'device': 'Oneplus 13',
      'kind': 'Regional Flasher',
      'region': 'GLO',
    });
    expect(request['upstreamBase'], 'upstream/');
    expect(
      identical(request['destination'], harness.bridge.saveFileResult),
      isTrue,
    );
    final virtual = Map<String, Object?>.from(request['virtual']! as Map);
    expect(identical((virtual['ota']! as Map)['file'], handle), isTrue);
    expect(virtual['bloat'], {'kind': 'opfs'});
    expect(virtual.containsKey('base'), isFalse);
    expect(controller.result?['sha256'], 'abc123');
    expect(controller.exporting, isFalse);
  });

  test('exporting a conversion package streams the BASE OTA', () async {
    final harness = Harness();
    harness.api.exportVirtualStream = (_) => Stream.fromIterable([
      {'type': 'result', 'job': _virtualJob, 'sha256': 'abc123', 'bytes': 10},
    ]);
    final controller = ExportController(
      api: harness.api,
      bridge: harness.bridge,
      upstreamBase: 'upstream/',
    );
    addTearDown(controller.dispose);
    final handle = Object();
    final baseHandle = Object();

    final message = await controller.export(
      virtual: {
        'ota': {'kind': 'file', 'file': handle},
        'base': {'kind': 'file', 'file': baseHandle},
        'bloat': {'kind': 'opfs'},
      },
      selection: const {
        'device': 'Oneplus Ace 6',
        'kind': 'SuperHybrid Flasher',
        'region': 'IN',
      },
      label: 'OnePlus Ace 6 SuperHybrid Flasher India',
    );

    expect(message, isNull);
    final request = harness.api.lastExportRequest!;
    expect(request['selection'], {
      'device': 'Oneplus Ace 6',
      'kind': 'SuperHybrid Flasher',
      'region': 'IN',
    });
    final virtual = Map<String, Object?>.from(request['virtual']! as Map);
    expect(virtual['ota'], {'kind': 'file', 'file': handle});
    expect(virtual['base'], {'kind': 'file', 'file': baseHandle});
    expect(virtual['bloat'], {'kind': 'opfs'});
  });

  testWidgets('a launched file becomes the local OTA choice', (tester) async {
    final harness = Harness();
    harness.api.inspectResult = _inspection();
    await pumpApp(tester, harness: harness);

    final handle = Object();
    harness.bridge.launch(
      PickedFile(handle: handle, name: 'launched.zip', size: 4096),
    );
    await tester.pumpAndSettle();

    expect(find.text('launched.zip'), findsOneWidget);
    expect(harness.api.lastInspectRequest?['ota'], {
      'kind': 'file',
      'file': handle,
    });
  });

  testWidgets('a remembered OTA is restored after a reload', (tester) async {
    final harness = Harness();
    harness.api.inspectResult = _inspection();
    harness.bridge.rememberedOta = PickedFile(
      handle: Object(),
      name: 'remembered.zip',
      size: 4096,
    );
    await pumpApp(tester, harness: harness);

    expect(find.text('remembered.zip'), findsOneWidget);
  });

  testWidgets('a remembered OTA asks for read permission again', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.inspectResult = _inspection();
    harness.bridge.rememberedOta = PickedFile(
      handle: Object(),
      name: 'remembered.zip',
      size: 4096,
    );
    harness.bridge.otaPermissionGranted = false;
    await pumpApp(tester, harness: harness);

    final reconnect = find.byKey(const ValueKey('reconnectOtaFile'));
    expect(reconnect, findsOneWidget);
    expect(find.textContaining('Reconnect remembered.zip'), findsOneWidget);
    await tester.ensureVisible(reconnect);
    await tester.tap(reconnect);
    await tester.pumpAndSettle();

    expect(find.text('remembered.zip'), findsOneWidget);
  });

  testWidgets('the environment page shows the budget and evicts a cached OTA', (
    tester,
  ) async {
    const digest =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final harness = Harness();
    harness.api.storageBudgetResult = const {
      'cap': 10 * 1024 * 1024 * 1024,
      'usage': 3 * 1024 * 1024 * 1024,
      'quota': 64 * 1024 * 1024 * 1024,
      'available': 7 * 1024 * 1024 * 1024,
      'items': [
        {
          'key': digest,
          'label': 'OP 13 / GLO / CPH2647_11.A.30',
          'bytes': 4 * 1024 * 1024 * 1024,
          'complete': true,
          'lastUsed': '2026-11-01T00:00:00Z',
        },
      ],
    };
    await pumpApp(tester, harness: harness);

    await tester.tap(find.text('Environment').first);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('storageBudgetBar')), findsOneWidget);
    expect(find.textContaining('OP 13 / GLO'), findsOneWidget);
    expect(find.textContaining('complete'), findsWidgets);

    final evict = find.byKey(const ValueKey('evict-$digest'));
    await tester.ensureVisible(evict);
    await tester.tap(evict);
    await tester.pumpAndSettle();

    expect(harness.api.evictCalls, 1);
    expect(harness.api.lastEvictRequest?['key'], digest);
    expect(harness.api.lastEvictRequest?['store'], {'kind': 'opfs'});
  });

  testWidgets('a catalog OTA downloads into the app cache from the dialog', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.catalog = _catalogOf(4 * 1024 * 1024 * 1024);
    harness.api.cacheOtaStream = (_) => Stream.fromIterable(const [
      {
        'type': 'result',
        'key': 'b',
        'label': 'OP 13 / GLO',
        'bytes': 4 * 1024 * 1024 * 1024,
        'complete': true,
      },
    ]);
    await pumpApp(tester, harness: harness);
    await _chooseRegional(tester);
    await tester.tap(find.text('Version catalog'));
    await tester.pumpAndSettle();

    await _openDownloadDialog(tester);
    await tester.tap(find.byKey(const ValueKey('downloadOtaCache')));
    await tester.pumpAndSettle();

    final request = harness.api.lastCacheOtaRequest!;
    expect(request['store'], {'kind': 'opfs'});
    final ota = Map<String, Object?>.from(request['ota']! as Map);
    expect(ota['kind'], 'catalog');
    expect((ota['entry']! as Map)['id'], 'regional-1');
    expect(harness.bridge.keepAwake, 0, reason: 'the wake lock is released');
  });

  testWidgets('a cached OTA that does not fit is not offered', (tester) async {
    final harness = Harness();
    harness.api.storageBudgetResult = const {
      'cap': 10 * 1024 * 1024 * 1024,
      'usage': 9 * 1024 * 1024 * 1024,
      'quota': 64 * 1024 * 1024 * 1024,
      'available': 1 * 1024 * 1024 * 1024,
      'items': <Map<String, Object?>>[],
    };
    harness.api.catalog = _catalogOf(4 * 1024 * 1024 * 1024);
    await pumpApp(tester, harness: harness);
    await _chooseRegional(tester);
    await tester.tap(find.text('Version catalog'));
    await tester.pumpAndSettle();

    await _openDownloadDialog(tester);
    final cache = tester.widget<ListTile>(
      find.byKey(const ValueKey('downloadOtaCache')),
    );
    expect(cache.enabled, isFalse);
    expect(find.textContaining('Does not fit the remaining'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('downloadOtaCache')));
    await tester.pumpAndSettle();
    expect(harness.api.lastCacheOtaRequest, isNull);
  });

  testWidgets('a catalog OTA saved to this computer becomes the local OTA', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.catalog = _catalogOf(4 * 1024 * 1024 * 1024);
    harness.api.inspectResult = _inspection();
    const saved = PickedFile(
      handle: 'saved-file',
      name: 'regional.zip',
      size: 4 * 1024 * 1024 * 1024,
    );
    harness.bridge.savedOta = saved;
    harness.api.saveOtaStream = (_) => Stream.fromIterable(const [
      {'type': 'started', 'label': 'OP 13 / GLO', 'total': 10},
      {'type': 'progress', 'label': 'OP 13 / GLO', 'done': 10, 'total': 10},
      {'type': 'result', 'label': 'OP 13 / GLO', 'bytes': 10, 'sha256': 'a'},
    ]);
    await pumpApp(tester, harness: harness);
    await _chooseRegional(tester);
    await tester.tap(find.text('Version catalog'));
    await tester.pumpAndSettle();

    await _openDownloadDialog(tester);
    await tester.tap(find.byKey(const ValueKey('downloadOtaComputer')));
    await tester.pumpAndSettle();

    expect(harness.bridge.saveFileNames, ['regional.zip']);
    final request = harness.api.lastSaveOtaRequest!;
    expect(request['destination'], harness.bridge.saveFileResult);
    expect((request['ota']! as Map)['kind'], 'catalog');
    expect(harness.bridge.openedSavedOtas, ['save-destination|remember=true']);
    expect(harness.bridge.rememberedOta, same(saved));
    expect(harness.api.lastInspectRequest?['ota'], {
      'kind': 'file',
      'file': 'saved-file',
    });
    expect(find.text('regional.zip'), findsWidgets);
    expect(harness.bridge.keepAwake, 0, reason: 'the wake lock is released');
    expect(
      harness.bridge.otaSave,
      isNull,
      reason: 'a finished save is forgotten',
    );
  });

  testWidgets('an unfinished save resumes into the same file after a reload', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.catalog = _catalogOf(4 * 1024 * 1024 * 1024);
    harness.api.inspectResult = _inspection();
    harness.api.saveOtaStream = (_) async* {
      yield {'type': 'started', 'label': 'OP 13 / GLO', 'total': 10};
      yield {
        'type': 'progress',
        'label': 'OP 13 / GLO',
        'done': 4,
        'total': 10,
      };
      throw StateError('network gone');
    };
    await pumpApp(tester, harness: harness);
    await _chooseRegional(tester);
    await tester.tap(find.text('Version catalog'));
    await tester.pumpAndSettle();
    await _openDownloadDialog(tester);
    await tester.tap(find.byKey(const ValueKey('downloadOtaComputer')));
    await tester.pumpAndSettle();

    expect(harness.bridge.otaSave?.destination, harness.bridge.saveFileResult);
    expect(find.byKey(const ValueKey('otaDownloadError-ota')), findsOneWidget);

    // A reload: a fresh app over the same browser state.
    await tester.pumpWidget(const SizedBox());
    harness.api.lastSaveOtaRequest = null;
    const saved = PickedFile(
      handle: 'saved-file',
      name: 'regional.zip',
      size: 10,
    );
    harness.bridge.savedOta = saved;
    harness.api.saveOtaStream = (_) => Stream.fromIterable(const [
      {
        'type': 'started',
        'label': 'OP 13 / GLO',
        'total': 10,
        'resumedFrom': 4,
      },
      {'type': 'result', 'label': 'OP 13 / GLO', 'bytes': 10, 'sha256': 'a'},
    ]);
    await pumpApp(tester, harness: harness);
    await _chooseRegional(tester);
    await tester.tap(find.text('Version catalog'));
    await tester.pumpAndSettle();

    final resume = find.byKey(const ValueKey('resumeOtaSave-ota'));
    await tester.ensureVisible(resume);
    await tester.tap(resume);
    await tester.pumpAndSettle();

    expect(harness.bridge.pickSaveFileCalls, 1, reason: 'no second picker');
    final request = harness.api.lastSaveOtaRequest!;
    expect(request['destination'], harness.bridge.saveFileResult);
    expect((request['ota']! as Map)['kind'], 'catalog');
    expect(harness.bridge.otaSave, isNull);
    expect(harness.bridge.rememberedOta, same(saved));
    expect(find.byKey(const ValueKey('resumeOtaSave-ota')), findsNothing);
  });

  testWidgets('a refused write permission does not start the resumed save', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.catalog = _catalogOf(4 * 1024 * 1024 * 1024);
    harness.bridge.otaSave = (
      destination: 'old-file',
      request: {
        'role': 'ota',
        'ota': {'kind': 'catalog'},
        'suggestedName': 'regional.zip',
      },
    );
    harness.bridge.grantOtaSave = false;
    await pumpApp(tester, harness: harness);
    await _chooseRegional(tester);
    await tester.tap(find.text('Version catalog'));
    await tester.pumpAndSettle();

    final resume = find.byKey(const ValueKey('resumeOtaSave-ota'));
    await tester.ensureVisible(resume);
    await tester.tap(resume);
    await tester.pumpAndSettle();

    expect(harness.api.lastSaveOtaRequest, isNull);
    expect(find.textContaining('did not allow writing'), findsOneWidget);
    expect(harness.bridge.otaSave, isNotNull, reason: 'still resumable');

    await tester.tap(find.byKey(const ValueKey('discardOtaSave-ota')));
    await tester.pumpAndSettle();
    expect(harness.bridge.otaSave, isNull);
    expect(find.byKey(const ValueKey('resumeOtaSave-ota')), findsNothing);
  });

  testWidgets('a cancelled save picker starts no download', (tester) async {
    final harness = Harness();
    harness.api.catalog = _catalogOf(4 * 1024 * 1024 * 1024);
    harness.bridge.saveFileResult = null;
    await pumpApp(tester, harness: harness);
    await _chooseRegional(tester);
    await tester.tap(find.text('Version catalog'));
    await tester.pumpAndSettle();

    await _openDownloadDialog(tester);
    await tester.tap(find.byKey(const ValueKey('downloadOtaComputer')));
    await tester.pumpAndSettle();

    expect(harness.bridge.pickSaveFileCalls, 1);
    expect(harness.api.lastSaveOtaRequest, isNull);
    expect(harness.bridge.keepAwake, 0);
  });
}

Map<String, dynamic> _catalogOf(int size) => {
  'api_version': '1',
  'releases': [
    {
      'id': 'regional-1',
      'device': 'OP 13',
      'region': 'GLO',
      'version': 'CPH2647_11.A.30',
      'source_url': 'https://example.test/regional.zip',
      'security_patch': '2025-09-01',
      'size': size,
      'is_latest': true,
    },
  ],
};

Future<void> _openDownloadDialog(WidgetTester tester) async {
  final download = find.byKey(const ValueKey('downloadOta-ota'));
  expect(download, findsOneWidget);
  await tester.ensureVisible(download);
  await tester.tap(download);
  await tester.pumpAndSettle();
}
