import 'dart:async';

import 'package:flasher_web/api/platform_bridge.dart';
import 'package:flasher_web/flash/flash_controller.dart';
import 'package:flasher_web/flash/flash_page.dart';
import 'package:flasher_web/flash/flash_target.dart';
import 'package:flasher_web/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake.dart';

const _serial = 'SERIAL123';
const _phone = FastbootUsbDevice(serial: _serial, label: 'Realme NEO8');

FlashTarget flashTarget() => FlashTarget(
  ota: {'kind': 'file', 'file': Object()},
  bloat: const {'kind': 'opfs'},
  selection: const {
    'device': 'Realme NEO8',
    'kind': 'Super Flasher',
    'region': 'CN',
  },
  label: 'Realme NEO8 / Super Flasher',
);

Map<String, Object?> resolvedPrepare({
  String? token = 'token-1',
  List<Map<String, Object?>> prompts = const [],
}) => {
  'token': ?token,
  'serial': _serial,
  'product': 'REALME_NEO8',
  'expectedProduct': 'REALME_NEO8',
  'productMatches': true,
  'mode': 'bootloader',
  'modeOk': true,
  'resolved': true,
  'job': '20260101-000000-abcdef',
  'format': 'zip',
  'version': 'CPH123_11.A.01',
  'steps': ['Require bootloader', 'Flash boot from boot.img'],
  'executionSteps': ['Require bootloader', 'Flash boot from boot.img'],
  'confirmation': [
    'Flash Realme NEO8, serial $_serial, product REALME_NEO8',
    'Flash boot from boot.img',
  ],
  'prompts': prompts,
  'warnings': <String>[],
};

Map<String, Object?> unresolvedPrepare() => {
  'serial': _serial,
  'product': 'REALME_NEO8',
  'expectedProduct': 'REALME_NEO8',
  'productMatches': true,
  'mode': 'bootloader',
  'modeOk': true,
  'resolved': false,
  'job': '20260101-000000-abcdef',
  'format': 'zip',
  'version': 'CPH123_11.A.01',
  'steps': ['Require bootloader', 'Do you want to wipe data? (unanswered)'],
  'prompts': [
    {
      'id': 'wipe',
      'question': 'Do you want to wipe data?',
      'choices': ['wipe', 'reboot'],
      'selected': null,
    },
  ],
  'warnings': <String>[],
};

Future<FlashController> pumpFlash(
  WidgetTester tester,
  Harness harness, {
  FlashTarget? target,
}) async {
  await tester.binding.setSurfaceSize(const Size(1440, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = FlashController(
    api: harness.api,
    bridge: harness.bridge,
    environment: harness.environment,
    target: target ?? flashTarget(),
    upstreamBase: 'https://upstream.test/',
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

Future<void> selectDevice(
  WidgetTester tester,
  FlashController controller,
) async {
  controller.selectDevice({
    'serial': _serial,
    'label': 'Realme NEO8',
    'transport': 'usb',
  });
  await tester.pumpAndSettle();
}

Future<void> confirmAndFlash(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('confirmFlashDevice')));
  await tester.tap(find.byKey(const ValueKey('confirmFlashDevice')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const ValueKey('startFlash')));
  await tester.tap(find.byKey(const ValueKey('startFlash')));
  await tester.pump();
}

void main() {
  testWidgets('the usb.web fact alone enables browser writes', (tester) async {
    final harness = Harness(
      environment: testEnvironment(facts: const ['fs.opfs', 'net']),
    );
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);

    expect(controller.writesSupported, isFalse);
    expect(controller.canFlash, isFalse);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('confirmFlashDevice')),
          )
          .onChanged,
      isNull,
    );
    expect(find.textContaining('no WebUSB support'), findsOneWidget);
    expect(harness.api.flashCalls, 0);
  });

  testWidgets('a resolved plan needs an explicit confirmation before writes', (
    tester,
  ) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>();
    addTearDown(events.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);

    final button = find.byKey(const ValueKey('startFlash'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(harness.api.flashCalls, 0);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('confirmFlashDevice')),
          )
          .onChanged,
      isNotNull,
    );

    await confirmAndFlash(tester);
    expect(harness.api.flashCalls, 1);
    expect(harness.api.lastFlashRequest?['confirmationToken'], 'token-1');
    expect(harness.api.lastFlashRequest?['serial'], _serial);
    expect(harness.bridge.keepAwake, 1);

    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    events.add({
      'type': 'result',
      'status': 'succeeded',
      'receipt': {
        'status': 'succeeded',
        'serial': _serial,
        'device': 'Realme NEO8',
        'product': 'REALME_NEO8',
        'job': '20260101-000000-abcdef',
        'version': '1',
        'steps': [
          {'index': 1, 'title': 'Require bootloader', 'status': 'ok'},
        ],
        'warnings': <String>[],
      },
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('flashReceipt')), findsOneWidget);
    expect(find.text('succeeded'), findsWidgets);
    expect(harness.bridge.keepAwake, 0);

    await tester.ensureVisible(
      find.byKey(const ValueKey('downloadFlashReceipt')),
    );
    await tester.tap(find.byKey(const ValueKey('downloadFlashReceipt')));
    await tester.pumpAndSettle();
    expect(
      harness.bridge.downloads,
      contains('flash-20260101-000000-abcdef-SERIAL123.json'),
    );
  });

  testWidgets('an unresolved prompt refuses execution and needs an answer', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.prepareFlashResult = (request) {
      final answers = request['answers'] as Map? ?? const {};
      if (answers['wipe'] == null) return unresolvedPrepare();
      return resolvedPrepare(
        prompts: [
          {
            'id': 'wipe',
            'question': 'Do you want to wipe data?',
            'choices': ['wipe', 'reboot'],
            'selected': answers['wipe'],
          },
        ],
      );
    };
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);

    expect(find.byKey(const ValueKey('answersIncomplete')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('startFlash')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('confirmFlashDevice')),
          )
          .onChanged,
      isNull,
    );
    expect(harness.api.flashCalls, 0);

    await tester.ensureVisible(find.byKey(const ValueKey('answer-wipe-wipe')));
    await tester.tap(find.byKey(const ValueKey('answer-wipe-wipe')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(harness.api.lastPrepareRequest?['answers'], {'wipe': 'wipe'});
    expect(harness.api.flashCalls, 0);
  });

  testWidgets('an unknown product needs an explicit override', (tester) async {
    final harness = Harness();
    harness.api.prepareFlashResult = (request) {
      final answers = request['answers'] as Map? ?? const {};
      if (answers['product'] == null) {
        return {
          'productRequired': true,
          'observedProduct': 'REALME_NEO8',
          'message': 'Check the model and explicitly type the observed product REALME_NEO8.',
        };
      }
      return resolvedPrepare();
    };
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);

    expect(
      find.byKey(const ValueKey('productOverrideRequired')),
      findsOneWidget,
    );
    expect(harness.api.flashCalls, 0);

    await tester.ensureVisible(find.byKey(const ValueKey('productOverride')));
    await tester.enterText(
      find.byKey(const ValueKey('productOverride')),
      'REALME_NEO8',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(harness.api.lastPrepareRequest?['answers'], {
      'product': 'REALME_NEO8',
    });
    expect(find.byKey(const ValueKey('flashPlan')), findsOneWidget);
  });

  testWidgets('product editing retains focus while invalidating confirmation', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    controller.setAcknowledged(true);
    final product = find.byKey(const ValueKey('productOverride'));
    await tester.ensureVisible(product);
    await tester.enterText(product, 'REALME_');
    await tester.pump();

    expect(product, findsOneWidget);
    expect(tester.widget<TextField>(product).focusNode!.hasFocus, isTrue);
    expect(controller.acknowledged, isFalse);
    expect(controller.canFlash, isFalse);
    await tester.enterText(product, 'REALME_NEO8');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(product).controller!.text, 'REALME_NEO8');
    expect(tester.widget<TextField>(product).focusNode!.hasFocus, isTrue);
  });

  testWidgets('an uncertain result explains the risk and releases the lock', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => Stream.fromIterable([
      {'type': 'step', 'index': 1, 'total': 2, 'title': 'Flash boot'},
      {
        'type': 'result',
        'status': 'uncertain',
        'receipt': {
          'status': 'uncertain',
          'serial': _serial,
          'device': 'Realme NEO8',
          'product': 'REALME_NEO8',
          'job': '20260101-000000-abcdef',
          'version': '1',
          'steps': [
            {'index': 1, 'title': 'Flash boot', 'status': 'uncertain'},
          ],
          'failure': {
            'name': 'LinkFailure',
            'message': 'Write reply lost',
            'stage': 'write',
            'uncertain': true,
          },
          'warnings': <String>[],
        },
      },
    ]);
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await confirmAndFlash(tester);
    await tester.pumpAndSettle();

    expect(controller.phase, FlashPhase.uncertain);
    expect(find.byKey(const ValueKey('flashGuidance')), findsOneWidget);
    expect(find.textContaining('Do not retry'), findsWidgets);
    expect(find.text('UNCERTAIN'), findsOneWidget);
    expect(harness.bridge.keepAwake, 0);
  });

  testWidgets('regranting a different serial is refused', (tester) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>(
      onCancel: () async {},
    );
    addTearDown(events.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await confirmAndFlash(tester);

    events.add({
      'type': 'waiting',
      'serial': _serial,
      'mode': 'fastbootd',
      'text': 'Waiting for $_serial to return in fastbootd.',
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('flashWaiting')), findsOneWidget);

    harness.bridge.fastbootChoices.add(
      const FastbootUsbDevice(serial: 'OTHER999', label: 'Wrong phone'),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('regrantDevice')));
    await tester.tap(find.byKey(const ValueKey('regrantDevice')));
    await tester.pump();

    expect(
      find.textContaining('Nothing was sent to the wrong device'),
      findsOneWidget,
    );
    expect(harness.api.flashCalls, 1);

    harness.bridge.fastbootChoices.add(_phone);
    await tester.tap(find.byKey(const ValueKey('regrantDevice')));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('regrantMessage')),
        matching: find.textContaining('granted again'),
      ),
      findsOneWidget,
    );

    unawaited(controller.cancel());
    await tester.pumpAndSettle();
    expect(harness.bridge.keepAwake, 0);
  });

  testWidgets('cancelling reports no rollback and releases the wake lock', (
    tester,
  ) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>(
      onCancel: () async {},
    );
    addTearDown(events.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await confirmAndFlash(tester);
    events.add({'type': 'step', 'index': 1, 'total': 2, 'title': 'Flash boot'});
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('cancelFlash')));
    await tester.tap(find.byKey(const ValueKey('cancelFlash')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(controller.phase, FlashPhase.cancelled);
    expect(find.byKey(const ValueKey('flashCancelNote')), findsOneWidget);
    expect(find.textContaining('No rollback'), findsWidgets);
    expect(harness.bridge.keepAwake, 0);
  });

  testWidgets(
    'cancellation keeps the guard until in-flight work acknowledges',
    (tester) async {
      final harness = Harness();
      final stopped = Completer<void>();
      final events = StreamController<Map<String, Object?>>(
        onCancel: () => stopped.future,
      );
      addTearDown(events.close);
      harness.api.prepareFlashResult = (_) => resolvedPrepare();
      harness.api.flashStream = (_) => events.stream;
      final controller = await pumpFlash(tester, harness);
      await selectDevice(tester, controller);
      await confirmAndFlash(tester);
      unawaited(controller.cancel());
      await tester.pump();
      expect(harness.bridge.keepAwake, 1);
      expect(controller.canFlash, isFalse);
      stopped.complete();
      await tester.pumpAndSettle();
      expect(harness.bridge.keepAwake, 0);
    },
  );

  testWidgets('input changed while acquiring the guard invalidates the write', (
    tester,
  ) async {
    final harness = Harness();
    final awake = Completer<void>();
    harness.bridge.keepAwakeGate = awake.future;
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    controller.setAcknowledged(true);
    final starting = controller.flash();
    await tester.pump();
    controller.setProductOverride('another-product');
    awake.complete();
    await starting;
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(harness.api.flashCalls, 0);
    expect(harness.bridge.keepAwake, 0);
    expect(controller.acknowledged, isFalse);
  });

  testWidgets('the chooser keeps its original error and explains cancelling', (
    tester,
  ) async {
    final harness = Harness();
    final controller = await pumpFlash(tester, harness);
    harness.bridge.fastbootChoices
      ..add(
        const FastbootUsbException(
          FastbootUsbFailure.permission,
          'The browser refused WebUSB permission.',
          'SecurityError: access denied',
        ),
      )
      ..add(null);

    await tester.ensureVisible(find.byKey(const ValueKey('chooseDevice')));
    await tester.tap(find.byKey(const ValueKey('chooseDevice')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chooseFastbootDevice')));
    await tester.pumpAndSettle();

    expect(find.textContaining('USB permission was refused'), findsOneWidget);
    expect(find.textContaining('SecurityError: access denied'), findsOneWidget);
    expect(controller.serial, isNull);

    await tester.tap(find.byKey(const ValueKey('chooseFastbootDevice')));
    await tester.pumpAndSettle();
    expect(find.textContaining('No device was chosen'), findsOneWidget);
    expect(harness.bridge.chooseFastbootCalls, 2);
  });

  testWidgets('a structured prepare error is guidance, not a plan', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.prepareFlashResult = (_) => {
      'error': {
        'blame': 'transport',
        'name': 'LinkFailure',
        'message': 'Device disappeared during getvar',
        'stage': 'prepare',
        'uncertain': false,
        'stack': 'trace',
        'causes': <String>['usb.read'],
        'cleanupErrors': <String>['close after prepare failed'],
      },
    };
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);

    expect(controller.prepared, isNull);
    expect(
      controller.prepareError,
      contains('Device disappeared during getvar'),
    );
    expect(controller.prepareError, contains('stage: prepare'));
    expect(controller.prepareError, contains('cleanup: close after prepare'));
    expect(find.byKey(const ValueKey('prepareError')), findsOneWidget);
    expect(find.byKey(const ValueKey('flashConfirmation')), findsNothing);
    expect(harness.api.flashCalls, 0);
  });

  testWidgets('a structured device error keeps its original evidence', (
    tester,
  ) async {
    final harness = Harness();
    harness.api.fastbootDevicesResponse = {
      'devices': <Map<String, Object?>>[],
      'error': {
        'blame': 'transport',
        'name': 'SecurityError',
        'message': 'Access denied by the browser',
        'stage': 'devices',
        'uncertain': false,
        'stack': '',
        'causes': <String>['usb.requestDevice'],
        'cleanupErrors': <String>[],
      },
    };
    final controller = await pumpFlash(tester, harness);

    expect(controller.devicesError, contains('SecurityError'));
    expect(controller.devicesError, contains('Access denied by the browser'));
    expect(controller.devicesError, contains('blame: transport'));
    expect(controller.devicesError, contains('stage: devices'));
    expect(find.textContaining('Access denied by the browser'), findsOneWidget);
  });
}
