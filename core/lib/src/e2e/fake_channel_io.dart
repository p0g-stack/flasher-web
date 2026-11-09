/// Native builds have no page-side control channel.
library;

/// Installs the channel. A native test entrypoint reads the fake's state
/// in-process instead.
void installFakeFastbootChannel({
  required Map<String, Object?> Function() state,
  required Map<String, Object?> Function(Map<String, Object?>) configure,
}) {}

/// Sends one event to the page. A native process has no listener.
void fakeFastbootBroadcast(Map<String, Object?> message) {}
