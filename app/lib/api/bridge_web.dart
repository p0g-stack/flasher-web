import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flasher_web_core/flasher_web_core.dart' show HandleWorkspace;
import 'package:web/web.dart' as web;

import 'platform_bridge.dart';

/// Creates the real page bridge. Compiled only for the browser.
PlatformBridge createBridge() => WebPlatformBridge();

/// The browser implementation: File System Access, IndexedDB, `fetch`,
/// downloads, the screen wake lock and page-level drag and drop.
final class WebPlatformBridge implements PlatformBridge {
  WebPlatformBridge() {
    _dragOver = ((web.Event event) {
      event.preventDefault();
    }).toJS;
    _drop = ((web.Event event) {
      event.preventDefault();
      final transfer = (event as web.DragEvent).dataTransfer;
      final files = transfer?.files;
      if (files == null) return;
      for (var i = 0; i < files.length; i++) {
        final file = files.item(i);
        if (file == null) continue;
        if (!file.name.toLowerCase().endsWith('.zip')) continue;
        _dropped.add(
          PickedFile(handle: file, name: file.name, size: file.size),
        );
      }
    }).toJS;
    web.document.addEventListener('dragover', _dragOver);
    web.document.addEventListener('drop', _drop);
  }

  late final JSFunction _dragOver;
  late final JSFunction _drop;
  final _dropped = StreamController<PickedFile>.broadcast();

  web.IDBDatabase? _db;
  int _keepAlive = 0;
  web.WakeLockSentinel? _sentinel;
  JSFunction? _leaveGuard;

  static const _databaseName = 'flasher_web';
  static const _store = 'handles';
  static const _prefix = 'flasher_web.handles.';

  @override
  bool get available => true;

  @override
  bool get canPickDirectory => _globalFunction('showDirectoryPicker') != null;

  JSFunction? _globalFunction(String name) {
    final value = globalContext[name];
    if (value == null || !value.isA<JSFunction>()) return null;
    return value as JSFunction;
  }

  @override
  Future<String> fetchText(String path) async {
    final response = await web.window.fetch(path.toJS).toDart;
    if (!response.ok) {
      throw StateError('Could not read $path: HTTP ${response.status}.');
    }
    return (await response.text().toDart).toDart;
  }

  @override
  Future<Map<String, Object?>?> readPreferences() async {
    final raw = web.window.localStorage.getItem('flasher_web.preferences');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? Map<String, Object?>.from(decoded)
          : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writePreferences(Map<String, Object?> value) async {
    web.window.localStorage.setItem(
      'flasher_web.preferences',
      jsonEncode(value),
    );
  }

  @override
  Future<DirectoryRef?> pickDirectory(
    String key, {
    String label = 'Choose folder',
  }) async {
    final picker = _globalFunction('showDirectoryPicker');
    if (picker == null) {
      throw UnsupportedError(
        'This browser cannot choose a folder; use browser storage.',
      );
    }
    final options = <String, Object?>{
      'id': key,
      'mode': 'readwrite',
      'startIn': 'documents',
    }.jsify();
    final promise = picker.callAsFunction(globalContext, options);
    final handle = await (promise as JSPromise<JSAny?>).toDart;
    if (handle == null) return null;
    final directory = handle as web.FileSystemDirectoryHandle;
    await _putHandle(key, directory);
    return DirectoryRef(handle: directory, name: directory.name);
  }

  @override
  Future<DirectoryRef?> rememberedDirectory(String key) async {
    final handle = await _getHandle(key);
    if (handle == null) return null;
    final permission = await _permission(handle, request: false);
    if (permission != 'granted') return null;
    return DirectoryRef(handle: handle, name: handle.name);
  }

  @override
  Future<String?> rememberedDirectoryName(String key) async {
    final handle = await _getHandle(key);
    return handle?.name;
  }

  @override
  Future<DirectoryRef?> requestRememberedDirectory(String key) async {
    final handle = await _getHandle(key);
    if (handle == null) return null;
    final permission = await _permission(handle, request: true);
    if (permission != 'granted') return null;
    return DirectoryRef(handle: handle, name: handle.name);
  }

  @override
  Future<PickedFile?> pickOtaFile() async {
    final picker = _globalFunction('showOpenFilePicker');
    if (picker != null) {
      final options = <String, Object?>{
        'id': 'ota',
        'multiple': false,
        'types': [
          {
            'description': 'Full OTA ZIP',
            'accept': {
              'application/zip': ['.zip'],
            },
          },
        ],
      }.jsify();
      final promise = picker.callAsFunction(globalContext, options);
      final value = await (promise as JSPromise<JSAny?>).toDart;
      if (value == null) return null;
      final handles = (value as JSArray<web.FileSystemFileHandle>).toDart;
      if (handles.isEmpty) return null;
      final file = await handles.first.getFile().toDart;
      return PickedFile(handle: file, name: file.name, size: file.size);
    }
    return _pickWithInput();
  }

  Future<PickedFile?> _pickWithInput() {
    final completer = Completer<PickedFile?>();
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = '.zip,application/zip';
    input.style.display = 'none';
    web.document.body?.append(input);
    input.onchange = ((web.Event event) {
      final file = input.files?.item(0);
      web.document.body?.removeChild(input);
      completer.complete(
        file == null
            ? null
            : PickedFile(handle: file, name: file.name, size: file.size),
      );
    }).toJS;
    input.click();
    return completer.future;
  }

  @override
  Stream<PickedFile> get droppedFiles => _dropped.stream;

  @override
  Future<bool> requestPersistentStorage() async {
    try {
      return (await web.window.navigator.storage.persist().toDart).toDart;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> downloadStoreFile(
    String path, {
    required String filename,
    Object? handle,
  }) async {
    final root = handle == null
        ? await web.window.navigator.storage.getDirectory().toDart
        : handle as web.FileSystemDirectoryHandle;
    final parts = path
        .split('/')
        .where((part) => part.isNotEmpty && part != '.')
        .toList();
    if (parts.isEmpty) throw StateError('No file to download.');
    var directory = root;
    for (final part in parts.take(parts.length - 1)) {
      directory = await directory
          .getDirectoryHandle(part, web.FileSystemGetDirectoryOptions())
          .toDart;
    }
    final file = await directory
        .getFileHandle(parts.last, web.FileSystemGetFileOptions())
        .toDart
        .then((handle) => handle.getFile().toDart);
    _downloadBlob(file, filename);
  }

  @override
  Future<void> downloadText(String text, String filename) async {
    final blob = web.Blob(
      [text.toJS].toJS,
      web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
    );
    _downloadBlob(blob, filename);
  }

  void _downloadBlob(web.Blob blob, String filename) {
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..style.display = 'none';
    web.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    Timer(const Duration(seconds: 5), () {
      web.URL.revokeObjectURL(url);
    });
  }

  @override
  Future<void> openExternal(String url) async {
    web.window.open(url, '_blank', 'noopener,noreferrer');
  }

  @override
  Future<void> beginKeepAwake() async {
    _keepAlive++;
    if (_keepAlive > 1) return;
    _leaveGuard = ((web.Event event) {
      event.preventDefault();
      event.returnValue = true;
    }).toJS;
    web.window.addEventListener('beforeunload', _leaveGuard);
    try {
      _sentinel = await web.window.navigator.wakeLock.request('screen').toDart;
    } catch (_) {
      // Screen wake lock is best effort: the leave guard still protects work.
    }
  }

  @override
  Future<void> endKeepAwake() async {
    if (_keepAlive == 0) return;
    _keepAlive--;
    if (_keepAlive > 0) return;
    final guard = _leaveGuard;
    if (guard != null) {
      web.window.removeEventListener('beforeunload', guard);
      _leaveGuard = null;
    }
    final sentinel = _sentinel;
    _sentinel = null;
    if (sentinel != null) {
      try {
        await sentinel.release().toDart;
      } catch (_) {
        // It may already have been released when the tab lost visibility.
      }
    }
  }

  @override
  Future<void> deleteStorePath(String path, {Object? handle}) async {
    final workspace = handle == null
        ? await HandleWorkspace.opfs()
        : HandleWorkspace(handle as JSObject);
    await workspace.delete(path);
  }

  @override
  void dispose() {
    web.document.removeEventListener('dragover', _dragOver);
    web.document.removeEventListener('drop', _drop);
    _dropped.close();
    _db?.close();
    final guard = _leaveGuard;
    if (guard != null) {
      web.window.removeEventListener('beforeunload', guard);
    }
    _sentinel?.release();
  }

  Future<web.IDBDatabase> _database() async {
    final cached = _db;
    if (cached != null) return cached;
    final completer = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_databaseName, 1);
    request.onupgradeneeded = ((web.Event event) {
      final database = request.result as web.IDBDatabase;
      if (!database.objectStoreNames.contains(_store)) {
        database.createObjectStore(_store);
      }
    }).toJS;
    request.onsuccess = ((web.Event event) {
      completer.complete(request.result as web.IDBDatabase);
    }).toJS;
    request.onerror = ((web.Event event) {
      completer.completeError(
        StateError('IndexedDB is unavailable in this browser context.'),
      );
    }).toJS;
    final database = await completer.future;
    _db = database;
    return database;
  }

  Future<void> _putHandle(
    String key,
    web.FileSystemDirectoryHandle handle,
  ) async {
    final database = await _database();
    final completer = Completer<void>();
    final transaction = database.transaction(_store.toJS, 'readwrite');
    transaction.objectStore(_store).put(handle as JSAny, '$_prefix$key'.toJS);
    transaction.oncomplete = ((web.Event event) {
      completer.complete();
    }).toJS;
    transaction.onerror = ((web.Event event) {
      completer.completeError(
        StateError('Could not remember the chosen folder.'),
      );
    }).toJS;
    await completer.future;
  }

  Future<web.FileSystemDirectoryHandle?> _getHandle(String key) async {
    final database = await _database();
    final completer = Completer<JSAny?>();
    final request = database
        .transaction(_store.toJS, 'readonly')
        .objectStore(_store)
        .get('$_prefix$key'.toJS);
    request.onsuccess = ((web.Event event) {
      completer.complete(request.result);
    }).toJS;
    request.onerror = ((web.Event event) {
      completer.complete(null);
    }).toJS;
    final value = await completer.future;
    return value as web.FileSystemDirectoryHandle?;
  }

  Future<String> _permission(
    web.FileSystemDirectoryHandle handle, {
    required bool request,
  }) async {
    final options = <String, Object?>{'mode': 'readwrite'}.jsify();
    try {
      final result = request
          ? await handle
                .callMethod<JSPromise<JSString>>(
                  'requestPermission'.toJS,
                  options,
                )
                .toDart
          : await handle
                .callMethod<JSPromise<JSString>>(
                  'queryPermission'.toJS,
                  options,
                )
                .toDart;
      return result.toDart;
    } catch (_) {
      return 'denied';
    }
  }
}
