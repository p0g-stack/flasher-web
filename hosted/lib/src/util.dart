import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final Random _random = Random.secure();

/// A URL-safe, cryptographically random identifier (128 bits by default).
String randomId({int bytes = 24}) {
  final raw = Uint8List(bytes);
  for (var index = 0; index < raw.length; index++) {
    raw[index] = _random.nextInt(256);
  }
  return base64Url.encode(raw).replaceAll('=', '');
}

final RegExp urlSafeId = RegExp(r'^[A-Za-z0-9_-]{16,128}$');
final RegExp _sha256Hex = RegExp(r'^[a-f0-9]{64}$');

bool isSha256Hex(String value) => _sha256Hex.hasMatch(value);

/// Compares two strings without an early return. Length is not secret.
bool constantTimeEquals(String left, String right) {
  final a = utf8.encode(left);
  final b = utf8.encode(right);
  var difference = a.length == b.length ? 0 : 1;
  final length = a.length < b.length ? a.length : b.length;
  for (var index = 0; index < length; index++) {
    difference |= a[index] ^ b[index];
  }
  return difference == 0;
}

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

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

String canonicalSha256(Object? value) =>
    sha256Hex(utf8.encode(canonicalJson(value)));

Future<String> sha256File(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// A streaming SHA-256 writer.
final class HashWriter {
  final _DigestSink _sink = _DigestSink();
  late final ByteConversionSink _input = sha256.startChunkedConversion(_sink);
  bool _closed = false;

  void add(List<int> bytes) => _input.add(bytes);

  String finish() {
    if (!_closed) {
      _input.close();
      _closed = true;
    }
    return _sink.digest.toString();
  }
}

final class _DigestSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}

/// Joins trusted path segments below [root].
String joinPath(String root, Iterable<String> segments) {
  var path = root;
  for (final segment in segments) {
    if (path.endsWith(Platform.pathSeparator)) {
      path = '$path$segment';
    } else {
      path = '$path${Platform.pathSeparator}$segment';
    }
  }
  return path;
}

/// A path segment that cannot escape its directory.
bool safeSegment(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    value != '..' &&
    !value.contains('/') &&
    !value.contains(r'\') &&
    !value.contains('\u0000');

Future<Uint8List> readBounded(File file, int limit) async {
  final length = await file.length();
  if (length > limit) {
    throw FileSystemException('file exceeds its size limit', file.path);
  }
  return file.readAsBytes();
}

/// Writes [bytes] to a sibling temporary file, flushes it, then renames it.
Future<void> atomicWriteBytes(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  final temporary = File(
    '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}-${randomId(bytes: 6)}',
  );
  try {
    final sink = await temporary.open(mode: FileMode.write);
    try {
      await sink.writeFrom(bytes);
      await sink.flush();
    } finally {
      await sink.close();
    }
    await temporary.rename(target.path);
  } on Object {
    try {
      if (await temporary.exists()) await temporary.delete();
    } on Object {
      // The caller's original error wins.
    }
    rethrow;
  }
}

Future<void> atomicWriteJson(File target, Object? value) =>
    atomicWriteBytes(target, utf8.encode(jsonEncode(value)));

Future<Map<String, dynamic>?> readJsonObject(
  File file, {
  int limit = 2 * 1024 * 1024,
}) async {
  if (!await file.exists()) return null;
  final bytes = await readBounded(file, limit);
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('expected a JSON object in ${file.path}');
  }
  return decoded;
}

String? envString(Map<String, String> environment, String name) {
  final value = environment[name];
  if (value == null || value.trim().isEmpty) return null;
  return value.trim();
}

int envInt(
  Map<String, String> environment,
  String name, {
  required int fallback,
  int? minimum,
  int? maximum,
}) {
  final raw = envString(environment, name);
  final value = raw == null ? fallback : int.tryParse(raw);
  if (value == null) {
    throw FormatException('$name must be an integer');
  }
  if (minimum != null && value < minimum) {
    throw FormatException('$name must be at least $minimum');
  }
  if (maximum != null && value > maximum) {
    throw FormatException('$name must be at most $maximum');
  }
  return value;
}

Duration envDuration(
  Map<String, String> environment,
  String name, {
  required Duration fallback,
  Duration? minimum,
}) {
  final raw = envString(environment, name);
  final value = raw == null
      ? fallback.inSeconds
      : int.tryParse(raw);
  if (value == null || (minimum != null && value < minimum.inSeconds)) {
    throw FormatException('$name must be an integer number of seconds');
  }
  return Duration(seconds: value);
}

String isoUtc(DateTime time) =>
    time.toUtc().toIso8601String().replaceFirst('+00:00', 'Z').replaceFirst(
      RegExp(r'\.000Z$'),
      'Z',
    );

DateTime? parseIsoUtc(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}
