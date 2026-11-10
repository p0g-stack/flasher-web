import 'dart:io';
import 'dart:typed_data';

import '../contracts.dart';
import '../range.dart';

/// A [ByteSource] over HTTP ranges, using `dart:io`'s [HttpClient].
///
/// [open] probes `bytes=0-0` (or a `416 bytes */0` for an empty resource) to
/// learn the total length. Every later read requires `206 Partial Content`
/// whose `Content-Range` names exactly the requested bytes and the same total;
/// a server that ignores `Range`, shortens the body or changes the length is
/// an error.
final class HttpRangeSource implements CancellableByteSource {
  HttpRangeSource._(
    this._uri,
    this._headers,
    this._client, {
    required this.length,
    this.observedEtag,
  });

  /// Probes [uri] and returns a source whose [length] is the remote length.
  ///
  /// [headers] are sent with every request (for example an upstream user
  /// agent).
  static Future<HttpRangeSource> open(
    Uri uri, {
    Map<String, String> headers = const {},
    int? expectedLength,
    String? expectedEtag,
  }) async {
    final client = HttpClient()
      ..autoUncompress = false
      ..maxConnectionsPerHost = 8;
    try {
      final probe = await _probe(client, uri, headers);
      if (expectedLength != null && probe.total != expectedLength) {
        throw RangeException(
          'remote length is ${probe.total}, expected $expectedLength',
        );
      }
      validatePinnedEtag(
        expected: expectedEtag,
        actual: probe.etag,
        context: 'probe of $uri',
      );
      return HttpRangeSource._(
        uri,
        Map<String, String>.unmodifiable(headers),
        client,
        length: probe.total,
        observedEtag: expectedEtag ?? strongEtag(probe.etag),
      );
    } on Object {
      client.close(force: true);
      rethrow;
    }
  }

  final Uri _uri;
  final Map<String, String> _headers;
  final HttpClient _client;
  bool _closed = false;

  @override
  final int length;

  /// The ETag the probe saw, or null when the server sent none. A download
  /// records it to refuse a server that swaps the same URL later.
  final String? observedEtag;

  @override
  Future<Uint8List> read(int offset, int length) =>
      readCancellable(offset, length, null);

  @override
  Future<Uint8List> readCancellable(
    int offset,
    int length,
    Future<void>? cancelled,
  ) async {
    checkReadRange(offset, length, this.length);
    if (length == 0) return Uint8List(0);
    if (_closed) throw StateError('HTTP range source is closed: $_uri');

    final response = await _send(
      _client,
      _uri,
      _headers,
      offset,
      length,
      etag: observedEtag,
      cancelled: cancelled,
    );
    final contentLength = response.contentLength >= 0
        ? response.contentLength
        : null;
    try {
      validatePinnedEtag(
        expected: observedEtag,
        actual: response.headers.value('etag'),
        context: 'range at $offset of $_uri',
      );
      validateRangeResponse(
        status: response.statusCode,
        contentRange: response.headers.value('content-range'),
        contentLength: contentLength,
        offset: offset,
        length: length,
        expectedTotal: this.length,
      );
    } on Object {
      await _discard(response);
      rethrow;
    }

    final bytes = Uint8List(length);
    var received = 0;
    await for (final chunk in response) {
      if (chunk.length > length - received) {
        await _discard(response);
        throw const RangeException('range body exceeds requested length');
      }
      bytes.setRange(received, received + chunk.length, chunk);
      received += chunk.length;
    }
    if (received != length) {
      throw RangeException(
        'body is $received bytes, wanted $length for '
        '$_uri at $offset',
      );
    }
    return bytes;
  }

  /// Closes the client this source created.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }

  static Future<({int total, String? etag})> _probe(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final response = await _send(client, uri, headers, 0, 1);
    final contentRange = response.headers.value('content-range');
    final etag = response.headers.value('etag');

    if (response.statusCode == 416) {
      await response.drain<void>();
      final total = unsatisfiedTotal(contentRange);
      if (total != 0) {
        throw RangeException(
          'server rejected a one-byte probe for a $total-byte resource',
        );
      }
      return (total: 0, etag: etag);
    }

    if (response.statusCode == 200) {
      final total = response.contentLength;
      if (total == 0) {
        await response.drain<void>();
        return (total: 0, etag: etag);
      }
      await _discard(response);
      throw RangeException('server ignored Range for $uri');
    }

    if (response.statusCode != 206) {
      await _discard(response);
      throw RangeException('probe of $uri returned ${response.statusCode}');
    }

    final range = ContentRange.parse(contentRange);
    if (!range.isSatisfied || range.start != 0 || range.end != 0) {
      await _discard(response);
      throw RangeException(
        'probe of $uri returned Content-Range ${contentRange ?? 'missing'}',
      );
    }
    if (range.total < 1) {
      await _discard(response);
      throw RangeException('probe of $uri reported length ${range.total}');
    }
    final contentLength = response.contentLength >= 0
        ? response.contentLength
        : null;
    if (contentLength != null && contentLength != 1) {
      await _discard(response);
      throw RangeException(
        'probe of $uri returned $contentLength bytes, wanted 1',
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    if (builder.length != 1) {
      throw RangeException(
        'probe of $uri returned ${builder.length} bytes, wanted 1',
      );
    }
    return (total: range.total, etag: etag);
  }

  static Future<HttpClientResponse> _send(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
    int offset,
    int length, {
    String? etag,
    Future<void>? cancelled,
  }) async {
    final request = await client.getUrl(uri);
    cancelled?.then((_) {
      request.abort(const RangeException('range read cancelled'));
    });
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    headers.forEach((name, value) => request.headers.set(name, value));
    request.headers.set('range', 'bytes=$offset-${offset + length - 1}');
    if (etag != null) request.headers.set('if-range', etag);
    return request.close();
  }

  /// Detaches and destroys an unread response, so a server that ignored
  /// `Range` cannot make us buffer a whole file just to reject it.
  static Future<void> _discard(HttpClientResponse response) async {
    try {
      final socket = await response.detachSocket();
      socket.destroy();
    } on Object {
      // Already consumed or detached; nothing left to release.
    }
  }
}
