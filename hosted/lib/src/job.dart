import 'request.dart';
import 'util.dart';

enum HostedState { queued, running, succeeded, failed }

extension HostedStateName on HostedState {
  String get wire => name;
}

/// One hosted job, in memory while active and persisted when finished.
final class HostedJob {
  HostedJob({
    required this.id,
    required this.request,
    required this.createdAt,
    required this.updatedAt,
    required this.lastUsedAt,
  });

  final String id;
  final HostedJobRequest request;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime lastUsedAt;
  HostedState state = HostedState.queued;
  List<Map<String, Object?>> events = [];
  String? error;
  String? errorCode;
  Map<String, Object?>? manifest;
  String? manifestSha256;
  String? artifactName;
  String? sha256;
  int? bytes;
  bool cacheHit = false;
  Map<String, Object?>? inputs;
  String? cacheKey;
  String? sourceJobId;

  bool get finished =>
      state == HostedState.succeeded || state == HostedState.failed;

  void event(Map<String, Object?> event) {
    if (event['type'] == 'progress') {
      final label = '${event['label'] ?? ''}';
      final index = events.lastIndexWhere(
        (existing) =>
            existing['type'] == 'progress' && '${existing['label'] ?? ''}' == label,
      );
      if (index >= 0) {
        events[index] = event;
        return;
      }
    }
    events.add(event);
    if (events.length > 800) {
      final drop = events.length - 800;
      events = events.sublist(drop);
    }
    updatedAt = DateTime.now().toUtc();
  }

  Map<String, Object?> publicJson({required Duration retention}) {
    final json = <String, Object?>{
      'id': id,
      'status': state.wire,
      'events': events,
      'selection': request.selection(),
      'catalogId': request.catalogId,
      if (request.baseCatalogId != null)
        'baseCatalogId': request.baseCatalogId,
      if (request.vulnerableAbl != null)
        'vulnerableAbl': request.vulnerableAbl,
      'createdAt': isoUtc(createdAt),
      'updatedAt': isoUtc(updatedAt),
      'cache': <String, Object?>{
        'hit': cacheHit,
        if (finished)
          'lastUsed': isoUtc(lastUsedAt),
        if (finished)
          'retainedUntil': isoUtc(lastUsedAt.add(retention)),
      },
    };
    if (error != null) json['error'] = error;
    if (errorCode != null) json['errorCode'] = errorCode;
    if (manifest != null) json['manifest'] = manifest;
    if (manifestSha256 != null) json['manifestSha256'] = manifestSha256;
    if (state == HostedState.succeeded) {
      json['artifactUrl'] = '/api/hosted/jobs/$id/artifact';
      if (artifactName != null) json['artifactName'] = artifactName;
      if (sha256 != null) json['sha256'] = sha256;
      if (bytes != null) json['bytes'] = bytes;
    }
    return json;
  }

  Map<String, Object?> recordJson() => {
    'schema': 1,
    'id': id,
    'request': request.toJson(),
    'status': state.wire,
    'events': events,
    'error': error,
    'errorCode': errorCode,
    'manifest': manifest,
    'manifestSha256': manifestSha256,
    'artifactName': artifactName,
    'sha256': sha256,
    'bytes': bytes,
    'cacheHit': cacheHit,
    'inputs': inputs,
    'cacheKey': cacheKey,
    'sourceJobId': sourceJobId,
    'createdAt': isoUtc(createdAt),
    'updatedAt': isoUtc(updatedAt),
    'lastUsedAt': isoUtc(lastUsedAt),
  };

  static HostedJob fromRecord(Map<String, dynamic> json) {
    final id = json['id'];
    final rawRequest = json['request'];
    final status = json['status'];
    final createdAt = parseIsoUtc(json['createdAt']);
    final updatedAt = parseIsoUtc(json['updatedAt']);
    final lastUsedAt = parseIsoUtc(json['lastUsedAt']);
    HostedState? state;
    for (final value in HostedState.values) {
      if (value.name == status) {
        state = value;
        break;
      }
    }
    if (json['schema'] != 1 ||
        id is! String ||
        !urlSafeId.hasMatch(id) ||
        rawRequest is! Map<String, dynamic> ||
        state == null ||
        createdAt == null ||
        updatedAt == null ||
        lastUsedAt == null) {
      throw const FormatException('invalid hosted job record');
    }
    final request = parseJobRequest(rawRequest);
    final manifest = json['manifest'];
    final events = json['events'];
    return HostedJob(
      id: id,
      request: request,
      createdAt: createdAt,
      updatedAt: updatedAt,
      lastUsedAt: lastUsedAt,
    )
      ..state = state
      ..events = [
        if (events is List)
          for (final item in events)
            if (item is Map) Map<String, Object?>.from(item),
      ]
      ..error = json['error'] is String ? json['error'] as String : null
      ..errorCode = json['errorCode'] is String
          ? json['errorCode'] as String
          : null
      ..manifest = manifest is Map
          ? Map<String, Object?>.from(manifest)
          : null
      ..manifestSha256 = json['manifestSha256'] is String
          ? json['manifestSha256'] as String
          : null
      ..artifactName = json['artifactName'] is String
          ? json['artifactName'] as String
          : null
      ..sha256 = json['sha256'] is String ? json['sha256'] as String : null
      ..bytes = json['bytes'] is int ? json['bytes'] as int : null
      ..cacheHit = json['cacheHit'] == true
      ..inputs = json['inputs'] is Map
          ? Map<String, Object?>.from(json['inputs'] as Map)
          : null
      ..cacheKey = json['cacheKey'] is String ? json['cacheKey'] as String : null
      ..sourceJobId = json['sourceJobId'] is String
          ? json['sourceJobId'] as String
          : null;
  }
}
