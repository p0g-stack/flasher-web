/// The `package:http` implementation of [CatalogTransport].
///
/// This file is the only catalog code that imports `package:http`; core needs
/// `http` in `pubspec.yaml`. Requests use relative URIs with the default
/// [CatalogClient.base], so the browser keeps them same-origin.
library;

import 'package:http/http.dart' as http;

import 'catalog_client.dart';

final class HttpCatalogTransport implements CatalogTransport {
  HttpCatalogTransport({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<CatalogResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    final response = await _client.get(uri, headers: headers);
    return CatalogResponse(
      statusCode: response.statusCode,
      body: response.bodyBytes,
      headers: response.headers,
    );
  }

  @override
  Future<CatalogResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    required String body,
  }) async {
    final response = await _client.post(uri, headers: headers, body: body);
    return CatalogResponse(
      statusCode: response.statusCode,
      body: response.bodyBytes,
      headers: response.headers,
    );
  }

  void close() => _client.close();
}
