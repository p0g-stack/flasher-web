import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:flasher_web_core/flasher_web_core.dart'
    show HandleWorkspace, fakeFastbootSerial;
import 'package:web/web.dart' as web;

import 'platform_bridge.dart';

/// Creates the real page bridge. Compiled only for the browser.
PlatformBridge createBridge() => WebPlatformBridge();

/// The browser implementation: File System Access, IndexedDB, `fetch`,
/// downloads, the screen wake lock, page-level drag and drop, and the WebUSB
/// fastboot device chooser.
final class WebPlatformBridge implements PlatformBridge, StreamExportBridge {
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
    _launchListener = ((web.Event event) {
      final jsEvent = _toJSAny(event);
      final detail = jsEvent != null && jsEvent.isA<JSObject>()
          ? (jsEvent as JSObject).getProperty<JSAny?>('detail'.toJS)
          : null;
      _enqueueLaunches(detail);
      unawaited(_drainLaunches());
    }).toJS;
    web.window.addEventListener('flasher-launch-files', _launchListener);
    // The shim queues handles before Flutter starts; take them and leave an
    // empty array so the queue cannot grow for the life of the page.
    _enqueueLaunches(globalContext['flasherLaunchFiles']);
    globalContext['flasherLaunchFiles'] = <JSAny>[].toJS;
  }

  late final JSFunction _dragOver;
  late final JSFunction _drop;
  late final JSFunction _launchListener;
  final _dropped = StreamController<PickedFile>.broadcast();
  final _launched = StreamController<PickedFile>.broadcast();
  final _launchQueue = <JSObject>[];
  bool _draining = false;

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

  /// The page's WebUSB object, or null when this context has none.
  JSObject? get _usb {
    final navigator = globalContext['navigator'];
    if (navigator == null || !navigator.isA<JSObject>()) return null;
    final usb = (navigator as JSObject)['usb'];
    if (usb == null || !usb.isA<JSObject>()) return null;
    return usb as JSObject;
  }

  bool get _secureContext {
    final value = globalContext['isSecureContext'];
    return value != null &&
        value.isA<JSBoolean>() &&
        (value as JSBoolean).toDart;
  }

  @override
  bool get canChooseFastbootDevice {
    final usb = _usb;
    return _secureContext &&
        usb != null &&
        usb.has('requestDevice') &&
        usb.has('getDevices');
  }

  @override
  Future<FastbootUsbDevice?> chooseFastbootDevice() {
    // The e2e build pairs this with the worker's recording fake transport:
    // the page hands over the fake serial without touching WebUSB.
    if (const bool.fromEnvironment('FLASHER_FAKE_USB')) {
      return Future.value(
        const FastbootUsbDevice(
          serial: fakeFastbootSerial,
          label: 'Fake fastboot phone',
        ),
      );
    }
    final usb = _usb;
    if (usb == null || !usb.has('requestDevice')) {
      return Future.error(
        const FastbootUsbException(
          FastbootUsbFailure.unsupported,
          'This browser does not expose WebUSB. Open the app in current '
          'Chrome, Edge or Chromium.',
        ),
      );
    }
    if (!_secureContext) {
      return Future.error(
        const FastbootUsbException(
          FastbootUsbFailure.insecureContext,
          'WebUSB needs a secure page. Open the app on HTTPS or localhost.',
        ),
      );
    }
    // requestDevice must run in the same task as the click that led here, so
    // nothing may be awaited before this call.
    final options = <String, Object?>{
      'filters': <Object?>[
        <String, Object?>{
          'classCode': 0xff,
          'subclassCode': 0x42,
          'protocolCode': 0x03,
        },
      ].jsify(),
    }.jsify()!;
    final JSPromise<JSAny?> promise;
    try {
      promise = usb.callMethod<JSPromise<JSAny?>>(
        'requestDevice'.toJS,
        options,
      );
    } on Object catch (error) {
      return Future.error(_chooserError(error));
    }
    return _settleChooser(promise);
  }

  Future<FastbootUsbDevice?> _settleChooser(JSPromise<JSAny?> promise) async {
    final JSAny? value;
    try {
      value = await promise.toDart;
    } on Object catch (error) {
      if (_jsString(_toJSAny(error), 'name') == 'NotFoundError') return null;
      throw _chooserError(error);
    }
    return value == null ? null : _deviceFrom(value);
  }

  FastbootUsbDevice _deviceFrom(JSAny? value) {
    if (value == null || !value.isA<JSObject>()) {
      throw const FastbootUsbException(
        FastbootUsbFailure.other,
        'The browser returned a device this page cannot read.',
      );
    }
    final device = value as JSObject;
    final serial = _jsString(device, 'serialNumber')?.trim() ?? '';
    if (serial.isEmpty) {
      throw const FastbootUsbException(
        FastbootUsbFailure.noSerial,
        'The browser did not expose this device serial. Fastboot needs a '
        'serial to reopen the same phone; reconnect it and choose it again.',
      );
    }
    final product = _jsString(device, 'productName')?.trim();
    final vendor = _jsNumber(device, 'vendorId');
    final productId = _jsNumber(device, 'productId');
    final ids = vendor == null || productId == null
        ? ''
        : 'USB ${_hex(vendor)}:${_hex(productId)}';
    final label = [
      product,
      ids,
    ].where((part) => part != null && part.isNotEmpty).join(' · ');
    return FastbootUsbDevice(
      serial: serial,
      label: label.isEmpty ? 'Fastboot device' : label,
    );
  }

  FastbootUsbException _chooserError(Object error) {
    final jsError = _toJSAny(error);
    final name = _jsString(jsError, 'name');
    final message = _jsString(jsError, 'message');
    final detail = message == null || message.isEmpty ? '$error' : message;
    if (name == 'SecurityError') {
      return FastbootUsbException(
        FastbootUsbFailure.permission,
        'The browser refused WebUSB permission. Allow USB access for this '
        'site, then choose the device again.',
        error,
      );
    }
    return FastbootUsbException(
      FastbootUsbFailure.other,
      'The browser could not open the USB chooser: $detail',
      error,
    );
  }

  JSAny? _toJSAny(Object? value) {
    if (value == null) return null;
    try {
      return value as JSAny;
    } on Object {
      return null;
    }
  }

  String? _jsString(JSAny? value, String key) {
    if (value == null || !value.isA<JSObject>()) return null;
    final property = (value as JSObject).getProperty<JSAny?>(key.toJS);
    if (property == null || !property.isA<JSString>()) return null;
    return (property as JSString).toDart;
  }

  int? _jsNumber(JSAny? value, String key) {
    if (value == null || !value.isA<JSObject>()) return null;
    final property = (value as JSObject).getProperty<JSAny?>(key.toJS);
    if (property == null || !property.isA<JSNumber>()) return null;
    return (property as JSNumber).toDartInt;
  }

  String _hex(int value) =>
      '0x${value.toRadixString(16).padLeft(4, '0').toUpperCase()}';

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
    if (handle == null || !handle.has('name')) return null;
    final directory = handle as web.FileSystemDirectoryHandle;
    final permission = await _permission(handle, request: false);
    if (permission != 'granted') return null;
    return DirectoryRef(handle: directory, name: directory.name);
  }

  @override
  Future<String?> rememberedDirectoryName(String key) async {
    final handle = await _getHandle(key);
    if (handle == null) return null;
    final name = handle.getProperty<JSAny?>('name'.toJS);
    return name != null && name.isA<JSString>() ? (name as JSString).toDart : null;
  }

  @override
  Future<DirectoryRef?> requestRememberedDirectory(String key) async {
    final handle = await _getHandle(key);
    if (handle == null || !handle.has('name')) return null;
    final directory = handle as web.FileSystemDirectoryHandle;
    final permission = await _permission(handle, request: true);
    if (permission != 'granted') return null;
    return DirectoryRef(handle: directory, name: directory.name);
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
      final handle = handles.first;
      final file = await handle.getFile().toDart;
      // Remember the handle, not just the File: a reload can reopen it with a
      // read-permission prompt, while a File object cannot be persisted.
      await _putHandle('ota', handle);
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
      if (file == null) {
        completer.complete(null);
        return;
      }
      // An <input> pick has no handle to reopen, so a stale remembered OTA
      // must not come back after a reload.
      unawaited(forgetRememberedOta());
      completer.complete(
        PickedFile(handle: file, name: file.name, size: file.size),
      );
    }).toJS;
    input.click();
    return completer.future;
  }

  @override
  Stream<PickedFile> get droppedFiles => _dropped.stream;

  @override
  Stream<PickedFile> get launchedFiles {
    // The queue may hold files launched before this page had a listener.
    unawaited(_drainLaunches());
    return _launched.stream;
  }

  void _enqueueLaunches(JSAny? files) {
    if (files == null || !files.isA<JSArray>()) return;
    for (final item in (files as JSArray).toDart) {
      if (item != null && item.isA<JSObject>()) {
        _launchQueue.add(item as JSObject);
      }
    }
  }

  /// Resolves queued launch handles to Files. `getFile()` may reject when the
  /// grant was withdrawn, so one unreadable handle never blocks the rest.
  Future<void> _drainLaunches() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_launchQueue.isNotEmpty) {
        final handle = _launchQueue.removeAt(0);
        final web.File file;
        try {
          file = await (handle as web.FileSystemFileHandle).getFile().toDart;
        } on Object {
          continue;
        }
        if (!file.name.toLowerCase().endsWith('.zip')) continue;
        _launched.add(
          PickedFile(handle: file, name: file.name, size: file.size),
        );
      }
    } finally {
      _draining = false;
      if (_launchQueue.isNotEmpty) unawaited(_drainLaunches());
    }
  }

  @override
  Future<PickedFile?> rememberedOtaFile() async {
    final handle = await _getHandle('ota');
    if (handle == null || !handle.has('getFile')) return null;
    if (await _permission(handle, request: false, mode: 'read') != 'granted') {
      return null;
    }
    return _otaFileFrom(handle);
  }

  @override
  Future<String?> rememberedOtaFileName() async {
    final handle = await _getHandle('ota');
    if (handle == null) return null;
    final name = handle.getProperty<JSAny?>('name'.toJS);
    return name != null && name.isA<JSString>() ? (name as JSString).toDart : null;
  }

  @override
  Future<PickedFile?> requestRememberedOtaFile() async {
    final handle = await _getHandle('ota');
    if (handle == null || !handle.has('getFile')) return null;
    if (await _permission(handle, request: true, mode: 'read') != 'granted') {
      return null;
    }
    return _otaFileFrom(handle);
  }

  @override
  Future<void> forgetRememberedOta() async {
    final database = await _database();
    final completer = Completer<void>();
    final transaction = database.transaction(_store.toJS, 'readwrite');
    transaction.objectStore(_store).delete('${_prefix}ota'.toJS);
    transaction.oncomplete = ((web.Event event) {
      completer.complete();
    }).toJS;
    transaction.onerror = ((web.Event event) {
      completer.complete();
    }).toJS;
    await completer.future;
  }

  Future<PickedFile?> _otaFileFrom(JSObject handle) async {
    try {
      final file = await (handle as web.FileSystemFileHandle)
          .getFile()
          .toDart;
      return PickedFile(handle: file, name: file.name, size: file.size);
    } on Object {
      return null;
    }
  }

  @override
  bool get canSaveFile => _globalFunction('showSaveFilePicker') != null;

  @override
  Future<Object?> pickSaveFile({required String suggestedName}) async {
    final picker = _globalFunction('showSaveFilePicker');
    if (picker == null) {
      throw UnsupportedError(
        'This browser cannot choose a save file; use the download button.',
      );
    }
    // The picker must run in this click task before any await.
    final options = <String, Object?>{
      'suggestedName': suggestedName,
      'types': [
        {
          'description': 'ZIP archive',
          'accept': {
            'application/zip': ['.zip'],
          },
        },
      ],
    }.jsify();
    try {
      final promise = picker.callAsFunction(globalContext, options);
      return await (promise as JSPromise<JSAny?>).toDart;
    } on Object catch (error) {
      if (_jsString(_toJSAny(error), 'name') == 'AbortError') return null;
      rethrow;
    }
  }

  /// The page's service worker container, or null in a browser without one.
  web.ServiceWorkerContainer? get _serviceWorkers {
    final navigator = globalContext['navigator'];
    if (navigator == null || !navigator.isA<JSObject>()) return null;
    final container = (navigator as JSObject)['serviceWorker'];
    if (container == null || !container.isA<JSObject>()) return null;
    return container as web.ServiceWorkerContainer;
  }

  @override
  bool get canStreamExport => _serviceWorkers?.controller != null;

  @override
  Future<Object?> beginStreamExport({required String suggestedName}) async {
    final controller = _serviceWorkers?.controller;
    if (controller == null) {
      throw UnsupportedError(
        'The download service is not running yet; reload the page.',
      );
    }
    final id = _exportId();
    final channel = 'flasher-export-$id';
    final accepted = _awaitExportAccepted(id);
    controller.postMessage(
      <String, Object?>{
        'type': 'flasher-export-register',
        'id': id,
        'filename': suggestedName,
        'channel': channel,
      }.jsify(),
    );
    await accepted;
    // A hidden iframe keeps the app page: the service worker answers this
    // navigation with `Content-Disposition: attachment`, so the browser turns
    // it into a download. An `<a download>` never reaches the worker.
    final frame = web.HTMLIFrameElement()
      ..src = 'download/$id'
      ..style.display = 'none';
    web.document.body?.append(frame);
    // The frame only starts the download; removing it earlier would cancel
    // the request.
    Timer(const Duration(minutes: 10), () => frame.remove());
    return <String, Object?>{'kind': 'stream', 'id': id, 'channel': channel};
  }

  @override
  void abortStreamExport(Object destination, {String? reason}) {
    final controller = _serviceWorkers?.controller;
    final id = destination is Map ? destination['id'] : null;
    if (controller == null || id is! String || id.isEmpty) return;
    try {
      controller.postMessage(
        <String, Object?>{
          'type': 'flasher-export-abort',
          'id': id,
          'reason': ?reason,
        }.jsify(),
      );
    } on Object {
      // The page or the worker is already gone; nothing is left to abort.
    }
  }

  /// A one-use download id; `randomUUID` needs a secure context, the clock and
  /// a random number do not.
  String _exportId() {
    final crypto = globalContext['crypto'];
    if (crypto != null && crypto.isA<JSObject>()) {
      final randomUuid = (crypto as JSObject)['randomUUID'];
      if (randomUuid != null && randomUuid.isA<JSFunction>()) {
        try {
          final value = (randomUuid as JSFunction).callAsFunction(crypto);
          if (value.isA<JSString>()) return (value as JSString).toDart;
        } on Object {
          // Fall through to the clock.
        }
      }
    }
    final now = DateTime.now().microsecondsSinceEpoch;
    final random = math.Random().nextInt(1 << 32).toRadixString(16);
    return '$now-$random';
  }

  /// Waits for the service worker to acknowledge [id] before the download is
  /// requested, so the route never answers 404 for an unknown id.
  Future<void> _awaitExportAccepted(String id) async {
    final completer = Completer<void>();
    late final JSFunction listener;
    void finish([Object? error]) {
      _serviceWorkers?.removeEventListener('message', listener);
      if (completer.isCompleted) return;
      if (error == null) {
        completer.complete();
      } else {
        completer.completeError(error);
      }
    }

    listener = ((web.MessageEvent event) {
      final data = event.data;
      if (data == null || !data.isA<JSObject>()) return;
      final object = data as JSObject;
      if (!_jsEquals(object, 'type', 'flasher-export-accepted')) return;
      if (!_jsEquals(object, 'id', id)) return;
      finish();
    }).toJS;
    _serviceWorkers?.addEventListener('message', listener);
    final timer = Timer(const Duration(seconds: 5), () {
      finish(
        StateError('The download service did not answer; reload the page.'),
      );
    });
    try {
      await completer.future;
    } finally {
      timer.cancel();
    }
  }

  bool _jsEquals(JSObject object, String key, String expected) {
    final value = object.getProperty<JSAny?>(key.toJS);
    return value != null &&
        value.isA<JSString>() &&
        (value as JSString).toDart == expected;
  }

  @override
  Future<void> saveStoreFile(
    String path, {
    Object? handle,
    required Object destination,
  }) async {
    final root = handle == null
        ? await web.window.navigator.storage.getDirectory().toDart
        : handle as web.FileSystemDirectoryHandle;
    final parts = path
        .split('/')
        .where((part) => part.isNotEmpty && part != '.')
        .toList();
    if (parts.isEmpty) throw StateError('No file to save.');
    var directory = root;
    for (final part in parts.take(parts.length - 1)) {
      directory = await directory
          .getDirectoryHandle(part, web.FileSystemGetDirectoryOptions())
          .toDart;
    }
    final source = await directory
        .getFileHandle(parts.last, web.FileSystemGetFileOptions())
        .toDart
        .then((file) => file.getFile().toDart);
    final writable = await (destination as web.FileSystemFileHandle)
        .createWritable()
        .toDart;
    await writable.write(source as JSAny).toDart;
    await writable.close().toDart;
  }

  @override
  Future<PickedFile?> openSavedOta(
    Object destination, {
    required bool remember,
  }) async {
    final handle = destination as web.FileSystemFileHandle;
    // The save picker granted read and write, so this needs no prompt.
    if (remember) await _putHandle('ota', handle);
    return _otaFileFrom(handle);
  }

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
    web.window.removeEventListener('flasher-launch-files', _launchListener);
    _dropped.close();
    _launched.close();
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

  Future<void> _putHandle(String key, JSObject handle) async {
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

  Future<JSObject?> _getHandle(String key) async {
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
    return value != null && value.isA<JSObject>() ? value as JSObject : null;
  }

  Future<String> _permission(
    JSObject handle, {
    required bool request,
    String mode = 'readwrite',
  }) async {
    final options = <String, Object?>{'mode': mode}.jsify();
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
