import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:squadron/squadron.dart';

import '../bloat/bloat_store.dart';
import '../bloat/gunzip_rust.dart';
import '../bloat/manifest.dart';
import '../catalog/catalog_client.dart';
import '../catalog/http_transport.dart';
import '../facts/facts.dart';
import '../log.dart';
import '../native/native.dart';
import '../pipeline/assets.dart';
import '../pipeline/build.dart';
import '../pipeline/errors.dart';
import '../pipeline/local_source.dart';
import '../pipeline/ota.dart';
import '../pipeline/ota_headers.dart';
import '../storage/storage.dart';
import '../upstream/tables.dart';
import 'flasher_service.activator.g.dart';
import 'storage_stats.dart';

part 'flasher_service.worker.g.dart';

final _log = Logger('service.flasher');

/// The upstream commit of the last snapshot this service read.
String _upstreamCommit = '';

/// The app's one service: inspect an OTA, download bloat, build a flasher.
///
/// Runs in a Web Worker on the web and in an isolate natively; the CLI calls
/// the same class. Requests and results are JSON-like maps, plus the browser's
/// `File` and `FileSystemDirectoryHandle` objects on the web.
@SquadronService(
  baseUrl: '~/workers',
  targetPlatform: TargetPlatform.vm | TargetPlatform.web,
)
base class FlasherService {
  FlasherService() {
    forwardLogs();
  }

  /// Facts, the Rust library and storage space in this place.
  @squadronMethod
  Future<Map<String, Object?>> environment() async {
    final place = await PlaceInfo.current();
    final storage = await storageStatistics();
    return {
      'facts': place.facts.present,
      'native': place.facts.has(Fact.native),
      'upstream': _upstreamCommit,
      'storage': {
        'opfs': place.facts.has(Fact.fsOpfs),
        'picker': place.facts.has(Fact.fsPicker),
        'handle': place.facts.has(Fact.fsHandle),
        'persisted': storage['persisted'],
        'quota': storage['quota'],
        'usage': storage['usage'],
      },
    };
  }

  /// Whether every bloat image this selection needs is present and verified.
  @squadronMethod
  Future<Map<String, Object?>> bloatStatus(Map<String, Object?> req) async {
    final tables = await _readTables(req);
    final selection = tables.selection(
      _stringArg(req['selection'], 'device', 'selection'),
      _stringArg(req['selection'], 'kind', 'selection'),
      _stringArg(req['selection'], 'region', 'selection'),
    );
    final workspace = await _openStoreWorkspace(req['store']);
    final manifest = await _readBloatManifest(req);
    final status = await BloatStore(
      workspace: workspace,
      manifest: manifest,
    ).inspect(selection);
    return _statusMap(status);
  }

  /// Downloads and verifies the selected bloat images into [store].
  @squadronMethod
  Stream<Map<String, Object?>> downloadBloat(Map<String, Object?> req) async* {
    final tables = await _readTables(req);
    final selection = tables.selection(
      _stringArg(req['selection'], 'device', 'device'),
      _stringArg(req['selection'], 'kind', 'kind'),
      _stringArg(req['selection'], 'region', 'region'),
    );
    final workspace = await _openStoreWorkspace(req['store']);
    final manifest = await _readBloatManifest(req);
    if (!await loadNative()) {
      throw const BuildException(
        "This place does not have flasher_web's native library.",
      );
    }
    final apiBase = req['apiBase'] as String? ?? '';
    final partBytes = <String, int>{
      for (final asset in manifest.assets.values)
        for (final part in asset.transportParts) part.assetName: part.bytes,
    };
    final store = BloatStore(
      workspace: workspace,
      manifest: manifest,
      gunzip: RustGunzip.new,
    );
    yield {
      'type': 'step',
      'index': 2,
      'total': 5,
      'title': 'Download and verify bloat',
    };
    await for (final event in store.materialize(
      selection,
      (asset) => _bloatAssetSource(apiBase, asset, partBytes[asset] ?? 0),
    )) {
      switch (event) {
        case BloatStarted(:final total, :final bytes):
          yield {
            'type': 'log',
            'text': 'Selected $total bloat image(s), $bytes bytes.',
          };
        case BloatStep(:final message):
          yield {'type': 'log', 'text': message};
        case BloatByteProgress(:final path, :final bytes, :final total):
          yield {
            'type': 'progress',
            'label': path,
            'done': bytes,
            'total': total,
          };
        case BloatFinished():
          break;
      }
    }
    final status = await store.inspect(selection);
    yield {'type': 'result', 'bloat': _statusMap(status)};
  }

  /// Validates a full AB OTA and reports what a build would use.
  @squadronMethod
  Future<Map<String, Object?>> inspectOta(Map<String, Object?> req) async {
    // ZIP and payload parsing are Rust calls; a Web Worker loads the wasm
    // on first use, and this is the first use for an inspect.
    if (!await loadNative()) {
      throw const BuildException(
        "This place does not have flasher_web's native library.",
      );
    }
    final archive = await _openOtaArchive(req);
    try {
      final arb = await archive.arb();
      final result = <String, Object?>{
        'version': archive.version,
        'fields': Map<String, Object?>.from(archive.fields),
        'partitions': archive.partitions,
        'length': archive.length,
        'stored': archive.stored,
      };
      if (arb != null) result['arb'] = arb;
      final device = archive.fields['pre-device'];
      if (device != null) result['device'] = device;
      final patch = archive.fields['post-security-patch-level'];
      if (patch != null) result['securityPatch'] = patch;
      return result;
    } finally {
      await archive.close();
    }
  }

  /// Builds a flasher: step, log and progress events, then one result.
  @squadronMethod
  Stream<Map<String, Object?>> build(Map<String, Object?> req) =>
      buildFlasher(req);

  /// `build.json` of every finished job in [output], newest first.
  @squadronMethod
  Future<List<Map<String, Object?>>> history(Map<String, Object?> req) async {
    final workspace = await _openStoreWorkspace(req['output']);
    final paths = await workspace.list('', recursive: true);
    final jobs = <(String, Map<String, Object?>)>[];
    for (final path in paths) {
      final parts = path.split('/');
      if (parts.length != 2 || parts.last != 'build.json') continue;
      try {
        final source = await workspace.open(path);
        final bytes = await source.read(0, source.length);
        await closeByteSource(source);
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map<String, dynamic>) {
          jobs.add((parts.first, Map<String, Object?>.from(decoded)));
        }
      } on Object catch (error) {
        _log.fine('skipping unreadable build.json in ${parts.first}: $error');
      }
    }
    jobs.sort((a, b) {
      final left = '${a.$2['created'] ?? a.$1}';
      final right = '${b.$2['created'] ?? b.$1}';
      return right.compareTo(left);
    });
    return [
      for (final (job, manifest) in jobs) {...manifest, 'job': job},
    ];
  }
}

Future<UpstreamTables> _readTables(Map<String, Object?> req) async {
  final assets = UpstreamAssets(req['upstreamBase'] as String? ?? '');
  final tables = await assets.tables();
  _upstreamCommit = tables.commit;
  return tables;
}

Future<BloatManifest> _readBloatManifest(Map<String, Object?> req) async {
  final assets = UpstreamAssets(req['upstreamBase'] as String? ?? '');
  return assets.bloatManifest();
}

Future<Workspace> _openStoreWorkspace(Object? value) async {
  if (value is! Map) {
    throw const BuildException('Missing store.');
  }
  return openStore(Map<String, Object?>.from(value));
}

ByteSource _bloatAssetSource(String apiBase, String asset, int length) {
  final uri = _apiUri(apiBase, 'api/bloat/${Uri.encodeComponent(asset)}');
  return _RangeAsset(uri, length);
}

Future<OtaArchive> _openOtaArchive(Map<String, Object?> req) async {
  final input = req['ota'];
  if (input is! Map) {
    throw const BuildException('Select a full OTA file or enter its URL.');
  }
  final apiBase = req['apiBase'] as String? ?? '';
  final kind = input['kind'];
  final place = await PlaceInfo.current();
  final proxied =
      place.facts.has(Fact.fsOpfs) || place.facts.has(Fact.fsPicker);
  switch (kind) {
    case 'file':
      final source = await openLocalOta(input['file']!);
      return _guarded(source, () => OtaArchive.open(source));
    case 'url':
      final url = input['url'];
      if (url is! String || url.isEmpty) {
        throw const BuildException(
          'Select a full OTA file or enter its HTTPS download URL.',
        );
      }
      final source = await HttpRangeSource.open(
        _otaUri(apiBase, url, proxied: proxied),
        headers: proxied ? const {} : otaRequestHeaders,
      );
      return _guarded(source, () => OtaArchive.open(source, remote: true));
    case 'catalog':
      final entry = input['entry'];
      if (entry is! Map) {
        throw const BuildException('Select an OTA catalog version.');
      }
      final client = CatalogClient(
        transport: HttpCatalogTransport(),
        base: _base(apiBase),
      );
      Future<ByteSource> openFresh() async => HttpRangeSource.open(
        _otaUri(
          apiBase,
          await client.resolveLink(Map<String, dynamic>.from(entry)),
          proxied: proxied,
        ),
        headers: proxied ? const {} : otaRequestHeaders,
      );
      final source = await openFresh();
      return _guarded(
        source,
        () => OtaArchive.open(source, remote: true, refresh: openFresh),
      );
    default:
      throw BuildException('Unknown OTA input: $kind.');
  }
}

Future<OtaArchive> _guarded(
  ByteSource source,
  Future<OtaArchive> Function() open,
) async {
  try {
    return await open();
  } on Object {
    await closeByteSource(source);
    rethrow;
  }
}

Uri _base(String apiBase) {
  if (apiBase.isEmpty) return Uri();
  return Uri.parse(apiBase);
}

Uri _apiUri(String apiBase, String path) {
  final base = _base(apiBase);
  final prefix = base.path.isEmpty || base.path.endsWith('/')
      ? base.path
      : '${base.path}/';
  return base.replace(path: '$prefix$path');
}

Uri _otaUri(String apiBase, String url, {required bool proxied}) {
  if (!proxied) return Uri.parse(url);
  return _apiUri(apiBase, 'api/ota').replace(queryParameters: {'u': url});
}

Map<String, Object?> _statusMap(BloatStatus status) => {
  'total': status.total,
  'downloaded': status.downloaded,
  'bytes': status.bytes,
  'ready': status.ready,
};

String _stringArg(Object? value, String key, String field) {
  if (value is! Map) throw BuildException('Missing $field.');
  final found = value[key];
  if (found is! String || found.isEmpty) {
    throw BuildException('Missing $field.$key.');
  }
  return found;
}

/// A bloat asset opened by HTTP ranges, so only what is downloaded crosses.
final class _RangeAsset implements ByteSource {
  _RangeAsset(this._uri, this.length);

  final Uri _uri;
  HttpRangeSource? _source;

  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    final source = _source ??= await HttpRangeSource.open(_uri);
    if (source.length != this.length) {
      throw BuildException(
        'The bloat asset changed size: ${_uri.pathSegments.last}.',
      );
    }
    return source.read(offset, length);
  }
}
