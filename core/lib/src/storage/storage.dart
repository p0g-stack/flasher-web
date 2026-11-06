/// Storage contracts and their VM and browser implementations.
///
/// A caller imports this library and gets the implementation for the place it
/// was compiled for: `dart:io` on the VM and CLI, and the browser's File System
/// Access / Blob APIs on the web. The contract types are the same everywhere.
library;

export 'contracts.dart';
export 'paths.dart'
    show normalizeWorkspacePath, workspaceSeparator, joinWorkspacePath;
export 'platform_stub.dart'
    if (dart.library.io) 'platform_io.dart'
    if (dart.library.js_interop) 'platform_web.dart';
export 'range.dart' show ContentRange, RangeException;
