import 'dart:async';

import 'package:flasher_web/flash/flash_controller.dart';
import 'package:flasher_web/flash/flash_page.dart';
import 'package:flasher_web/flash/flash_target.dart';
import 'package:flasher_web/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_usb_grant/web_usb_grant.dart';

import 'fake.dart';

const _serial = 'SERIAL123';
const _phone = (serial: _serial, label: 'Realme NEO8');

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
  'mode': 'bootloader',
  'modeOk': true,
  'resolved': true,
  'job': '20260101-000000-abcdef',
  'format': 'zip',
  'version': 'CPH123_11.A.01',
  'steps': ['Require bootloader', 'Flash boot from boot.img'],
  'executionSteps': ['Require bootloader', 'Flash boot from boot.img'],
  'confirmation': [
    'Flash Realme NEO8, serial $_serial',
    'Flash boot from boot.img',
  ],
  'prompts': prompts,
  'warnings': <String>[],
};

Map<String, Object?> unresolvedPrepare() => {
  'serial': _serial,
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

const _sha =
    'b1946ac92492d2347c6235b4d2611184'
    'b1946ac92492d2347c6235b4d2611184';

/// A receipt as the landed service returns it: one-based step indexes, the
/// ARB index, per-image hashes and the failure of a failed step.
Map<String, Object?> flashReceipt({
  String status = 'succeeded',
  int? stepIndex,
  String? reason,
  bool withAbl = false,
  List<Map<String, Object?>> steps = const [
    {'index': 1, 'title': 'Require bootloader', 'status': 'ok'},
    {'index': 2, 'title': 'Flash boot from boot.img', 'status': 'ok'},
  ],
}) => {
  'version': 1,
  'runId': 'run-1',
  'status': status,
  'serial': _serial,
  'device': 'Realme NEO8',
  'otaVersion': 'CPH123_11.A.01',
  'arb': {'major': 1, 'minor': 2, 'index': 3},
  'image_sha256': {'boot.img': _sha, 'super.img': _sha},
  if (withAbl)
    'abl_source': {'version': '16.0.6', 'sha256': _sha, 'bytes': 4096},
  'stepIndex': ?stepIndex,
  'reason': ?reason,
  if (status == 'failed' || status == 'uncertain')
    'failure': {
      'name': 'LinkFailure',
      'message': reason ?? 'Flash failed.',
      'stage': 'execute',
      'uncertain': status == 'uncertain',
      'stepIndex': stepIndex ?? 0,
    },
  'steps': steps,
  'uncertain': status == 'uncertain',
  'cleanupErrors': <String>[],
};

Map<String, Object?> failedFlashResult({
  String reason = 'FAIL reply on flash',
  bool canRetry = true,
  bool withAbl = false,
}) => {
  'type': 'result',
  'runId': 'run-1',
  'status': 'failed',
  'canRetry': canRetry,
  'receipt': flashReceipt(
    status: 'failed',
    stepIndex: 1,
    reason: reason,
    withAbl: withAbl,
  ),
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

    harness.bridge.fastbootChoices.add((
      serial: 'OTHER999',
      label: 'Wrong phone',
    ));
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
    controller.answerPrompt('wipe', 'wipe');
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
        const UsbException(
          UsbFailureKind.permission,
          'access denied',
          name: 'SecurityError',
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
        'blame': 'unknown',
        'name': 'Disconnected',
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
    expect(controller.prepareError, contains("The phone isn't answering fastboot"));
    expect(controller.logText, contains('Device disappeared during getvar'));
    expect(controller.logText, contains('close after prepare failed'));
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
        'blame': 'host',
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

    expect(controller.devicesError, contains('USB access was refused'));
    expect(controller.logText, contains('Access denied by the browser'));
    expect(controller.logText, contains('usb.requestDevice'));
    expect(find.textContaining('USB access was refused'), findsOneWidget);
  });

  testWidgets('a failed step offers retry, reboot retry and stop', (
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

    events.add({'type': 'run', 'runId': 'run-1'});
    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    events.add({
      'type': 'step',
      'index': 2,
      'total': 2,
      'title': 'Flash boot from boot.img',
    });
    events.add({
      'type': 'failure',
      'stepIndex': 1,
      'status': 'failed',
      'reason': 'FAIL reply on flash',
    });
    events.add(failedFlashResult(withAbl: true));
    await tester.pumpAndSettle();

    expect(controller.runId, 'run-1');
    expect(controller.phase, FlashPhase.failed);
    expect(controller.failedStepIndex, 1);
    expect(controller.failureReason, 'FAIL reply on flash');
    expect(controller.canRetry, isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('flashFailure')),
        matching: find.textContaining('Step 2'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('FAIL reply on flash'), findsWidgets);
    expect(find.byKey(const ValueKey('retryFlashStep')), findsOneWidget);
    expect(find.byKey(const ValueKey('rebootRetryFlashStep')), findsOneWidget);
    expect(find.byKey(const ValueKey('stopFlashRun')), findsOneWidget);
    expect(find.text('FAILED'), findsOneWidget);
    expect(find.byKey(const ValueKey('downloadFlashReceipt')), findsOneWidget);
    // The receipt card names the device, serial, version, ARB, ABL source and
    // every image hash the service reported.
    expect(find.text(_serial), findsWidgets);
    expect(find.text('Realme NEO8'), findsWidgets);
    expect(find.text('CPH123_11.A.01'), findsOneWidget);
    expect(find.textContaining('major 1'), findsOneWidget);
    expect(find.textContaining('16.0.6'), findsOneWidget);
    expect(find.textContaining('super.img'), findsWidgets);
    expect(find.text(_sha), findsWidgets);
    expect(harness.bridge.keepAwake, 0);
    expect(harness.api.lastFlashRequest?['confirmationToken'], 'token-1');
  });

  testWidgets('retry continues from the failed step and keeps earlier steps', (
    tester,
  ) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>(
      onCancel: () async {},
    );
    addTearDown(events.close);
    final retried = StreamController<Map<String, Object?>>(
      onCancel: () async {},
    );
    addTearDown(retried.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    harness.api.retryStepStream = (_) => retried.stream;
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await confirmAndFlash(tester);

    events.add({'type': 'run', 'runId': 'run-1'});
    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    events.add({
      'type': 'step',
      'index': 2,
      'total': 2,
      'title': 'Flash boot from boot.img',
    });
    events.add({
      'type': 'failure',
      'stepIndex': 1,
      'status': 'failed',
      'reason': 'FAIL reply on flash',
    });
    events.add(failedFlashResult());
    await tester.pumpAndSettle();

    final earlier = controller.log
        .where((line) => line.contains('Require bootloader'))
        .length;
    expect(earlier, greaterThan(0));

    await tester.ensureVisible(find.byKey(const ValueKey('retryFlashStep')));
    await tester.tap(find.byKey(const ValueKey('retryFlashStep')));
    await tester.pump();

    expect(harness.api.lastRetryStepRequest, {'runId': 'run-1'});
    expect(controller.phase, FlashPhase.running);
    expect(controller.canRetry, isFalse);
    expect(find.byKey(const ValueKey('retryFlashStep')), findsNothing);
    expect(harness.bridge.keepAwake, 1);

    retried.add({'type': 'run', 'runId': 'run-1'});
    retried.add({
      'type': 'step',
      'index': 2,
      'total': 2,
      'title': 'Flash boot from boot.img',
    });
    retried.add({
      'type': 'result',
      'runId': 'run-1',
      'status': 'succeeded',
      'canRetry': false,
      'receipt': flashReceipt(
        steps: const [
          {'index': 1, 'title': 'Require bootloader', 'status': 'ok'},
          {'index': 2, 'title': 'Flash boot from boot.img', 'status': 'ok'},
        ],
      ),
    });
    await tester.pumpAndSettle();

    expect(controller.phase, FlashPhase.succeeded);
    expect(controller.stepIndex, 2);
    expect(
      controller.log
          .where((line) => line.contains('Require bootloader'))
          .length,
      earlier,
    );
    expect(controller.receipt?['steps'], hasLength(2));
    expect(find.byKey(const ValueKey('retryFlashStep')), findsNothing);
    expect(find.byKey(const ValueKey('stopFlashRun')), findsNothing);
    expect(harness.api.flashCalls, 1);
    expect(harness.bridge.keepAwake, 0);
  });

  testWidgets('reboot retry names the run and reboots first', (tester) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>(
      onCancel: () async {},
    );
    addTearDown(events.close);
    final retried = StreamController<Map<String, Object?>>(
      onCancel: () async {},
    );
    addTearDown(retried.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    harness.api.rebootRetryStream = (_) => retried.stream;
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await confirmAndFlash(tester);

    events.add({'type': 'run', 'runId': 'run-1'});
    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    events.add({
      'type': 'failure',
      'stepIndex': 0,
      'status': 'uncertain',
      'reason': 'Write reply lost',
    });
    events.add({
      'type': 'result',
      'runId': 'run-1',
      'status': 'uncertain',
      'canRetry': true,
      'receipt': flashReceipt(
        status: 'uncertain',
        stepIndex: 0,
        reason: 'Write reply lost',
        steps: const [
          {'index': 1, 'title': 'Require bootloader', 'status': 'uncertain'},
        ],
      ),
    });
    await tester.pumpAndSettle();
    expect(controller.phase, FlashPhase.uncertain);
    expect(find.text('UNCERTAIN'), findsOneWidget);
    expect(find.textContaining('Do not retry'), findsWidgets);

    await tester.ensureVisible(
      find.byKey(const ValueKey('rebootRetryFlashStep')),
    );
    await tester.tap(find.byKey(const ValueKey('rebootRetryFlashStep')));
    await tester.pump();

    expect(harness.api.lastRebootRetryRequest, {'runId': 'run-1'});
    expect(harness.api.lastRetryStepRequest, isNull);
    expect(controller.phase, FlashPhase.running);

    retried.add({'type': 'run', 'runId': 'run-1'});
    retried.add({
      'type': 'waiting',
      'serial': _serial,
      'mode': 'bootloader',
      'text': 'Waiting for $_serial in bootloader.',
    });
    retried.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    retried.add({
      'type': 'result',
      'runId': 'run-1',
      'status': 'succeeded',
      'canRetry': false,
      'receipt': flashReceipt(),
    });
    await tester.pumpAndSettle();
    expect(controller.phase, FlashPhase.succeeded);
  });

  testWidgets('stop returns and shows the stopped receipt', (tester) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>(
      onCancel: () async {},
    );
    addTearDown(events.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    harness.api.stopResult = (request) async => {
      'receipt': flashReceipt(status: 'stopped', stepIndex: 1),
    };
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await confirmAndFlash(tester);

    events.add({'type': 'run', 'runId': 'run-1'});
    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    events.add({
      'type': 'failure',
      'stepIndex': 1,
      'status': 'failed',
      'reason': 'USB device disappeared',
    });
    events.add(failedFlashResult(reason: 'USB device disappeared'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('stopFlashRun')));
    await tester.tap(find.byKey(const ValueKey('stopFlashRun')));
    await tester.pumpAndSettle();

    expect(harness.api.lastStopRequest, {'runId': 'run-1'});
    expect(controller.phase, FlashPhase.stopped);
    expect(controller.receipt?['status'], 'stopped');
    expect(find.byKey(const ValueKey('flashReceipt')), findsOneWidget);
    expect(find.text('STOPPED'), findsOneWidget);
    expect(find.text('stopped'), findsWidgets);
    expect(find.byKey(const ValueKey('flashGuidance')), findsOneWidget);
    expect(find.byKey(const ValueKey('retryFlashStep')), findsNothing);
    expect(find.byKey(const ValueKey('stopFlashRun')), findsNothing);

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

  testWidgets('retry buttons stay hidden when the service cannot retry', (
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

    events.add({'type': 'run', 'runId': 'run-1'});
    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    events.add({
      'type': 'failure',
      'stepIndex': 0,
      'status': 'failed',
      'reason': 'The package digest changed',
    });
    events.add(failedFlashResult(canRetry: false));
    await tester.pumpAndSettle();

    expect(controller.phase, FlashPhase.failed);
    expect(controller.canRetry, isFalse);
    expect(find.byKey(const ValueKey('flashFailure')), findsOneWidget);
    expect(find.byKey(const ValueKey('failureStepTitle')), findsOneWidget);
    expect(find.byKey(const ValueKey('retryFlashStep')), findsNothing);
    expect(find.byKey(const ValueKey('rebootRetryFlashStep')), findsNothing);
    expect(find.byKey(const ValueKey('stopFlashRun')), findsNothing);
  });

  testWidgets('a broken stream leaves no retry buttons', (tester) async {
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

    events.add({'type': 'run', 'runId': 'run-1'});
    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    events.addError(StateError('stream broke'));
    await tester.pumpAndSettle();

    expect(controller.phase, FlashPhase.uncertain);
    expect(controller.canRetry, isFalse);
    expect(find.byKey(const ValueKey('retryFlashStep')), findsNothing);
    expect(find.byKey(const ValueKey('stopFlashRun')), findsNothing);
    expect(harness.bridge.keepAwake, 0);
  });
}
