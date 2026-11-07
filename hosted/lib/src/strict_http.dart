import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'errors.dart';

/// One non-redirect HTTP response whose body fits a small cap.
final class StrictResponse {
  const StrictResponse(this.status, this.headers, this.body);

  final int status;
  final Map<String, String> headers;
  final Uint8List body;

  String? header(String name) => headers[name.toLowerCase()];
}

/// A 206 response whose body is still streaming.
final class StrictRangeResponse {
  StrictRangeResponse(this.response);

  final HttpClientResponse response;

  int get status => response.statusCode;
  String? header(String name) => response.headers.value(name);

  Future<void> discard() async {
    try {
      final socket = await response.detachSocket();
      socket.destroy();
    } on Object {
      // Already consumed or detached.
    }
  }
}

/// A single-origin HTTP client that never follows a redirect.
///
/// The origin is the operator-approved edge worker. Every request is built by
/// the server, never from a caller-supplied URL.
final class StrictHttp {
  StrictHttp(this.origin, {this.connectTimeout = const Duration(seconds: 20)})
    : _client = HttpClient()
        ..autoUncompress = false
        ..connectionTimeout = connectTimeout
        ..idleTimeout = const Duration(seconds: 45)
        ..userAgent = 'flasher_web_hosted/1';

  final Uri origin;
  final Duration connectTimeout;
  final HttpClient _client;
  bool _closed = false;

  Uri resolve(String path, [Map<String, String>? query]) {
    final base = origin.path.endsWith('/')
        ? origin
        : origin.replace(path: '${origin.path}/');
    final uri = base.resolve(path);
    if (query != null) return uri.replace(queryParameters: query);
    return uri;
  }

  Future<StrictResponse> bytes(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
    int maxBytes = 16 * 1024 * 1024,
  }) async {
    _checkOrigin(uri);
    final request = await _open(method, uri, headers, body);
    final response = await request.close().timeout(connectTimeout);
    await _rejectRedirect(response);
    final chunks = <Uint8List>[];
    var length = 0;
    var oversized = false;
    await for (final chunk in response) {
      length += chunk.length;
      if (length > maxBytes) {
        oversized = true;
        break;
      }
      chunks.add(Uint8List.fromList(chunk));
    }
    if (oversized) {
      throw const HostedInternalException(
        'upstream_oversized',
        'The approved service returned an oversized response.',
      );
    }
    final responseBody = Uint8List(length);
    var offset = 0;
    for (final chunk in chunks) {
      responseBody.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return StrictResponse(
      response.statusCode,
      {
        for (final name in _forwardedResponseHeaders)
          if (response.headers.value(name) != null)
            name.toLowerCase(): response.headers.value(name)!,
      },
      responseBody,
    );
  }

  /// Sends one byte range and returns the still-open 206 response.
  Future<StrictRangeResponse> range(
    Uri uri, {
    required int start,
    required int end,
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    _checkOrigin(uri);
    if (start < 0 || end < start) {
      throw const HostedInternalException('range_invalid', 'Invalid range.');
    }
    if (end - start + 1 > maxBytes) {
      throw const HostedInternalException(
        'range_too_large',
        'A single byte range is too large.',
      );
    }
    final request = await _open(
      'GET',
      uri,
      const {'Accept-Encoding': 'identity'},
      null,
    );
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    final response = await request.close().timeout(connectTimeout);
    await _rejectRedirect(response);
    if (response.statusCode != HttpStatus.partialContent) {
      await _discard(response);
      throw HostedUpstreamStatus(response.statusCode);
    }
    return StrictRangeResponse(response);
  }

  Future<HttpClientRequest> _open(
    String method,
    Uri uri,
    Map<String, String> headers,
    List<int>? body,
  ) async {
    if (_closed) throw StateError('HTTP client is closed');
    final request = await _client.openUrl(method, uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.contentLength = body.length;
      request.add(body);
    }
    return request;
  }

  void _checkOrigin(Uri uri) {
    if (uri.scheme != origin.scheme ||
        uri.host != origin.host ||
        uri.port != origin.port ||
        uri.userInfo.isNotEmpty) {
      throw const HostedInternalException(
        'upstream_origin_refused',
        'An internal request left the approved origin.',
      );
    }
  }

  static Future<void> _rejectRedirect(HttpClientResponse response) async {
    final status = response.statusCode;
    if (status == 301 ||
        status == 302 ||
        status == 303 ||
        status == 307 ||
        status == 308) {
      await _discard(response);
      throw const HostedInternalException(
        'upstream_redirect_refused',
        'The approved service returned a redirect.',
      );
    }
  }

  static Future<void> _discard(HttpClientResponse response) async {
    try {
      final socket = await response.detachSocket();
      socket.destroy();
    } on Object {
      // Already consumed or detached.
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}

final class HostedUpstreamStatus implements Exception {
  const HostedUpstreamStatus(this.status);

  final int status;

  @override
  String toString() => 'upstream status $status';
}

const _forwardedResponseHeaders = [
  'content-type',
  'content-length',
  'content-range',
  'etag',
  'last-modified',
  'accept-ranges',
];
