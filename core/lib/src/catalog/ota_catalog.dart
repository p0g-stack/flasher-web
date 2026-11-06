/// Daniel Springer's OTA catalog: device targets, validation, release order,
/// metadata matching and security-patch selection.
///
/// Port of `flasher_builder/ota_catalog.py`.
library;

/// A catalog, feed, or selection failure. Messages match upstream.
final class CatalogException implements Exception {
  const CatalogException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Catalog display names for every upstream device.
// ignore: constant_identifier_names
const Map<String, String> DEVICE_NAMES = {
  'Oneplus 13': 'OP 13',
  'Oneplus 13R': 'OP 13R',
  'Oneplus 13S': 'OP 13S',
  'Oneplus 13T': 'OP 13T',
  'Oneplus 15': 'OP 15',
  'Oneplus 15R': 'OP 15R',
  'Oneplus 15T': 'OP 15T',
  'Oneplus Ace 5': 'OP ACE 5',
  'Oneplus Ace 5 Pro': 'OP ACE 5 PRO',
  'Oneplus Ace 6': 'OP ACE 6',
  'Oneplus Ace 6T': 'OP ACE 6T',
  'Oneplus Pad 2 Pro': 'OP PAD2 PRO',
  'Oneplus Pad 3': 'OP PAD3',
  'Oneplus Pad 3 Pro': 'OP PAD3 PRO',
  'Realme GT 7 Pro': 'Realme GT7 PRO',
  'Realme NEO8': 'Realme NEO 8',
  'OPPO Find X9 Ultra': 'OPPO FIND X9 ULTRA',
};

/// Whether this build reads the dedicated NA feed.
bool usesNaApi(String device, String region) {
  final name = DEVICE_NAMES[device] ?? device;
  return region == 'NA' && (name == 'OP 13' || name == 'OP 15');
}

/// Ace 6T's IN/GLO Super Flasher uses a CN ODM with an exactly matching
/// security patch instead of the static ODM image.
bool needsMatchedOdm(String device, String kind, String region) =>
    device == 'Oneplus Ace 6T' &&
    kind == 'Super Flasher' &&
    (region == 'IN' || region == 'GLO');

/// Catalog targets for a build, keyed `ota` and, for the Ace 6 conversion,
/// `base`. Returns a map of `(device, region)` records.
Map<String, ({String device, String region})> targets(
  String device,
  String kind,
  String region,
) {
  if (needsMatchedOdm(device, kind, region)) {
    return {'ota': (device: 'OP 15R', region: region)};
  }
  if (device == 'Oneplus Ace 6' &&
      kind == 'SuperHybrid Flasher' &&
      region == 'IN') {
    return {
      'ota': (device: 'OP 15R', region: 'IN'),
      'base': (device: 'OP ACE 6', region: 'CN'),
    };
  }
  final name = DEVICE_NAMES[device];
  if (name == null) {
    throw const CatalogException('This device has no OTA catalog mapping.');
  }
  return {'ota': (device: name, region: region)};
}

/// Validate a complete `YYYY-MM-DD` security patch date and return it.
String patchDate(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const CatalogException(
      'A complete security patch date is required to match the ODM source.',
    );
  }
  final parts = value.split('-').map(int.parse).toList();
  final year = parts[0], month = parts[1], day = parts[2];
  final parsed = DateTime.utc(year, month, day);
  if (year < 1 ||
      year > 9999 ||
      parsed.year != year ||
      parsed.month != month ||
      parsed.day != day) {
    throw const CatalogException('The security patch date is invalid.');
  }
  return value;
}

/// The first Ace 6T CN release whose security patch equals [target]'s.
Map<String, dynamic> matchingOdm(
  Map<String, dynamic> data,
  Map<String, dynamic> target,
) {
  final patch = patchDate(target['security_patch']);
  final candidates = [
    for (final entry in releasesFor(data, 'OP ACE 6T', 'CN'))
      if (entry['security_patch'] == patch) entry,
  ];
  if (candidates.isEmpty) {
    throw CatalogException(
      'No Ace 6T CN OTA has security patch $patch. Choose a target with an '
      'exact patch match; a different ODM will not be substituted.',
    );
  }
  return candidates.first;
}

/// Identify the local/downloaded target without choosing a newer release.
Map<String, dynamic> releaseFromMetadata(
  Map<String, dynamic> data,
  String device,
  String region,
  Map<String, dynamic> metadata,
) {
  final values = [
    for (final key in [
      'version_name',
      'ota_version',
      'post-build-incremental',
      'post-build',
    ])
      _pyString(metadata[key]),
  ].join('\n');
  final versions = {
    for (final match in RegExp(r'\d+(?:\.\d+){2,4}').allMatches(values))
      match.group(0)!,
  };
  final matches = [
    for (final entry in releasesFor(data, device, region))
      if (_metadataMatches(entry, values, versions)) entry,
  ];
  if (matches.length != 1) {
    throw const CatalogException(
      'Could not identify this local OTA as an exact OnePlus 15R version for '
      'the selected region. Select its version in the catalog or use a '
      'matching full OTA.',
    );
  }
  return matches.first;
}

bool _metadataMatches(
  Map<String, dynamic> entry,
  String values,
  Set<String> versions,
) {
  final otaVersion = entry['ota_version'];
  if (otaVersion is String &&
      otaVersion.isNotEmpty &&
      values.contains(otaVersion)) {
    return true;
  }
  final model = entry['model'];
  if (model is! String || model.isEmpty) return false;
  final modelPattern = RegExp(
    '(?<![A-Za-z0-9])${RegExp.escape(model)}(?![A-Za-z0-9])',
  );
  if (!modelPattern.hasMatch(values)) return false;
  final version = entry['version'];
  if (version is! String) return false;
  return RegExp(r'\d+(?:\.\d+){2,4}')
      .allMatches(version)
      .any((match) => versions.contains(match.group(0)));
}

/// Validate the catalog envelope and every release. Messages match upstream.
Map<String, dynamic> validateCatalog(Object? data) {
  if (data is! Map<String, dynamic> ||
      '${data['api_version']}' != '1' ||
      data['releases'] is! List) {
    throw const CatalogException(
      'The OTA service returned an unsupported catalog format.',
    );
  }
  final ids = <String>{};
  for (final entry in data['releases'] as List) {
    if (entry is! Map ||
        !const ['id', 'device', 'region', 'version', 'source_url'].every(
          (key) => entry[key] is String && (entry[key] as String).isNotEmpty,
        )) {
      throw const CatalogException(
        'The OTA catalog contains an incomplete release.',
      );
    }
    final id = entry['id'] as String;
    final source = entry['source_url'] as String;
    final uri = Uri.tryParse(source);
    final scheme = uri?.scheme.toLowerCase();
    if (ids.contains(id) || (scheme != 'http' && scheme != 'https')) {
      throw const CatalogException(
        'The OTA catalog contains an invalid release.',
      );
    }
    ids.add(id);
  }
  return data;
}

/// Releases for exactly this device and region, newest first.
///
/// Ordering is upstream's natural version key: `is_latest`, then
/// `build_timestamp`, then the version split around digit runs, compared
/// descending and stable.
List<Map<String, dynamic>> releasesFor(
  Map<String, dynamic> data,
  String device,
  String region,
) {
  final releases = data['releases'];
  if (releases is! List) {
    throw const CatalogException(
      'The OTA service returned an unsupported catalog format.',
    );
  }
  final selected = <({int index, Map<String, dynamic> entry})>[];
  for (var index = 0; index < releases.length; index++) {
    final entry = releases[index];
    if (entry is Map<String, dynamic> &&
        entry['device'] == device &&
        entry['region'] == region) {
      selected.add((index: index, entry: entry));
    }
  }
  selected.sort((a, b) {
    final order = _compareRelease(a.entry, b.entry);
    return order != 0 ? order : a.index.compareTo(b.index);
  });
  return [for (final item in selected) item.entry];
}

/// A [releaseFromMetadata]-style exact lookup by id.
Map<String, dynamic> findReleaseIn(
  Map<String, dynamic> data,
  String id,
  String device,
  String region,
) {
  for (final entry in releasesFor(data, device, region)) {
    if (entry['id'] == id) return entry;
  }
  throw const CatalogException(
    'The selected OTA version is no longer listed for this device/region. '
    'Fetch versions again.',
  );
}

int _compareRelease(Map<String, dynamic> a, Map<String, dynamic> b) {
  final aLatest = _truthy(a['is_latest']);
  final bLatest = _truthy(b['is_latest']);
  if (aLatest != bLatest) return bLatest ? 1 : -1;
  final timestamp = _timestamp(a).compareTo(_timestamp(b));
  if (timestamp != 0) return -timestamp;
  final left = _versionParts(a['version']);
  final right = _versionParts(b['version']);
  final count = left.length < right.length ? left.length : right.length;
  for (var index = 0; index < count; index++) {
    final order = left[index].compareTo(right[index]);
    if (order != 0) return -order;
  }
  return right.length.compareTo(left.length);
}

String _timestamp(Map<String, dynamic> entry) {
  final value = entry['build_timestamp'];
  return value is String ? value : '';
}

String _pyString(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is bool) return value ? 'True' : 'False';
  return value.toString();
}

bool _truthy(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value.isNotEmpty;
  if (value is Iterable) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

List<_VersionPart> _versionParts(Object? version) {
  final text = version is String ? version : '';
  final parts = <_VersionPart>[];
  var start = 0;
  for (final match in RegExp(r'\d+').allMatches(text)) {
    parts.add(_VersionPart.text(text.substring(start, match.start)));
    parts.add(_VersionPart.number(int.parse(match.group(0)!)));
    start = match.end;
  }
  parts.add(_VersionPart.text(text.substring(start)));
  return parts;
}

final class _VersionPart implements Comparable<_VersionPart> {
  const _VersionPart.number(this.number) : kind = 1, text = '';

  const _VersionPart.text(this.text) : kind = 0, number = 0;

  final int kind;
  final int number;
  final String text;

  @override
  int compareTo(_VersionPart other) {
    if (kind != other.kind) return kind.compareTo(other.kind);
    return kind == 1
        ? number.compareTo(other.number)
        : text.toLowerCase().compareTo(other.text.toLowerCase());
  }
}
