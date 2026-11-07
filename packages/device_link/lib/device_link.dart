library;

import 'dart:typed_data';

/// Identity from descriptors, never a product/mode inferred from VID/PID.
final class FastbootDevice {
  const FastbootDevice({
    required this.serial,
    this.label = '',
    this.transport = '',
  });
  final String serial;
  final String label;
  final String transport;
  Map<String, Object?> toMap() => {
    'serial': serial,
    'label': label,
    'transport': transport,
  };
}

/// Classification is additional evidence; the original error is retained.
final class LinkFailure implements Exception {
  const LinkFailure({
    required this.blame,
    required this.name,
    required this.message,
    required this.stage,
    this.uncertain = false,
    this.source = '',
    this.sessionRetired = false,
    this.stack = '',
    this.causes = const [],
    this.cleanupErrors = const [],
    this.messages = const [],
  });
  final String blame;

  /// Producing layer, not a responsibility category.
  final String source;

  /// Whether the session is no longer usable; independent of [blame].
  final bool sessionRetired;
  final String name;
  final String message;
  final String stage;
  final bool uncertain;
  final String stack;
  final List<String> causes;
  final List<String> cleanupErrors;

  /// Ordered device INFO/TEXT records; classification never replaces them.
  final List<Map<String, String>> messages;
  Map<String, Object?> toMap() => {
    'blame': blame,
    'source': source,
    'sessionRetired': sessionRetired,
    'name': name,
    'message': message,
    'stage': stage,
    'uncertain': uncertain,
    'stack': stack,
    'causes': causes,
    'cleanupErrors': cleanupErrors,
    'messages': messages,
  };
  @override
  String toString() => '$name: $message';
}

abstract interface class FastbootTransport {
  /// Granted devices only on web. Never opens a chooser.
  Future<List<FastbootDevice>> devices();

  /// Requires exactly one fastboot device with this nonempty serial.
  Future<FastbootSession> open(String serial);
}

/// One exclusive connection. Only explicitly retired failures end its lifetime.
abstract interface class FastbootSession {
  String get serial;

  /// Returns the final OKAY payload. Complete FAIL replies are device errors.
  Future<String> command(String command, {bool write = false});
  Future<void> beginDownload(int length);

  /// Bounded pieces, not a whole image. Length must match beginDownload.
  Future<void> writeDownload(Uint8List bytes);
  Future<void> endDownload();
  Future<void> close();
}
