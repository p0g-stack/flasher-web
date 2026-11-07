import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../contracts.dart';
import '../range.dart';
import 'interop.dart';

/// A [ByteSource] over HTTP ranges, using `fetch` in the page or a worker.
///
/// [open] probes `bytes=0-0` (or a `416 bytes */0` for an empty resource) to
/// learn the total length. Every later read requires `206 Partial Content`
/// whose `Content-Range` names exactly the requested bytes and the same total;
/// a server that ignores `Range`, shortens the body or changes the length is
/// an error.
final class HttpRangeSource implements ByteSource {
  HttpRangeSource._(
    this._uri,
    this._headers, {
    required this.length,
    required this.etag,
  });

  /// Probes [uri] and returns a source whose [length] is the remote length.
  ///
  /// A hosted artifact passes its immutable `expectedLength` and
  /// `expectedEtag`; the probe and every later read must match both, so a
  /// server that swaps the artifact cannot feed a flash.
  static Future<HttpRangeSource> open(
    Uri uri, {
    Map<String, String> headers = const {},
    int? expectedLength,
    String? expectedEtag,
  }) async {
    final probe = await _probe(uri, headers);
    if (expectedLength != null && probe.length != expectedLength) {
      throw RangeException(
        'remote length is ${probe.length}, expected $expectedLength for $uri',
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
      length: probe.length,
      etag: expectedEtag,
    );
  }

  final Uri _uri;
  final Map<String, String> _headers;

  /// The pinned strong ETag, when this source must stay immutable.
  final String? etag;
  bool _closed = false;

  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    checkReadRange(offset, length, this.length);
    if (length == 0) return Uint8List(0);
    if (_closed) throw StateError('HTTP range source is closed: $_uri');

    final response = await _send(
      _uri,
      _headers,
      offset,
      length,
      ifRange: etag,
    );
    final contentLength = _contentLength(response);
    try {
      validatePinnedEtag(
        expected: etag,
        actual: response.headers.get('etag'),
        context: 'range $offset-$length of $_uri',
      );
      validateRangeResponse(
        status: response.status,
        contentRange: response.headers.get('content-range'),
        contentLength: contentLength,
        offset: offset,
        length: length,
        expectedTotal: this.length,
      );
    } on Object {
      await _cancel(response);
      rethrow;
    }

    final bytes = (await response.arrayBuffer().toDart).toDart.asUint8List();
    if (bytes.length != length) {
      throw RangeException(
        'body is ${bytes.length} bytes, wanted $length for '
        '$_uri at $offset',
      );
    }
    return bytes;
  }

  /// The browser owns the connection pool; this only stops further reads.
  Future<void> close() async {
    _closed = true;
  }

  static Future<({int length, String? etag})> _probe(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final response = await _send(uri, headers, 0, 1);
    final contentRange = response.headers.get('content-range');
    final etag = response.headers.get('etag');

    if (response.status == 416) {
      await _cancel(response);
      final total = unsatisfiedTotal(contentRange);
      if (total != 0) {
        throw RangeException(
          'server rejected a one-byte probe for a $total-byte resource',
        );
      }
      return (length: 0, etag: etag);
    }

    if (response.status == 200) {
      final total = _contentLength(response);
      await _cancel(response);
      if (total == 0) return (length: 0, etag: etag);
      throw RangeException('server ignored Range for $uri');
    }

    if (response.status != 206) {
      await _cancel(response);
      throw RangeException('probe of $uri returned ${response.status}');
    }

    final range = ContentRange.parse(contentRange);
    if (!range.isSatisfied || range.start != 0 || range.end != 0) {
      await _cancel(response);
      throw RangeException(
        'probe of $uri returned Content-Range ${contentRange ?? 'missing'}',
      );
    }
    if (range.total < 1) {
      await _cancel(response);
      throw RangeException('probe of $uri reported length ${range.total}');
    }
    final contentLength = _contentLength(response);
    if (contentLength != null && contentLength != 1) {
      await _cancel(response);
      throw RangeException(
        'probe of $uri returned $contentLength bytes, wanted 1',
      );
    }
    final bytes = (await response.arrayBuffer().toDart).toDart.asUint8List();
    if (bytes.length != 1) {
      throw RangeException(
        'probe of $uri returned ${bytes.length} bytes, wanted 1',
      );
    }
    return (length: range.total, etag: etag);
  }

  static Future<web.Response> _send(
    Uri uri,
    Map<String, String> headers,
    int offset,
    int length, {
    String? ifRange,
  }) {
    final requestHeaders = web.Headers();
    headers.forEach((name, value) => requestHeaders.set(name, value));
    requestHeaders.set('range', 'bytes=$offset-${offset + length - 1}');
    requestHeaders.set('accept-encoding', 'identity');
    if (ifRange != null) requestHeaders.set('if-range', ifRange);
    return webFetch(
      uri.toString().toJS,
      web.RequestInit(headers: requestHeaders),
    ).toDart;
  }

  static int? _contentLength(web.Response response) {
    final value = response.headers.get('content-length');
    return value == null ? null : int.tryParse(value);
  }

  static Future<void> _cancel(web.Response response) async {
    try {
      final body = response.body;
      if (body != null) await body.cancel().toDart;
    } on Object {
      // The body was already consumed or the stream cannot be cancelled.
    }
  }
}
