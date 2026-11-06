/// The same-origin catalog client: `/api/catalog`, `/api/resolve`, the
/// 15-minute feed cache and the NA merge.
///
/// Network access is an injected [CatalogTransport]; [HttpCatalogTransport] in
/// `http_transport.dart` is the `package:http` implementation.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'ota_catalog.dart';

/// One transport response.
final class CatalogResponse {
  const CatalogResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final Uint8List body;

  /// Response headers, matched case-insensitively for `ETag`.
  final Map<String, String> headers;
}

/// The HTTP verbs the catalog client needs. Tests provide a fake; the browser
/// and CLI use `HttpCatalogTransport`.
abstract interface class CatalogTransport {
  Future<CatalogResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  });

  Future<CatalogResponse> post(
    Uri uri, {
    Map<String, String> headers = const {},
    required String body,
  });
}

/// Catalog feeds and the resolver, caching each feed for [ttl].
final class CatalogClient {
  CatalogClient({
    required this.transport,
    Uri? base,
    this.ttl = const Duration(minutes: 15),
    DateTime Function()? clock,
    this.maxResponseBytes = 16 * 1024 * 1024,
  }) : _base = base ?? Uri(),
       _clock = clock ?? DateTime.now;

  /// The HTTP verbs this client uses.
  final CatalogTransport transport;

  /// Origin, or directory ending in `/`, that `/api/...` is relative to. The
  /// default empty URI keeps requests same-origin in a browser.
  final Uri _base;

  /// How long a successful feed read stays fresh. 15 minutes matches upstream.
  final Duration ttl;

  /// Maximum bytes accepted from a catalog or resolve response.
  final int maxResponseBytes;

  final DateTime Function() _clock;
  final Map<bool, _FeedCache> _cache = {};

  /// Load the catalog. With [na], merge the dedicated NA feed and regular
  /// OP 15 NA releases exactly as upstream `load_catalog` does.
  ///
  /// [force] revalidates with `If-None-Match` even while the cache is fresh.
  Future<Map<String, dynamic>> loadCatalog({
    bool force = false,
    bool na = false,
  }) async {
    if (!na) return _loadFeed(na: false, force: force);
    final feeds = <String, Map<String, dynamic>>{};
    final errors = <String, String>{};
    for (final (name, dedicated) in [('na', true), ('regular', false)]) {
      try {
        feeds[name] = await _loadFeed(na: dedicated, force: force);
      } on CatalogException catch (error) {
        errors[name] = error.message;
      }
    }
    if (feeds.isEmpty) {
      throw CatalogException(errors['na']!);
    }
    final data = Map<String, dynamic>.from(
      feeds['na'] ?? const {'api_version': '1'},
    );
    final entries = <String, Map<String, dynamic>>{
      for (final entry in (feeds['na']?['releases'] as List? ?? const []))
        if (entry is Map &&
            usesNaApi(
              entry['device'] as String? ?? '',
              entry['region'] as String? ?? '',
            ))
          entry['id'] as String: Map<String, dynamic>.from(entry),
    };
    for (final entry in (feeds['regular']?['releases'] as List? ?? const [])) {
      if (entry is! Map) continue;
      if (entry['device'] == 'OP 15' && entry['region'] == 'NA') {
        entries.putIfAbsent(
          entry['id'] as String,
          () => Map<String, dynamic>.from(entry),
        );
      }
    }
    data['releases'] = entries.values.toList();
    if (data.containsKey('count')) data['count'] = entries.length;
    if (feeds.values.any((feed) => feed['_stale'] == true)) {
      data['_stale'] = true;
    }
    if (errors.isNotEmpty) data['_feed_errors'] = errors;
    return data;
  }

  /// Find a release by id in the feed this device/region reads.
  Future<Map<String, dynamic>> findRelease(
    String id,
    String device,
    String region,
  ) async {
    final data = await loadCatalog(na: usesNaApi(device, region));
    return findReleaseIn(data, id, device, region);
  }

  /// Resolve a release entry through `POST /api/resolve` and return the fresh
  /// signed URL. Nothing is cached.
  Future<String> resolveLink(Map<String, dynamic> entry) async {
    final response = await _send(
      method: 'POST',
      path: 'api/resolve',
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(entry),
    );
    if (response.statusCode == 304) {
      throw const CatalogException(
        'The OTA service returned an invalid link response.',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.body));
    } on FormatException {
      throw const CatalogException(
        'The OTA service returned an invalid link response.',
      );
    }
    final url = decoded is Map ? decoded['url'] : null;
    if (url is! String || url.isEmpty) {
      throw const CatalogException(
        'The OTA service could not provide a fresh download link. Try another '
        'version or retry later.',
      );
    }
    return url;
  }

  /// Drop the in-memory cache, for example while switching servers in tests.
  void clearCache() => _cache.clear();

  Future<Map<String, dynamic>> _loadFeed({
    required bool na,
    required bool force,
  }) async {
    final cached = _cache[na];
    if (cached != null && !force && _fresh(cached)) return cached.data;
    final headers = <String, String>{
      if (cached != null && cached.etag.isNotEmpty)
        'If-None-Match': cached.etag,
    };
    try {
      final response = await _send(
        method: 'GET',
        path: 'api/catalog',
        query: {'na': na ? '1' : '0'},
        headers: headers,
      );
      if (response.statusCode == 304) {
        if (cached == null) {
          throw const CatalogException(
            'The OTA service returned an empty catalog.',
          );
        }
        final etag = _header(response, headers);
        final data = cached.data;
        _cache[na] = _FeedCache(_clock(), etag, data);
        return data;
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(response.body));
      } on FormatException {
        throw const CatalogException('The OTA service returned invalid JSON.');
      }
      final data = validateCatalog(decoded);
      final etag = _header(response, headers);
      _cache[na] = _FeedCache(_clock(), etag, data);
      return data;
    } on CatalogException {
      if (cached != null) {
        return {...cached.data, '_stale': true};
      }
      rethrow;
    }
  }

  String _header(CatalogResponse response, Map<String, String> headers) {
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == 'etag') return entry.value;
    }
    return headers['If-None-Match'] ?? '';
  }

  bool _fresh(_FeedCache cached) {
    final age = _clock().difference(cached.fetchedAt).inMilliseconds;
    return age >= 0 && age < ttl.inMilliseconds;
  }

  /// A response; a 304 comes back with its headers and an empty body.
  Future<CatalogResponse> _send({
    required String method,
    required String path,
    Map<String, String>? query,
    Map<String, String> headers = const {},
    String? body,
  }) async {
    var uri = _base.resolve(path);
    if (query != null) uri = uri.replace(queryParameters: query);
    final CatalogResponse response;
    try {
      response = method == 'GET'
          ? await transport.get(uri, headers: headers)
          : await transport.post(uri, headers: headers, body: body ?? '');
    } on CatalogException {
      rethrow;
    } catch (error) {
      throw const CatalogException(
        'Could not reach the OTA service. Check your connection and try again.',
      );
    }
    if (response.statusCode == 304) return response;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CatalogException(
        'OTA service returned HTTP ${response.statusCode}. Try again later.',
      );
    }
    if (response.body.length > maxResponseBytes) {
      throw const CatalogException(
        'The OTA service returned an oversized response.',
      );
    }
    return response;
  }
}

final class _FeedCache {
  const _FeedCache(this.fetchedAt, this.etag, this.data);

  final DateTime fetchedAt;
  final String etag;
  final Map<String, dynamic> data;
}
