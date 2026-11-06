/// The browser services the app needs but the pipeline does not.
///
/// Pickers, remembered handles, downloads, the wake lock and the drag-and-drop
/// listener are page-only APIs. They live behind this interface so widget
/// tests run on the VM and the UI chooses a store from the service's facts,
/// never from `kIsWeb`.
library;

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

  /// Preferences stored in `localStorage`.
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
