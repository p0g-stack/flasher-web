import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/flasher_api.dart';
import '../api/platform_bridge.dart';
import '../runtime.dart';
import 'flash_target.dart';

/// Where one flash attempt is.
enum FlashPhase {
  idle,
  preparing,
  ready,
  running,
  succeeded,
  failed,
  uncertain,
  cancelled,
}

/// Prepares and executes one flash from a finished job.
///
/// Preparation is read-only and returns a token that binds the exact device,
/// job, answers and inspected images. Any change clears both that token and
/// the user's confirmation; execution sends the token from the latest
/// preparation only.
final class FlashController extends ChangeNotifier {
  FlashController({
    required this.api,
    required this.bridge,
    required this.environment,
    required this.target,
    required this.upstreamBase,
  });

  final FlasherApi api;
  final PlatformBridge bridge;
  final EnvironmentInfo environment;
  final FlashTarget target;
  final String upstreamBase;

  FlashPhase _phase = FlashPhase.idle;
  List<Map<String, Object?>> _devices = const [];
  bool _devicesLoading = false;
  String? _devicesError;
  String? _serial;
  String _deviceLabel = '';
  final _answers = <String, String>{};
  bool _productRequired = false;
  bool _acknowledged = false;
  bool _preparing = false;
  bool _starting = false;
  bool _stopping = false;
  Future<void>? _stoppingFuture;
  String? _prepareError;
  PreparedFlash? _prepared;
  Map<String, Object?>? _preparedRequest;
  String? _derivedJob;
  int _generation = 0;
  Timer? _debounce;
  StreamSubscription<Map<String, Object?>>? _subscription;
  bool _sawStep = false;
  bool _awake = false;
  bool _disposed = false;

  final _log = <String>[];
  final _progress = <String, ({int done, int total})>{};
  int _stepIndex = 0;
  int _totalSteps = 0;
  String _stepTitle = '';
  Map<String, Object?>? _waiting;
  Map<String, Object?>? _result;
  Map<String, Object?>? _receipt;
  String? _errorText;
  String? _guidance;
  String? _cancelNote;
  bool _regranting = false;
  String? _regrantMessage;

  bool _exporting = false;
  String? _exportError;
  Map<String, Object?>? _exportResult;
  StreamSubscription<Map<String, Object?>>? _exportSubscription;
  final _exportLog = <String>[];
  final _exportProgress = <String, ({int done, int total})>{};

  FlashPhase get phase => _phase;
  List<Map<String, Object?>> get devices => List.unmodifiable(_devices);
  bool get devicesLoading => _devicesLoading;
  String? get devicesError => _devicesError;
  String? get serial => _serial;
  String get deviceLabel => _deviceLabel;
  Map<String, String> get answers => Map.unmodifiable(_answers);
  bool get productRequired => _productRequired;
  bool get acknowledged => _acknowledged;
  bool get preparing => _preparing;
  String? get prepareError => _prepareError;
  PreparedFlash? get prepared => _prepared;
  bool get writesSupported => environment.has('usb.web');
  bool get pageCanChoose => bridge.canChooseFastbootDevice;
  bool get running => _phase == FlashPhase.running || _stopping;
  bool get terminal => switch (_phase) {
    FlashPhase.succeeded ||
    FlashPhase.failed ||
    FlashPhase.uncertain ||
    FlashPhase.cancelled => true,
    _ => false,
  };
  List<String> get log => List.unmodifiable(_log);
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
  String? get cancelNote => _cancelNote;
  bool get regranting => _regranting;
  String? get regrantMessage => _regrantMessage;
  String get logText => _log.join('\n');

  /// The job the service will flash. A virtual job id is derived by the
  /// service from the OTA identity, so it appears after preparation.
  String get jobId {
    if (!target.isVirtual) return target.job;
    final job = _prepared?.job ?? _derivedJob;
    return job == null || job.isEmpty ? 'assigned by the service' : job;
  }

  String get receiptPath => target.isHosted
      ? 'this browser download (hosted job ${target.job})'
      : target.isVirtual
      ? 'this browser download (virtual job $jobId; no local job exists)'
      : '${target.job}/flash-receipt.json';

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
      _prepared!.productMatches &&
      answersComplete;

  /// The final button is enabled only for a fully resolved, explicitly
  /// confirmed plan whose token belongs to the current input.
  bool get canFlash =>
      writesSupported &&
      !running &&
      !_preparing &&
      !_starting &&
      ready &&
      _acknowledged;

  /// Any prompt without an explicit answer, or a plan whose product/mode
  /// still blocks it.
  String? get blockingReason {
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
      return 'The plan is not resolved yet. Prepare again after answering.';
    }
    if (!prepared.modeOk) {
      return 'The phone is in ${prepared.mode}. Reboot it to bootloader '
          'fastboot, then choose it and prepare again.';
    }
    if (!_acknowledged) {
      return 'Confirm the exact serial and product below.';
    }
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

  Future<void> start() async {
    await refreshDevices();
  }

  Future<void> refreshDevices() async {
    if (_disposed || running) return;
    _devicesLoading = true;
    _devicesError = null;
    _notify();
    try {
      final response = await api.fastbootDevices();
      if (_disposed) return;
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
      if (error != null) _devicesError = describeLinkFailure(error);
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
        }
      }
    } on Object catch (error) {
      if (_disposed) return;
      _devicesLoading = false;
      _devicesError = '$error';
    }
    _notify();
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
    if (serial is! String || serial.isEmpty || running) return;
    if (serial == _serial) return;
    _serial = serial;
    _deviceLabel = _labelOf(device);
    _devicesError = null;
    _resetPreparation();
    _answers.clear();
    _productRequired = false;
    _notify();
    unawaited(prepare());
  }

  /// Uses the page chooser. The chooser is invoked before any await so the
  /// browser still sees the click gesture.
  Future<void> chooseDevice() async {
    if (running) return;
    _devicesError = null;
    _notify();
    final FastbootUsbDevice? chosen;
    try {
      chosen = await bridge.chooseFastbootDevice();
    } on FastbootUsbException catch (error) {
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
    _resetPreparation();
    _answers.clear();
    _productRequired = false;
    _notify();
    await prepare();
  }

  void setProductOverride(String value) {
    if (running) return;
    final product = value.trim();
    if ((_answers['product'] ?? '') == product) return;
    if (product.isEmpty) {
      _answers.remove('product');
    } else {
      _answers['product'] = product;
    }
    _resetPreparation();
    _notify();
    _schedulePrepare();
  }

  void answerPrompt(String id, String choice) {
    if (running) return;
    if (_answers[id] == choice) return;
    _answers[id] = choice;
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
    final request = <String, Object?>{
      'selection': target.selection,
      'upstreamBase': upstreamBase,
      if (_serial != null) 'serial': _serial,
      'answers': Map<String, String>.from(_answers),
      'confirmationToken': ?token,
    };
    if (target.isHosted) {
      request['job'] = target.job;
      request['hosted'] = target.hostedRequest;
      return request;
    }
    if (target.isVirtual) {
      // Preparation omits the job: the service derives it from the OTA
      // identity and returns it. Execution echoes the returned id, which is
      // what the confirmed plan is bound to.
      final jobId = job ?? _prepared?.job ?? target.job;
      if (jobId.isNotEmpty) request['job'] = jobId;
      request['virtual'] = _virtualSnapshot();
      return request;
    }
    request['job'] = target.job;
    request['output'] = target.store;
    return request;
  }

  /// A copy of the virtual identity, so the prepared request cannot change
  /// when the caller's map changes. The file object itself stays the same
  /// reference: that is the identity the service compares too.
  Map<String, Object?>? _virtualSnapshot() {
    final virtual = target.virtualRequest;
    if (virtual == null) return null;
    final ota = virtual['ota'];
    final bloat = virtual['bloat'];
    return {
      'ota': ota is Map
          ? <String, Object?>{
              'kind': ota['kind'],
              if (ota['file'] != null) 'file': ota['file'],
              if (ota['url'] != null) 'url': ota['url'],
              if (ota['entry'] is Map)
                'entry': Map<String, Object?>.from(ota['entry'] as Map),
            }
          : ota,
      'bloat': bloat is Map
          ? <String, Object?>{
              'kind': bloat['kind'],
              if (bloat['path'] != null) 'path': bloat['path'],
              if (bloat['handle'] != null) 'handle': bloat['handle'],
            }
          : bloat,
    };
  }

  Future<void> prepare() async {
    if (_disposed || running) return;
    final serial = _serial;
    if (serial == null || serial.isEmpty) return;
    _debounce?.cancel();
    final generation = ++_generation;
    if (terminal) {
      _result = null;
      _receipt = null;
      _guidance = null;
      _cancelNote = null;
      _errorText = null;
    }
    _phase = FlashPhase.preparing;
    _preparing = true;
    _prepareError = null;
    _acknowledged = false;
    _notify();
    final request = _request();
    try {
      final response = await api.prepareFlash(request);
      if (_disposed || generation != _generation) return;
      final linkError = response['error'];
      if (linkError != null) {
        _prepared = null;
        _preparedRequest = null;
        _productRequired = false;
        _prepareError = describeLinkFailure(linkError);
        return;
      }
      if (response['productRequired'] == true) {
        _prepared = null;
        _preparedRequest = null;
        _productRequired = true;
        _prepareError = '${response['message']}';
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
            id != 'product' &&
            (!promptIds.contains(id) ||
                !prepared.prompts
                    .firstWhere((prompt) => prompt.id == id)
                    .choices
                    .contains(value)),
      );
      _prepared = prepared;
      _preparedRequest = Map<String, Object?>.unmodifiable(request);
      if (prepared.job.isNotEmpty) _derivedJob = prepared.job;
      _productRequired = false;
    } on Object catch (error) {
      if (_disposed || generation != _generation) return;
      final text = '$error';
      _prepared = null;
      _preparedRequest = null;
      _productRequired = false;
      _prepareError = text;
    } finally {
      if (!_disposed && generation == _generation) {
        _preparing = false;
        if (_phase == FlashPhase.preparing) _phase = FlashPhase.ready;
        _notify();
      }
    }
  }

  void setAcknowledged(bool value) {
    if (running) return;
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
      _phase = FlashPhase.ready;
      _notify();
      return;
    }
    final generation = _generation;
    _starting = true;
    _notify();
    // The leave guard and wake lock must hold before the first command.
    try {
      await bridge.beginKeepAwake();
      _awake = true;
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
    _phase = FlashPhase.running;
    _starting = false;
    _sawStep = false;
    _waiting = null;
    _result = null;
    _receipt = null;
    _errorText = null;
    _guidance = null;
    _cancelNote = null;
    _regrantMessage = null;
    _stepIndex = 0;
    _stepTitle = '';
    _log
      ..clear()
      ..add('Flashing ${target.label} to serial ${_serial ?? ''}.')
      ..add('Product ${prepared.expectedProduct}.');
    _notify();
    try {
      _subscription = api
          .flash(request)
          .listen(
            _onEvent,
            onError: _onError,
            onDone: _onDone,
            cancelOnError: false,
          );
    } on Object catch (error) {
      _onError(error);
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
    if (target.isVirtual) {
      // The job is derived from the OTA identity, so the identity itself is
      // what must still match: the same file object or catalog entry and the
      // same bloat store. A changed identity needs a new preparation.
      return _sameVirtual(request['virtual'], prepared['virtual']);
    }
    if (request['job'] != prepared['job']) return false;
    if (target.isHosted) {
      return _sameMap(request['hosted'], prepared['hosted']);
    }
    return _sameStore(request['output'], prepared['output']);
  }

  /// The virtual identity: the OTA source and the bloat store.
  bool _sameVirtual(Object? a, Object? b) {
    if (a is! Map || b is! Map) return false;
    return _sameOta(a['ota'], b['ota']) && _sameStore(a['bloat'], b['bloat']);
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

  void _onEvent(Map<String, Object?> event) {
    if (_disposed) return;
    switch (event['type']) {
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
      case 'result':
        _result = Map<String, Object?>.from(event);
        final receipt = event['receipt'];
        _receipt = receipt is Map ? Map<String, Object?>.from(receipt) : null;
        final status = '${event['status'] ?? _receipt?['status'] ?? ''}';
        _phase = switch (status) {
          'succeeded' => FlashPhase.succeeded,
          'cancelled' => FlashPhase.cancelled,
          'uncertain' => FlashPhase.uncertain,
          _ => FlashPhase.failed,
        };
        _log.add('Flash finished: $status.');
        if (_phase == FlashPhase.failed) {
          _guidance =
              'The flash stopped at the first failure. Do not retry writes '
              'automatically. Reconnect the phone, inspect the steps above, '
              'then choose it and prepare a new flash.';
        } else if (_phase == FlashPhase.uncertain) {
          _guidance =
              'A write may have reached the phone without confirmation. Do '
              'not retry automatically. Reconnect it in fastboot and check '
              'the affected partitions before preparing a new flash.';
        } else if (_phase == FlashPhase.succeeded) {
          final persistence = _receipt?['persistenceWarnings'];
          _guidance = target.isHosted
              ? (persistence is List && persistence.isNotEmpty
                    ? 'Flashing finished, but the hosted receipt warning is: '
                          '${persistence.join('; ')} Download the receipt now.'
                    : 'The hosted build has no local job, so download the '
                          'receipt now; it is not written into a local folder. '
                          'Wiping and rooting stay manual on the phone.')
              : target.isVirtual
              ? 'The OTA was flashed in place from its own bytes and no local '
                    'job exists, so download the receipt now. Wiping and '
                    'rooting stay manual on the phone.'
              : (persistence is List && persistence.isNotEmpty
                    ? 'Flashing finished, but the receipt could not be fully '
                          'saved. Download it now. '
                          '${persistence.join('; ')}'
                    : 'The service saved the receipt at $receiptPath. Wiping '
                          'and rooting stay manual on the phone.');
        }
        _finish(cancelSubscription: false);
      default:
        break;
    }
    _notify();
  }

  void _onError(Object error) {
    if (_disposed || terminal) return;
    if (_phase != FlashPhase.running) {
      _errorText = '$error';
      _phase = FlashPhase.failed;
      _finish();
      return;
    }
    _errorText = '$error';
    _phase = _sawStep ? FlashPhase.uncertain : FlashPhase.failed;
    _guidance = _phase == FlashPhase.uncertain
        ? 'The stream broke after at least one command, so the phone may be '
              'partially written. Do not retry automatically. Reconnect it in '
              'fastboot and inspect the device before preparing again.'
        : 'The stream ended before any step ran. Reconnect the phone and '
              'prepare again.';
    _log.add('ERROR: $error');
    _finish();
  }

  void _onDone() {
    if (_disposed || terminal) return;
    if (_phase == FlashPhase.running) {
      _phase = _sawStep ? FlashPhase.uncertain : FlashPhase.failed;
      _errorText = 'The flash stream ended without a result.';
      _guidance = _phase == FlashPhase.uncertain
          ? 'A command may have reached the phone. Do not retry '
                'automatically; reconnect it and inspect the device.'
          : 'No step ran. Reconnect the phone and prepare again.';
      _log.add('ERROR: The flash stream ended without a result.');
    }
    _finish();
  }

  void _finish({bool cancelSubscription = true}) {
    _regranting = false;
    _waiting = null;
    final subscription = _subscription;
    _subscription = null;
    if (cancelSubscription && subscription != null) {
      _stopping = true;
      _stoppingFuture = _cancelAndRelease(subscription);
    } else if (!_stopping) {
      _releaseAwake();
    }
    // A used token is never offered again: a retry needs a new read-only
    // preparation and a new explicit confirmation.
    if (terminal) {
      _prepared = null;
      _preparedRequest = null;
      _acknowledged = false;
    }
    _notify();
  }

  Future<void> _cancelAndRelease(
    StreamSubscription<Map<String, Object?>> subscription,
  ) async {
    try {
      // Cancellation acknowledges only after the service stops in-flight work.
      await subscription.cancel();
    } on Object catch (error) {
      _log.add('Cancellation acknowledgement failed: $error');
      _phase = FlashPhase.uncertain;
      _guidance =
          'The worker did not acknowledge cancellation. Inspect the '
          'phone before any retry; no rollback was performed.';
    } finally {
      if (_awake) {
        _awake = false;
        await _endAwake();
      }
      _stopping = false;
      _notify();
    }
  }

  /// Cancelling stops future commands; it never rolls the phone back.
  Future<void> cancel() async {
    if (_phase != FlashPhase.running) {
      await _stoppingFuture;
      return;
    }
    _phase = FlashPhase.cancelled;
    _cancelNote =
        'Cancelled. No rollback was performed. Commands already sent stay '
        'applied, and a write in flight may have left the phone partially '
        'written. Reconnect it in fastboot and inspect it before flashing '
        'again. ${target.isHosted ? 'Download the receipt from this page; a hosted job has no local folder.' : 'The service may still persist a receipt at $receiptPath.'}';
    _guidance =
        'This is not a rollback. Do not retry automatically; reconnect the '
        'phone and inspect its state.';
    _log.add('Cancelled by you; no rollback was performed.');
    _finish();
    await _stoppingFuture;
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
    final FastbootUsbDevice? chosen;
    try {
      chosen = await bridge.chooseFastbootDevice();
    } on FastbootUsbException catch (error) {
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
    if (receipt == null) {
      return 'No receipt is available yet.';
    }
    final port = (_serial ?? 'device').replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    final name = 'flash-$_jobSlug-$port.json';
    await bridge.downloadText(
      '${const JsonEncoder.withIndent('  ').convert(receipt)}\n',
      name,
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

  String get _jobSlug => target.isVirtual
      ? jobId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
      : target.job;

  // ---------------------------------------------------------------- export

  bool get canExportZip => target.isVirtual;

  bool get exporting => _exporting;
  String? get exportError => _exportError;
  Map<String, Object?>? get exportResult => _exportResult;
  List<String> get exportLog => List.unmodifiable(_exportLog);
  Map<String, ({int done, int total})> get exportProgress =>
      Map.unmodifiable(_exportProgress);

  /// Writes a portable ZIP of this virtual package into a save-picker file.
  ///
  /// The service reads the OTA and verified bloat exactly as a flash does and
  /// streams the archive into the chosen `FileSystemFileHandle`; nothing is
  /// staged in browser storage. Returns null on success or cancellation and an
  /// explanation otherwise.
  Future<String?> exportZip() async {
    final virtual = target.virtualRequest;
    if (virtual == null) {
      return 'Only the OTA-backed direct flash can export a package.';
    }
    if (_exporting) return 'An export is already running.';
    final Object? destination;
    try {
      // The picker must run inside the click task, before any await.
      destination = await bridge.pickSaveFile(
        suggestedName: 'flasher-${_safeName(target.label)}.zip',
      );
    } on Object catch (error) {
      return '$error';
    }
    if (destination == null) return null;
    _exporting = true;
    _exportError = null;
    _exportResult = null;
    _exportLog.clear();
    _exportProgress.clear();
    _notify();
    final completer = Completer<String?>();
    final request = <String, Object?>{
      'virtual': virtual,
      'selection': target.selection,
      'upstreamBase': upstreamBase,
      'destination': destination,
    };
    void finish() {
      _exporting = false;
      if (!completer.isCompleted) {
        completer.complete(_exportError);
      }
      _notify();
    }

    try {
      _exportSubscription = api
          .exportVirtual(request)
          .listen(
            (event) {
              switch (event['type']) {
                case 'step':
                  final title = event['title'];
                  if (title is String && title.isNotEmpty) {
                    _exportLog.add(title);
                  }
                case 'log':
                  final text = event['text'];
                  if (text is String) {
                    for (final line in text.split('\n')) {
                      if (line.trim().isNotEmpty) _exportLog.add(line);
                    }
                  }
                case 'progress':
                  final label = event['label'];
                  final done = event['done'];
                  final total = event['total'];
                  if (label is String && done is num && total is num) {
                    _exportProgress[label] = (
                      done: done.toInt(),
                      total: total.toInt(),
                    );
                  }
                case 'result':
                  _exportResult = Map<String, Object?>.from(event);
                  _exportLog.add(
                    'Exported ${event['bytes']} bytes · SHA-256 '
                    '${event['sha256']}',
                  );
                default:
                  break;
              }
              _notify();
            },
            onError: (Object error) {
              _exportError = 'The export failed: $error';
              _exportLog.add('ERROR: $error');
              finish();
            },
            onDone: () {
              if (_exportResult == null && _exportError == null) {
                _exportError = 'The export ended without a result.';
              }
              finish();
            },
            cancelOnError: false,
          );
    } on Object catch (error) {
      _exportError = 'The export failed: $error';
      _exportLog.add('ERROR: $error');
      finish();
    }
    return completer.future;
  }

  String _safeName(String value) => value
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  void _resetPreparation() {
    _debounce?.cancel();
    _generation++;
    _prepared = null;
    _preparedRequest = null;
    _acknowledged = false;
    _prepareError = null;
    _progress.clear();
    _stepIndex = 0;
    _totalSteps = 0;
    _stepTitle = '';
    if (_phase != FlashPhase.running) {
      _phase = _serial == null ? FlashPhase.idle : FlashPhase.ready;
    }
  }

  void _releaseAwake() {
    if (!_awake) return;
    _awake = false;
    unawaited(_endAwake());
  }

  Future<void> _endAwake() async {
    try {
      await bridge.endKeepAwake();
    } on Object {
      // The page is closing or the lock was already gone; nothing to fix.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    final export = _exportSubscription;
    _exportSubscription = null;
    if (export != null) unawaited(export.cancel());
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      _stopping = true;
      unawaited(_cancelAndRelease(subscription));
    } else if (!_stopping) {
      _releaseAwake();
    }
    super.dispose();
  }
}
