import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'range_http.dart';
import 'util.dart';

/// A loopback-only catalog/resolve/range shim.
///
/// The build pipeline would otherwise follow a fresh signed OTA link itself.
/// Giving it a private origin keeps every external read in this server, where
/// the origin allowlist and redirect refusal live. Only pre-registered local
/// files can be resolved.
final class LoopbackOtaHost {
  LoopbackOtaHost._(this._server, this._nonce, this.catalogData);

  final HttpServer _server;
  final String _nonce;
  final Map<String, dynamic> catalogData;
  final Map<String, ({File file, int length})> _files = {};
  final Map<String, String> _byCatalogId = {};

  static Future<LoopbackOtaHost> start(
    Map<String, dynamic> catalogData,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = LoopbackOtaHost._(server, randomId(bytes: 18), catalogData);
    server.listen(host._handle, onError: (Object _) {});
    return host;
  }

  Uri get baseUri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _server.port,
    path: '/$_nonce/',
  );

  /// Registers the bytes the pipeline may resolve for [catalogId].
  void register(String catalogId, File file) {
    final token = randomId(bytes: 18);
    final length = file.lengthSync();
    _files[token] = (file: file, length: length);
    _byCatalogId[catalogId] = token;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final prefix = '/$_nonce/';
      if (!request.uri.path.startsWith(prefix)) {
        await _notFound(response);
        return;
      }
      final path = request.uri.path.substring(prefix.length);
      if (path == 'api/catalog') {
        if (request.method != 'GET') {
          await _method(response, 'GET');
          return;
        }
        final body = utf8.encode(jsonEncode(catalogData));
        response.headers.contentType = ContentType.json;
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.contentLength = body.length;
        response.add(body);
        await response.close();
        return;
      }
      if (path == 'api/resolve') {
        if (request.method != 'POST') {
          await _method(response, 'POST');
          return;
        }
        final chunks = <List<int>>[];
        var length = 0;
        await for (final chunk in request) {
          length += chunk.length;
          if (length > 1024 * 1024) {
            await _json(response, 413, {'error': 'request too large'});
            return;
          }
          chunks.add(chunk);
        }
        final bytes = Uint8List(length);
        var offset = 0;
        for (final chunk in chunks) {
          bytes.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        Object? decoded;
        try {
          decoded = jsonDecode(utf8.decode(bytes));
        } on Object {
          await _json(response, 400, {'error': 'invalid request'});
          return;
        }
        final id = decoded is Map ? decoded['id'] : null;
        final token = id is String ? _byCatalogId[id] : null;
        if (token == null) {
          await _json(response, 404, {'error': 'release is not local'});
          return;
        }
        await _json(response, 200, {
          'url': baseUri.resolve('ota/$token').toString(),
        });
        return;
      }
      if (path.startsWith('ota/')) {
        final token = path.substring(4);
        final entry = _files[token];
        if (entry == null) {
          await _notFound(response);
          return;
        }
        if (request.method != 'GET' && request.method != 'HEAD') {
          await _method(response, 'GET, HEAD');
          return;
        }
        await _serve(entry.file, entry.length, request, response);
        return;
      }
      await _notFound(response);
    } on Object {
      try {
        await _json(response, 500, {'error': 'internal error'});
      } on Object {
        // The socket may be gone.
      }
    }
  }

  Future<void> _serve(
    File file,
    int length,
    HttpRequest request,
    HttpResponse response,
  ) async {
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader == null) {
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.binary;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.contentLength = length;
      if (request.method != 'HEAD') {
        await response.addStream(file.openRead());
      }
      await response.close();
      return;
    }
    final ByteRange range;
    try {
      range = parseSingleRange(rangeHeader, length);
    } on RangeNotSatisfiable {
      await sendRangeNotSatisfiable(response, length);
      return;
    }
    response.statusCode = HttpStatus.partialContent;
    response.headers.contentType = ContentType.binary;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes ${range.start}-${range.end}/$length',
    );
    response.contentLength = range.length;
    if (request.method != 'HEAD') {
      await response.addStream(file.openRead(range.start, range.end + 1));
    }
    await response.close();
  }

  static Future<void> _json(
    HttpResponse response,
    int status,
    Object body,
  ) async {
    final bytes = utf8.encode(jsonEncode(body));
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  static Future<void> _notFound(HttpResponse response) =>
      _json(response, 404, {'error': 'not found'});

  static Future<void> _method(HttpResponse response, String allow) async {
    response.statusCode = HttpStatus.methodNotAllowed;
    response.headers.set('allow', allow);
    await _json(response, HttpStatus.methodNotAllowed, {
      'error': 'method not allowed',
    });
  }
}
