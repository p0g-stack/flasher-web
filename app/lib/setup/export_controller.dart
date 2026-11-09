import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/flasher_api.dart';
import '../api/platform_bridge.dart';

/// Streams the OTA-direct package into a file the user picks.
///
/// The service reads the OTA, the optional BASE OTA and verified bloat exactly
/// as a flash does and writes the archive straight into the chosen
/// `FileSystemFileHandle`; nothing is staged in browser storage.
final class ExportController extends ChangeNotifier {
  ExportController({
    required this.api,
    required this.bridge,
    required this.upstreamBase,
  });

  final FlasherApi api;
  final PlatformBridge bridge;
  final String upstreamBase;

  bool _exporting = false;
  String? _error;
  Map<String, Object?>? _result;
  StreamSubscription<Map<String, Object?>>? _subscription;
  final _log = <String>[];
  final _progress = <String, ({int done, int total})>{};
  bool _disposed = false;

  /// Whether this page can show a save-file picker at all.
  bool get available => bridge.canSaveFile;

  bool get exporting => _exporting;
  String? get error => _error;
  Map<String, Object?>? get result => _result;
  List<String> get log => List.unmodifiable(_log);
  Map<String, ({int done, int total})> get progress =>
      Map.unmodifiable(_progress);

  /// Writes a portable ZIP of [virtual] into a save-picker file.
  ///
  /// Returns null on success or cancellation and an explanation otherwise.
  Future<String?> export({
    required Map<String, Object?> virtual,
    required Map<String, Object?> selection,
    required String label,
  }) async {
    if (_exporting) return 'An export is already running.';
    final Object? destination;
    try {
      // The picker must run inside the click task, before any await.
      destination = await bridge.pickSaveFile(
        suggestedName: 'flasher-${_safeName(label)}.zip',
      );
    } on Object catch (error) {
      return '$error';
    }
    if (destination == null) return null;
    _exporting = true;
    _error = null;
    _result = null;
    _log.clear();
    _progress.clear();
    _notify();
    final completer = Completer<String?>();
    final request = <String, Object?>{
      'virtual': virtual,
      'selection': selection,
      'upstreamBase': upstreamBase,
      'destination': destination,
    };
    void finish() {
      _exporting = false;
      _subscription = null;
      if (!completer.isCompleted) {
        completer.complete(_error);
      }
      _notify();
    }

    try {
      _subscription = api
          .exportVirtual(request)
          .listen(
            (event) {
              switch (event['type']) {
                case 'step':
                  final title = event['title'];
                  if (title is String && title.isNotEmpty) {
                    _log.add(title);
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
                    _progress[label] = (
                      done: done.toInt(),
                      total: total.toInt(),
                    );
                  }
                case 'result':
                  _result = Map<String, Object?>.from(event);
                  _log.add(
                    'Exported ${event['bytes']} bytes · SHA-256 '
                    '${event['sha256']}',
                  );
                default:
                  break;
              }
              _notify();
            },
            onError: (Object error) {
              _error = 'The export failed: $error';
              _log.add('ERROR: $error');
              finish();
            },
            onDone: () {
              if (_result == null && _error == null) {
                _error = 'The export ended without a result.';
              }
              finish();
            },
            cancelOnError: false,
          );
    } on Object catch (error) {
      _error = 'The export failed: $error';
      _log.add('ERROR: $error');
      finish();
    }
    return completer.future;
  }

  String _safeName(String value) => value
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }
}
