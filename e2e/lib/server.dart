/// A static server for the define-built app plus the fixture's upstream,
/// OTA and bloat files.
library;

import 'dart:async';
import 'dart:io';

/// Serves `app/build/web`, with `/upstream/` and `/e2e/` from the fixture.
final class E2eServer {
  E2eServer._(this._server, this.webRoot, this.upstreamDir, this.otaPath,
      this.bloatDir);

  final HttpServer _server;
  final String webRoot;
  final String upstreamDir;
  final String otaPath;
  final String bloatDir;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<E2eServer> start({
    required String webRoot,
    required String upstreamDir,
    required String otaPath,
    required String bloatDir,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = E2eServer._(server, webRoot, upstreamDir, otaPath, bloatDir);
    server.listen(result._handle);
    return result;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      var path = request.uri.path;
      File? file;
      if (path.startsWith('/upstream/')) {
        file = File('$upstreamDir/${path.substring('/upstream/'.length)}');
      } else if (path == '/e2e/ota.zip') {
        file = File(otaPath);
      } else if (path.startsWith('/e2e/bloat/')) {
        file = File('$bloatDir/${path.substring('/e2e/bloat/'.length)}');
      } else {
        if (path == '/' || path.isEmpty) path = '/index.html';
        final candidate = File('$webRoot$path');
        file = await candidate.exists() ? candidate : File('$webRoot/index.html');
      }
      if (!await file.exists()) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"error":"not found"}');
        await request.response.close();
        return;
      }
      request.response.headers.contentType = _type(file.path);
      request.response.headers.set('cache-control', 'no-store');
      await request.response.addStream(file.openRead());
      await request.response.close();
    } on Object catch (error) {
      try {
        request.response.statusCode = 500;
        request.response.write('$error');
        await request.response.close();
      } on Object {
        // The client went away.
      }
    }
  }

  Future<void> stop() => _server.close(force: true);
}

ContentType _type(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.js')) return ContentType('application', 'javascript');
  if (lower.endsWith('.mjs')) return ContentType('application', 'javascript');
  if (lower.endsWith('.wasm')) return ContentType('application', 'wasm');
  if (lower.endsWith('.json')) return ContentType.json;
  if (lower.endsWith('.html')) return ContentType.html;
  if (lower.endsWith('.css')) return ContentType('text', 'css');
  if (lower.endsWith('.png')) return ContentType('image', 'png');
  if (lower.endsWith('.svg')) return ContentType('image', 'svg+xml');
  if (lower.endsWith('.ttf')) return ContentType('font', 'ttf');
  if (lower.endsWith('.otf')) return ContentType('font', 'otf');
  if (lower.endsWith('.woff2')) return ContentType('font', 'woff2');
  if (lower.endsWith('.md')) return ContentType('text', 'markdown');
  return ContentType.binary;
}
