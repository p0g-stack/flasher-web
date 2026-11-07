/// The same-origin HTTP contract for operator-hosted builds.
///
/// Only catalog release identifiers cross this boundary. Local files, uploads
/// and arbitrary URLs are rejected before a request is made, and the job,
/// artifact and manifest paths are derived from a validated capability id.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The worker's hosted route accepts capability ids of this shape.
final RegExp hostedJobIdPattern = RegExp(r'^[A-Za-z0-9_-]{16,128}$');

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// A hosted API or job-metadata failure, with the HTTP status when there was
/// one. Messages keep the server's evidence instead of replacing it.
final class HostedApiException implements Exception {
  const HostedApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// The only accepted hosted build input: a catalog selection and its ids.
///
/// [fromBuildRequest] rejects every unknown key, so a custom URL, file handle
/// or upload field can never travel from the setup page to the server.
final class HostedJobRequest {
  const HostedJobRequest({
    required this.selection,
    required this.catalogId,
    this.baseCatalogId,
    this.vulnerableAbl,
  });

  factory HostedJobRequest.fromBuildRequest(Map<String, Object?> request) {
    const allowed = {
      'hosted',
      'selection',
      'catalogId',
      'baseCatalogId',
      'vulnerableAbl',
    };
    for (final key in request.keys) {
      if (!allowed.contains(key)) {
        throw HostedApiException(
          'Hosted builds accept catalog ids only; "$key" is not allowed.',
        );
      }
    }
    if (request['hosted'] != true) {
      throw const HostedApiException('Not a hosted build request.');
    }
    final selectionValue = request['selection'];
    if (selectionValue is! Map) {
      throw const HostedApiException('Hosted build selection is missing.');
    }
    const selectionKeys = {'device', 'kind', 'region'};
    for (final key in selectionValue.keys) {
      if (!selectionKeys.contains(key)) {
        throw HostedApiException(
          'Hosted build selection field "$key" is not allowed.',
        );
      }
    }
    String requiredText(String name) {
      final value = selectionValue[name];
      if (value is! String || value.trim().isEmpty) {
        throw HostedApiException('Hosted build selection $name is missing.');
      }
      return value;
    }

    final catalogId = _catalogId(request['catalogId']);
    final baseValue = request['baseCatalogId'];
    final baseCatalogId = baseValue == null ? null : _catalogId(baseValue);
    final abl = request['vulnerableAbl'];
    if (abl != null && abl is! bool) {
      throw const HostedApiException('vulnerableAbl must be true or false.');
    }
    return HostedJobRequest(
      selection: {
        'device': requiredText('device'),
        'kind': requiredText('kind'),
        'region': requiredText('region'),
      },
      catalogId: catalogId,
      baseCatalogId: baseCatalogId,
      vulnerableAbl: abl as bool?,
    );
  }

  final Map<String, String> selection;
  final String catalogId;
  final String? baseCatalogId;
  final bool? vulnerableAbl;

  /// The exact JSON body of `POST /api/hosted/jobs`.
  Map<String, Object?> toJson() => {
    'selection': selection,
    'catalogId': catalogId,
    if (baseCatalogId != null) 'baseCatalogId': baseCatalogId,
    if (vulnerableAbl != null) 'vulnerableAbl': vulnerableAbl,
  };

  static String _catalogId(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 256 ||
        value.contains(RegExp(r'[\s/\\?#]')) ||
        value.contains('://')) {
      throw const HostedApiException('A catalog release id is required.');
    }
    return value;
  }
}

/// What the hosted server reports about a job.
enum HostedJobStatus {
  queued,
  running,
  succeeded,
  failed;

  bool get finished => this == succeeded || this == failed;

  static HostedJobStatus parse(Object? value) {
    for (final status in values) {
      if (status.name == value) return status;
    }
    throw HostedApiException(
      'The hosted build reported an unknown status: $value.',
    );
  }
}

/// Reuse facts for the finished ZIP: whether this request shared a cached
/// build and when the cache entry was last used or stops being retained.
final class HostedCacheInfo {
  const HostedCacheInfo({this.hit, this.lastUsed, this.retainedUntil});

  factory HostedCacheInfo.fromJson(Map<String, Object?> json) {
    final hit = json['hit'];
    return HostedCacheInfo(
      hit: hit is bool ? hit : null,
      lastUsed: _date(json['lastUsed'] ?? json['last_used']),
      retainedUntil: _date(json['retainedUntil'] ?? json['retained_until']),
    );
  }

  final bool? hit;
  final DateTime? lastUsed;
  final DateTime? retainedUntil;

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  /// One line for the result card, or null when the server sent no facts.
  String? get text {
    final parts = <String>[];
    if (hit == true) {
      parts.add('Reused an identical cached build');
    } else if (hit == false) {
      parts.add('Built for this request');
    }
    if (lastUsed != null) {
      parts.add('last used ${_day(lastUsed!)}');
    }
    if (retainedUntil != null) {
      parts.add('retained until ${_day(retainedUntil!)}');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _day(DateTime value) {
    final utc = value.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year}-${two(utc.month)}-${two(utc.day)}';
  }
}

/// One hosted job metadata response.
final class HostedJob {
  const HostedJob({
    required this.id,
    required this.status,
    required this.events,
    required this.artifactUrl,
    required this.manifestUrl,
    this.error,
    this.manifest,
    this.sha256,
    this.bytes,
    this.cache,
    this.artifact,
    this.manifestSha256,
  });

  factory HostedJob.fromJson(
    Map<String, Object?> json, {
    required String expectedId,
    Uri? origin,
  }) {
    if (!hostedJobIdPattern.hasMatch(expectedId)) {
      throw const HostedApiException(
        'The hosted build returned an invalid job id.',
      );
    }
    final id = json['id'];
    if (id is! String || id != expectedId) {
      throw const HostedApiException(
        'The hosted build returned a different job than requested.',
      );
    }
    final status = HostedJobStatus.parse(json['status']);
    final eventsValue = json['events'];
    if (eventsValue != null && eventsValue is! List) {
      throw const HostedApiException(
        'The hosted build returned malformed events.',
      );
    }
    final events = <Map<String, Object?>>[
      for (final event in eventsValue as List? ?? const [])
        if (event is Map) Map<String, Object?>.from(event),
    ];

    final artifactPath = hostedArtifactPath(expectedId);
    final manifestPath = hostedManifestPath(expectedId);
    final artifactUrl = _canonicalPath(
      json['artifactUrl'],
      artifactPath,
      origin,
      'artifact',
    );
    final manifestUrl = _canonicalPath(
      json['manifestUrl'],
      manifestPath,
      origin,
      'manifest',
    );

    final errorValue = json['error'];
    final manifestValue = json['manifest'];
    Map<String, Object?>? manifest;
    if (manifestValue != null) {
      if (manifestValue is! Map) {
        throw const HostedApiException(
          'The hosted build returned a malformed manifest.',
        );
      }
      manifest = Map<String, Object?>.from(manifestValue);
    }

    final shaValue = json['sha256'];
    String? sha256;
    if (shaValue != null) {
      if (shaValue is! String || !_sha256Pattern.hasMatch(shaValue.toLowerCase())) {
        throw const HostedApiException(
          'The hosted build returned an invalid SHA-256.',
        );
      }
      sha256 = shaValue.toLowerCase();
    }

    final bytesValue = json['bytes'];
    int? bytes;
    if (bytesValue != null) {
      if (bytesValue is! num ||
          bytesValue < 0 ||
          bytesValue != bytesValue.toInt()) {
        throw const HostedApiException(
          'The hosted build returned an invalid artifact length.',
        );
      }
      bytes = bytesValue.toInt();
    }

    final cacheValue = json['cache'];
    HostedCacheInfo? cache;
    if (cacheValue != null) {
      if (cacheValue is! Map) {
        throw const HostedApiException(
          'The hosted build returned malformed cache details.',
        );
      }
      cache = HostedCacheInfo.fromJson(Map<String, Object?>.from(cacheValue));
    }

    if (status == HostedJobStatus.succeeded) {
      if (sha256 == null) {
        throw const HostedApiException(
          'The hosted build finished without a SHA-256.',
        );
      }
      if (bytes == null) {
        throw const HostedApiException(
          'The hosted build finished without an artifact length.',
        );
      }
      if (manifest == null) {
        throw const HostedApiException(
          'The hosted build finished without build.json.',
        );
      }
    }

    final artifactValue = json['artifactName'] ?? json['artifact'];
    final artifact = artifactValue is String && artifactValue.isNotEmpty
        ? artifactValue
        : manifest?['artifact'] is String
        ? manifest!['artifact']! as String
        : 'hosted build';

    final manifestShaValue = json['manifestSha256'];
    String? manifestSha256;
    if (manifestShaValue != null) {
      if (manifestShaValue is! String ||
          !_sha256Pattern.hasMatch(manifestShaValue.toLowerCase())) {
        throw const HostedApiException(
          'The hosted build returned an invalid manifest SHA-256.',
        );
      }
      manifestSha256 = manifestShaValue.toLowerCase();
    }

    return HostedJob(
      id: id,
      status: status,
      events: List.unmodifiable(events),
      error: errorValue is String && errorValue.isNotEmpty ? errorValue : null,
      manifest: manifest,
      sha256: sha256,
      bytes: bytes,
      cache: cache,
      artifact: artifact,
      manifestSha256: manifestSha256,
      artifactUrl: artifactUrl,
      manifestUrl: manifestUrl,
    );
  }

  final String id;
  final HostedJobStatus status;
  final List<Map<String, Object?>> events;
  final String? error;
  final Map<String, Object?>? manifest;
  final String? sha256;
  final int? bytes;
  final HostedCacheInfo? cache;
  final String? artifact;
  final String? manifestSha256;

  /// Same-origin paths, never a server-supplied URL.
  final String artifactUrl;
  final String manifestUrl;

  static String _canonicalPath(
    Object? value,
    String expectedPath,
    Uri? origin,
    String label,
  ) {
    if (value == null || value == '') return expectedPath;
    if (value is! String) {
      throw HostedApiException('The hosted build returned a bad $label URL.');
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.hasQuery || uri.hasFragment) {
      throw HostedApiException('The hosted build returned a bad $label URL.');
    }
    if (!uri.hasScheme && !uri.hasAuthority) {
      if (uri.path != expectedPath) {
        throw HostedApiException(
          'The hosted build returned an unexpected $label path.',
        );
      }
      return expectedPath;
    }
    final sameOrigin =
        origin != null &&
        uri.scheme == origin.scheme &&
        uri.host == origin.host &&
        uri.port == origin.port;
    if (!sameOrigin || uri.path != expectedPath) {
      throw HostedApiException(
        'The hosted build returned a foreign $label URL.',
      );
    }
    return expectedPath;
  }
}

String hostedArtifactPath(String id) => '/api/hosted/jobs/$id/artifact';

String hostedManifestPath(String id) => '/api/hosted/jobs/$id/manifest';

/// Formats one cumulative job event as log lines and progress.
String? hostedEventLine(Map<String, Object?> event) {
  switch (event['type']) {
    case 'log':
      final text = event['text'];
      return text is String ? text : null;
    case 'step':
      final index = event['index'];
      final total = event['total'];
      final title = event['title'];
      if (title is String) {
        return 'STEP ${index ?? '?'}/${total ?? '?'}: $title';
      }
      return null;
    case 'waiting':
      final message = event['message'] ?? event['text'];
      return message is String ? message : null;
    default:
      final text = event['text'] ?? event['message'];
      return text is String ? text : null;
  }
}

/// The same-origin `POST/GET /api/hosted` client.
final class HostedApiClient {
  HostedApiClient({
    http.Client? client,
    Uri? base,
    this.requestTimeout = const Duration(seconds: 30),
    this.maxResponseBytes = 4 * 1024 * 1024,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _origin = base == null || base == Uri() ? null : base,
       base = base ?? Uri() {
    final path = this.base.path;
    if (path.isNotEmpty && path != '/') {
      throw ArgumentError.value(
        this.base,
        'base',
        'Must be an origin or a directory, not a page path.',
      );
    }
  }

  final http.Client _client;
  final bool _ownsClient;
  final Uri? _origin;
  final Uri base;
  final Duration requestTimeout;
  final int maxResponseBytes;

  Uri _uri(String path) => base.resolve(path);

  /// `POST /api/hosted/jobs`; returns the queued job.
  Future<HostedJob> create(HostedJobRequest request) async {
    final response = await _post(
      '/api/hosted/jobs',
      jsonEncode(request.toJson()),
    );
    final json = _decode(response);
    final id = json['id'];
    if (id is! String || !hostedJobIdPattern.hasMatch(id)) {
      throw const HostedApiException(
        'The hosted build returned an invalid job id.',
      );
    }
    return HostedJob.fromJson(json, expectedId: id, origin: _origin);
  }

  /// `GET /api/hosted/jobs/{id}`. Metadata is never reused from a cache.
  Future<HostedJob> get(String id) async {
    if (!hostedJobIdPattern.hasMatch(id)) {
      throw const HostedApiException('Invalid hosted job id.');
    }
    final request = http.Request('GET', _uri('/api/hosted/jobs/$id'))
      ..followRedirects = false
      ..headers.addAll(const {
        'accept': 'application/json',
        'cache-control': 'no-store',
      });
    final response = await _send(() async =>
        http.Response.fromStream(await _client.send(request)));
    return HostedJob.fromJson(
      _decode(response),
      expectedId: id,
      origin: _origin,
    );
  }

  Future<http.Response> _post(String path, String body) {
    final request = http.Request('POST', _uri(path))
      ..followRedirects = false
      ..headers.addAll(const {
        'accept': 'application/json',
        'content-type': 'application/json',
        'cache-control': 'no-store',
      })
      ..body = body;
    return _send(() async =>
        http.Response.fromStream(await _client.send(request)));
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request().timeout(requestTimeout);
    } on TimeoutException {
      throw HostedApiException(
        'The hosted builder did not answer within '
        '${requestTimeout.inSeconds} seconds.',
      );
    } on http.ClientException catch (error) {
      throw HostedApiException('Could not reach the hosted builder: $error');
    }
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw HostedApiException(
        'The hosted builder attempted a redirect (HTTP '
        '${response.statusCode}); redirects are not followed.',
        statusCode: response.statusCode,
      );
    }
    return response;
  }

  Map<String, Object?> _decode(http.Response response) {
    final String body;
    try {
      body = utf8.decode(response.bodyBytes, allowMalformed: false);
    } on FormatException {
      throw HostedApiException(
        'The hosted builder returned non-UTF-8 data (HTTP '
        '${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HostedApiException(
        _errorMessage(body, response.statusCode),
        statusCode: response.statusCode,
      );
    }
    if (response.bodyBytes.length > maxResponseBytes) {
      throw const HostedApiException(
        'The hosted builder returned an oversized response.',
      );
    }
    final Object? value;
    try {
      value = jsonDecode(body);
    } on FormatException {
      throw HostedApiException(
        'The hosted builder returned malformed JSON (HTTP '
        '${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    if (value is! Map) {
      throw const HostedApiException(
        'The hosted builder returned an unexpected response.',
      );
    }
    return Map<String, Object?>.from(value);
  }

  static String _errorMessage(String body, int status) {
    try {
      final value = jsonDecode(body);
      if (value is Map) {
        final error = value['error'] ?? value['message'];
        if (error is String && error.isNotEmpty) {
          return 'Hosted build failed (HTTP $status): $error';
        }
      }
    } on FormatException {
      // Keep the status and the evidence below.
    }
    final detail = body.trim();
    if (detail.isEmpty) return 'Hosted build failed (HTTP $status).';
    return 'Hosted build failed (HTTP $status): '
        '${detail.length > 500 ? '${detail.substring(0, 500)}…' : detail}';
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
