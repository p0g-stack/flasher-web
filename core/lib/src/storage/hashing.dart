/// SHA-256 helpers shared by the bloat store and the OTA cache.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A streaming SHA-256, so multi-gigabyte images never sit in memory at once.
///
/// [hex] closes the stream; a second call returns the same digest. This is the
/// Dart-side hasher over bytes read from a workspace or a range; the Rust
/// `Sha256Hasher` in `rust/api/payload.dart` hashes decoded payload images.
final class StreamingSha256 {
  final _DigestSink _sink = _DigestSink();
  late final ByteConversionSink _input = sha256.startChunkedConversion(_sink);
  bool _closed = false;

  void add(List<int> bytes) => _input.add(bytes);

  String get hex {
    if (!_closed) {
      _input.close();
      _closed = true;
    }
    return _sink.digest.toString();
  }
}

/// Lowercase hex SHA-256 of [bytes].
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// SHA-256 of [value] encoded as canonical JSON: object keys sorted, so two
/// equivalent maps have the same digest.
String canonicalSha256(Object? value) =>
    sha256Hex(utf8.encode(canonicalJson(value)));

/// Canonical JSON with object keys sorted, so equivalent maps hash equally.
String canonicalJson(Object? value) => jsonEncode(_canonical(value));

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = [for (final key in value.keys) '$key']..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonical(value[key]),
    };
  }
  if (value is List) return [for (final item in value) _canonical(item)];
  return value;
}

final class _DigestSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
