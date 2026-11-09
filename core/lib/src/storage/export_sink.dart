/// A [ByteSink] on a destination file the user chose, outside the app's
/// stores.
///
/// The web host passes the `FileSystemFileHandle` the save picker returned;
/// the VM passes `{"kind": "path", "path": "..."}`. Both truncate an existing
/// file, matching `createWritable()`, and neither writes into the origin's
/// storage, so an export does not count against the storage cap.
library;

export 'export_sink_stub.dart'
    if (dart.library.io) 'export_sink_io.dart'
    if (dart.library.js_interop) 'export_sink_web.dart';
