import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flasher_web_core/flasher_web_core.dart'
    show
        FlashConnection,
        FlashFlowState,
        FlashRecovery,
        FlashRunPhase,
        WriteCertainty;
import 'package:web_usb_grant/web_usb_grant.dart';

import '../api/flasher_api.dart';
import '../api/platform_bridge.dart';
import '../runtime.dart';
import 'flash_target.dart';

/// The guided screen the flash flow is on.
///
/// Setup is the shell's own page; the flash flow's screens start at Connect.
/// Each screen has exactly one primary action and derives it from the core
/// [FlashFlowState] plus the facts of the current preparation.
enum FlashScreen { connect, check, confirm, flash, recover, done }

/// The guided screens, in order, for the progress rail.
const flashScreenOrder = [
  FlashScreen.connect,
  FlashScreen.check,
  FlashScreen.confirm,
  FlashScreen.flash,
  FlashScreen.recover,
  FlashScreen.done,
];

/// What a screen is for, as its heading and one-line instruction.
({String title, String detail}) flashScreenHeading(FlashScreen screen) =>
    switch (screen) {
      FlashScreen.connect => (
        title: 'Connect your phone',
        detail:
            'Put the phone in bootloader fastboot, then choose it. Nothing '
            'is written on this screen.',
      ),
      FlashScreen.check => (
        title: 'Check and prepare',
        detail:
            'Read-only checks and the plan’s remaining questions. The phone '
            'is not written.',
      ),
      FlashScreen.confirm => (
        title: 'Confirm the exact phone',
        detail: 'Nothing is written until you confirm this serial.',
      ),
      FlashScreen.flash => (
        title: 'Flashing',
        detail: 'Do not unplug the phone. Commands are sent one at a time.',
      ),
      FlashScreen.recover => (
        title: 'Recover the run',
        detail:
            'Choose one explicit action. Nothing is resent automatically, '
            'and reconnecting never settles a write.',
      ),
      FlashScreen.done => (
        title: 'Finished',
        detail: 'The receipt is the only record. Save it.',
      ),
    };

/// Prepares and executes one OTA-direct flash as a guided flow.
///
/// Core owns transitions and the allowed recovery actions; this controller
/// renders them and drives the page-only lifecycle: the WebUSB grant, the
/// wake lock and leave guard while writing, the reload checkpoint and the
/// service-worker update offer. Preparation is read-only and returns a token
/// bound to the exact device, OTA, bloat store, answers and inspected images;
/// a used token is never offered again.
final class FlashController extends ChangeNotifier {
  FlashController({
    required this.api,
    required this.bridge,
    required this.environment,
    required this.upstreamBase,
    this.target,
    Map<String, Object?>? checkpoint,
  }) {
    if (checkpoint != null && checkpoint.isNotEmpty) {
      _restore(checkpoint);
    } else {
      _flow = const FlashFlowState();
    }
  }

  final FlasherApi api;
  final PlatformBridge bridge;
  final EnvironmentInfo environment;
  final String upstreamBase;

  /// The package this flow would write; null for a restored receipt, which is
  /// inspection only.
  final FlashTarget? target;

  /// The package label the flow shows; a restored receipt has no package.
  String get targetLabel => target?.label ?? 'not selected';

  late FlashFlowState _flow;
  bool _restored = false;
  String? _restoredNote;

  List<Map<String, Object?>> _devices = const [];
  bool _devicesLoading = false;
  String? _devicesError;
  String? _serial;
  String _deviceLabel = '';
  final _answers = <String, String>{};
  bool _acknowledged = false;
  bool _preparing = false;
  bool _starting = false;
  bool _stopping = false;
  String? _prepareError;
  PreparedFlash? _prepared;
  Map<String, Object?>? _preparedRequest;
  String? _derivedJob;
  int _generation = 0;
  int _devicesGeneration = 0;
  Timer? _debounce;
  StreamSubscription<Map<String, Object?>>? _subscription;
  StreamSubscription<UsbAttachEvent>? _usbSubscription;
  StreamSubscription<String>? _updateSubscription;
  int _streamToken = 0;
  _RunKind _runKind = _RunKind.none;
  bool _sawStep = false;
  bool _keepAwakeHeld = false;
  bool _wakeLockReported = false;
  bool _disposed = false;
  String? _runId;

  final _log = <String>[];
  final _progress = <String, ({int done, int total})>{};
  int _stepIndex = 0;
  int _totalSteps = 0;
  String _stepTitle = '';
  Map<String, Object?>? _waiting;
  Map<String, Object?>? _result;
  Map<String, Object?>? _receipt;
  Map<String, Object?>? _failureEvent;
  Map<String, Object?>? _superPreflight;
  String? _errorText;
  String? _guidance;
  String? _notice;
  bool _canRetry = false;
  bool _stoppingRun = false;
  bool _workerLost = false;
  bool _updateReady = false;
  String? _updateVersion;
  String? _regrantMessage;
  bool _regranting = false;
  Future<void> _checkpointWrites = Future<void>.value();

  FlashFlowState get state => _flow;
  FlashConnection get connection => _flow.connection;
  FlashRunPhase get phase => _flow.phase;
  WriteCertainty get certainty => _flow.certainty;

  /// A receipt restored after a reload. It is inspection only: nothing on
  /// this page can resume it, write again or change its certainty.
  bool get restored => _restored;
  String? get restoredNote => _restoredNote;

  /// The screen the flow is on.
  FlashScreen get screen {
    if (_restored) return FlashScreen.done;
    switch (_flow.phase) {
      case FlashRunPhase.writing:
        return FlashScreen.flash;
      case FlashRunPhase.recovering:
        return FlashScreen.recover;
      case FlashRunPhase.done:
      case FlashRunPhase.stopped:
        return FlashScreen.done;
      case FlashRunPhase.confirming:
        return FlashScreen.confirm;
      case FlashRunPhase.preparing:
        return _live ? FlashScreen.flash : FlashScreen.check;
      case FlashRunPhase.setup:
      case FlashRunPhase.connecting:
        if (_live) return FlashScreen.flash;
        return _serial == null ? FlashScreen.connect : FlashScreen.check;
    }
  }

  /// A run stream this controller is still following.
  bool get _live =>
      _runKind != _RunKind.none &&
      (_subscription != null || _starting || _stoppingRun);

  /// A run is in flight or its stop acknowledgement is pending.
  bool get busy => _live || _stopping;

  /// A write is in progress (including an in-flight command after Stop):
  /// exactly the span that holds the wake lock and the leave guard.
  bool get writing => _keepAwakeHeld;

  List<Map<String, Object?>> get devices => List.unmodifiable(_devices);
  bool get devicesLoading => _devicesLoading;
  String? get devicesError => _devicesError;
  bool get hasGrant => _devices.isNotEmpty;
  String? get serial => _serial;
  String get deviceLabel => _deviceLabel;
  Map<String, String> get answers => Map.unmodifiable(_answers);
  bool get acknowledged => _acknowledged;
  bool get preparing => _preparing;
  String? get prepareError => _prepareError;
  PreparedFlash? get prepared => _prepared;
  bool get writesSupported => environment.has('usb.web');
  bool get pageCanChoose => bridge.canChooseFastbootDevice;
  bool get wakeLockSupported => bridge.wakeLockSupported;
  bool get stopping => _stoppingRun;
  bool get stoppingRun => _stopping;
  bool get workerLost => _workerLost;
  bool get updateReady => _updateReady;
  String? get updateVersion => _updateVersion;

  List<String> get log => List.unmodifiable(_log);
  String get logText => _log.join('\n');
  String get lastReply => _log.isEmpty ? '' : _log.last;
  Map<String, ({int done, int total})> get progress =>
      Map.unmodifiable(_progress);
  int get stepIndex => _stepIndex;
  int get totalSteps => _totalSteps;
  String get stepTitle => _stepTitle;
  Map<String, Object?>? get waiting => _waiting;
  String? get waitingSerial =>
      _waiting?['serial'] is String ? _waiting!['serial']! as String : null;
  String? get waitingMode =>
      _waiting?['mode'] is String ? _waiting!['mode']! as String : null;
  String? get waitingText =>
      _waiting?['text'] is String ? _waiting!['text']! as String : null;
  Map<String, Object?>? get result => _result;
  Map<String, Object?>? get receipt => _receipt;
  String? get errorText => _errorText;
  String? get guidance => _guidance;
  String? get notice => _notice;
  bool get regranting => _regranting;
  String? get regrantMessage => _regrantMessage;

  String get connectionLabel => switch (_flow.connection) {
    FlashConnection.unavailable => 'USB is not available in this browser',
    FlashConnection.waiting => 'Waiting for a phone',
    FlashConnection.opening => 'Opening the phone',
    FlashConnection.probing => 'Checking the phone',
    FlashConnection.ready => 'Phone ready',
    FlashConnection.active => 'Commands running',
    FlashConnection.transitioning => 'The phone is rebooting',
    FlashConnection.needsAccess => 'Grant the same phone again',
    FlashConnection.lost => 'The phone left USB',
    FlashConnection.closing => 'Closing the connection',
    FlashConnection.stopped => 'Connection closed',
  };

  /// The core's id for this run, read from its first `run` event. A recovery
  /// names exactly this run; nothing reopens a used confirmation token.
  String? get runId => _runId;

  /// The failed step and its status, as the service reported them.
  int? get failedStepIndex {
    final value = _receipt?['stepIndex'];
    return value is num ? value.toInt() : null;
  }

  bool get uncertain =>
      _flow.certainty == WriteCertainty.uncertain ||
      _receipt?['uncertain'] == true;

  /// The failed step as the receipt names it, one-based for display.
  String get failedStepLabel {
    final index = _receipt?['stepIndex'];
    if (index is! num) return 'The failed step';
    final oneBased = index.toInt() + 1;
    final title = _stepTitle.isNotEmpty
        ? _stepTitle
        : _receiptStepTitle(oneBased);
    return title.isEmpty ? 'Step $oneBased' : 'Step $oneBased: $title';
  }

  String _receiptStepTitle(int oneBased) {
    final steps = _receipt?['steps'];
    if (steps is List) {
      for (final step in steps) {
        if (step is Map &&
            step['index'] is num &&
            (step['index'] as num).toInt() == oneBased) {
          return '${step['title'] ?? ''}';
        }
      }
    }
    return '';
  }

  /// Whether the service kept the failed run paused and accepts another
  /// explicit command. A restored receipt cannot recover: its run ended with
  /// the page.
  bool get canRecover =>
      !_restored &&
      _canRetry &&
      _runId != null &&
      !_starting &&
      !_stoppingRun &&
      !_live;

  bool get canStop =>
      !_restored &&
      _runId != null &&
      (_flow.phase == FlashRunPhase.writing || _canRetry) &&
      !_stoppingRun;

  /// Every action the service offers for this receipt, in its order.
  ///
  /// The service decides which actions exist; the page only renders them. A
  /// generic retry is never among them for an uncertain write.
  List<Map<String, Object?>> get recoveryActions {
    final actions = _receipt?['recoveryActions'];
    if (actions is! List) return const [];
    return [
      for (final value in actions)
        if (value is Map) Map<String, Object?>.from(value),
    ];
  }

  /// The safest applicable action: the first the service offers, and Stop
  /// when it offers nothing else.
  Map<String, Object?>? get primaryRecovery {
    for (final action in recoveryActions) {
      if (action['action'] != FlashRecovery.stopRun.name) return action;
    }
    return null;
  }

  /// The service's own words for an action, e.g. for a dialog title.
  String recoveryTitle(Map<String, Object?> action) =>
      '${action['label'] ?? action['action'] ?? ''}';

  Map<String, Object?>? get superPreflight {
    final value = _superPreflight ?? _receipt?['superPreflight'];
    return value is Map ? Map<String, Object?>.from(value) : null;
  }

  /// The phone's super holds allocations this plan needs; the service offers
  /// Clear super and Stop, nothing else.
  bool get needsWipeSuper {
    final preflight = superPreflight;
    if (preflight != null &&
        preflight['needsWipe'] == true &&
        preflight['cleared'] != true) {
      return true;
    }
    return _receipt?['wipeSuperRequired'] == true &&
        recoveryActions.any(
          (action) => action['action'] == FlashRecovery.wipeSuper.name,
        );
  }

  /// The plain-language failure: the core's link guidance, or the worker
  /// loss when the page lost its service.
  String? get plainFailure {
    if (_workerLost) {
      return 'The service worker stopped, so this page can no longer send '
          'commands to the phone. It was not restarted and nothing was '
          'replayed. Check the phone, reconnect it and start a new run.';
    }
    final failure = _receipt?['failure'] ?? _failureEvent;
    if (failure is Map && failure.isNotEmpty) {
      // The super preflight question is the service's own wording; the link
      // guidance has nothing better for it.
      if ('${failure['name']}' == 'SuperSpaceRequired') {
        final message = '${failure['message'] ?? ''}'.trim();
        return message.isEmpty ? superPreflightQuestion : message;
      }
      return describeLinkFailure(failure);
    }
    final reason = _receipt?['reason'];
    if (reason is String && reason.isNotEmpty) return reason;
    return _errorText;
  }

  /// The original structured evidence, one tap away from the plain message.
  String? get rawFailure {
    final failure = _receipt?['failure'] ?? _failureEvent;
    if (failure is Map && failure.isNotEmpty) {
      return const JsonEncoder.withIndent('  ').convert(failure);
    }
    return null;
  }

  static const powerCycleInstructions =
      'Unplug the USB cable. Hold Power for 15 seconds until the phone turns '
      'off, then hold Volume-Down + Power to enter bootloader fastboot and '
      'reconnect the cable. This does not settle an uncertain write.';

  static const superPreflightQuestion =
      "This phone's super still holds another system (for example a custom "
      'ROM). Clear it?';

  String get superWarning =>
      'Clearing super removes every logical system partition on '
      '${_serial ?? 'the phone'}. The phone cannot boot until this run '
      'completes. It is never automatic.';

  /// The job the service derives from the OTA identity.
  String get jobId {
    final job = _prepared?.job ?? _derivedJob;
    if (job == null || job.isEmpty) return 'assigned by the service';
    return job;
  }

  String get receiptPath =>
      'this browser download (virtual job $jobId; no local job exists)';

  bool get answersComplete {
    final prepared = _prepared;
    if (prepared == null) return false;
    return prepared.prompts.every(
      (prompt) => prompt.choices.contains(_answers[prompt.id]),
    );
  }

  bool get ready =>
      _prepared?.resolved == true &&
      _prepared!.hasToken &&
      _prepared!.modeOk &&
      answersComplete;

  /// The final button is enabled only for a fully resolved, explicitly
  /// confirmed plan whose token belongs to the current input.
  bool get canFlash =>
      !_restored &&
      writesSupported &&
      !_live &&
      !_preparing &&
      !_starting &&
      !_stoppingRun &&
      ready &&
      _acknowledged;

  /// Why the write cannot start, or null when it can.
  String? get blockingReason {
    if (_restored) {
      return 'This receipt is inspection only. Prepare and confirm a new run '
          'to write again.';
    }
    if (!writesSupported) {
      return 'This browser context cannot reach USB devices. Open the app in '
          'a Chromium browser over HTTPS or localhost.';
    }
    if (_serial == null) return 'Choose a fastboot device serial.';
    if (_preparing) return 'Preparation is running.';
    final prepared = _prepared;
    if (prepared == null) return _prepareError ?? 'Preparing the flash plan.';
    final unanswered = [
      for (final prompt in prepared.prompts)
        if (!prompt.choices.contains(_answers[prompt.id])) prompt.question,
    ];
    if (unanswered.isNotEmpty) {
      return 'Answer every question before flashing: ${unanswered.join(' ')}';
    }
    if (!prepared.resolved || !prepared.hasToken) {
      return 'The plan is not resolved yet. Answer the questions again.';
    }
    if (!prepared.modeOk) {
      return 'The phone is in ${prepared.mode}. Reboot it to bootloader '
          'fastboot, then check the phone again.';
    }
    if (!_acknowledged) return 'Confirm the exact serial below.';
    return null;
  }

  /// The ordered steps of the plan, including nested choices it resolved.
  List<String> get planSteps {
    final prepared = _prepared;
    if (prepared == null) return const [];
    final execution = prepared.raw['executionSteps'];
    if (execution is List) {
      return [
        for (final step in execution)
          if (step is String) step,
      ];
    }
    return prepared.steps;
  }

  /// Reload is offered only when no run is preparing, confirming, writing or
  /// recovering.
  bool get canReloadNow =>
      _updateReady &&
      !_live &&
      !_preparing &&
      !_starting &&
      !_stoppingRun &&
      _flow.phase != FlashRunPhase.recovering &&
      _flow.phase != FlashRunPhase.confirming;

  Future<void> start() async {
    _usbSubscription ??= bridge.usbAttachEvents.listen(_onUsbAttach);
    _updateSubscription ??= bridge.appUpdates.listen(_onAppUpdate);
    if (_restored) {
      _notify();
      return;
    }
    await refreshDevices();
  }

  Future<void> refreshDevices() async {
    if (_disposed || _live || _restored) return;
    final generation = ++_devicesGeneration;
    _devicesLoading = true;
    _devicesError = null;
    _notify();
    try {
      final response = await api.fastbootDevices();
      if (_disposed || generation != _devicesGeneration) return;
      final values = response['devices'];
      _devices = [
        if (values is List)
          for (final device in values)
            if (device is Map &&
                device['serial'] is String &&
                '${device['serial']}'.isNotEmpty)
              Map<String, Object?>.unmodifiable(
                Map<String, Object?>.from(device),
              ),
      ];
      _devicesLoading = false;
      final error = response['error'];
      if (error != null) {
        _log.add('Connection evidence: ${jsonEncode(error)}');
        _devicesError = describeLinkFailure(error);
      }
      final discoveryFailures = response['discoveryFailures'];
      if (discoveryFailures is List && discoveryFailures.isNotEmpty) {
        _log.add('USB discovery evidence: ${jsonEncode(discoveryFailures)}');
      }
      final current = _serial;
      if (current != null) {
        final known = _devices.where((device) => device['serial'] == current);
        if (known.isNotEmpty) {
          _deviceLabel = _labelOf(known.first);
        } else {
          _serial = null;
          _deviceLabel = '';
          _answers.clear();
          _resetPreparation();
          _devicesError =
              'Serial $current is no longer granted. Reconnect the phone and '
              'choose it again.';
          _setConnection(FlashConnection.lost);
        }
      }
    } on Object catch (error) {
      if (_disposed || generation != _devicesGeneration) return;
      _devicesLoading = false;
      _devicesError = '$error';
    }
    _notify();
  }

  /// The Connect screen's "Check phone": lists the grants this page already
  /// holds and selects the one phone when there is exactly one.
  Future<void> checkPhone() async {
    if (_disposed || _live || _restored) return;
    await refreshDevices();
    if (_disposed || _serial != null || _devices.length != 1) return;
    selectDevice(_devices.first);
  }

  String _labelOf(Map<String, Object?> device) {
    final label = device['label'];
    final serial = '${device['serial'] ?? ''}';
    final transport = device['transport'];
    final parts = [
      if (label is String && label.trim().isNotEmpty) label.trim(),
      if (transport is String && transport.trim().isNotEmpty) transport,
    ];
    return parts.isEmpty ? serial : '${parts.join(' · ')} · $serial';
  }

  void selectDevice(Map<String, Object?> device) {
    final serial = device['serial'];
    if (serial is! String || serial.isEmpty || _live || _restored) return;
    if (serial == _serial) return;
    _serial = serial;
    _deviceLabel = _labelOf(device);
    _devicesError = null;
    _answers.clear();
    _resetPreparation();
    _setConnection(FlashConnection.waiting);
    _setPhase(FlashRunPhase.connecting);
    _notice = null;
    _notify();
    unawaited(prepare());
  }

  /// Uses the page chooser. The chooser is invoked before any await so the
  /// browser still sees the click gesture.
  Future<void> chooseDevice() async {
    if (_live || _restored) return;
    _devicesError = null;
    _notify();
    final FastbootDeviceChoice? chosen;
    try {
      chosen = await bridge.chooseFastbootDevice();
    } on UsbException catch (error) {
      _devicesError = '${error.kind.name}: $error';
      _notify();
      return;
    } on Object catch (error) {
      _devicesError = 'Could not open the USB chooser: $error';
      _notify();
      return;
    }
    if (_disposed) return;
    if (chosen == null) {
      _devicesError =
          'No device was chosen. Put the phone in bootloader fastboot, then '
          'choose it again.';
      _notify();
      return;
    }
    _serial = chosen.serial;
    _deviceLabel = chosen.label.isEmpty
        ? chosen.serial
        : '${chosen.label} · ${chosen.serial}';
    _answers.clear();
    _resetPreparation();
    _setConnection(FlashConnection.waiting);
    _setPhase(FlashRunPhase.connecting);
    _notice = null;
    _notify();
    await prepare();
  }

  void answerPrompt(String id, String choice) {
    if (_live || _restored) return;
    if (_answers[id] == choice) return;
    _answers[id] = choice;
    _acknowledged = false;
    _resetPreparation();
    _notify();
    _schedulePrepare();
  }

  void _schedulePrepare() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(prepare());
    });
  }

  Map<String, Object?> _request({String? token, String? job}) {
    final jobId = job ?? _prepared?.job ?? _derivedJob;
    return {
      'selection': target?.selection ?? const <String, Object?>{},
      'upstreamBase': upstreamBase,
      if (_serial != null) 'serial': _serial,
      'answers': Map<String, String>.from(_answers),
      'confirmationToken': ?token,
      'virtual': _virtualSnapshot(),
      if (jobId != null && jobId.isNotEmpty) 'job': jobId,
    };
  }

  /// A copy of the virtual identity, so the prepared request cannot change
  /// when the caller's map changes. The file object itself stays the same
  /// reference: that is the identity the service compares too.
  Map<String, Object?> _virtualSnapshot() {
    final virtual = target?.virtualRequest ?? const <String, Object?>{};
    return {
      'ota': _otaSnapshot(virtual['ota']),
      if (virtual['base'] != null) 'base': _otaSnapshot(virtual['base']),
      'bloat': _storeSnapshot(virtual['bloat']),
      if (target?.vulnerableAbl != null)
        'vulnerableAbl': target!.vulnerableAbl,
    };
  }

  Object? _otaSnapshot(Object? ota) => ota is Map
      ? <String, Object?>{
          'kind': ota['kind'],
          if (ota['file'] != null) 'file': ota['file'],
          if (ota['url'] != null) 'url': ota['url'],
          if (ota['entry'] is Map)
            'entry': Map<String, Object?>.from(ota['entry'] as Map),
        }
      : ota;

  Object? _storeSnapshot(Object? store) => store is Map
      ? <String, Object?>{
          'kind': store['kind'],
          if (store['path'] != null) 'path': store['path'],
          if (store['handle'] != null) 'handle': store['handle'],
        }
      : store;

  Future<void> prepare() async {
    if (_disposed || _live || _restored) return;
    final serial = _serial;
    if (serial == null || serial.isEmpty) return;
    _debounce?.cancel();
    final generation = ++_generation;
    _preparing = true;
    _prepareError = null;
    _acknowledged = false;
    _setPhase(FlashRunPhase.preparing);
    _notify();
    final request = _request();
    try {
      final response = await api.prepareFlash(request);
      if (_disposed || generation != _generation) return;
      final linkError = response['error'];
      if (linkError != null) {
        _prepared = null;
        _preparedRequest = null;
        _prepareError = describeLinkFailure(linkError);
        _log.add('Preparation evidence: ${jsonEncode(linkError)}');
        _setConnection(_linkLost(linkError)
            ? FlashConnection.lost
            : FlashConnection.waiting);
        return;
      }
      final prepared = PreparedFlash.fromMap(response);
      if (prepared.serial.isNotEmpty && prepared.serial != serial) {
        throw StateError(
          'The service prepared serial ${prepared.serial}, not $serial. '
          'Choose the device again.',
        );
      }
      final promptIds = {for (final prompt in prepared.prompts) prompt.id};
      _answers.removeWhere(
        (id, value) =>
            !promptIds.contains(id) ||
            !prepared.prompts
                .firstWhere((prompt) => prompt.id == id)
                .choices
                .contains(value),
      );
      _prepared = prepared;
      _preparedRequest = Map<String, Object?>.unmodifiable(request);
      if (prepared.job.isNotEmpty) _derivedJob = prepared.job;
      _setConnection(
        prepared.modeOk ? FlashConnection.ready : FlashConnection.waiting,
      );
    } on Object catch (error) {
      if (_disposed || generation != _generation) return;
      _prepared = null;
      _preparedRequest = null;
      _prepareError = '$error';
      _setConnection(FlashConnection.waiting);
    } finally {
      if (!_disposed && generation == _generation) {
        _preparing = false;
        _notify();
      }
    }
  }

  bool _linkLost(Object? error) {
    if (error is! Map) return false;
    return error['disconnectObserved'] == true ||
        error['sessionRetired'] == true ||
        '${error['name']}' == 'Disconnected' ||
        '${error['name']}' == 'NoDevice';
  }

  /// Check → Confirm. Only a resolved, consistent plan moves on.
  void reviewPlan() {
    if (_restored || _live || _preparing || !ready) return;
    if (_flow.phase != FlashRunPhase.confirming) {
      _flow = FlashFlowState(
        connection: _flow.connection,
        phase: FlashRunPhase.confirming,
        certainty: _flow.certainty,
      );
    }
    _notify();
  }

  /// Confirm → Check, so an answer can change. The acknowledgement clears.
  void editAnswers() {
    if (_restored || _live) return;
    _acknowledged = false;
    _setPhase(FlashRunPhase.preparing);
    _notify();
  }

  void setAcknowledged(bool value) {
    if (_live || _restored) return;
    if (value && !ready) return;
    _acknowledged = value && ready;
    _notify();
  }

  Future<void> flash() async {
    if (!canFlash) return;
    final prepared = _prepared!;
    final token = prepared.token!;
    final request = _request(token: token, job: prepared.job);
    if (!_sameRequest(_request(job: prepared.job), _preparedRequest)) {
      _errorText =
          'The confirmed input changed. Prepare the flash again before '
          'writing.';
      _resetPreparation();
      _notify();
      return;
    }
    final generation = _generation;
    _starting = true;
    _notify();
    // The checkpoint is written before the first command exists, so a reload
    // during preparation still restores what this page knew.
    await _persist();
    // The leave guard and wake lock must hold before the first command.
    try {
      await bridge.beginKeepAwake();
      _keepAwakeHeld = true;
      _wakeLockReported = !wakeLockSupported;
    } on Object catch (error) {
      _starting = false;
      _errorText =
          'Could not hold a wake lock or leave guard, so the flash '
          'was not started: $error';
      _notify();
      return;
    }
    if (_disposed ||
        generation != _generation ||
        !identical(_prepared, prepared) ||
        !_acknowledged) {
      _starting = false;
      _releaseAwake();
      _notify();
      return;
    }
    _starting = false;
    _runKind = _RunKind.flash;
    _sawStep = false;
    _waiting = null;
    _result = null;
    _receipt = null;
    _failureEvent = null;
    _superPreflight = null;
    _errorText = null;
    _guidance = null;
    _notice = null;
    _workerLost = false;
    _stepIndex = 0;
    _totalSteps = 0;
    _stepTitle = '';
    _progress.clear();
    _runId = null;
    _canRetry = false;
    _log
      ..clear()
      ..add('Flashing ${target?.label ?? ''} to serial ${_serial ?? ''}.');
    _setPhase(FlashRunPhase.preparing);
    _notify();
    _listen(api.flash(request));
  }

  void _listen(Stream<Map<String, Object?>> stream) {
    final token = ++_streamToken;
    try {
      _subscription = stream.listen(
        (event) => _onEvent(event, token),
        onError: (Object error) => _onError(error, token),
        onDone: () => _onDone(token),
        cancelOnError: false,
      );
    } on Object catch (error) {
      _onError(error, token);
    }
  }

  bool _sameRequest(
    Map<String, Object?> request,
    Map<String, Object?>? prepared,
  ) {
    if (prepared == null) return false;
    if (request['serial'] != prepared['serial']) return false;
    if ((request['upstreamBase'] ?? '') != (prepared['upstreamBase'] ?? '')) {
      return false;
    }
    if (!_sameMap(request['selection'], prepared['selection'])) return false;
    if (!_sameMap(request['answers'], prepared['answers'])) return false;
    // The job is derived from the OTA identity, so the identity itself is
    // what must still match: the same file object or catalog entry and the
    // same bloat store. A changed identity needs a new preparation.
    return _sameVirtual(request['virtual'], prepared['virtual']);
  }

  bool _sameVirtual(Object? a, Object? b) {
    if (a is! Map || b is! Map) return false;
    if (!_sameOta(a['ota'], b['ota']) || !_sameStore(a['bloat'], b['bloat'])) {
      return false;
    }
    final left = a['base'];
    final right = b['base'];
    if (left == null && right == null) return true;
    return _sameOta(left, right);
  }

  bool _sameOta(Object? a, Object? b) {
    if (a is! Map || b is! Map) return false;
    if (a['kind'] != b['kind']) return false;
    return switch ('${a['kind']}') {
      // A picked file is the browser object itself; a re-pick is new identity.
      'file' => a['file'] != null && identical(a['file'], b['file']),
      'url' => a['url'] == b['url'],
      'catalog' => _sameMap(a['entry'], b['entry']),
      _ => false,
    };
  }

  bool _sameMap(Object? a, Object? b) {
    if (a is! Map || b is! Map) return false;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// A directory store carries a browser handle that cannot be JSON encoded;
  /// the same handle object is the identity the service compares too.
  bool _sameStore(Object? a, Object? b) {
    if (a is! Map || b is! Map) return false;
    if (a['kind'] != b['kind']) return false;
    if (a['path'] != b['path']) return false;
    final left = a['handle'];
    final right = b['handle'];
    if (left == null && right == null) return true;
    return identical(left, right);
  }

  void _applyFlow(Map<String, Object?> event) {
    final flow = event['flow'];
    if (flow is Map) {
      final connection = _enumByName(FlashConnection.values, flow['connection']);
      final phase = _enumByName(FlashRunPhase.values, flow['phase']);
      final certainty = _enumByName(WriteCertainty.values, flow['certainty']);
      _flow = FlashFlowState(
        connection: connection ?? _flow.connection,
        phase: phase ?? _flow.phase,
        certainty: certainty ?? _flow.certainty,
      );
    } else {
      _flow = _flow.onEvent(event);
    }
  }

  T? _enumByName<T extends Enum>(List<T> values, Object? name) {
    for (final value in values) {
      if (value.name == '$name') return value;
    }
    return null;
  }

  void _onEvent(Map<String, Object?> event, int token) {
    if (_disposed || token != _streamToken) return;
    _applyFlow(event);
    switch (event['type']) {
      case 'run':
        final runId = event['runId'];
        if (runId is String && runId.isNotEmpty) _runId = runId;
      case 'failure':
        _waiting = null;
        _regrantMessage = null;
        _failureEvent = Map<String, Object?>.from(event);
        final index = event['stepIndex'];
        final failedAt = index is num ? index.toInt() : 0;
        final status = '${event['status']}';
        final reason = event['reason'];
        _log.add(
          '${status == 'uncertain' ? 'UNCERTAIN' : 'FAILED'}: step '
          '${failedAt + 1}'
          '${reason is String && reason.isNotEmpty ? ' — $reason' : ''}',
        );
        _releaseAwake();
      case 'step':
        _waiting = null;
        _regrantMessage = null;
        final index = event['index'];
        final total = event['total'];
        final title = event['title'];
        if (index is num) _stepIndex = index.toInt();
        if (total is num) _totalSteps = total.toInt();
        if (title is String) {
          _stepTitle = title;
          _log.add('$index/$total  $title');
          _sawStep = true;
        }
      case 'log':
        final text = event['text'];
        if (text is String) {
          for (final line in text.split('\n')) {
            if (line.trim().isNotEmpty) _log.add(line);
          }
        }
      case 'progress':
        final label = event['label'];
        final done = event['done'];
        final total = event['total'];
        if (label is String && done is num && total is num) {
          _progress[label] = (done: done.toInt(), total: total.toInt());
        }
      case 'waiting':
        _waiting = Map<String, Object?>.from(event);
        _log.add(
          'Waiting for ${event['serial']} in ${event['mode']}. Grant the same '
          'phone again in the USB chooser.',
        );
      case 'superPreflight':
        _superPreflight = Map<String, Object?>.from(event);
        _log.add('Super preflight: ${jsonEncode(event)}');
      case 'result':
        _result = Map<String, Object?>.from(event);
        final receipt = event['receipt'];
        _receipt = receipt is Map ? Map<String, Object?>.from(receipt) : null;
        final runId = event['runId'];
        if (runId is String && runId.isNotEmpty) _runId = runId;
        _canRetry = event['canRetry'] == true;
        final status = '${event['status'] ?? _receipt?['status'] ?? ''}';
        _log.add('Run finished: $status.');
        switch (status) {
          case 'succeeded':
            _failureEvent = null;
            _guidance =
                'The phone accepted every command with OKAY. That is not a '
                'readback verification of the bytes. Wiping and root '
                'installation stay manual on the phone.';
          case 'stopped' || 'cancelled':
            _guidance =
                'Stopped on request. No rollback was performed; commands '
                'already sent stay applied and a write in flight may have '
                'left the phone partially written.';
          default:
            break;
        }
        _finish(cancelSubscription: false);
      default:
        break;
    }
    if (const {
      'connection',
      'run',
      'step',
      'failure',
      'waiting',
      'superPreflight',
      'result',
    }.contains('${event['type']}')) {
      unawaited(_persist());
    }
    _notify();
  }

  void _onError(Object error, int token) {
    if (_disposed || token != _streamToken) return;
    _workerLost = true;
    _errorText = '$error';
    _log.add('ERROR: $error');
    _failureEvent = {
      'name': 'WorkerLost',
      'message': '$error',
      'stage': 'stream',
      'uncertain': _sawStep,
    };
    final certainty = _sawStep
        ? WriteCertainty.uncertain
        : _flow.certainty == WriteCertainty.confirmed
        ? WriteCertainty.confirmed
        : WriteCertainty.notSubmitted;
    _flow = FlashFlowState(
      connection: FlashConnection.stopped,
      phase: FlashRunPhase.stopped,
      certainty: certainty,
    );
    _finish(cancelSubscription: false);
    _notify();
  }

  void _onDone(int token) {
    if (_disposed || token != _streamToken) return;
    if (_flow.phase == FlashRunPhase.writing ||
        _flow.phase == FlashRunPhase.preparing) {
      _workerLost = true;
      _errorText = 'The flash stream ended without a result.';
      _log.add('ERROR: the flash stream ended without a result.');
      _failureEvent = {
        'name': 'WorkerLost',
        'message': _errorText,
        'stage': 'stream',
        'uncertain': _sawStep,
      };
      _flow = FlashFlowState(
        connection: FlashConnection.stopped,
        phase: FlashRunPhase.stopped,
        certainty: _sawStep
            ? WriteCertainty.uncertain
            : WriteCertainty.notSubmitted,
      );
      _finish(cancelSubscription: false);
      _notify();
    }
  }

  void _finish({bool cancelSubscription = true}) {
    _regranting = false;
    _waiting = null;
    _runKind = _RunKind.none;
    _streamToken++;
    final subscription = _subscription;
    _subscription = null;
    if (cancelSubscription && subscription != null) {
      _stopping = true;
      unawaited(_cancelAndRelease(subscription));
    } else {
      _releaseAwake();
    }
    // A used token is never offered again: a new flash needs a new read-only
    // preparation and confirmation.
    _prepared = null;
    _preparedRequest = null;
    _acknowledged = false;
    unawaited(_persist());
    _notify();
  }

  Future<void> _cancelAndRelease(
    StreamSubscription<Map<String, Object?>> subscription,
  ) async {
    try {
      await subscription.cancel();
    } on Object catch (error) {
      _log.add('Cancellation acknowledgement failed: $error');
    } finally {
      _releaseAwake();
      _stopping = false;
      _notify();
    }
  }

  /// Stops a running or paused run and keeps the returned receipt.
  ///
  /// No rollback happens: no new command is sent after the in-flight one
  /// completes, and an uncertain attempt stays uncertain.
  Future<void> stop() async {
    final runId = _runId;
    if (runId == null || _stoppingRun || _disposed || _restored) return;
    if (_flow.phase != FlashRunPhase.writing && !_canRetry) return;
    _stoppingRun = true;
    _notify();
    await _persist();
    Map<String, Object?>? receipt;
    Object? failure;
    try {
      final response = await api.stopRun({'runId': runId});
      final value = response['receipt'];
      if (value is Map) receipt = Map<String, Object?>.from(value);
    } on Object catch (error) {
      failure = error;
    }
    if (_disposed) return;
    _stoppingRun = false;
    if (receipt == null) {
      _errorText = 'The service did not confirm the stop: ${failure ?? ''}';
      _log.add('ERROR: the stop was not confirmed: ${failure ?? ''}');
      _notify();
      return;
    }
    _receipt = receipt;
    _canRetry = false;
    _errorText = null;
    _notice = null;
    _guidance =
        'Stopped on request. No rollback was performed; commands already sent '
        'stay applied and a write in flight may have left the phone partially '
        'written.';
    _log.add('Stopped on request; no further commands are sent.');
    final flow = _flow.onEvent({
      'type': 'result',
      'status': 'stopped',
      'receipt': receipt,
    });
    _flow = flow;
    await _finishStopped();
  }

  Future<void> _finishStopped() async {
    _regranting = false;
    _waiting = null;
    _runKind = _RunKind.none;
    _streamToken++;
    final subscription = _subscription;
    _subscription = null;
    await _persist();
    if (subscription == null) {
      _releaseAwake();
      _notify();
      return;
    }
    _stopping = true;
    try {
      await subscription.cancel();
    } on Object catch (error) {
      _log.add('The stop acknowledgement failed: $error');
    } finally {
      _releaseAwake();
      _stopping = false;
      _notify();
    }
  }

  /// Runs one explicit recovery action. Only the service decides which
  /// actions exist; this method only names the exact serial and the physical
  /// confirmation the action requires.
  Future<void> recover(
    FlashRecovery action, {
    String? confirmedSerial,
    bool powerCycled = false,
  }) async {
    final runId = _runId;
    if (runId == null || !canRecover || action == FlashRecovery.stopRun) {
      return;
    }
    if ((action == FlashRecovery.rewriteStep ||
            action == FlashRecovery.wipeSuper) &&
        (confirmedSerial == null ||
            _serial == null ||
            confirmedSerial != _serial)) {
      _errorText =
          'Type the exact serial ${_serial ?? ''} to confirm this action.';
      _notify();
      return;
    }
    if (action == FlashRecovery.recoverPowerCycle && !powerCycled) {
      _errorText = 'Follow the power-cycle instructions first.';
      _notify();
      return;
    }
    if (!recoveryActions.any((option) => option['action'] == action.name)) {
      _errorText = 'The service does not offer that action for this run.';
      _notify();
      return;
    }
    _starting = true;
    _notify();
    await _persist();
    try {
      await bridge.beginKeepAwake();
      _keepAwakeHeld = true;
      _wakeLockReported = !wakeLockSupported;
    } on Object catch (error) {
      _starting = false;
      _errorText =
          'Could not hold a wake lock or leave guard, so the recovery was '
          'not started: $error';
      _notify();
      return;
    }
    if (_disposed || _runId != runId || !_canRetry) {
      _starting = false;
      _releaseAwake();
      _notify();
      return;
    }
    _starting = false;
    _canRetry = false;
    _runKind = _RunKind.recovery;
    _result = null;
    _errorText = null;
    _guidance = null;
    _notice = null;
    _waiting = null;
    _workerLost = false;
    _stepIndex = 0;
    _totalSteps = 0;
    _stepTitle = '';
    _progress.clear();
    _setPhase(FlashRunPhase.preparing);
    _log.add('Recovery ${action.name} requested for step '
        '${(_receipt?['stepIndex'] is num ? (_receipt!['stepIndex']! as num).toInt() : 0) + 1}.');
    _notify();
    final request = <String, Object?>{
      'runId': runId,
      'confirmedSerial': ?confirmedSerial,
      if (powerCycled) 'powerCycled': true,
    };
    final stream = switch (action) {
      FlashRecovery.retryRead => api.retryRead(request),
      FlashRecovery.reconnectDevice => api.reconnectDevice(request),
      FlashRecovery.recoverBootloader => api.recoverBootloader(request),
      FlashRecovery.recoverFastbootd => api.recoverFastbootd(request),
      FlashRecovery.recoverPowerCycle => api.recoverPowerCycle(request),
      FlashRecovery.rewriteStep => api.rewriteStep(request),
      FlashRecovery.wipeSuper => api.wipeSuper(request),
      FlashRecovery.stopRun => throw StateError('Use stop() to stop.'),
    };
    _listen(stream);
  }

  /// Grants the waiting serial again. A different device is refused before
  /// any command can reach it.
  Future<void> regrantDevice() async {
    final expected = waitingSerial;
    if (expected == null || _regranting || _disposed) return;
    _regranting = true;
    _regrantMessage = null;
    _notify();
    // The chooser must run inside this click task, before any await.
    final FastbootDeviceChoice? chosen;
    try {
      chosen = await bridge.chooseFastbootDevice();
    } on UsbException catch (error) {
      _regranting = false;
      _regrantMessage = '$error';
      _notify();
      return;
    } on Object catch (error) {
      _regranting = false;
      _regrantMessage = 'Could not open the USB chooser: $error';
      _notify();
      return;
    }
    if (_disposed) return;
    _regranting = false;
    if (chosen == null) {
      _regrantMessage =
          'No device chosen. The flash is still waiting for serial $expected.';
    } else if (chosen.serial != expected) {
      _regrantMessage =
          'You chose ${chosen.serial}, but the flash is waiting for '
          '$expected. Nothing was sent to the wrong device. Choose the '
          'same phone again.';
    } else {
      _regrantMessage =
          'Serial $expected is granted again. The service will reopen that '
          'exact device.';
      _log.add('Serial $expected granted again.');
    }
    _notify();
  }

  Future<String?> downloadReceipt() async {
    final receipt = _receipt;
    if (receipt == null) return 'No receipt is available yet.';
    final port = (_serial ?? 'device').replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    await bridge.downloadText(
      '${const JsonEncoder.withIndent('  ').convert(receipt)}\n',
      'flash-$_jobSlug-$port.json',
    );
    return null;
  }

  Future<String?> saveLog() async {
    if (_log.isEmpty) return 'There is no flash log yet.';
    final port = (_serial ?? 'device').replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    await bridge.downloadText(logText, 'flash-$_jobSlug-$port.log');
    return null;
  }

  /// The diagnostics the Done and Recover screens expose: the log plus the
  /// raw receipt when one exists.
  String get diagnosticsText {
    final receipt = _receipt;
    final failure = _failureEvent;
    final buffer = StringBuffer();
    if (_log.isNotEmpty) buffer.writeln(_log.join('\n'));
    if (failure != null && receipt?['failure'] == null) {
      buffer
        ..writeln()
        ..writeln('Failure evidence:')
        ..writeln(const JsonEncoder.withIndent('  ').convert(failure));
    }
    if (receipt != null) {
      buffer
        ..writeln()
        ..writeln('Receipt:')
        ..writeln(const JsonEncoder.withIndent('  ').convert(receipt));
    }
    return buffer.toString();
  }

  /// The reload offer: the page keeps its checkpoint and reloads into it.
  Future<void> reloadForUpdate() async {
    if (!canReloadNow) return;
    await _persist();
    bridge.reloadPage();
  }

  String get _jobSlug => jobId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  void _resetPreparation() {
    _debounce?.cancel();
    _generation++;
    // The in-flight preparation is fenced by the generation; its spinner must
    // not outlive it.
    _preparing = false;
    _prepared = null;
    _preparedRequest = null;
    _acknowledged = false;
    _prepareError = null;
    _progress.clear();
    _stepIndex = 0;
    _totalSteps = 0;
    _stepTitle = '';
    if (!_live && !_restored) {
      _setPhase(
        _serial == null ? FlashRunPhase.setup : FlashRunPhase.preparing,
      );
    }
  }

  void _setPhase(FlashRunPhase phase) {
    if (_flow.phase == phase) return;
    _flow = FlashFlowState(
      connection: _flow.connection,
      phase: phase,
      certainty: _flow.certainty,
    );
  }

  void _setConnection(FlashConnection connection) {
    if (_flow.connection == connection) return;
    _flow = _flow.onEvent({'type': 'connection', 'state': connection.name});
  }

  // ------------------------------------------------------------ lifecycle

  void _onUsbAttach(UsbAttachEvent event) {
    if (_disposed || _restored) return;
    _log.add('USB $event.');
    // Arrival and removal never change write certainty, never issue a write
    // and never start a competing probe while a run is live.
    if (_live || _flow.phase == FlashRunPhase.writing) {
      _notify();
      return;
    }
    final serial = event.serial;
    if (serial != null && serial == _serial) {
      if (event.attached) {
        _setConnection(FlashConnection.waiting);
        _notice =
            'Serial $serial is back. Check the phone to prepare a new plan.';
      } else {
        _setConnection(FlashConnection.lost);
        _notice =
            'Serial $serial left USB. Replug it, then check the phone again.';
        _resetPreparation();
      }
      _notify();
      return;
    }
    if (!event.attached && _devices.isNotEmpty) {
      _devices = [
        for (final device in _devices)
          if (device['serial'] != serial) device,
      ];
    }
    _notify();
  }

  void _onAppUpdate(String version) {
    if (_disposed) return;
    _updateVersion = version;
    _updateReady = true;
    _log.add('A new app version ($version) took control of this page.');
    _notify();
  }

  // ---------------------------------------------------------- checkpoints

  Map<String, Object?> _checkpoint() => {
    'version': 1,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'runId': ?_runId,
    'serial': ?_serial,
    'target': {
      'label': target?.label ?? '',
      'selection': target?.selection ?? const <String, Object?>{},
    },
    'status': _checkpointStatus,
    'phase': _flow.phase.name,
    'connection': _flow.connection.name,
    'certainty': _flow.certainty.name,
    'stepIndex': _stepIndex,
    'totalSteps': _totalSteps,
    'stepTitle': _stepTitle,
    'receipt': ?_receipt,
    if (_failureEvent != null) 'failure': _failureEvent,
    if (_superPreflight != null) 'superPreflight': _superPreflight,
  };

  String get _checkpointStatus {
    final status = _receipt?['status'];
    if (status is String && status.isNotEmpty) return status;
    return switch (_flow.phase) {
      FlashRunPhase.writing => 'writing',
      FlashRunPhase.preparing => 'preparing',
      FlashRunPhase.recovering => 'failed',
      FlashRunPhase.done => 'succeeded',
      FlashRunPhase.stopped => 'stopped',
      _ => 'idle',
    };
  }

  Future<void> _persist() {
    final snapshot = _checkpoint();
    _checkpointWrites = _checkpointWrites.then((_) async {
      try {
        await bridge.writeFlashCheckpoint(snapshot);
      } on Object {
        // A blocked store leaves no restorable receipt; the live run is
        // unaffected.
      }
    });
    return _checkpointWrites;
  }

  void _restore(Map<String, Object?> checkpoint) {
    _restored = true;
    final runId = checkpoint['runId'];
    if (runId is String && runId.isNotEmpty) _runId = runId;
    final serial = checkpoint['serial'];
    if (serial is String && serial.isNotEmpty) _serial = serial;
    final receipt = checkpoint['receipt'];
    _receipt = receipt is Map ? Map<String, Object?>.from(receipt) : null;
    final failure = checkpoint['failure'];
    _failureEvent = failure is Map ? Map<String, Object?>.from(failure) : null;
    final preflight = checkpoint['superPreflight'];
    _superPreflight = preflight is Map
        ? Map<String, Object?>.from(preflight)
        : null;
    final index = checkpoint['stepIndex'];
    if (index is num) _stepIndex = index.toInt();
    final total = checkpoint['totalSteps'];
    if (total is num) _totalSteps = total.toInt();
    final title = checkpoint['stepTitle'];
    if (title is String) _stepTitle = title;
    final status = '${_receipt?['status'] ?? checkpoint['status'] ?? ''}';
    final finished =
        _receipt != null &&
        (status == 'succeeded' || status == 'stopped' || status == 'failed');
    final uncertain = _receipt?['uncertain'] == true || !finished;
    _canRetry = false;
    _flow = FlashFlowState(
      connection: FlashConnection.stopped,
      phase: status == 'succeeded' && !uncertain
          ? FlashRunPhase.done
          : FlashRunPhase.stopped,
      certainty: status == 'succeeded' && !uncertain
          ? WriteCertainty.confirmed
          : uncertain
          ? WriteCertainty.uncertain
          : WriteCertainty.refused,
    );
    _restoredNote = uncertain
        ? 'This run was still live, failed or uncertain when the page '
              'reloaded. It was not resumed and none of its commands will be '
              'replayed: treat any unconfirmed write as uncertain.'
        : 'This is the receipt this browser kept when the page last loaded. '
              'It is inspection only; prepare and confirm a new run to write.';
  }

  void _releaseAwake() {
    if (!_keepAwakeHeld) return;
    _keepAwakeHeld = false;
    unawaited(_endAwake());
  }

  Future<void> _endAwake() async {
    try {
      await bridge.endKeepAwake();
    } on Object {
      // The page is closing or the guard was already gone; nothing to fix.
    }
  }

  /// Reported once the guard is held: a page without a wake lock is told so
  /// rather than treated as a reason to write without confirmation.
  bool get wakeLockMissing => _wakeLockReported;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _streamToken++;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      _stopping = true;
      unawaited(_cancelAndRelease(subscription));
    } else {
      _releaseAwake();
    }
    unawaited(_usbSubscription?.cancel());
    unawaited(_updateSubscription?.cancel());
    super.dispose();
  }
}

enum _RunKind { none, flash, recovery }
