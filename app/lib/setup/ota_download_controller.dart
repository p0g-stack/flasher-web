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

  OtaDownloadTarget? _target;
  String? _role;
  String? _error;
  String? _notice;
  int _token = 0;
  bool _awake = false;
  bool _disposed = false;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Object? _streamDestination;
  ({String name, String role})? _pendingSave;
  final _progress = <String, ({int done, int total})>{};
  final _resumedFrom = <String, int>{};
  final _samples = <String, List<({DateTime at, int done})>>{};

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

  /// Bytes a resumed download already had on disk when it started, by label.
  /// They may be scattered segments, not a prefix.
  int resumedFrom(String label) => _resumedFrom[label] ?? 0;

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

  /// A save into a picked file that stopped before it finished, which
  /// [resumeSave] continues; null when there is none.
  ({String name, String role})? get pendingSave => _pendingSave;

  /// Reads the save a previous page left unfinished.
  Future<void> loadPendingSave() async {
    try {
      final saved = await bridge.rememberedOtaSave();
      final role = saved?.request['role'];
      _pendingSave = saved == null || role is! String
          ? null
          : (name: saved.name, role: role);
    } on Object {
      _pendingSave = null;
    }
    _notify();
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
    final streamed = destination is Map && destination['kind'] == 'stream';
    if (!streamed) {
      // Remembered before the first byte, so a reload can continue this file.
      try {
        await bridge.rememberOtaSave(destination, {
          'role': role,
          'ota': ota,
          'suggestedName': suggestedName,
        });
      } on Object catch (error) {
        _role = role;
        _error = 'Could not remember the save for resuming: $error';
        _notify();
        return;
      }
    }
    await _save(
      role: role,
      ota: ota,
      apiBase: apiBase,
      suggestedName: suggestedName,
      destination: destination,
      streamed: streamed,
      onSaved: onSaved,
    );
  }

  /// Continues the [pendingSave] into the same file.
  ///
  /// Call from the click handler: renewing write permission needs the user
  /// gesture, so it is the first await.
  Future<void> resumeSave({
    required String apiBase,
    required Future<void> Function(PickedFile file) onSaved,
  }) async {
    final pending = _pendingSave;
    if (running || pending == null) return;
    final Object? destination;
    final ({String name, Map<String, Object?> request})? saved;
    try {
      destination = await bridge.requestRememberedOtaSave();
      saved = await bridge.rememberedOtaSave();
    } on Object catch (error) {
      _role = pending.role;
      _error = 'Could not reopen ${pending.name}: $error';
      _notify();
      return;
    }
    final ota = saved?.request['ota'];
    final suggestedName = saved?.request['suggestedName'];
    if (destination == null ||
        ota is! Map<String, dynamic> ||
        suggestedName is! String) {
      _role = pending.role;
      _error =
          'The browser did not allow writing to ${pending.name}. Allow it, '
          'or discard the unfinished save and download again.';
      _notify();
      return;
    }
    await _save(
      role: pending.role,
      ota: Map<String, Object?>.from(ota),
      apiBase: apiBase,
      suggestedName: suggestedName,
      destination: destination,
      streamed: false,
      onSaved: onSaved,
    );
  }

  /// Forgets the [pendingSave]; the partial file stays on disk.
  Future<void> discardSave() async {
    if (running) return;
    _pendingSave = null;
    _notify();
    await bridge.forgetOtaSave();
  }

  Future<void> _save({
    required String role,
    required Map<String, Object?> ota,
    required String apiBase,
    required String suggestedName,
    required Object destination,
    required bool streamed,
    required Future<void> Function(PickedFile file) onSaved,
  }) async {
    final token = _begin(OtaDownloadTarget.computer, role);
    _pendingSave = streamed ? null : (name: suggestedName, role: role);
    _streamDestination = streamed ? destination : null;
    await _holdAwake(token);
    if (token != _token) return;
    _listen(
      token,
      api.saveOta({'apiBase': apiBase, 'ota': ota, 'destination': destination}),
      failure: 'Could not save the OTA',
      onResult: (_) async {
        if (streamed) {
          _notice =
              'Saved as $suggestedName in the browser downloads. Choose it '
              'under Local file to read it from disk.';
          return;
        }
        _pendingSave = null;
        await bridge.forgetOtaSave();
        final file = await bridge.openSavedOta(
          destination,
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

  /// Stops the running download. A cache download and a save into a picked
  /// file resume later from the segments already written; a streamed download
  /// is left partial.
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
    _resumedFrom.clear();
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
            final resumed = event['resumedFrom'];
            if (label is String && total is num) {
              final from = resumed is num ? resumed.toInt() : 0;
              _resumedFrom[label] = from;
              _progress[label] = (done: from, total: total.toInt());
              _sample(label, from);
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
