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
final class HttpRangeSource implements ByteSource {
  HttpRangeSource._(
    this._uri,
    this._headers,
    this._client, {
    required this.length,
  });

  /// Probes [uri] and returns a source whose [length] is the remote length.
  ///
  /// [headers] are sent with every request (for example an upstream user
  /// agent).
  static Future<HttpRangeSource> open(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient()..autoUncompress = false;
    try {
      final total = await _probe(client, uri, headers);
      return HttpRangeSource._(
        uri,
        Map<String, String>.unmodifiable(headers),
        client,
        length: total,
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

  @override
  Future<Uint8List> read(int offset, int length) async {
    checkReadRange(offset, length, this.length);
    if (length == 0) return Uint8List(0);
    if (_closed) throw StateError('HTTP range source is closed: $_uri');

    final response = await _send(_client, _uri, _headers, offset, length);
    final contentLength = response.contentLength >= 0
        ? response.contentLength
        : null;
    try {
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

    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != length) {
      throw RangeException(
        'body is ${bytes.length} bytes, wanted $length for '
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

  static Future<int> _probe(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final response = await _send(client, uri, headers, 0, 1);
    final contentRange = response.headers.value('content-range');

    if (response.statusCode == 416) {
      await response.drain<void>();
      final total = unsatisfiedTotal(contentRange);
      if (total != 0) {
        throw RangeException(
          'server rejected a one-byte probe for a $total-byte resource',
        );
      }
      return 0;
    }

    if (response.statusCode == 200) {
      final total = response.contentLength;
      if (total == 0) {
        await response.drain<void>();
        return 0;
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
    return range.total;
  }

  static Future<HttpClientResponse> _send(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
    int offset,
    int length,
  ) async {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    headers.forEach((name, value) => request.headers.set(name, value));
    request.headers.set('range', 'bytes=$offset-${offset + length - 1}');
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
