import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/flasher_api.dart';
import '../api/platform_bridge.dart';

/// Saves one catalog OTA onto this computer, outside the app's stores.
///
/// One save runs at a time. The page holds the wake lock and the leave guard
/// while it runs, because closing the tab stops it.
final class OtaDownloadController extends ChangeNotifier {
  OtaDownloadController({
    required this.api,
    required this.bridge,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// How far back the transfer rate looks.
  static const rateWindow = Duration(seconds: 5);

  final FlasherApi api;
  final PlatformBridge bridge;
  final DateTime Function() _clock;

  String? _role;
  String? _error;
  String? _notice;
  int _token = 0;
  bool _awake = false;
  bool _disposed = false;
  bool _running = false;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Object? _streamDestination;
  final _progress = <String, ({int done, int total})>{};
  final _samples = <String, List<({DateTime at, int done})>>{};

  StreamExportBridge? get _stream =>
      bridge is StreamExportBridge ? bridge as StreamExportBridge : null;

  bool get running => _running;

  /// The catalog role (`ota` or `base`) of the running or last save, which
  /// [error] and [notice] belong to.
  String? get role => _role;

  /// The last save's failure, or null.
  String? get error => _error;

  /// What the user does next after a save that ended outside the app.
  String? get notice => _notice;

  Map<String, ({int done, int total})> get progress =>
      Map.unmodifiable(_progress);

  /// Bytes per second over the last [rateWindow], or null before two samples.
  double? rate(String label) {
    final samples = _samples[label];
    if (samples == null || samples.length < 2) return null;
    final first = samples.first;
    final last = samples.last;
    final micros = last.at.difference(first.at).inMicroseconds;
    if (micros <= 0) return null;
    return (last.done - first.done) * Duration.microsecondsPerSecond / micros;
  }

  /// Whether this page can write an OTA onto the computer at all.
  bool get canSaveToComputer =>
      bridge.canSaveFile || (_stream?.canStreamExport ?? false);

  /// Copies the catalog [ota] into a file the user chooses.
  ///
  /// Call from the click handler: the save picker needs the user gesture, so it
  /// opens before any await. [onSaved] receives the saved file when the page
  /// can read it back; a streamed download leaves a [notice] instead.
  Future<void> toComputer({
    required String role,
    required Map<String, Object?> ota,
    required String apiBase,
    required String suggestedName,
    required Future<void> Function(PickedFile file) onSaved,
  }) async {
    if (running) return;
    final Object? destination;
    try {
      destination = await _pickDestination(suggestedName);
    } on Object catch (error) {
      _role = role;
      _error = '$error';
      _notify();
      return;
    }
    if (destination == null) return;
    final picked = destination;
    final streamed = picked is Map && picked['kind'] == 'stream';
    final token = _begin(role);
    _streamDestination = streamed ? picked : null;
    await _holdAwake(token);
    if (token != _token) return;
    _listen(
      token,
      api.saveOta({'apiBase': apiBase, 'ota': ota, 'destination': picked}),
      failure: 'Could not save the OTA',
      onResult: (_) async {
        if (streamed) {
          _notice =
              'Saved as $suggestedName in the browser downloads. Choose it '
              'under Local file to read it from disk.';
          return;
        }
        final file = await bridge.openSavedOta(picked, remember: role == 'ota');
        if (file == null) {
          _notice =
              'Saved as $suggestedName. Choose it under Local file to read it '
              'from disk.';
          return;
        }
        await onSaved(file);
      },
    );
  }

  /// Stops the running save; the file stays partial.
  void cancel() {
    if (!running) return;
    _token++;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _abortStream('The download was cancelled.');
    _finish();
  }

  int _begin(String role) {
    _running = true;
    _role = role;
    _error = null;
    _notice = null;
    _progress.clear();
    _samples.clear();
    _notify();
    return ++_token;
  }

  Future<void> _holdAwake(int token) async {
    try {
      await bridge.beginKeepAwake();
      if (token == _token) {
        _awake = true;
      } else {
        await bridge.endKeepAwake();
      }
    } on Object {
      // The wake lock is a courtesy; the download runs without it.
    }
  }

  void _listen(
    int token,
    Stream<Map<String, Object?>> events, {
    required String failure,
    required Future<void> Function(Map<String, Object?> result) onResult,
  }) {
    var finished = false;
    _subscription = events.listen(
      (event) {
        if (_disposed || token != _token) return;
        switch (event['type']) {
          case 'started':
            final label = event['label'];
            final total = event['total'];
            if (label is String && total is num) {
              _progress[label] = (done: 0, total: total.toInt());
              _sample(label, 0);
              _notify();
            }
          case 'progress':
            final label = event['label'];
            final done = event['done'];
            final total = event['total'];
            if (label is String && done is num && total is num) {
              _progress[label] = (done: done.toInt(), total: total.toInt());
              _sample(label, done.toInt());
              _notify();
            }
          case 'result':
            finished = true;
            _streamDestination = null;
            unawaited(_complete(token, () => onResult(event), failure));
        }
      },
      onError: (Object error) {
        if (_disposed || token != _token || finished) return;
        // The stream still closes after an error; that close must not
        // replace the error with "ended without a result".
        finished = true;
        _error = '$failure: $error';
        _abortStream(_error);
        _subscription = null;
        _finish();
      },
      onDone: () {
        if (_disposed || token != _token || finished) return;
        _error = '$failure: the download ended without a result.';
        _abortStream(_error);
        _subscription = null;
        _finish();
      },
      cancelOnError: false,
    );
  }

  void _sample(String label, int done) {
    final now = _clock();
    final samples = _samples.putIfAbsent(label, () => []);
    samples.add((at: now, done: done));
    final oldest = now.subtract(rateWindow);
    while (samples.length > 2 && samples[1].at.isBefore(oldest)) {
      samples.removeAt(0);
    }
  }

  Future<void> _complete(
    int token,
    Future<void> Function() action,
    String failure,
  ) async {
    try {
      await action();
    } on Object catch (error) {
      if (token == _token) _error = '$failure: $error';
    }
    if (_disposed || token != _token) return;
    _subscription = null;
    _finish();
  }

  void _finish() {
    _running = false;
    if (_awake) {
      _awake = false;
      unawaited(bridge.endKeepAwake().catchError((Object _) {}));
    }
    _notify();
  }

  Future<Object?> _pickDestination(String suggestedName) async {
    if (bridge.canSaveFile) {
      return bridge.pickSaveFile(suggestedName: suggestedName);
    }
    final stream = _stream;
    if (stream != null && stream.canStreamExport) {
      return stream.beginStreamExport(suggestedName: suggestedName);
    }
    throw UnsupportedError(
      'This browser cannot save files. Open the app in a current Chromium '
      'browser over HTTPS or localhost.',
    );
  }

  void _abortStream(String? reason) {
    final streamed = _streamDestination;
    _streamDestination = null;
    if (streamed != null) _stream?.abortStreamExport(streamed, reason: reason);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _token++;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _abortStream('The page closed during the download.');
    if (_awake) {
      _awake = false;
      unawaited(bridge.endKeepAwake().catchError((Object _) {}));
    }
    super.dispose();
  }
}
