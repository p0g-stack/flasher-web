/// Selects the fake device's browser control channel.
///
/// A native process has no page to talk to, so the IO variant installs
/// nothing; the browser variant opens a same-origin `BroadcastChannel` the
/// e2e harness listens on.
library;

export 'fake_channel_io.dart'
    if (dart.library.js_interop) 'fake_channel_web.dart';
