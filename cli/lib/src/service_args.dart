import 'dart:convert';
import 'dart:io';

import 'package:flasher_web_core/flasher_web_core.dart';

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

/// A local OTA file, read in place.
Map<String, Object?> fileOta(String path) => {
  'kind': 'file',
  'file': File(path).absolute.path,
};

/// A direct HTTP(S) OTA URL.
Map<String, Object?> urlOta(String url) => {'kind': 'url', 'url': url};

/// An OTA input: a local path or a direct HTTP(S) URL.
Map<String, Object?> otaInput(String source) =>
    isHttpUrl(source) ? urlOta(source) : fileOta(source);

/// Resolve a catalog release id through `/api/catalog`.
///
/// [role] is `ota` or `base`; its catalog target comes from the same
/// `ota_catalog.targets` rules the desktop app uses.
Future<Map<String, Object?>> resolveCatalogEntry({
  required String apiBase,
  required String device,
  required String kind,
  required String region,
  required String id,
  required String role,
}) async {
  final target = targets(device, kind, region)[role];
  if (target == null) {
    throw const CatalogException('A BASE OTA is not used for this selection.');
  }
  final transport = HttpCatalogTransport();
  try {
    final catalog = CatalogClient(
      transport: transport,
      base: apiBaseUri(apiBase),
    );
    final entry = await catalog.findRelease(id, target.device, target.region);
    return {'kind': 'catalog', 'entry': entry};
  } finally {
    transport.close();
  }
}

/// The `virtual` member of a prepare, flash or export request.
Map<String, Object?> virtualRequest({
  required Map<String, Object?> ota,
  required Map<String, Object?>? base,
  required String bloatDir,
  required bool? vulnerableAbl,
}) => {
  'ota': ota,
  'base': ?base,
  'bloat': pathStore(bloatDir),
  'vulnerableAbl': ?vulnerableAbl,
};

/// The `prepareFlash` request map of the virtual flash contract.
Map<String, Object?> flashPrepareRequest({
  required Map<String, Object?> selection,
  required Map<String, Object?> virtual,
  required String serial,
  required Map<String, String> answers,
  required String apiBase,
  required String upstream,
}) => {
  'selection': selection,
  'virtual': virtual,
  'serial': serial,
  'answers': answers,
  'apiBase': apiBase,
  'upstreamBase': upstreamBase(upstream),
};

/// The `exportVirtual` request map, with a path [destination] for the VM.
Map<String, Object?> exportVirtualRequest({
  required Map<String, Object?> selection,
  required Map<String, Object?> virtual,
  required String apiBase,
  required String upstream,
  required String destination,
}) => {
  'selection': selection,
  'virtual': virtual,
  'apiBase': apiBase,
  'upstreamBase': upstreamBase(upstream),
  'destination': {'kind': 'path', 'path': File(destination).absolute.path},
};

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

/// Prints the read-only plan and every prompt.
void printFlashPreparation(Map<String, Object?> prepared) {
  final serial = prepared['serial'] ?? '?';
  final mode = prepared['mode'] ?? '?';
  final job = prepared['job'] ?? '?';
  final version = prepared['version'] ?? '?';
  print('Job: $job ($version)');
  print(
    'Device: ${prepared['device'] ?? '?'} '
    '(${prepared['dev'] ?? '?'}) / ${prepared['kind'] ?? '?'} / '
    '${prepared['region'] ?? '?'}',
  );
  print('Serial: $serial');
  print('Mode: $mode');
  print('max-download-size: ${prepared['maxDownloadSize'] ?? '?'} bytes');
  final warnings = prepared['warnings'];
  if (warnings is List) {
    for (final warning in warnings) {
      print('WARNING: $warning');
    }
  }
  final steps = prepared['steps'];
  if (steps is List) {
    print('Plan (${steps.length} steps):');
    for (var index = 0; index < steps.length; index++) {
      print('  ${index + 1}. ${steps[index]}');
    }
  }
  final prompts = prepared['prompts'];
  if (prompts is List) {
    for (final prompt in prompts) {
      if (prompt is! Map) continue;
      final selected = prompt['selected'];
      print(
        'Prompt ${prompt['id']}: ${prompt['question']} '
        '(choices: ${(prompt['choices'] as List?)?.join('/') ?? ''}; '
        'selected: ${selected ?? 'unanswered'})',
      );
    }
  }
  final confirmation = prepared['confirmation'];
  if (confirmation is List) {
    print('Confirmation:');
    for (final line in confirmation) {
      print('  $line');
    }
  }
}

/// Prints one failed step and its reason.
void printFlashFailure(Map<String, Object?> failure) {
  final step = failure['stepIndex'];
  print(
    'FAILED at step ${step is num ? step.toInt() + 1 : '?'} '
    '(${failure['status'] ?? 'failed'}): ${failure['reason'] ?? 'unknown'}',
  );
}

/// Prints a flash result and its receipt.
void printFlashResult(Map<String, Object?> result) {
  final receipt = result['receipt'];
  print('Flash: ${result['status'] ?? 'unknown'}');
  if (receipt is Map) {
    final runId = receipt['runId'] ?? result['runId'];
    if (runId != null) print('Run: $runId');
    final writes = receipt['writes'];
    if (writes is List) {
      print('Writes: ${writes.length}');
      for (final write in writes) {
        if (write is! Map) continue;
        print(
          '  ${write['partition']} ${write['bytes']} bytes '
          'part ${write['part'] ?? 1}/${write['parts'] ?? 1} '
          '${write['status']}',
        );
      }
    }
    final verification = receipt['verification'];
    if (verification is Map) {
      print(
        'Verification: ${verification['status']} '
        '(${verification['detail'] ?? ''})',
      );
    }
    final failure = receipt['failure'];
    if (failure is Map) {
      print(
        'Failure: ${failure['name']}: ${failure['message']} '
        '(uncertain: ${failure['uncertain']})',
      );
    }
    final cleanup = receipt['cleanupErrors'];
    if (cleanup is List && cleanup.isNotEmpty) {
      print('Cleanup errors: ${cleanup.join('; ')}');
    }
  }
}

/// Writes [receipt] as indented JSON to [path] and prints where it landed.
Future<void> writeReceipt(String path, Map<String, Object?> receipt) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(receipt)}\n',
  );
  print('Receipt: ${file.absolute.path}');
}

/// Prints an export result.
void printExportResult(Map<String, Object?> result) {
  print('Format: ${result['format'] ?? 'zip'}');
  final job = result['job'];
  if (job is String && job.isNotEmpty) print('Job: $job');
  final sha256 = result['sha256'];
  if (sha256 is String && sha256.isNotEmpty) print('SHA-256: $sha256');
  print('Bytes: ${result['bytes'] ?? 0}');
  print('Entries: ${result['entries'] ?? 0}');
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
