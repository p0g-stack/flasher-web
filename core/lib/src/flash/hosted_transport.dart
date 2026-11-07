/// Selects the hosted transport for the current platform.
///
/// The web build talks to the same origin with `fetch`; natively there is no
/// hosted origin, so a hosted request is refused instead of reaching an
/// arbitrary URL.
library;

export 'hosted_transport_stub.dart'
    if (dart.library.js_interop) 'hosted_transport_web.dart';
