/// The platform capacity reading behind [StorageBudget].
///
/// A caller imports this library and gets the implementation for the place it
/// was compiled for: free volume space on the VM and the browser's
/// `navigator.storage` estimate on the web. The class name and constructor are
/// the same on every target.
library;

export 'estimate_stub.dart'
    if (dart.library.io) 'estimate_io.dart'
    if (dart.library.js_interop) 'estimate_web.dart';
