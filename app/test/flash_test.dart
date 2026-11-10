import 'dart:async';

import 'package:flasher_web/flash/flash_controller.dart';
import 'package:flasher_web/flash/flash_page.dart';
import 'package:flasher_web/flash/flash_target.dart';
import 'package:flasher_web/theme.dart';
import 'package:flasher_web_core/flasher_web_core.dart'
    show FlashConnection, FlashRunPhase, WriteCertainty;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake.dart';

const _serial = 'SERIAL123';

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

const _sha =
    'b1946ac92492d2347c6235b4d2611184'
    'b1946ac92492d2347c6235b4d2611184';

/// A receipt as the service returns it, with the actions it offers.
Map<String, Object?> flashReceipt({
  String status = 'succeeded',
  int? stepIndex,
  String reason = 'FAIL reply on flash',
  bool uncertain = false,
  List<Map<String, Object?>> steps = const [
    {'index': 1, 'title': 'Require bootloader', 'status': 'ok'},
    {'index': 2, 'title': 'Flash boot from boot.img', 'status': 'ok'},
  ],
  List<Map<String, Object?>>? recoveryActions,
  Map<String, Object?>? superPreflight,
}) => {
  'version': 1,
  'runId': 'run-1',
  'status': status,
  'serial': _serial,
  'device': 'Realme NEO8',
  'otaVersion': 'CPH123_11.A.01',
  'arb': {'major': 1, 'minor': 2, 'index': 3},
  'image_sha256': {'boot.img': _sha, 'super.img': _sha},
  'stepIndex': ?stepIndex,
  'reason': ?(stepIndex == null ? null : reason),
  if (status == 'failed' || status == 'uncertain')
    'failure': {
      'name': 'FastbootFail',
      'blame': 'device',
      'message': reason,
      'stage': 'execute',
      'uncertain': uncertain,
      'stepIndex': stepIndex ?? 0,
    },
  'steps': steps,
  'uncertain': uncertain,
  'recoveryActions':
      recoveryActions ??
      [
        {
          'action': 'rewriteStep',
          'label': 'Rewrite this step from byte zero',
          'confirmationRequired': true,
        },
        {'action': 'stopRun', 'label': 'Stop further commands'},
      ],
  'superPreflight': ?superPreflight,
  'cleanupErrors': <String>[],
};

Map<String, Object?> failedResult({
  bool uncertain = false,
  bool canRetry = true,
  List<Map<String, Object?>>? recoveryActions,
  Map<String, Object?>? superPreflight,
}) => {
  'type': 'result',
  'runId': 'run-1',
  'status': uncertain ? 'uncertain' : 'failed',
  'canRetry': canRetry,
  'receipt': flashReceipt(
    status: uncertain ? 'uncertain' : 'failed',
    uncertain: uncertain,
    stepIndex: 1,
    recoveryActions: recoveryActions,
    superPreflight: superPreflight,
  ),
};

Map<String, Object?> succeededResult() => {
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
};

/// Pumps a bounded number of frames.
///
/// A live run keeps an indeterminate progress bar animating, so
/// `pumpAndSettle` can never settle; these tests only need pending microtasks
/// and the next frames.
Future<void> pumpFrames(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<FlashController> pumpFlash(
  WidgetTester tester,
  Harness harness, {
  FlashTarget? target,
  Map<String, Object?>? checkpoint,
}) async {
  await tester.binding.setSurfaceSize(const Size(1440, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = FlashController(
    api: harness.api,
    bridge: harness.bridge,
    environment: harness.environment,
    target: checkpoint == null ? target ?? flashTarget() : null,
    upstreamBase: 'https://upstream.test/',
    checkpoint: checkpoint,
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
  await pumpFrames(tester);
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
  await pumpFrames(tester);
}

Future<void> reviewAndFlash(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('reviewPlan')));
  await pumpFrames(tester);
  await tester.tap(find.byKey(const ValueKey('confirmFlashDevice')));
  await pumpFrames(tester);
  await tester.tap(find.byKey(const ValueKey('startFlash')));
  // The guard and the checkpoint are awaited before the stream starts; the
  // flash screen then shows an indeterminate bar, so no settle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  testWidgets('the guided screens follow the core flow state', (tester) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>();
    addTearDown(events.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    final controller = await pumpFlash(tester, harness);

    expect(controller.screen, FlashScreen.connect);
    expect(find.byKey(const ValueKey('screenConnect')), findsOneWidget);
    expect(find.byKey(const ValueKey('connectPrimary')), findsOneWidget);
    expect(find.text('Check phone'), findsOneWidget);

    await selectDevice(tester, controller);
    expect(controller.screen, FlashScreen.check);
    expect(controller.phase, FlashRunPhase.preparing);
    expect(controller.connection, FlashConnection.ready);
    expect(find.byKey(const ValueKey('screenCheck')), findsOneWidget);
    expect(find.byKey(const ValueKey('reviewPlan')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reviewPlan')));
    await pumpFrames(tester);
    expect(controller.screen, FlashScreen.confirm);
    expect(controller.phase, FlashRunPhase.confirming);
    expect(find.byKey(const ValueKey('screenConfirm')), findsOneWidget);
    expect(find.byKey(const ValueKey('startFlash')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirmFlashDevice')));
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('startFlash')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.screen, FlashScreen.flash);
    expect(find.byKey(const ValueKey('screenFlash')), findsOneWidget);
    expect(find.byKey(const ValueKey('stopFlash')), findsOneWidget);
    expect(find.byKey(const ValueKey('startFlash')), findsNothing);

    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    events.add(succeededResult());
    await pumpFrames(tester);
    expect(controller.screen, FlashScreen.done);
    expect(controller.phase, FlashRunPhase.done);
    expect(controller.certainty, WriteCertainty.confirmed);
    expect(find.byKey(const ValueKey('screenDone')), findsOneWidget);
    expect(find.byKey(const ValueKey('saveReceipt')), findsOneWidget);
  });

  testWidgets('writing holds the guard only while a run is live', (
    tester,
  ) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>();
    addTearDown(events.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);

    expect(controller.canFlash, isFalse);
    expect(harness.api.flashCalls, 0);
    expect(harness.bridge.keepAwake, 0);

    await reviewAndFlash(tester);
    events.add({'type': 'run', 'runId': 'run-1'});
    expect(harness.api.flashCalls, 1);
    expect(harness.api.lastFlashRequest?['confirmationToken'], 'token-1');
    expect(harness.api.lastFlashRequest?['serial'], _serial);
    expect(harness.bridge.keepAwake, 1);
    expect(controller.writing, isTrue);
    // The checkpoint exists before the first command could reach the phone.
    expect(harness.bridge.checkpoint, isNotNull);
    expect(harness.bridge.checkpoint?['serial'], _serial);

    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    await pumpFrames(tester);
    expect(harness.bridge.keepAwake, 1);

    events.add(succeededResult());
    await pumpFrames(tester);
    expect(harness.bridge.keepAwake, 0);
    expect(controller.writing, isFalse);
    final checkpoint = harness.bridge.checkpoint!;
    expect((checkpoint['receipt'] as Map?)?['status'], 'succeeded');

    await tester.ensureVisible(find.byKey(const ValueKey('saveReceipt')));
    await tester.tap(find.byKey(const ValueKey('saveReceipt')));
    await pumpFrames(tester);
    expect(
      harness.bridge.downloads,
      contains('flash-20260101-000000-abcdef-SERIAL123.json'),
    );
  });

  testWidgets('an uncertain write never offers a generic retry', (
    tester,
  ) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>();
    addTearDown(events.close);
    final recovery = StreamController<Map<String, Object?>>();
    addTearDown(recovery.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    harness.api.recoveryStream = (_) => recovery.stream;
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await reviewAndFlash(tester);
    events.add({'type': 'run', 'runId': 'run-1'});

    events.add({
      'type': 'step',
      'index': 2,
      'total': 2,
      'title': 'Flash boot from boot.img',
    });
    events.add({
      'type': 'failure',
      'stepIndex': 1,
      'status': 'uncertain',
      'reason': 'write reply lost',
    });
    events.add(
      failedResult(
        uncertain: true,
        recoveryActions: const [
          {
            'action': 'rewriteStep',
            'label': 'Rewrite this step from byte zero',
            'confirmationRequired': true,
          },
          {
            'action': 'recoverPowerCycle',
            'label': 'I have power-cycled the phone',
            'powerCycleRequired': true,
          },
          {'action': 'stopRun', 'label': 'Stop further commands'},
        ],
      ),
    );
    await pumpFrames(tester);

    expect(controller.screen, FlashScreen.recover);
    expect(controller.certainty, WriteCertainty.uncertain);
    expect(find.byKey(const ValueKey('uncertainBanner')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('failureMessage')),
      findsOneWidget,
    );
    expect(find.text('Retry step'), findsNothing);
    expect(find.textContaining('Retry'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('recoverPrimary')),
        matching: find.text('Rewrite this step from byte zero'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('recover-stopRun')), findsNothing);
    expect(find.byKey(const ValueKey('stopFlashRun')), findsOneWidget);
    // No run is live, so the guard is released while the run is paused.
    expect(harness.bridge.keepAwake, 0);
    final paused = harness.bridge.checkpoint!;
    expect((paused['receipt'] as Map?)?['uncertain'], isTrue);

    await tester.tap(find.byKey(const ValueKey('recoverPrimary')));
    await pumpFrames(tester);
    expect(
      find.textContaining('rewrites'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('confirmDestructiveAction')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('confirmDestructive')));
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('confirmDestructiveAction')));
    // The recovery stream stays open, so the busy bar never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(harness.api.lastRecoveryAction, 'rewriteStep');
    expect(harness.api.lastRecoveryRequest?['runId'], 'run-1');
    expect(harness.api.lastRecoveryRequest?['confirmedSerial'], _serial);
    expect(harness.bridge.keepAwake, 1);
  });

  testWidgets('clear super needs the exact serial and keeps the guard down', (
    tester,
  ) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>();
    addTearDown(events.close);
    final recovery = StreamController<Map<String, Object?>>();
    addTearDown(recovery.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    harness.api.recoveryStream = (_) => recovery.stream;
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await reviewAndFlash(tester);
    events.add({'type': 'run', 'runId': 'run-1'});

    events.add({
      'type': 'step',
      'index': 2,
      'total': 2,
      'title': 'Create logical partition',
    });
    events.add({
      'type': 'failure',
      'stepIndex': 1,
      'status': 'failed',
      'reason': "This phone's super still holds another system.",
    });
    events.add(
      failedResult(
        recoveryActions: const [
          {
            'action': 'wipeSuper',
            'label': 'Clear super and restart logical writes',
            'confirmationRequired': true,
          },
          {'action': 'stopRun', 'label': 'Stop further commands'},
        ],
        superPreflight: const {
          'needsWipe': true,
          'requiredBytes': 4096,
          'freeBytes': 0,
        },
      ),
    );
    await pumpFrames(tester);

    expect(controller.screen, FlashScreen.recover);
    expect(controller.needsWipeSuper, isTrue);
    expect(find.byKey(const ValueKey('superPreflight')), findsOneWidget);
    expect(find.byKey(const ValueKey('recover-wipeSuper')), findsNothing);

    // Declining sends nothing.
    await tester.tap(find.byKey(const ValueKey('recoverPrimary')));
    await pumpFrames(tester);
    expect(find.textContaining('cannot boot'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await pumpFrames(tester);
    expect(harness.api.lastRecoveryAction, isNull);

    await tester.tap(find.byKey(const ValueKey('recoverPrimary')));
    await pumpFrames(tester);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('confirmDestructiveAction')),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey('confirmSerialField')),
      _serial,
    );
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('confirmDestructive')));
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('confirmDestructiveAction')));
    // The recovery stream stays open, so the busy bar never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(harness.api.lastRecoveryAction, 'wipeSuper');
    expect(harness.api.lastRecoveryRequest?['confirmedSerial'], _serial);
    expect(harness.bridge.keepAwake, 1);
  });

  testWidgets('power-cycle recovery states the physical steps first', (
    tester,
  ) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>();
    addTearDown(events.close);
    final recovery = StreamController<Map<String, Object?>>();
    addTearDown(recovery.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    harness.api.recoveryStream = (_) => recovery.stream;
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await reviewAndFlash(tester);
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
      'reason': 'inconsistent answers',
    });
    events.add(
      failedResult(
        recoveryActions: const [
          {
            'action': 'recoverPowerCycle',
            'label': 'I have power-cycled the phone',
            'powerCycleRequired': true,
          },
          {'action': 'stopRun', 'label': 'Stop further commands'},
        ],
      ),
    );
    await pumpFrames(tester);

    expect(find.byKey(const ValueKey('recoverPrimary')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('powerCycleInstructions')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('recoverPrimary')));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('confirmPowerCycle')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirmPowerCycle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(harness.api.lastRecoveryAction, 'recoverPowerCycle');
    expect(harness.api.lastRecoveryRequest?['powerCycled'], isTrue);
  });

  testWidgets('a reload restores an inspection-only receipt', (tester) async {
    final harness = Harness();
    final controller = await pumpFlash(
      tester,
      harness,
      checkpoint: {
        'version': 1,
        'runId': 'run-1',
        'serial': _serial,
        'status': 'writing',
        'phase': 'writing',
        'connection': 'active',
        'stepIndex': 1,
        'totalSteps': 2,
        'stepTitle': 'Flash boot from boot.img',
      },
    );

    expect(controller.restored, isTrue);
    expect(controller.screen, FlashScreen.done);
    expect(controller.certainty, WriteCertainty.uncertain);
    expect(controller.phase, FlashRunPhase.stopped);
    expect(controller.canFlash, isFalse);
    expect(controller.canRecover, isFalse);
    expect(controller.canStop, isFalse);
    expect(find.byKey(const ValueKey('restoredNote')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('restoredNote')),
        matching: find.textContaining('was not resumed'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('saveReceipt')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('saveReceipt')))
          .onPressed,
      isNull,
    );
    expect(harness.api.flashCalls, 0);
    expect(harness.api.prepareCalls, 0);
  });

  testWidgets('a finished receipt restores as inspection only', (tester) async {
    final harness = Harness();
    final controller = await pumpFlash(
      tester,
      harness,
      checkpoint: {
        'version': 1,
        'runId': 'run-1',
        'serial': _serial,
        'status': 'succeeded',
        'receipt': flashReceipt(),
      },
    );

    expect(controller.restored, isTrue);
    expect(controller.screen, FlashScreen.done);
    expect(controller.certainty, WriteCertainty.confirmed);
    expect(controller.phase, FlashRunPhase.done);
    expect(controller.canFlash, isFalse);
    expect(find.text('The phone accepted every write'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('saveReceipt')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('USB removal only updates connection state', (tester) async {
    final harness = Harness();
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    final prepares = harness.api.prepareCalls;

    harness.bridge.attach(attached: false, serial: _serial);
    await pumpFrames(tester);

    expect(controller.connection, FlashConnection.lost);
    expect(find.textContaining('left USB'), findsWidgets);
    expect(harness.api.flashCalls, 0);
    expect(harness.bridge.keepAwake, 0);

    harness.bridge.attach(attached: true, serial: _serial);
    await pumpFrames(tester);
    expect(controller.connection, FlashConnection.waiting);
    // An arrival never prepares or probes on its own.
    expect(harness.api.prepareCalls, prepares);
  });

  testWidgets('a deploy is announced while busy and reload waits for idle', (
    tester,
  ) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>();
    addTearDown(events.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await reviewAndFlash(tester);
    events.add({'type': 'run', 'runId': 'run-1'});
    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    await pumpFrames(tester);

    harness.bridge.announceUpdate('v3');
    await pumpFrames(tester);
    expect(controller.updateReady, isTrue);
    expect(controller.canReloadNow, isFalse);
    expect(find.byKey(const ValueKey('updateBanner')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('reloadForUpdate')))
          .onPressed,
      isNull,
    );

    events.add(succeededResult());
    await pumpFrames(tester);
    expect(controller.canReloadNow, isTrue);
    await tester.tap(find.byKey(const ValueKey('reloadForUpdate')));
    await pumpFrames(tester);
    expect(harness.bridge.reloads, 1);
  });

  testWidgets('a lost worker ends the run without restarting it', (
    tester,
  ) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>();
    addTearDown(events.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await reviewAndFlash(tester);
    events.add({'type': 'run', 'runId': 'run-1'});

    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    events.addError(StateError('the service worker terminated'));
    await pumpFrames(tester);

    expect(controller.workerLost, isTrue);
    expect(controller.screen, FlashScreen.done);
    expect(controller.certainty, WriteCertainty.uncertain);
    expect(harness.api.flashCalls, 1);
    expect(harness.bridge.keepAwake, 0);
    expect(controller.diagnosticsText, contains('the service worker terminated'));
    expect(controller.diagnosticsText, contains('WorkerLost'));
    expect(find.byKey(const ValueKey('flashError')), findsOneWidget);
  });

  testWidgets('stop keeps the guard until the service acknowledges', (
    tester,
  ) async {
    final harness = Harness();
    final events = StreamController<Map<String, Object?>>(
      onCancel: () async {},
    );
    addTearDown(events.close);
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    harness.api.flashStream = (_) => events.stream;
    harness.api.stopResult = (request) async => {
      'receipt': flashReceipt(status: 'stopped', uncertain: true),
    };
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await reviewAndFlash(tester);
    events.add({'type': 'run', 'runId': 'run-1'});
    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    await pumpFrames(tester);
    expect(controller.canStop, isTrue);

    await tester.tap(find.byKey(const ValueKey('stopFlash')));
    await pumpFrames(tester);

    expect(harness.api.lastStopRequest, {'runId': 'run-1'});
    expect(controller.screen, FlashScreen.done);
    expect(controller.certainty, WriteCertainty.uncertain);
    expect(controller.receipt?['status'], 'stopped');
    expect(harness.bridge.keepAwake, 0);
    expect(find.textContaining('No rollback'), findsWidgets);
  });

  testWidgets('a page without a wake lock reports it while writing', (
    tester,
  ) async {
    final harness = Harness();
    harness.bridge.wakeLockSupported = false;
    harness.api.prepareFlashResult = (_) => resolvedPrepare();
    final events = StreamController<Map<String, Object?>>();
    addTearDown(events.close);
    harness.api.flashStream = (_) => events.stream;
    final controller = await pumpFlash(tester, harness);
    await selectDevice(tester, controller);
    await reviewAndFlash(tester);
    events.add({'type': 'run', 'runId': 'run-1'});
    events.add({
      'type': 'step',
      'index': 1,
      'total': 2,
      'title': 'Require bootloader',
    });
    await pumpFrames(tester);
    expect(controller.wakeLockSupported, isFalse);
    expect(find.byKey(const ValueKey('wakeLockMissing')), findsOneWidget);
  });
}
