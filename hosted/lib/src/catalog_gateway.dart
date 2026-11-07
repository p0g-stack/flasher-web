import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flasher_web_core/flasher_web_core.dart';

import 'config.dart';
import 'errors.dart';
import 'strict_http.dart';
import 'util.dart';

/// One catalog release, with the identity that makes it immutable.
final class CatalogRelease {
  const CatalogRelease({
    required this.role,
    required this.entry,
    required this.entryDigest,
    required this.feedSha256,
    required this.stale,
  });

  /// `ota` or `base`.
  final String role;
  final Map<String, dynamic> entry;
  final String entryDigest;
  final String feedSha256;
  final bool stale;

  String get id => '${entry['id']}';
  String get device => '${entry['device']}';
  String get region => '${entry['region']}';
  String get version => '${entry['version']}';
  int? get size => entry['size'] is int ? entry['size'] as int : null;

  Map<String, Object?> identity() => {
    'id': id,
    'device': device,
    'region': region,
    'version': version,
    'entryDigest': entryDigest,
    'size': size,
  };
}

/// Reads the approved catalog through the edge worker, with a bounded disk
/// cache so a transient edge failure does not lose the pin metadata.
final class CatalogGateway {
  CatalogGateway({
    required this.config,
    required this.http,
    required this.cacheDir,
  });

  final HostedConfig config;
  final StrictHttp http;
  final Directory cacheDir;
  final Map<bool, _Feed> _memory = {};
  final Map<bool, Future<_Feed>> _loading = {};

  static const int _feedLimit = 16 * 1024 * 1024;

  Future<_Feed> _feedCached({required bool na, bool force = false}) {
    final cached = _memory[na];
    if (!force && cached != null && _fresh(cached)) return Future.value(cached);
    final inFlight = _loading[na];
    if (inFlight != null) return inFlight;
    final future = _loadFeed(na, force: force);
    _loading[na] = future;
    return future.whenComplete(() => _loading.remove(na));
  }

  Future<Map<String, dynamic>> loadCatalog({required bool na}) async {
    if (!na) {
      final feed = await _feedCached(na: false);
      return _decorate(stale: feed.stale, errors: {}, data: feed.data);
    }
    final feeds = <String, _Feed>{};
    final errors = <String, String>{};
    for (final (name, dedicated) in [('na', true), ('regular', false)]) {
      try {
        feeds[name] = await _feedCached(na: dedicated);
      } on Object catch (error) {
        errors[name] = error.toString();
      }
    }
    if (feeds.isEmpty) {
      throw HostedException(
        'catalog_unavailable',
        errors['na'] ?? errors['regular'] ?? 'The catalog is unavailable.',
        status: 503,
      );
    }
    final data = Map<String, dynamic>.from(
      feeds['na']?.data ?? const {'api_version': '1'},
    );
    final entries = <String, Map<String, dynamic>>{
      for (final entry in (feeds['na']?.data['releases'] as List? ?? const []))
        if (entry is Map &&
            usesNaApi(
              entry['device'] as String? ?? '',
              entry['region'] as String? ?? '',
            ))
          entry['id'] as String: Map<String, dynamic>.from(entry),
    };
    for (final entry in (feeds['regular']?.data['releases'] as List? ?? const [])) {
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
    final stale = feeds.values.any((feed) => feed.stale);
    return _decorate(
      stale: stale,
      errors: errors,
      data: data,
    );
  }

  Future<CatalogRelease> release({
    required String role,
    required ({String device, String region}) target,
    required String id,
  }) async {
    final na = usesNaApi(target.device, target.region);
    final data = await loadCatalog(na: na);
    final Map<String, dynamic> entry;
    try {
      entry = findReleaseIn(data, id, target.device, target.region);
    } on CatalogException catch (error) {
      throw HostedException('catalog_release_missing', error.message, status: 404);
    }
    return CatalogRelease(
      role: role,
      entry: entry,
      entryDigest: releaseDigest(entry),
      feedSha256: canonicalSha256(data),
      stale: data['_stale'] == true,
    );
  }

  /// Resolves one already-validated catalog entry to a fresh signed link.
  Future<Uri> resolve(Map<String, dynamic> entry) async {
    final StrictResponse response;
    try {
      response = await http.bytes(
        'POST',
        http.resolve('api/resolve'),
        body: utf8.encode(jsonEncode(entry)),
        maxBytes: 1024 * 1024,
      );
    } on TimeoutException {
      throw const HostedException(
        'ota_resolve_unavailable',
        'The OTA service did not answer in time.',
        status: 503,
      );
    }
    if (response.status < 200 || response.status >= 300) {
      throw HostedException(
        'ota_resolve_failed',
        'The OTA service returned HTTP ${response.status}.',
        status: 502,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.body));
    } on FormatException {
      throw const HostedException(
        'ota_resolve_invalid',
        'The OTA service returned an invalid link response.',
        status: 502,
      );
    }
    final url = decoded is Map ? decoded['url'] : null;
    if (url is! String || url.isEmpty) {
      throw const HostedException(
        'ota_resolve_missing',
        'The OTA service did not provide a fresh download link.',
        status: 502,
      );
    }
    try {
      return config.checkOtaUrl(url);
    } on HostedConfigException catch (error) {
      throw HostedException('ota_url_refused', error.message, status: 502);
    }
  }

  Future<_Feed> _loadFeed(bool na, {required bool force}) async {
    final persisted = await _readFeed(na);
    if (!force && persisted != null && _fresh(persisted)) {
      _memory[na] = persisted;
      return persisted;
    }
    try {
      final headers = <String, String>{
        if (persisted != null && persisted.etag.isNotEmpty)
          'If-None-Match': persisted.etag,
      };
      final response = await http.bytes(
        'GET',
        http.resolve('api/catalog', {'na': na ? '1' : '0'}),
        headers: headers,
        maxBytes: _feedLimit,
      );
      if (response.status == 304) {
        if (persisted == null) {
          throw const HostedException(
            'catalog_empty',
            'The OTA service returned an empty catalog.',
            status: 502,
          );
        }
        final etag = response.header('etag') ?? persisted.etag;
        final refreshed = persisted.copyWith(
          fetchedAt: DateTime.now().toUtc(),
          etag: etag,
        );
        await _writeFeed(na, refreshed);
        _memory[na] = refreshed;
        return refreshed;
      }
      if (response.status < 200 || response.status >= 300) {
        throw HostedException(
          'catalog_http',
          'The OTA service returned HTTP ${response.status}.',
          status: 502,
        );
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(response.body));
        validateCatalog(decoded);
      } on CatalogException catch (error) {
        throw HostedException('catalog_invalid', error.message, status: 502);
      } on FormatException {
        throw const HostedException(
          'catalog_invalid',
          'The OTA service returned invalid JSON.',
          status: 502,
        );
      }
      final feed = _Feed(
        data: Map<String, dynamic>.from(decoded as Map),
        sha256: canonicalSha256(decoded),
        etag: response.header('etag') ?? '',
        fetchedAt: DateTime.now().toUtc(),
        stale: false,
      );
      await _writeFeed(na, feed);
      _memory[na] = feed;
      return feed;
    } on Object catch (error) {
      if (persisted != null) {
        final age = DateTime.now().toUtc().difference(persisted.fetchedAt);
        if (age >= Duration.zero && age <= config.catalogMaxStale) {
          final stale = persisted.copyWith(stale: true);
          _memory[na] = stale;
          return stale;
        }
      }
      if (error is HostedException) rethrow;
      throw HostedException(
        'catalog_unavailable',
        'Could not reach the OTA catalog.',
        status: 503,
      );
    }
  }

  Future<_Feed?> _readFeed(bool na) async {
    final file = File(joinPath(cacheDir.path, ['feed-${na ? 1 : 0}.json']));
    try {
      final json = await readJsonObject(file, limit: _feedLimit + 4096);
      if (json == null || json['schema'] != 1) return null;
      final data = json['data'];
      if (data is! Map<String, dynamic>) return null;
      validateCatalog(data);
      final sha = json['sha256'];
      final fetchedAt = parseIsoUtc(json['fetchedAt']);
      if (sha is! String || !isSha256Hex(sha) || fetchedAt == null) return null;
      if (canonicalSha256(data) != sha) return null;
      return _Feed(
        data: data,
        sha256: sha,
        etag: json['etag'] is String ? json['etag'] as String : '',
        fetchedAt: fetchedAt,
        stale: false,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _writeFeed(bool na, _Feed feed) async {
    await atomicWriteJson(
      File(joinPath(cacheDir.path, ['feed-${na ? 1 : 0}.json'])),
      {
        'schema': 1,
        'sha256': feed.sha256,
        'etag': feed.etag,
        'fetchedAt': isoUtc(feed.fetchedAt),
        'data': feed.data,
      },
    );
  }

  bool _fresh(_Feed feed) {
    final age = DateTime.now().toUtc().difference(feed.fetchedAt);
    return age >= Duration.zero && age < config.catalogTtl;
  }

  Map<String, dynamic> _decorate({
    required bool stale,
    required Map<String, String> errors,
    required Map<String, dynamic> data,
  }) {
    final result = Map<String, dynamic>.from(data);
    if (stale) result['_stale'] = true;
    if (errors.isNotEmpty) result['_feed_errors'] = errors;
    return result;
  }
}

final class _Feed {
  const _Feed({
    required this.data,
    required this.sha256,
    required this.etag,
    required this.fetchedAt,
    required this.stale,
  });

  final Map<String, dynamic> data;
  final String sha256;
  final String etag;
  final DateTime fetchedAt;
  final bool stale;

  _Feed copyWith({DateTime? fetchedAt, String? etag, bool? stale}) => _Feed(
    data: data,
    sha256: sha256,
    etag: etag ?? this.etag,
    fetchedAt: fetchedAt ?? this.fetchedAt,
    stale: stale ?? this.stale,
  );
}

/// Stable release identity: signed URL query strings and ranking hints are
/// excluded, every other catalog field participates.
String releaseDigest(Map<String, dynamic> entry) {
  final stable = <String, Object?>{};
  for (final item in entry.entries) {
    if (item.key == 'source_url' || item.key == 'is_latest') continue;
    stable[item.key] = item.value;
  }
  final source = entry['source_url'];
  if (source is String) {
    final uri = Uri.tryParse(source);
    if (uri != null) {
      stable['source_origin'] = {
        'scheme': uri.scheme,
        'host': uri.host,
        'path': uri.path,
      };
    }
  }
  return canonicalSha256(stable);
}
