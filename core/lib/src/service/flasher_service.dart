import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:logging/logging.dart';
import 'package:squadron/squadron.dart';

import '../bloat/bloat_store.dart';
import '../bloat/gunzip_rust.dart';
import '../bloat/manifest.dart';
import '../catalog/catalog_client.dart';
import '../catalog/http_transport.dart';
import '../facts/facts.dart';
import '../flash/executor.dart';
import '../flash/hosted.dart';
import '../flash/identity.dart';
import '../flash/model.dart' as flash_model;
import '../flash/package_source.dart';
import '../flash/prepare.dart' as flash_prepare;
import '../flash/store_identity.dart';
import '../flash/strategy.dart';
import '../link/native_fastboot.dart';
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

  final Map<String, _PreparedEntry> _prepared = {};
  final Map<String, String> _jobLocks = {};

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

  /// Granted fastboot devices. Never opens a browser chooser.
  @squadronMethod
  Future<Map<String, Object?>> fastbootDevices() async {
    try {
      final devices = await nativeFastbootTransport().devices();
      return {
        'devices': [for (final device in devices) device.toMap()],
      };
    } on LinkFailure catch (error) {
      return {'devices': <Map<String, Object?>>[], 'error': error.toMap()};
    }
  }

  /// Read-only preparation. Returns the plan, prompts and a token that binds
  /// the device, the exact request, and the inspected package.
  @squadronMethod
  Future<Map<String, Object?>> prepareFlash(Map<String, Object?> req) async {
    try {
      final tables = await _readTables(req);
      final selectionMap = req['selection'];
      final selection = tables.selection(
        _stringArg(selectionMap, 'device', 'selection'),
        _stringArg(selectionMap, 'kind', 'selection'),
        _stringArg(selectionMap, 'region', 'selection'),
      );
      final hosted = _hostedArg(req);
      final output = req['output'];
      late final FlashPackage package;
      HostedFlashSession? hostedSession;
      final String job;
      final String storeKey;
      if (hosted != null) {
        job = hosted.jobId;
        storeKey = _hostedStoreKey(hosted);
      } else {
        if (output is! Map) {
          throw const BuildException('Missing output store.');
        }
        final rawJob = req['job'];
        if (rawJob is! String || rawJob.isEmpty) {
          throw const BuildException('Missing job directory.');
        }
        job = normalizeWorkspacePath(rawJob);
        storeKey = _storeKey(output);
      }
      final lockKey = '$storeKey|$job';
      if (_jobLocks.containsKey(lockKey)) {
        throw const flash_model.FlashException('This job is being flashed.');
      }
      final serial = req['serial'];
      if (serial is! String || serial.trim().isEmpty) {
        throw const BuildException('Choose a fastboot device serial.');
      }
      final answers = _flashAnswers(req['answers']);
      if (hosted != null) {
        hostedSession = await HostedFlashSession.open(artifact: hosted);
        package = hostedSession.package;
      }
      try {
        // A hosted preparation also needs the lease guard: every getvar and
        // partition read below happens only while the server-side job is
        // pinned, and a lost lease aborts before the next command.
        final transport = hostedSession != null
            ? hostedSession.guardedTransport(nativeFastbootTransport())
            : nativeFastbootTransport();
        if (deviceIdentities[selection.dev]?.product == null &&
            (answers['product'] ?? '').trim().isEmpty) {
          final device = await transport.open(serial);
          try {
            if (device.serial != serial) {
              throw const flash_model.FlashException(
                'The connected serial changed.',
              );
            }
            final product = await flash_prepare.readProduct(device);
            return {
              'productRequired': true,
              'serial': serial,
              'observedProduct': product,
              'message':
                  'Connected product: $product. No confirmed product mapping '
                  'exists for ${selection.device}. Check the selected model, then '
                  'type the product explicitly to continue.',
            };
          } finally {
            await device.close();
          }
        }
        if (hosted == null) {
          final workspace = await _openStoreWorkspace(output);
          final buildJson = await readJobManifest(workspace, job);
          package = await openFlashPackage(workspace, job, buildJson);
        }
        final token = _newToken();
        final prepared = await flash_prepare.prepareFlash(
          package: package,
          selection: selection,
          answers: answers,
          serial: serial,
          transport: transport,
          job: job,
          upstreamBase: req['upstreamBase'] as String? ?? '',
          storeKey: storeKey,
          token: token,
        );
        if (prepared.resolved) {
          _prepared.removeWhere((_, entry) => entry.lockKey == lockKey);
          _prepared[token] = _PreparedEntry(
            prepared,
            lockKey,
            hosted == null
                ? Map<String, Object?>.unmodifiable(
                    Map<String, Object?>.from(output! as Map),
                  )
                : null,
            hosted,
          );
        }
        return prepared.toMap();
      } finally {
        await hostedSession?.close();
      }
    } on LinkFailure catch (error) {
      return {'error': error.toMap()};
    } on flash_model.FlashException catch (error, stack) {
      return {'error': error.failure(stage: 'prepare', stack: '$stack')};
    }
  }

  /// Executes the prepared plan. The first event is a step; the last is a
  /// result carrying the receipt. Cancelling the subscription stops future
  /// commands and records an uncertain in-flight write.
  @squadronMethod
  Stream<Map<String, Object?>> flash(Map<String, Object?> req) {
    final controller = StreamController<Map<String, Object?>>();
    final run = _FlashRun(this, req, controller);
    controller.onListen = () {
      unawaited(run.start());
    };
    controller.onCancel = run.cancel;
    return controller.stream;
  }
}

final class _PreparedEntry {
  const _PreparedEntry(this.prepared, this.lockKey, this.store, this.hosted);
  final flash_prepare.PreparedFlash prepared;
  final String lockKey;
  final Map<String, Object?>? store;
  final HostedArtifact? hosted;
}

final class _FlashRun {
  _FlashRun(this._service, this._req, this._controller);

  final FlasherService _service;
  final Map<String, Object?> _req;
  final StreamController<Map<String, Object?>> _controller;
  Completer<void>? _done;
  FlashCancellation? _cancellation;
  String? _lockKey;
  bool _cancelled = false;

  void _emit(Map<String, Object?> event) {
    if (_cancelled || _controller.isClosed) return;
    _controller.add(event);
  }

  Future<void> start() async {
    final done = _done = Completer<void>();
    final cancellation = _cancellation = FlashCancellation();
    if (_cancelled) {
      cancellation.cancel('cancelled before preparation completed');
    }
    HostedArtifact? hosted;
    HostedFlashSession? session;
    try {
      final token = _req['confirmationToken'];
      if (token is! String || token.isEmpty) {
        throw const flash_model.FlashException(
          'A confirmation token from prepareFlash is required.',
        );
      }
      final entry = _service._prepared.remove(token);
      if (entry == null) {
        throw const flash_model.FlashException(
          'The confirmation token is unknown, expired or already used. '
          'Prepare again.',
        );
      }
      hosted = _hostedArg(_req);
      if (entry.hosted != null &&
          (hosted == null || !entry.hosted!.sameIdentity(hosted))) {
        throw const flash_model.FlashException(
          'The flash request names a different hosted artifact than the '
          'confirmed plan. Prepare again.',
        );
      }
      if (entry.hosted == null && hosted != null) {
        throw const flash_model.FlashException(
          'The confirmed plan is a local job, not a hosted artifact. '
          'Prepare again.',
        );
      }
      final storeKey = hosted != null
          ? _hostedStoreKey(hosted)
          : _storeKey(_req['output']);
      final rawJob = _req['job'];
      final job = hosted != null
          ? hosted.jobId
          : (rawJob is String ? normalizeWorkspacePath(rawJob) : '');
      final bound = <String, Object?>{..._req, 'job': job};
      if (!entry.prepared.binding.matches(bound, storeKey: storeKey)) {
        throw const flash_model.FlashException(
          'The flash request no longer matches the confirmed plan. '
          'Prepare again.',
        );
      }
      Workspace? workspace;
      final FlashPackage currentPackage;
      if (hosted != null) {
        if (_req['output'] != null) {
          throw const flash_model.FlashException(
            'A hosted flash cannot name a local output store.',
          );
        }
        session = await HostedFlashSession.open(artifact: hosted);
        currentPackage = session.package;
      } else {
        final output = _req['output'];
        if (output is! Map) throw const BuildException('Missing output store.');
        final store = entry.store;
        if (store == null ||
            !await sameFlashStore(store, Map<String, Object?>.from(output))) {
          throw const flash_model.FlashException(
            'The output folder changed. Prepare again.',
          );
        }
        workspace = await _openStoreWorkspace(output);
        final manifest = await readJobManifest(workspace, job);
        currentPackage = await openFlashPackage(workspace, job, manifest);
      }
      try {
        final digest = await flash_prepare.packageDigest(currentPackage);
        if (digest != entry.prepared.binding.packageDigest) {
          throw const flash_model.FlashException(
            'The job or its images changed after preparation. Prepare again.',
          );
        }
        // Every byte the plan will write is read and hashed through the
        // pinned hosted source before the first device command.
        await flash_prepare.verifyPreparedImages(
          entry.prepared,
          package: currentPackage,
        );
        final runPrepared = hosted != null
            ? entry.prepared.withPackage(currentPackage)
            : entry.prepared;
        if (_service._jobLocks.containsKey(entry.lockKey)) {
          throw const flash_model.FlashException(
            'This job is already being flashed.',
          );
        }
        _service._jobLocks[entry.lockKey] = token;
        _lockKey = entry.lockKey;
        if (_cancelled) {
          cancellation.cancel('cancelled while checking the package');
        }
        final flashTransport = session != null
            ? session.guardedTransport(nativeFastbootTransport())
            : nativeFastbootTransport();
        final receipt = await applyConfirmedFlash(
          runPrepared,
          flashTransport,
          await PlaceInfo.current(),
          emit: _emit,
          cancellation: cancellation,
        );
        if (hosted != null) {
          // A hosted job has no local directory to persist into. The receipt
          // is returned in full; the page downloads it.
          receipt['hosted'] = hosted.toMap();
          receipt['persistenceWarnings'] = <String>[];
          if (session!.leaseLost) {
            receipt['persistenceWarnings'] = [
              'The hosted retention lease was lost while flashing. The '
                  'returned receipt is the only copy.',
            ];
          }
        } else {
          receipt['persistenceWarnings'] = await _persistReceipt(
            workspace!,
            entry.prepared.job,
            receipt,
          );
        }
        _emit({
          'type': 'result',
          'status': receipt['status'],
          'receipt': receipt,
        });
      } finally {
        await session?.close();
      }
    } on LinkFailure catch (error) {
      _emit({
        'type': 'result',
        'status': 'failed',
        'receipt': {
          'version': 1,
          'status': 'failed',
          'serial': _req['serial'],
          'job': _req['job'],
          if (hosted != null) 'hosted': hosted.toMap(),
          'writes': <Map<String, Object?>>[],
          'steps': <Map<String, Object?>>[],
          'verification': {'status': 'not-run'},
          'uncertain': false,
          'failure': error.toMap(),
        },
      });
    } on Object catch (error, stack) {
      if (!_controller.isClosed) _controller.addError(error, stack);
    } finally {
      final lock = _lockKey;
      if (lock != null) _service._jobLocks.remove(lock);
      if (!done.isCompleted) done.complete();
      if (!_controller.isClosed) {
        try {
          await _controller.close();
        } on Object {
          // A cancelled subscription needs no close acknowledgement.
        }
      }
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    _cancellation?.cancel('the subscriber cancelled the flash');
    final done = _done;
    if (done != null && !done.isCompleted) {
      try {
        await done.future;
      } on Object {
        // The stream's error belongs to the subscriber.
      }
    }
  }
}

Future<List<String>> _persistReceipt(
  Workspace workspace,
  String job,
  Map<String, Object?> receipt,
) async {
  final warnings = <String>[];
  try {
    final path = '$job/flash-receipt.json';
    final bytes = utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert(receipt)}\n',
    );
    final sink = await workspace.create('$path.part');
    try {
      await sink.write(bytes, 0);
    } finally {
      await sink.close();
    }
    await workspace.move('$path.part', path);
  } on Object catch (error) {
    _log.warning('could not persist $job/flash-receipt.json: $error');
    warnings.add('Could not save flash-receipt.json: $error');
  }
  try {
    final manifest = await readJobManifest(workspace, job);
    manifest['flash'] = receipt;
    final bytes = utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    );
    final sink = await workspace.create('$job/build.json.part');
    try {
      await sink.write(bytes, 0);
    } finally {
      await sink.close();
    }
    await workspace.move('$job/build.json.part', '$job/build.json');
  } on Object catch (error) {
    _log.warning('could not record the flash receipt in build.json: $error');
    warnings.add('Could not save the receipt in build.json: $error');
  }
  return warnings;
}

String _storeKey(Object? value) {
  if (value is! Map) return 'missing';
  final kind = '${value['kind']}';
  final path = value['path'];
  if (path is String) return '$kind|$path';
  // A browser handle is cloned between service calls, so its identity is not
  // stable. Keying every handle store together is deliberately conservative:
  // it can serialize two picked folders, but never races one job.
  if (value['handle'] != null) return '$kind|handle';
  return kind;
}

/// A hosted request names exactly one immutable artifact; a local store and
/// a hosted artifact cannot be mixed.
HostedArtifact? _hostedArg(Map<String, Object?> req) {
  final hosted = HostedArtifact.tryParse(req['hosted']);
  if (hosted != null && req['output'] != null) {
    throw const flash_model.FlashException(
      'A hosted flash cannot name a local output store.',
    );
  }
  return hosted;
}

String _hostedStoreKey(HostedArtifact artifact) =>
    'hosted|${artifact.jobId}|${artifact.sha256}|${artifact.bytes}';

Map<String, String> _flashAnswers(Object? value) {
  if (value == null) return const {};
  if (value is! Map) {
    throw const flash_model.FlashException('answers must be a map of strings.');
  }
  final answers = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! String) {
      throw const flash_model.FlashException(
        'answers must be a map of strings.',
      );
    }
    answers[entry.key as String] = entry.value as String;
  }
  return answers;
}

String _newToken() {
  final random = Random.secure();
  final bytes = Uint8List(32);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
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
