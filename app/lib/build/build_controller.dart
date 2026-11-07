import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/flasher_api.dart';
import '../api/platform_bridge.dart';
import 'hosted_api.dart';

/// What the output page is showing.
enum BuildPhase { idle, running, succeeded, failed, canceled }

Future<void> _pollDelay(Duration duration) => Future<void>.delayed(duration);

/// One build job: the service stream, elapsed time and the final result.
final class BuildController extends ChangeNotifier {
  BuildController({
    required this.api,
    required this.bridge,
    HostedApiClient? hosted,
    this.hostedPollInterval = const Duration(seconds: 2),
    Future<void> Function(Duration)? hostedWait,
  }) : hostedApi = hosted ?? HostedApiClient(),
       _ownsHostedApi = hosted == null,
       _hostedWait = hostedWait ?? _pollDelay;

  final FlasherApi api;
  final PlatformBridge bridge;
  final HostedApiClient hostedApi;
  final bool _ownsHostedApi;
  final Duration hostedPollInterval;
  final Future<void> Function(Duration) _hostedWait;

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

  bool _hosted = false;
  bool _hostedCanceled = false;
  HostedJob? _hostedJob;
  int _hostedGeneration = 0;
  bool _disposed = false;

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

  /// Whether this build runs on the operator's host.
  bool get hosted => _hosted;

  HostedJob? get hostedJob => _hostedJob;

  HostedJobStatus? get hostedStatus => _hostedJob?.status;

  HostedCacheInfo? get hostedCache => _hostedJob?.cache;

  String? get cacheText => _hostedJob?.cache?.text;

  String get hostedStatusText => switch (_hostedJob?.status) {
    HostedJobStatus.queued => 'Waiting for a hosted builder',
    HostedJobStatus.running => 'Building on the hosted server',
    HostedJobStatus.succeeded => 'Hosted package ready',
    HostedJobStatus.failed => 'Hosted build failed',
    null => 'Contacting the hosted server',
  };

  bool get running => _phase == BuildPhase.running;
  bool get hasResult => _result != null;
  bool get zip => _hosted || _request?['zip'] == true;

  List<String> get stepLabels => _hosted
      ? const [
          '01  Queue job',
          '02  Fetch OTA',
          '03  Build images',
          '04  Package ZIP',
          '05  Complete',
        ]
      : [
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
    _hosted = request['hosted'] == true;
    _hostedCanceled = false;
    _hostedJob = null;
    _hostedGeneration++;
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

    if (_hosted) {
      final generation = _hostedGeneration;
      await _startHosted(request, generation);
      return;
    }

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

  Future<void> _startHosted(
    Map<String, Object?> request,
    int generation,
  ) async {
    try {
      final hostedRequest = HostedJobRequest.fromBuildRequest(request);
      final created = await hostedApi.create(hostedRequest);
      if (!_hostedActive(generation)) return;
      _applyHosted(created);
      var job = created;
      while (!job.status.finished) {
        await _hostedWait(hostedPollInterval);
        if (!_hostedActive(generation)) return;
        job = await hostedApi.get(created.id);
        if (!_hostedActive(generation)) return;
        _applyHosted(job);
      }
    } on Object catch (error) {
      if (!_hostedActive(generation)) return;
      _failHosted('$error');
    }
  }

  bool _hostedActive(int generation) =>
      !_disposed &&
      generation == _hostedGeneration &&
      _phase == BuildPhase.running &&
      !_hostedCanceled;

  void _failHosted(String message) {
    _phase = BuildPhase.failed;
    _error = message;
    _log.add('ERROR: $message');
    _finish();
  }

  void _applyHosted(HostedJob job) {
    _hostedJob = job;
    _log.clear();
    _progress.clear();
    _log.add('Hosted job ${job.id} · ${job.status.name}.');
    for (final event in job.events) {
      final type = event['type'];
      if (type == 'progress') {
        final label = event['label'];
        final done = event['done'];
        final total = event['total'];
        if (label is String && done is num && total is num) {
          _progress[label] = (done: done.toInt(), total: total.toInt());
        }
        continue;
      }
      if (type == 'step') {
        final index = event['index'];
        final total = event['total'];
        final title = event['title'];
        if (index is num) _stepIndex = index.toInt();
        if (total is num) _totalSteps = total.toInt();
        if (title is String) _stepTitle = title;
      }
      final line = hostedEventLine(event);
      if (line == null) continue;
      for (final part in line.split('\n')) {
        if (part.trim().isNotEmpty) _log.add(part);
      }
    }
    switch (job.status) {
      case HostedJobStatus.queued:
        _log.add('Waiting in the hosted build queue.');
      case HostedJobStatus.running:
        _log.add(_stepTitle.isEmpty ? job.status.name : _stepTitle);
      case HostedJobStatus.succeeded:
        final sha256 = job.sha256!;
        final bytes = job.bytes!;
        _result = {
          'type': 'result',
          'hosted': true,
          'job': job.id,
          'artifact': job.artifact ?? 'hosted build',
          'format': 'zip',
          'sha256': sha256,
          'bytes': bytes,
          'manifest': job.manifest!,
          if (job.manifestSha256 != null)
            'manifestSha256': job.manifestSha256,
          'artifactUrl': job.artifactUrl,
          'manifestUrl': job.manifestUrl,
          if (job.cache != null) 'cache': {
            if (job.cache!.hit != null) 'hit': job.cache!.hit,
            if (job.cache!.lastUsed != null)
              'lastUsed': job.cache!.lastUsed!.toIso8601String(),
            if (job.cache!.retainedUntil != null)
              'retainedUntil': job.cache!.retainedUntil!.toIso8601String(),
          },
        };
        _phase = BuildPhase.succeeded;
        _stepIndex = _totalSteps;
        _log.add('Hosted package complete.');
        _finish();
      case HostedJobStatus.failed:
        _phase = BuildPhase.failed;
        _error = job.error ?? 'The hosted build failed.';
        _log.add('ERROR: $_error');
        _finish();
    }
    notifyListeners();
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
    _hostedCanceled = true;
    _phase = BuildPhase.canceled;
    _log.add(
      _hosted
          ? 'Stopped waiting · the hosted job continues on the server.'
          : 'Build cancelled · output cleaned.',
    );
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    _finish();
  }

  /// Downloads the finished ZIP, or explains the folder result.
  Future<String?> downloadArtifact() async {
    final result = _result;
    if (result == null) return null;
    if (_hosted) {
      final url = result['artifactUrl'];
      if (url is! String || url.isEmpty) {
        return 'The hosted result has no downloadable artifact.';
      }
      await bridge.openExternal(url);
      return null;
    }
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

  /// Opens the hosted `build.json`, or explains why it is unavailable.
  Future<String?> openManifest() async {
    final url = _result?['manifestUrl'];
    if (!_hosted || url is! String || url.isEmpty) {
      return 'The hosted result has no build.json link.';
    }
    await bridge.openExternal(url);
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
    _disposed = true;
    _hostedCanceled = true;
    _hostedGeneration++;
    _timer?.cancel();
    _subscription?.cancel();
    _timer = null;
    if (_awake) {
      _awake = false;
      unawaited(_endAwake());
    }
    if (_ownsHostedApi) hostedApi.close();
    super.dispose();
  }
}
