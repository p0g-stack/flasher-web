import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/flasher_api.dart';
import '../api/platform_bridge.dart';

/// What the output page is showing.
enum BuildPhase { idle, running, succeeded, failed, canceled }

/// One build job: the service stream, elapsed time and the final result.
final class BuildController extends ChangeNotifier {
  BuildController({required this.api, required this.bridge});

  final FlasherApi api;
  final PlatformBridge bridge;

  BuildPhase _phase = BuildPhase.idle;
  final _log = <String>[];
  final _progress = <String, ({int done, int total})>{};
  Map<String, Object?>? _result;
  Map<String, Object?>? _request;
  Map<String, Object?>? _summary;
  String? _error;
  int _stepIndex = 0;
  String _stepTitle = '';
  int _totalSteps = 5;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  Stopwatch? _watch;
  StreamSubscription<Map<String, Object?>>? _subscription;
  bool _cancelRequested = false;
  bool _awake = false;

  BuildPhase get phase => _phase;
  List<String> get log => List.unmodifiable(_log);
  Map<String, ({int done, int total})> get progress =>
      Map.unmodifiable(_progress);
  Map<String, Object?>? get result => _result;
  Map<String, Object?>? get request => _request;
  Map<String, Object?>? get summary => _summary;
  String? get error => _error;
  int get stepIndex => _stepIndex;
  String get stepTitle => _stepTitle;
  int get totalSteps => _totalSteps;
  Duration get elapsed => _elapsed;

  bool get running => _phase == BuildPhase.running;
  bool get hasResult => _result != null;
  bool get zip => _request?['zip'] == true;

  List<String> get stepLabels => [
    '01  Prepare OTA',
    '02  Stage files',
    '03  Build images',
    zip ? '04  Package ZIP' : '04  Finalize folder',
    '05  Complete',
  ];

  String get elapsedText {
    final seconds = _elapsed.inSeconds;
    final minutes = seconds ~/ 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')} elapsed';
  }

  String get logText => _log.join('\n');

  Future<void> start({
    required Map<String, Object?> request,
    required Map<String, Object?> summary,
    bool zip = true,
  }) async {
    if (_phase == BuildPhase.running) return;
    _request = request;
    _summary = summary;
    _result = null;
    _error = null;
    _phase = BuildPhase.running;
    _cancelRequested = false;
    _log.clear();
    _progress.clear();
    _stepIndex = 0;
    _stepTitle = '';
    _totalSteps = 5;
    _elapsed = Duration.zero;
    _watch = Stopwatch()..start();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsed = _watch?.elapsed ?? _elapsed;
      notifyListeners();
    });
    _awake = true;
    unawaited(_beginAwake());
    notifyListeners();

    try {
      _subscription = api
          .build(request)
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

  Future<void> _beginAwake() async {
    try {
      await bridge.beginKeepAwake();
    } catch (_) {
      // Best effort.
    }
  }

  void _onEvent(Map<String, Object?> event) {
    switch (event['type']) {
      case 'step':
        final index = event['index'];
        final total = event['total'];
        final title = event['title'];
        if (index is num) _stepIndex = index.toInt();
        if (total is num) _totalSteps = total.toInt();
        if (title is String) _stepTitle = title;
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
      case 'result':
        _result = Map<String, Object?>.from(event);
        _phase = BuildPhase.succeeded;
        _stepIndex = _totalSteps;
        _log.add('Package complete.');
        _finish();
      default:
        break;
    }
    notifyListeners();
  }

  void _onError(Object error) {
    if (_cancelRequested) {
      _phase = BuildPhase.canceled;
      _log.add('Build cancelled · output cleaned.');
    } else {
      _phase = BuildPhase.failed;
      _error = '$error';
      _log.add('ERROR: $error');
    }
    _finish();
  }

  void _onDone() {
    if (_phase == BuildPhase.running) {
      _phase = _cancelRequested ? BuildPhase.canceled : BuildPhase.failed;
      if (!_cancelRequested) {
        _error = 'The build stopped without a result.';
        _log.add('ERROR: The build stopped without a result.');
      }
    }
    _finish();
  }

  void _finish() {
    _timer?.cancel();
    _timer = null;
    _elapsed = _watch?.elapsed ?? _elapsed;
    _watch?.stop();
    final subscription = _subscription;
    _subscription = null;
    if (_phase != BuildPhase.running) unawaited(subscription?.cancel());
    if (_awake) {
      _awake = false;
      unawaited(_endAwake());
    }
    notifyListeners();
  }

  Future<void> _endAwake() async {
    try {
      await bridge.endKeepAwake();
    } catch (_) {
      // Best effort.
    }
  }

  void cancel() {
    if (_phase != BuildPhase.running) return;
    _cancelRequested = true;
    _phase = BuildPhase.canceled;
    _log.add('Build cancelled · output cleaned.');
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    _finish();
  }

  /// Downloads the finished ZIP, or explains the folder result.
  Future<String?> downloadArtifact() async {
    final result = _result;
    if (result == null) return null;
    if (result['format'] == 'folder') {
      return 'This build kept a flasher folder in the chosen output store. '
          'Folder builds are not available as a single download.';
    }
    final artifact = result['artifact'];
    final job = result['job'];
    if (artifact is! String || artifact.isEmpty || job is! String) {
      return 'The build result has no downloadable artifact.';
    }
    final output = _request?['output'];
    final handle = output is Map ? output['handle'] : null;
    await bridge.downloadStoreFile(
      '$job/$artifact',
      filename: artifact,
      handle: handle,
    );
    return null;
  }

  Future<void> saveLog() async {
    final artifact = _result?['artifact'];
    final base = artifact is String && artifact.isNotEmpty
        ? artifact.replaceAll(RegExp(r'\.zip$'), '')
        : 'build';
    await bridge.downloadText(logText, '$base.log');
  }

  @override
  void dispose() {
    _timer?.cancel();
    _subscription?.cancel();
    _timer = null;
    if (_awake) {
      _awake = false;
      unawaited(_endAwake());
    }
    super.dispose();
  }
}
