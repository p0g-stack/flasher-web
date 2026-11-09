/// A [ByteSink] on a destination file the user chose, outside the app's
/// stores.
///
/// The web host passes the `FileSystemFileHandle` the save picker returned, or
/// `{"kind": "stream", "channel": "..."}` when the browser has no save picker
/// and the service worker serves the archive as a download; the VM passes
/// `{"kind": "path", "path": "..."}`. All three truncate an existing
/// destination and none writes into the origin's storage, so an export does
/// not count against the storage cap.
library;

export 'export_sink_stub.dart'
    if (dart.library.io) 'export_sink_io.dart'
    if (dart.library.js_interop) 'export_sink_web.dart';
