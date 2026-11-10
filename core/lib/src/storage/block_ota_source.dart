import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../pipeline/errors.dart' show CancelledException;
import 'contracts.dart';

/// A pinned catalog release, read directly from Garage in aligned 8 MiB blocks.
/// Both the VM and browser use this implementation; only misses use the Worker.
final class BlockOtaSource implements StreamingByteSource {
  BlockOtaSource._(this._client, this._apiBase, this._bucketBase, this.id,
      this.identity, this.etag, this.length);

  static const blockSize = 8 << 20;
  static const _window = 8;
  final http.Client _client;
  final Uri _apiBase;
  final Uri? _bucketBase;
  final String id;
  final String identity;
  final String etag;
  @override
  final int length;
  final _closed = Completer<void>();
  final _cache = <int, Uint8List>{};
  final _pending = <int, Future<Uint8List>>{};
  final _pins = <int, int>{};
  final _waiters = Queue<Completer<void>>();
  int _active = 0;

  /// When [bucketBase] is absent, discover it from the same-origin Worker.
  /// A null public base means Worker-only reads, not another CDN reader.
  static Future<BlockOtaSource> open({
    required String id,
    String apiBase = '',
    String? bucketBase,
    int? expectedLength,
    http.Client? client,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'invalid catalog release id');
    }
    final transport = client ?? http.Client();
    final api = _base(apiBase);
    try {
      if (bucketBase == null) {
        final config = await _get(transport, api.resolve('api/block-config'), 4096);
        if (config.statusCode != 200) throw _failure(config, 'The OTA block cache is unavailable.');
        final value = jsonDecode(utf8.decode(config.bodyBytes)) as Map<String, dynamic>;
        final publicBase = value['publicBase'];
        if (publicBase != null && publicBase is! String) throw const FormatException('Invalid OTA cache configuration.');
        bucketBase = publicBase as String?;
      }
      final bucket = bucketBase == null || bucketBase.isEmpty ? null : _base(bucketBase);
      http.Response? manifest;
      if (bucket != null) {
        try {
          manifest = await _get(transport, bucket.resolve('ota/v1/releases/$id/manifest.json'), 4096);
        } on Exception {
          // A public-endpoint network/CORS outage may leave the S3 API healthy.
        }
      }
      if (manifest == null || manifest.statusCode == 404) {
        manifest = await _get(transport, api.resolve('api/manifest').replace(queryParameters: {'id': id}), 4096);
      }
      if (manifest.statusCode != 200) throw _failure(manifest, 'Could not open the OTA block manifest.');
      final data = jsonDecode(utf8.decode(manifest.bodyBytes)) as Map<String, dynamic>;
      final etag = data['etag'];
      final length = data['length'];
      final identity = data['identity'];
      if (data['id'] != id || etag is! String || !RegExp(r'^"[^"\x00-\x20\x7f]+"$').hasMatch(etag) ||
          length is! int || length <= 0 || length > 9007199254740991 || data['blockSize'] != blockSize ||
          identity is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(identity) ||
          data['created'] is! String || DateTime.tryParse(data['created'] as String) == null ||
          sha256.convert(utf8.encode(jsonEncode([id, etag, length]))).toString() != identity) {
        throw const FormatException('The OTA block manifest identity is invalid.');
      }
      if (expectedLength != null && expectedLength != length) throw StateError('The OTA length differs from the catalog.');
      return BlockOtaSource._(transport, api, bucket, id, identity, etag, length);
    } on Object {
      transport.close();
      rethrow;
    }
  }

  /// Opens the catalog release [entry]: its `id` and, when present, the size
  /// the catalog declares, which must equal the manifest length.
  static Future<BlockOtaSource> openCatalog(
    Map<String, dynamic> entry, {
    String apiBase = '',
    String? bucketBase,
    http.Client? client,
  }) {
    final id = entry['id'];
    if (id is! String) {
      throw ArgumentError('A catalog release id is required.');
    }
    final size = entry['size'];
    return open(
      id: id,
      apiBase: apiBase,
      bucketBase: bucketBase,
      expectedLength: size is int && size > 0 ? size : null,
      client: client,
    );
  }

  /// An empty base is the origin root, never the caller's directory: a Web
  /// Worker resolves relative URLs against its own script (`/workers/…`).
  static Uri _base(String value) => Uri.parse(value.isEmpty ? '/' : value.endsWith('/') ? value : '$value/');

  /// Bound the response before buffering it, including error responses. Never
  /// accidentally turn an ignored Range / wrong endpoint into a whole OTA GET.
  static Future<http.Response> _get(http.Client client, Uri uri, int limit, {Future<void>? abort}) async {
    final finished = Completer<void>();
    final request = http.AbortableRequest(
      'GET', uri,
      abortTrigger: abort == null ? finished.future : Future.any([abort, finished.future]),
    );
    try {
      // Bound headers AND the response body, and abort transport on timeout.
      return await _receive(client, request, limit).timeout(const Duration(seconds: 10));
    } finally {
      finished.complete();
    }
  }

  static Future<http.Response> _receive(http.Client client, http.BaseRequest request, int limit) async {
    final response = await client.send(request);
    final expected = response.contentLength;
    final reader = StreamIterator(response.stream);
    if (response.statusCode != 200) limit = 4096;
    final builder = BytesBuilder(copy: false);
    var size = 0;
    try {
      if (expected != null && expected > limit) {
        if (response.statusCode != 200) return http.Response.bytes(const [], response.statusCode);
        throw StateError('The OTA cache response exceeds its size limit.');
      }
      while (await reader.moveNext()) {
        size += reader.current.length;
        if (size > limit) {
          if (response.statusCode != 200) return http.Response.bytes(const [], response.statusCode);
          throw StateError('The OTA cache response exceeds its size limit.');
        }
        builder.add(reader.current);
      }
      if (response.statusCode == 200 && expected != null && expected != size) throw StateError('The OTA cache response is truncated.');
    } finally {
      await reader.cancel();
    }
    return http.Response.bytes(builder.takeBytes(), response.statusCode, headers: response.headers);
  }

  static StateError _failure(http.Response response, String fallback) {
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is Map && value['error'] is String) {
        return StateError('${value['error']} (HTTP ${response.statusCode}).');
      }
    } on FormatException {
      // Non-JSON bucket errors are not useful UI text.
    }
    return StateError('$fallback (HTTP ${response.statusCode}).');
  }

  Future<http.Response> _workerBlock(int n, int expected) async {
    final uri = _apiBase.resolve('api/block').replace(
      queryParameters: {'id': id, 'v': identity, 'n': '$n'},
    );
    for (var attempt = 0; ; attempt++) {
      _checkOpen();
      try {
        final response = await _get(_client, uri, expected, abort: _closed.future);
        final transient = response.statusCode == 408 ||
            response.statusCode == 429 || response.statusCode >= 500;
        if (!transient || attempt == 2) return response;
      } on http.ClientException {
        if (attempt == 2) rethrow;
      } on TimeoutException {
        if (attempt == 2) rethrow;
      }
      // These are read-only, generation-pinned GETs, never device writes.
      await Future<void>.delayed(Duration(milliseconds: 250 << attempt));
    }
  }

  void _checkOpen() {
    if (_closed.isCompleted) throw StateError('The OTA block source is closed.');
  }

  Future<Uint8List> _block(int n) {
    _checkOpen();
    final cached = _cache.remove(n);
    if (cached != null) {
      _cache[n] = cached;
      return Future.value(cached);
    }
    return _pending.putIfAbsent(n, () {
      final future = _loadBlock(n);
      // Observe failures immediately, including prefetched requests whose turn
      // has not arrived, without hiding them from the actual reader.
      unawaited(future.then<void>((_) => _pending.remove(n), onError: (Object _, StackTrace _) { _pending.remove(n); }));
      return future;
    });
  }

  Future<Uint8List> _loadBlock(int n) async {
    // A prefetched result stays pinned until its stream consumes it. Evicting
    // it earlier would leave a hidden copy in that stream's Future queue.
    while (_cache.length + _active >= _window) {
      int? victim;
      for (final key in _cache.keys) {
        if (!_pins.containsKey(key)) {
          victim = key;
          break;
        }
      }
      if (victim != null) {
        _cache.remove(victim);
        continue;
      }
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
      _checkOpen();
    }
    _active++;
    try {
      final expected = math.min(blockSize, length - n * blockSize);
      http.Response? response;
      if (_bucketBase != null) {
        try {
          response = await _get(_client, _bucketBase.resolve('ota/v1/releases/$id/$identity/$n'), expected, abort: _closed.future);
        } on Exception {
          _checkOpen();
        }
      }
      if (response == null || response.statusCode == 404) {
        response = await _workerBlock(n, expected);
      }
      if (response.statusCode != 200) throw _failure(response, 'Could not read OTA block $n.');
      if (response.headers['x-amz-meta-ota-etag'] != etag) throw StateError('The OTA block ETag differs from its manifest.');
      if (response.bodyBytes.length != expected) throw StateError('OTA block $n has the wrong length.');
      _checkOpen();
      final bytes = response.bodyBytes;
      _cache[n] = bytes;
      return bytes;
    } finally {
      _active--;
      if (_waiters.isNotEmpty) _waiters.removeFirst().complete();
    }
  }

  void _unpin(int n) {
    final count = _pins[n]!;
    if (count == 1) {
      _pins.remove(n);
      if (_waiters.isNotEmpty) _waiters.removeFirst().complete();
    } else {
      _pins[n] = count - 1;
    }
  }

  @override
  Future<Uint8List> read(int offset, int length) => readCancellable(offset, length, null);

  @override
  Future<Uint8List> readCancellable(int offset, int length, Future<void>? cancelled) async {
    checkReadRange(offset, length, this.length);
    final result = Uint8List(length);
    var written = 0;
    await for (final bytes in streamRange(offset, length, cancelled: cancelled)) {
      result.setRange(written, written + bytes.length, bytes);
      written += bytes.length;
    }
    return result;
  }

  @override
  Stream<Uint8List> streamRange(int offset, int length, {Future<void>? cancelled}) async* {
    checkReadRange(offset, length, this.length);
    _checkOpen();
    if (length == 0) return;
    var aborted = false;
    unawaited(cancelled?.then((_) { aborted = true; }));
    final end = offset + length;
    var next = offset ~/ blockSize;
    final last = (end - 1) ~/ blockSize;
    final window = Queue<({int n, Future<Uint8List> bytes})>();
    void refill() {
      while (next <= last && window.length < _window) {
        final n = next++;
        _pins[n] = (_pins[n] ?? 0) + 1;
        window.add((n: n, bytes: _block(n)));
      }
    }
    try {
      refill();
      for (var n = offset ~/ blockSize; n <= last; n++) {
        if (aborted) throw const CancelledException('The OTA read was cancelled.');
        final request = window.removeFirst();
        try {
          final bytes = await request.bytes;
          _checkOpen();
          if (aborted) throw const CancelledException('The OTA read was cancelled.');
          final start = math.max(offset - n * blockSize, 0);
          final stop = math.min(end - n * blockSize, bytes.length);
          yield Uint8List.sublistView(bytes, start, stop);
        } finally {
          _unpin(request.n);
        }
        refill();
      }
    } finally {
      for (final request in window) {
        _unpin(request.n);
      }
    }
  }

  Future<void> close() async {
    if (_closed.isCompleted) return;
    _closed.complete();
    _client.close();
    _cache.clear();
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    }
  }
}

/// Bytes per ranged read when a catalog OTA is copied out of the block cache.
const int blockReadChunkBytes = 8 << 20;

/// Ranges kept in flight ahead of the consumer: 8 × 8 MiB = 64 MiB resident.
const int blockReadWindow = 8;

/// Reads [source] from byte zero in order, keeping at most [window] ranges of
/// [chunkBytes] in flight.
///
/// The window bounds memory: at most `window * chunkBytes` bytes wait ahead of
/// the consumer, which is also why [chunkBytes] and [window] may not describe
/// more than 64 MiB together. Bytes reach the consumer in file order whatever
/// order the reads complete in, and a failed range fails the stream at its
/// turn instead of after the bytes that follow it. A copy has no resume: a
/// reopened one starts at zero, which is cheap while the blocks stay cached.
Stream<Uint8List> orderedReads(
  ByteSource source, {
  int chunkBytes = blockReadChunkBytes,
  int window = blockReadWindow,
}) async* {
  if (chunkBytes <= 0 ||
      window < 1 ||
      window > blockReadWindow ||
      chunkBytes > (64 << 20) ~/ window) {
    throw ArgumentError('invalid OTA read window');
  }
  final pending =
      <Future<({Uint8List? bytes, Object? error, StackTrace? stack})>>[];
  var offset = 0;
  void fill() {
    while (pending.length < window && offset < source.length) {
      final length = math.min(chunkBytes, source.length - offset);
      // A later range can fail before the ordered consumer reaches it, so the
      // error is captured here rather than left unobserved.
      pending.add(
        source.read(offset, length).then<
          ({Uint8List? bytes, Object? error, StackTrace? stack})
        >(
          (bytes) => (bytes: bytes, error: null, stack: null),
          onError: (Object error, StackTrace stack) =>
              (bytes: null, error: error, stack: stack),
        ),
      );
      offset += length;
    }
  }

  fill();
  while (pending.isNotEmpty) {
    final result = await pending.removeAt(0);
    if (result.error case final Object error) {
      Error.throwWithStackTrace(error, result.stack!);
    }
    yield result.bytes!;
    fill();
  }
}
