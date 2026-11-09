import 'dart:io';

/// The edge worker's default origin: local `wrangler dev`.
const defaultApiBase = 'http://127.0.0.1:8787';

/// Where bootstrap writes the upstream snapshot, relative to the workspace.
const defaultUpstream = 'app/web/upstream';

/// The `Sel` map of `docs/service.md`.
Map<String, Object?> selectionMap({
  required String device,
  required String kind,
  required String region,
}) => {'device': device, 'kind': kind, 'region': region};

/// A `dart:io` directory [Store] for `docs/service.md`.
Map<String, Object?> pathStore(String path) => {
  'kind': 'path',
  'path': Directory(path).absolute.path,
};

bool isHttpUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

/// The API origin as a directory URI, so `api/catalog` resolves below it.
Uri apiBaseUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw FormatException('Invalid --api-base URL: $value');
  }
  return Uri.parse(value.endsWith('/') ? value : '$value/');
}

/// A local upstream folder becomes absolute; an HTTP(S) upstream stays a URL.
///
/// The service's workspace paths are `/`-separated, and it rejects a local
/// snapshot path containing `\`, so native separators are normalized.
String upstreamBase(String value) => isHttpUrl(value)
    ? value
    : Directory(value).absolute.path.replaceAll('\\', '/');

/// The `downloadBloat` request map of `docs/service.md`.
Map<String, Object?> bloatRequest({
  required Map<String, Object?> selection,
  required String bloatDir,
  required String apiBase,
  required String upstream,
}) => {
  'selection': selection,
  'store': pathStore(bloatDir),
  'apiBase': apiBase,
  'upstreamBase': upstreamBase(upstream),
};

/// Print one service event the way upstream's backend prints its steps.
void printEvent(Map<String, Object?> event) {
  final type = event['type'];
  if (type == 'step') {
    print('STEP ${event['index']}/${event['total']} • ${event['title']}');
  } else if (type == 'log') {
    final text = event['text'];
    if (text is String && text.isNotEmpty) print(text);
  } else if (type == 'progress') {
    final label = event['label'];
    final done = event['done'];
    final total = event['total'];
    if (label is String) {
      print(
        '$label: ${done is num ? done.toInt() : '?'} / '
        '${total is num ? total.toInt() : '?'} bytes',
      );
    }
  } else if (type == 'waiting') {
    final text = event['text'];
    if (text is String && text.isNotEmpty) print(text);
  }
}

/// Print a bloat download result.
void printBloatResult(Map<String, Object?> result) {
  final bloat = result['bloat'];
  if (bloat is Map) {
    print(
      'Bloat files: ${bloat['downloaded'] ?? 0}/${bloat['total'] ?? 0} '
      'verified, ${bloat['bytes'] ?? 0} bytes',
    );
    if (bloat['ready'] != true) {
      print('Bloat files are not ready.');
    }
  }
}
