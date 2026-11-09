import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/flasher_api.dart';
import '../api/platform_bridge.dart';

/// Where a catalog OTA download lands.
enum OtaDownloadTarget {
  /// `ota-cache/` in the bloat store, under the app's storage cap; a flash of
  /// the same catalog version reads it instead of the network.
  cache,

  /// A file on this computer outside the app's stores: the save picker's file,
  /// or a streamed download where the browser has no picker.
  computer,
}

/// Downloads one catalog OTA into the app cache or onto this computer.
///
/// One download runs at a time. The page holds the wake lock and the leave
/// guard while it runs, because closing the tab stops it.
final class OtaDownloadController extends ChangeNotifier {
  OtaDownloadController({required this.api, required this.bridge});

  final FlasherApi api;
  final PlatformBridge bridge;

  OtaDownloadTarget? _target;
  String? _role;
  String? _error;
  String? _notice;
  int _token = 0;
  bool _awake = false;
  bool _disposed = false;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Object? _streamDestination;
  final _progress = <String, ({int done, int total})>{};

  StreamExportBridge? get _stream =>
      bridge is StreamExportBridge ? bridge as StreamExportBridge : null;

  bool get running => _target != null;

  /// The running download's target, or null.
  OtaDownloadTarget? get target => _target;

  /// The catalog role (`ota` or `base`) of the running or last download, which
  /// [error] and [notice] belong to.
  String? get role => _role;

  /// The last download's failure, or null.
  String? get error => _error;

  /// What the user does next after a download that ended outside the app.
  String? get notice => _notice;

  Map<String, ({int done, int total})> get progress =>
      Map.unmodifiable(_progress);

  /// Whether this page can write an OTA onto the computer at all.
  bool get canSaveToComputer =>
      bridge.canSaveFile || (_stream?.canStreamExport ?? false);

  /// Whether the saved file can be read back as the local OTA: only a save
  /// picker returns a handle the page can open again.
  bool get savesIntoPickedFile => bridge.canSaveFile;

  /// Downloads (or resumes) the catalog [ota] into the cache under [store].
  ///
  /// [onCached] runs after the result, so the caller can refresh its budget.
  Future<void> toCache({
    required String role,
    required Map<String, Object?> ota,
    required Map<String, Object?> store,
    required String apiBase,
    required void Function() onCached,
  }) async {
    if (running) return;
    final token = _begin(OtaDownloadTarget.cache, role);
    await _holdAwake(token);
    if (token != _token) return;
    _listen(
      token,
      api.cacheOta({'store': store, 'apiBase': apiBase, 'ota': ota}),
      failure: 'Could not keep the OTA offline',
      onResult: (_) async => onCached(),
    );
  }

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
    final Object picked = destination;
    final token = _begin(OtaDownloadTarget.computer, role);
    _streamDestination = destination is Map && destination['kind'] == 'stream'
        ? destination
        : null;
    await _holdAwake(token);
    if (token != _token) return;
    final streamed = _streamDestination != null;
    _listen(
      token,
      api.saveOta({
        'apiBase': apiBase,
        'ota': ota,
        'destination': destination,
      }),
      failure: 'Could not save the OTA',
      onResult: (_) async {
        if (streamed) {
          _notice =
              'Saved as $suggestedName in the browser downloads. Choose it '
              'under Local file to read it from disk.';
          return;
        }
        final file = await bridge.openSavedOta(
          picked,
          remember: role == 'ota',
        );
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

  /// Stops the running download. A cache download resumes later at its last
  /// recorded offset; a file on the computer is left partial.
  void cancel() {
    if (!running) return;
    _token++;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _abortStream('The download was cancelled.');
    _finish();
  }

  int _begin(OtaDownloadTarget target, String role) {
    _target = target;
    _role = role;
    _error = null;
    _notice = null;
    _progress.clear();
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
          case 'progress':
            final label = event['label'];
            final done = event['done'];
            final total = event['total'];
            if (label is String && done is num && total is num) {
              _progress[label] = (done: done.toInt(), total: total.toInt());
              _notify();
            }
          case 'result':
            finished = true;
            _streamDestination = null;
            unawaited(_complete(token, () => onResult(event), failure));
        }
      },
      onError: (Object error) {
        if (_disposed || token != _token) return;
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
    _target = null;
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
