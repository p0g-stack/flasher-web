/// The browser services the app needs but the pipeline does not.
///
/// Pickers, remembered handles, downloads, the wake lock, the drag-and-drop
/// listener and the WebUSB fastboot chooser are page-only APIs. They live
/// behind this interface so widget tests run on the VM and the UI chooses a
/// store from the service's facts, never from `kIsWeb`.
library;

import 'package:web_usb_grant/web_usb_grant.dart';

/// A file the user picked: the browser object, not its bytes.
final class PickedFile {
  const PickedFile({
    required this.handle,
    required this.name,
    required this.size,
  });

  /// The browser's `File` (or `FileSystemFileHandle` after picker resolution).
  final Object handle;

  final String name;
  final int size;

  @override
  String toString() => name;
}

/// A directory handle the user picked or that was remembered.
final class DirectoryRef {
  const DirectoryRef({required this.handle, required this.name});

  /// The browser's `FileSystemDirectoryHandle`.
  final Object handle;

  final String name;

  @override
  String toString() => name;
}

/// App policy projection of a grant, after requiring a serial. Only this
/// serial and display label cross to the service, never the USBDevice handle.
typedef FastbootDeviceChoice = ({String serial, String label});

/// The page-side capabilities.
abstract interface class PlatformBridge {
  /// Whether this build of the app has a real browser bridge.
  bool get available;

  /// Whether the page itself can show a directory picker.
  ///
  /// The service reports worker facts, where `fs.picker` is always false; the
  /// page probe is the caller-side half of the same fact.
  bool get canPickDirectory;

  /// Reads a same-origin static file, for example `upstream/tables.json`.
  Future<String> fetchText(String path);

  /// Preferences, kept through `shared_preferences`.
  Future<Map<String, Object?>?> readPreferences();

  Future<void> writePreferences(Map<String, Object?> value);

  /// Picks a directory and remembers the handle under [key].
  Future<DirectoryRef?> pickDirectory(
    String key, {
    String label = 'Choose folder',
  });

  /// A remembered directory whose write permission is still granted.
  Future<DirectoryRef?> rememberedDirectory(String key);

  /// The name of a remembered directory even when permission must be renewed.
  Future<String?> rememberedDirectoryName(String key);

  /// Asks the browser to renew a remembered handle's write permission.
  Future<DirectoryRef?> requestRememberedDirectory(String key);

  /// Picks a full OTA ZIP.
  Future<PickedFile?> pickOtaFile();

  /// Files opened through the installed PWA's file handler (`launchQueue`).
  ///
  /// The page's shim queues handles before Flutter starts, so the first
  /// listener receives them as well. Only `.zip` files are emitted.
  Stream<PickedFile> get launchedFiles;

  /// A previously picked OTA whose read permission is still granted.
  Future<PickedFile?> rememberedOtaFile();

  /// The name of a remembered OTA even when read permission must be renewed.
  Future<String?> rememberedOtaFileName();

  /// Renews read permission on the remembered OTA and opens it.
  ///
  /// Call from the click handler: the permission prompt needs the gesture.
  Future<PickedFile?> requestRememberedOtaFile();

  /// Drops the remembered OTA, for a pick the browser cannot persist.
  Future<void> forgetRememberedOta();

  /// Whether this page can show a save-file picker.
  bool get canSaveFile;

  /// Shows the browser save picker and returns its `FileSystemFileHandle`.
  ///
  /// Call from the click handler before any await. Null means the user
  /// cancelled; a browser without the picker throws [UnsupportedError].
  Future<Object?> pickSaveFile({required String suggestedName});

  /// Writes one store file into a save-picker [destination] handle.
  Future<void> saveStoreFile(
    String path, {
    Object? handle,
    required Object destination,
  });

  /// Opens the OTA a catalog download wrote into a save-picker [destination].
  ///
  /// With [remember] the handle replaces the remembered OTA, as a pick does,
  /// so a reload reopens the saved file. Null means the file is unreadable.
  Future<PickedFile?> openSavedOta(
    Object destination, {
    required bool remember,
  });

  /// Remembers an OTA download into a save-picker [destination] before it
  /// starts, with the [request] that resumes it, so a reload can continue the
  /// partial file instead of starting over. One save is remembered at a time.
  Future<void> rememberOtaSave(
    Object destination,
    Map<String, Object?> request,
  );

  /// The remembered save's file name and request, without a permission
  /// prompt; null when none is remembered.
  Future<({String name, Map<String, Object?> request})?> rememberedOtaSave();

  /// Renews write permission on the remembered save and returns its handle.
  ///
  /// Call from the click handler: the permission prompt needs the gesture.
  /// Null when nothing is remembered or the user refuses.
  Future<Object?> requestRememberedOtaSave();

  /// Drops the remembered save.
  Future<void> forgetOtaSave();

  /// Whether the page can open a WebUSB fastboot chooser right now.
  ///
  /// This is a page capability probe; whether the place can write is the
  /// service's facts, never this value alone.
  bool get canChooseFastbootDevice;

  /// Asks the browser for one fastboot device (interface ff/42/03).
  ///
  /// Call this synchronously from the click handler: the browser requires a
  /// user gesture, so no `await` may run first. Returns null when the user
  /// closes the chooser without choosing. Browser errors are wrapped in a
  /// [UsbException] with its original DOMException name, message and stack.
  Future<FastbootDeviceChoice?> chooseFastbootDevice();

  /// Files dropped onto the page. Only `.zip` files are emitted.
  Stream<PickedFile> get droppedFiles;

  /// Calls `navigator.storage.persist()`.
  Future<bool> requestPersistentStorage();

  /// Downloads [path] from the store rooted at [handle] (null means OPFS).
  Future<void> downloadStoreFile(
    String path, {
    required String filename,
    Object? handle,
  });

  /// Downloads [text] as [filename].
  Future<void> downloadText(String text, String filename);

  /// Opens an HTTP(S) link in a new tab.
  Future<void> openExternal(String url);

  /// Holds a screen wake lock and a leave guard until [endKeepAwake].
  Future<void> beginKeepAwake();

  Future<void> endKeepAwake();

  /// Deletes one job directory from the store at [handle] (null means OPFS).
  Future<void> deleteStorePath(String path, {Object? handle});

  void dispose();
}

/// The page's streamed download, for browsers without a save-file picker.
///
/// Android Chrome has no `showSaveFilePicker`, so the page registers a one-use
/// download with its service worker and hands the export a destination the
/// worker streams the ZIP through instead of a file handle. Only the real
/// browser bridge implements this; a bridge without it keeps the picker path.
abstract interface class StreamExportBridge {
  /// Whether the app's service worker controls this page, which is what serves
  /// the download. A page loaded before the worker first activated is not, and
  /// must be reloaded.
  bool get canStreamExport;

  /// Registers a one-use download named [suggestedName] and starts it.
  ///
  /// Returns the export destination `{"kind": "stream", "id", "channel"}`: the
  /// service streams the archive over the channel named here. Throws when the
  /// service worker does not answer.
  Future<Object?> beginStreamExport({required String suggestedName});

  /// Drops the registered download after a failed export, so the browser does
  /// not keep a broken file.
  void abortStreamExport(Object destination, {String? reason});
}

/// A bridge for platforms without a browser, and the analyzer's stub branch.
///
/// Widget tests supply a scripted bridge; this one fails loudly if a caller
/// reaches it at runtime instead of silently pretending work happened.
final class UnsupportedPlatformBridge implements PlatformBridge {
  const UnsupportedPlatformBridge();

  Never _unsupported() =>
      throw UnsupportedError('The browser bridge is not available here.');

  @override
  bool get available => false;

  @override
  bool get canPickDirectory => false;

  @override
  Future<String> fetchText(String path) async => _unsupported();

  @override
  Future<Map<String, Object?>?> readPreferences() async => null;

  @override
  Future<void> writePreferences(Map<String, Object?> value) async {}

  @override
  Future<DirectoryRef?> pickDirectory(
    String key, {
    String label = 'Choose folder',
  }) async => _unsupported();

  @override
  Future<DirectoryRef?> rememberedDirectory(String key) async => null;

  @override
  Future<String?> rememberedDirectoryName(String key) async => null;

  @override
  Future<DirectoryRef?> requestRememberedDirectory(String key) async => null;

  @override
  Future<PickedFile?> pickOtaFile() async => _unsupported();

  @override
  Stream<PickedFile> get launchedFiles => const Stream.empty();

  @override
  Future<PickedFile?> rememberedOtaFile() async => null;

  @override
  Future<String?> rememberedOtaFileName() async => null;

  @override
  Future<PickedFile?> requestRememberedOtaFile() async => null;

  @override
  Future<void> forgetRememberedOta() async {}

  @override
  bool get canSaveFile => false;

  @override
  Future<Object?> pickSaveFile({required String suggestedName}) async =>
      _unsupported();

  @override
  Future<void> saveStoreFile(
    String path, {
    Object? handle,
    required Object destination,
  }) async => _unsupported();

  @override
  Future<PickedFile?> openSavedOta(
    Object destination, {
    required bool remember,
  }) async => _unsupported();

  @override
  Future<void> rememberOtaSave(
    Object destination,
    Map<String, Object?> request,
  ) async => _unsupported();

  @override
  Future<({String name, Map<String, Object?> request})?>
  rememberedOtaSave() async => null;

  @override
  Future<Object?> requestRememberedOtaSave() async => null;

  @override
  Future<void> forgetOtaSave() async {}

  @override
  bool get canChooseFastbootDevice => false;

  @override
  Future<FastbootDeviceChoice?> chooseFastbootDevice() async => _unsupported();

  @override
  Stream<PickedFile> get droppedFiles => const Stream.empty();

  @override
  Future<bool> requestPersistentStorage() async => false;

  @override
  Future<void> downloadStoreFile(
    String path, {
    required String filename,
    Object? handle,
  }) async => _unsupported();

  @override
  Future<void> downloadText(String text, String filename) async =>
      _unsupported();

  @override
  Future<void> openExternal(String url) async => _unsupported();

  @override
  Future<void> beginKeepAwake() async {}

  @override
  Future<void> endKeepAwake() async {}

  @override
  Future<void> deleteStorePath(String path, {Object? handle}) async =>
      _unsupported();

  @override
  void dispose() {}
}
