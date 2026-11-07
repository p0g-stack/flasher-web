import 'errors.dart';
import 'util.dart';

/// The only POST /api/hosted/jobs body the server accepts.
final class HostedJobRequest {
  const HostedJobRequest({
    required this.device,
    required this.kind,
    required this.region,
    required this.catalogId,
    this.baseCatalogId,
    this.vulnerableAbl,
  });

  final String device;
  final String kind;
  final String region;
  final String catalogId;
  final String? baseCatalogId;
  final bool? vulnerableAbl;

  Map<String, Object?> selection() => {
    'device': device,
    'kind': kind,
    'region': region,
  };

  Map<String, Object?> toJson() => {
    'selection': selection(),
    'catalogId': catalogId,
    if (baseCatalogId != null) 'baseCatalogId': baseCatalogId,
    if (vulnerableAbl != null) 'vulnerableAbl': vulnerableAbl,
  };

  String get fingerprint => canonicalSha256(toJson());
}

const Set<String> _topLevel = {
  'selection',
  'catalogId',
  'baseCatalogId',
  'vulnerableAbl',
};

const Set<String> _selectionKeys = {'device', 'kind', 'region'};

/// Parses the one recognized request shape. Unknown fields are rejected, not
/// ignored: there is no upload, URL, catalog entry or extra option path.
HostedJobRequest parseJobRequest(Object? decoded) {
  if (decoded is! Map<String, dynamic>) {
    throw const HostedException(
      'request_invalid',
      'The request body must be a JSON object.',
    );
  }
  _exactKeys(decoded, _topLevel);
  final selection = decoded['selection'];
  if (selection is! Map<String, dynamic>) {
    throw const HostedException(
      'selection_invalid',
      'selection must be an object with device, kind and region.',
    );
  }
  _exactKeys(selection, _selectionKeys);
  final device = _text(selection['device'], 'selection.device');
  final kind = _text(selection['kind'], 'selection.kind');
  final region = _text(selection['region'], 'selection.region');
  final catalogId = _releaseId(decoded['catalogId'], 'catalogId');
  final baseRaw = decoded['baseCatalogId'];
  final baseCatalogId = baseRaw == null
      ? null
      : _releaseId(baseRaw, 'baseCatalogId');
  final vulnerable = decoded['vulnerableAbl'];
  if (vulnerable != null && vulnerable is! bool) {
    throw const HostedException(
      'vulnerable_abl_invalid',
      'vulnerableAbl must be a boolean.',
    );
  }
  return HostedJobRequest(
    device: device,
    kind: kind,
    region: region,
    catalogId: catalogId,
    baseCatalogId: baseCatalogId,
    vulnerableAbl: vulnerable as bool?,
  );
}

void _exactKeys(Map<String, dynamic> value, Set<String> allowed) {
  for (final key in value.keys) {
    if (!allowed.contains(key)) {
      throw const HostedException(
        'request_field_unknown',
        'The request contains an unrecognized field.',
      );
    }
  }
  for (final key in allowed) {
    if (!value.containsKey(key)) {
      if (key == 'baseCatalogId' || key == 'vulnerableAbl') continue;
      throw const HostedException(
        'request_field_missing',
        'The request is missing a required field.',
      );
    }
  }
}

String _text(Object? value, String field) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 80 ||
      value.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
    throw HostedException(
      'request_invalid',
      '$field must be a short text value.',
    );
  }
  return value;
}

String _releaseId(Object? value, String field) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 200 ||
      value.contains(RegExp(r'[\u0000-\u001f\u007f]')) ||
      value.contains('://') ||
      value.contains('/') ||
      value.contains(r'\') ||
      value.contains('?') ||
      value.contains('#') ||
      value.contains('@')) {
    throw HostedException(
      'request_invalid',
      '$field must name a catalog release, not a URL or path.',
    );
  }
  return value;
}
