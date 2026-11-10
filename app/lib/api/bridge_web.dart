import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:dir_picker/dir_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker_web/file_picker_web.dart';
import 'package:flasher_web_core/flasher_web_core.dart'
    show HandleWorkspace, fakeFastbootSerial;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web/web.dart' as web;
import 'package:web_usb_grant/web_usb_grant.dart';

import 'platform_bridge.dart';

/// Creates the real page bridge. Compiled only for the browser.
PlatformBridge createBridge() => WebPlatformBridge(
  usb: const bool.fromEnvironment('FLASHER_FAKE_USB')
      ? WebUsb(backend: const _FakeFastbootUsbBackend())
      : null,
);

/// The browser implementation: the file system access handles, `fetch`,
/// downloads, the screen wake lock, page-level drag and drop, and the WebUSB
/// fastboot device chooser. OTA files are picked with `file_picker`, whose
/// patched web package keeps the handle a reload reopens; folder picking is
/// `dir_picker`, preferences are `shared_preferences`, external links are
/// `url_launcher`.
final class WebPlatformBridge implements PlatformBridge, StreamExportBridge {
  WebPlatformBridge({WebUsb? usb}) : _webUsb = usb ?? WebUsb() {
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
    _watchUsb();
    _watchUpdates();
  }

  final _usbEvents = StreamController<UsbAttachEvent>.broadcast();
  final _appUpdates = StreamController<String>.broadcast();
  JSFunction? _usbConnect;
  JSFunction? _usbDisconnect;
  JSFunction? _updateMessage;

  /// A new app deploy is only an update for a page that was already
  /// controlled: the first install has nothing old to replace.
  bool _wasControlled = false;

  final WebUsb _webUsb;
  late final JSFunction _dragOver;
  late final JSFunction _drop;
  late final JSFunction _launchListener;
  final _dropped = StreamController<PickedFile>.broadcast();
  final _launched = StreamController<PickedFile>.broadcast();
  final _launchQueue = <JSObject>[];
  bool _draining = false;

  int _keepAlive = 0;
  web.WakeLockSentinel? _sentinel;
  JSFunction? _leaveGuard;
  JSFunction? _visibility;
  Future<void>? _acquiring;
  late final _preferences = SharedPreferencesAsync();

  /// The OTA ZIP the page remembered, and the unfinished save, each as the
  /// `file_picker` token of its handle.
  static const _otaTokenKey = 'flasher_web.ota-token';
  static const _preferencesKey = 'flasher_web.preferences';
  static const _directoryPrefix = 'flasher_web.directory.';

  /// The OTA pick: the browser's file system access dialog where it has one, so
  /// the pick carries a handle a reload can reopen, and `<input type="file">`
  /// everywhere else.
  ///
  /// `withData: false` keeps the pick from reading an OTA into memory; the
  /// page streams ranges from the `File` instead.
  static const _otaPicker = FilePickerWebOptions(
    // ignore: deprecated_member_use
    withData: false,
    dialog: WebFileDialog.auto,
    pickerId: 'ota',
    types: [
      WebFileTypeFilter(
        description: 'Full OTA ZIP',
        accept: {
          'application/zip': ['.zip'],
        },
      ),
    ],
  );

  @override
  bool get available => true;

  @override
  bool get canPickDirectory => _globalFunction('showDirectoryPicker') != null;

  @override
  bool get canChooseFastbootDevice => _webUsb.isSupported;

  @override
  Future<FastbootDeviceChoice?> chooseFastbootDevice() async {
    // The package invokes requestDevice synchronously, before this await.
    // Fastboot policy stays here, not in the generic grant package.
    final UsbGrant grant;
    try {
      grant = await _webUsb.request(
        filters: const [
          UsbFilter(classCode: 0xff, subclassCode: 0x42, protocolCode: 0x03),
        ],
      );
    } on UsbException catch (error) {
      if (error.kind == UsbFailureKind.cancelled) return null;
      rethrow;
    }
    final serial = grant.requireSerial();
    final product = grant.product?.trim();
    final ids = 'USB ${_hex(grant.vendorId)}:${_hex(grant.productId)}';
    return (
      serial: serial,
      label: [
        if (product != null && product.isNotEmpty) product,
        ids,
      ].join(' · '),
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
    final String? raw;
    try {
      raw = await _preferences.getString(_preferencesKey);
    } on Object {
      // Unreadable or of another type: start from the defaults.
      return null;
    }
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
  Future<void> writePreferences(Map<String, Object?> value) =>
      _preferences.setString(_preferencesKey, jsonEncode(value));

  @override
  Future<DirectoryRef?> pickDirectory(
    String key, {
    String label = 'Choose folder',
  }) async {
    final location = await DirPicker.pick(
      options: PickOptions.web(
        mode: WebPermissionMode.readwrite,
        id: key,
        startIn: WebStartIn.documents,
      ),
    );
    if (location is! WebPickedLocation) return null;
    final token = await DirPicker.persist(location);
    final previous = await _preferences.getString('$_directoryPrefix$key');
    await _preferences.setString('$_directoryPrefix$key', token);
    if (previous != null && previous != token) {
      await DirPicker.release(previous);
    }
    return DirectoryRef(handle: location.handle, name: location.name);
  }

  @override
  Future<DirectoryRef?> rememberedDirectory(String key) async {
    final location = await _restoreDirectory(key);
    if (location == null) return null;
    if (!await location.hasAccess(mode: WebPermissionMode.readwrite)) {
      return null;
    }
    return DirectoryRef(handle: location.handle, name: location.name);
  }

  @override
  Future<String?> rememberedDirectoryName(String key) async =>
      (await _restoreDirectory(key))?.name;

  @override
  Future<DirectoryRef?> requestRememberedDirectory(String key) async {
    final location = await _restoreDirectory(key);
    if (location == null) return null;
    try {
      if (!await location.requestAccess(mode: WebPermissionMode.readwrite)) {
        return null;
      }
    } on DirPickerException {
      return null;
    }
    return DirectoryRef(handle: location.handle, name: location.name);
  }

  Future<WebPickedLocation?> _restoreDirectory(String key) async {
    final token = await _preferences.getString('$_directoryPrefix$key');
    if (token == null) return null;
    final location = await DirPicker.restore(token);
    return location is WebPickedLocation ? location : null;
  }

  @override
  Future<PickedFile?> pickOtaFile() async {
    // The dialog filters with `types`; the extensions keep the `<input>`
    // fallback, which every other browser picks through, filtered to zips.
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      webOptions: _otaPicker,
    );
    if (picked is! WebPlatformFile) return null;
    final file = picked.file;
    if (file == null) return null;
    // Remember the handle, not just the File: a reload can reopen it with a
    // read-permission prompt, while a File object cannot be persisted. An
    // input pick has no handle, so it clears what a reload would reopen.
    await _rememberOtaToken(await picked.persist());
    return PickedFile(handle: file, name: file.name, size: file.size);
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
    final file = await _rememberedOta();
    if (file == null || !await file.hasAccess()) return null;
    return _pickedOta(file);
  }

  @override
  Future<String?> rememberedOtaFileName() async =>
      (await _rememberedOta())?.name;

  @override
  Future<PickedFile?> requestRememberedOtaFile() async {
    final file = await _rememberedOta();
    if (file == null) return null;
    if (!await file.requestAccess()) return null;
    try {
      await file.getFile();
    } on Object {
      // Deleted or moved since it was picked; nothing is left to reopen.
      await forgetRememberedOta();
      return null;
    }
    return _pickedOta(file);
  }

  @override
  Future<void> forgetRememberedOta() async {
    final token = await _preferences.getString(_otaTokenKey);
    await _preferences.remove(_otaTokenKey);
    await _forgetToken(token);
  }

  /// [file] as the core takes it: the browser `File` it slices, not the handle.
  static PickedFile? _pickedOta(WebPlatformFile file) {
    final browser = file.file;
    return browser == null
        ? null
        : PickedFile(handle: browser, name: browser.name, size: browser.size);
  }

  /// The OTA the page remembered, or null when it has none left.
  Future<WebPlatformFile?> _rememberedOta() async {
    final token = await _preferences.getString(_otaTokenKey);
    if (token == null) return null;
    final file = await WebPlatformFile.restore(token);
    if (file == null) {
      // Cleared site data, another profile, or a file that moved away.
      await _preferences.remove(_otaTokenKey);
    }
    return file;
  }

  /// Points the remembered OTA at [token]; a null token forgets it.
  Future<void> _rememberOtaToken(String? token) async {
    final previous = await _preferences.getString(_otaTokenKey);
    if (previous == token) return;
    if (token == null) {
      await _preferences.remove(_otaTokenKey);
    } else {
      await _preferences.setString(_otaTokenKey, token);
    }
    await _forgetToken(previous);
  }

  /// Drops [token] from the browser's store unless the remembered OTA still
  /// uses it.
  Future<void> _forgetToken(String? token) async {
    if (token == null) return;
    if (await _preferences.getString(_otaTokenKey) == token) return;
    try {
      await WebPlatformFile.forget(token);
    } on Object {
      // Already gone.
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
    if (remember) {
      await _rememberOtaToken(await WebPlatformFile.persistHandle(handle));
    }
    return _otaFileFrom(handle);
  }

  Future<PickedFile?> _otaFileFrom(web.FileSystemFileHandle handle) async {
    try {
      final file = await handle.getFile().toDart;
      return PickedFile(handle: file, name: file.name, size: file.size);
    } on Object {
      return null;
    }
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
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
  }

  /// Page-level WebUSB arrival/removal.
  ///
  /// Only connection state reads these events: the worker's transport owns
  /// every session, so this listener never opens a device or sends a command.
  void _watchUsb() {
    final navigator = globalContext['navigator'];
    if (navigator == null || !navigator.isA<JSObject>()) return;
    final usbValue = (navigator as JSObject).getProperty<JSAny?>('usb'.toJS);
    if (usbValue == null || !usbValue.isA<JSObject>()) return;
    final usb = usbValue as JSObject;
    JSFunction listener(bool attached) => ((JSAny event) {
      final device = event.isA<JSObject>()
          ? (event as JSObject).getProperty<JSAny?>('device'.toJS)
          : null;
      JSAny? field(String key) =>
          device != null && device.isA<JSObject>()
          ? (device as JSObject).getProperty<JSAny?>(key.toJS)
          : null;
      String? text(String key) {
        final value = field(key);
        return value != null && value.isA<JSString>()
            ? (value as JSString).toDart
            : null;
      }

      int? number(String key) {
        final value = field(key);
        return value != null && value.isA<JSNumber>()
            ? (value as JSNumber).toDartInt
            : null;
      }

      final vendor = number('vendorId');
      final product = number('productId');
      _usbEvents.add(
        UsbAttachEvent(
          attached: attached,
          serial: text('serialNumber'),
          product: text('productName'),
          ids: vendor == null || product == null
              ? null
              : '${_hex(vendor)}:${_hex(product)}',
        ),
      );
    }).toJS;
    _usbConnect = listener(true);
    _usbDisconnect = listener(false);
    usb.callMethod<JSAny?>(
      'addEventListener'.toJS,
      'connect'.toJS,
      _usbConnect!,
    );
    usb.callMethod<JSAny?>(
      'addEventListener'.toJS,
      'disconnect'.toJS,
      _usbDisconnect!,
    );
  }

  /// Listens for the app service worker announcing a deploy that took control.
  ///
  /// The service worker posts `flasher-app-updated` once a new version
  /// activated; the page decides when a reload is safe.
  void _watchUpdates() {
    final container = _serviceWorkers;
    if (container == null) return;
    _wasControlled = container.controller != null;
    _updateMessage = ((web.Event event) {
      final data = (event as web.MessageEvent).data;
      if (data == null || !data.isA<JSObject>()) return;
      final type = (data as JSObject).getProperty<JSAny?>('type'.toJS);
      if (type == null ||
          !type.isA<JSString>() ||
          (type as JSString).toDart != 'flasher-app-updated' ||
          !_wasControlled) {
        return;
      }
      final version = data.getProperty<JSAny?>('version'.toJS);
      _appUpdates.add(
        version != null && version.isA<JSString>()
            ? (version as JSString).toDart
            : 'new',
      );
    }).toJS;
    container.addEventListener('message', _updateMessage);
  }

  @override
  bool get wakeLockSupported {
    final navigator = globalContext['navigator'];
    if (navigator == null || !navigator.isA<JSObject>()) return false;
    final lock = (navigator as JSObject).getProperty<JSAny?>('wakeLock'.toJS);
    return lock != null && lock.isA<JSObject>();
  }

  @override
  Stream<UsbAttachEvent> get usbAttachEvents => _usbEvents.stream;

  @override
  Stream<String> get appUpdates => _appUpdates.stream;

  @override
  void reloadPage() => web.window.location.reload();

  static const _checkpointKey = 'flasher_web.flash-checkpoint';

  @override
  Future<Map<String, Object?>?> readFlashCheckpoint() async {
    final String? raw;
    try {
      raw = web.window.localStorage.getItem(_checkpointKey);
    } on Object {
      return null;
    }
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
  Future<void> writeFlashCheckpoint(Map<String, Object?> value) async {
    try {
      web.window.localStorage.setItem(_checkpointKey, jsonEncode(value));
    } on Object {
      // A full or blocked storage leaves the page without a restorable
      // receipt; the live run is unaffected.
    }
  }

  @override
  Future<void> clearFlashCheckpoint() async {
    try {
      web.window.localStorage.removeItem(_checkpointKey);
    } on Object {
      // Nothing to clear if storage is blocked.
    }
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
    // The browser releases a screen wake lock whenever the tab is hidden;
    // take it again when the tab is visible while work still runs.
    _visibility = ((web.Event event) {
      if (web.document.visibilityState == 'visible') unawaited(_wakeLock());
    }).toJS;
    web.document.addEventListener('visibilitychange', _visibility);
    await _wakeLock();
  }

  /// One request at a time, so a visibility change during [beginKeepAwake]
  /// cannot leave a second sentinel behind.
  Future<void> _wakeLock() =>
      _acquiring ??= _acquireWakeLock().whenComplete(() => _acquiring = null);

  Future<void> _acquireWakeLock() async {
    if (_keepAlive == 0) return;
    final held = _sentinel;
    if (held != null && !held.released) return;
    try {
      final sentinel = await web.window.navigator.wakeLock
          .request('screen')
          .toDart;
      if (_keepAlive == 0) {
        await sentinel.release().toDart;
        return;
      }
      _sentinel = sentinel;
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
    final visibility = _visibility;
    if (visibility != null) {
      web.document.removeEventListener('visibilitychange', visibility);
      _visibility = null;
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
    final navigator = globalContext['navigator'];
    final usb = navigator != null && navigator.isA<JSObject>()
        ? (navigator as JSObject).getProperty<JSAny?>('usb'.toJS)
        : null;
    if (usb != null && usb.isA<JSObject>()) {
      final connect = _usbConnect;
      final disconnect = _usbDisconnect;
      if (connect != null) {
        (usb as JSObject).callMethod<JSAny?>(
          'removeEventListener'.toJS,
          'connect'.toJS,
          connect,
        );
      }
      if (disconnect != null) {
        (usb as JSObject).callMethod<JSAny?>(
          'removeEventListener'.toJS,
          'disconnect'.toJS,
          disconnect,
        );
      }
    }
    final update = _updateMessage;
    if (update != null) _serviceWorkers?.removeEventListener('message', update);
    _dropped.close();
    _launched.close();
    _usbEvents.close();
    _appUpdates.close();
    final guard = _leaveGuard;
    if (guard != null) {
      web.window.removeEventListener('beforeunload', guard);
    }
    final visibility = _visibility;
    if (visibility != null) {
      web.document.removeEventListener('visibilitychange', visibility);
    }
    _sentinel?.release();
  }
}

/// Injected only at the e2e composition root, paired with the worker's fake
/// transport. The production chooser and the package have no fake-USB branch.
final class _FakeFastbootUsbBackend implements UsbBackend {
  const _FakeFastbootUsbBackend();

  @override
  UsbCapabilities get capabilities => const UsbCapabilities(
    secureContext: true,
    canRequest: true,
    canList: true,
  );

  UsbGrant get _grant => UsbGrant(
    vendorId: 0,
    productId: 0,
    serial: fakeFastbootSerial,
    product: 'Fake fastboot phone',
    handle: Object(),
  );

  @override
  Future<UsbGrant> request({
    List<UsbFilter> filters = const [],
    List<UsbFilter> exclude = const [],
  }) => Future.value(_grant);

  @override
  Future<List<UsbGrant>> granted() => Future.value([_grant]);
}
