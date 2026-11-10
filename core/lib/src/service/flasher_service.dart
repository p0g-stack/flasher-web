import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:squadron/squadron.dart';

import '../bloat/bloat_store.dart';
import '../bloat/gunzip_rust.dart';
import '../bloat/manifest.dart';
import '../catalog/catalog_client.dart';
import '../catalog/http_transport.dart';
import '../catalog/ota_catalog.dart';
import '../e2e/fake_fastboot.dart';
import '../facts/facts.dart';
import '../flash/executor.dart';
import '../flash/identity.dart';
import '../flash/model.dart' as flash_model;
import '../flash/op_decoder.dart';
import '../flash/prepare.dart' as flash_prepare;
import '../flash/store_identity.dart';
import '../flash/strategy.dart';
import '../flash/virtual.dart';
import '../flash/virtual_export.dart';
import '../link/native_fastboot.dart';
import '../log.dart';
import '../native/native.dart';
import '../pipeline/assets.dart';
import '../pipeline/errors.dart';
import '../pipeline/local_source.dart';
import '../pipeline/ota.dart';
import '../pipeline/ota_headers.dart';
import '../storage/budget.dart';
import '../storage/catalog_ota_source.dart';
import '../storage/estimate.dart';
import '../storage/export_sink.dart';
import '../storage/hashing.dart';
import '../storage/ota_cache.dart';
import '../storage/ota_destination.dart';
import '../storage/storage.dart';
import '../upstream/tables.dart';
import 'flasher_service.activator.g.dart';
import 'storage_stats.dart';

part 'flasher_service.worker.g.dart';


/// The upstream commit of the last snapshot this service read.
String _upstreamCommit = '';

/// How the service opens fastboot devices when the caller injects nothing.
///
/// The e2e build defines `FLASHER_FAKE_USB=true`; the constant branch below
/// is dead code in every other build, so the fake and its marker are dropped
/// from the compiled output.
FastbootTransport _defaultFastbootFactory() {
  if (const bool.fromEnvironment('FLASHER_FAKE_USB')) {
    return fakeFastbootTransport();
  }
  return nativeFastbootTransport();
}

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
  FlasherService({Object? transportFactory})
    : _transportFactory = transportFactory ?? _defaultFastbootFactory {
    forwardLogs();
  }

  /// How this service opens fastboot devices. Tests inject a recording fake;
  /// the default is the native/WebUSB transport. Stored as [Object] because
  /// squadron_builder cannot describe a function-typed field.
  final Object _transportFactory;

  FastbootTransport _fastbootTransport() =>
      (_transportFactory as FastbootTransport Function())();

  final Map<String, _PreparedEntry> _prepared = {};
  final Map<String, String> _jobLocks = {};
  final Map<String, _PausedFlash> _paused = {};
  final Map<String, _FlashRun> _active = {};

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
    final cache = _otaCache(
      workspace,
      apiBase,
    );
    final store = BloatStore(
      workspace: workspace,
      manifest: manifest,
      gunzip: RustGunzip.new,
      budget: _budgetFor(
        req['store'],
        evict: (needed) => cache.evict(bytesNeeded: needed),
      ),
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

  /// The storage cap, the origin's usage and the cached OTAs of [store].
  ///
  /// `items` is the UI's cache list, most recently used first: `key` (catalog
  /// entry digest), `label`, `bytes` (durable data), `allocated` (file extent),
  /// `complete`, `lastUsed` (ISO-8601 UTC).
  @squadronMethod
  Future<Map<String, Object?>> storageBudget(Map<String, Object?> req) async {
    final workspace = await _openStoreWorkspace(req['store']);
    final cache = _otaCache(
      workspace,
      req['apiBase'] as String? ?? '',
    );
    final report = await _budgetFor(req['store']).snapshot();
    final entries = await cache.entries();
    return {
      'cap': report.cap,
      'usage': report.usage,
      'quota': report.quota,
      'available': report.available,
      'items': [
        for (final entry in entries.reversed)
          {
            'key': entry.key,
            'label': entry.label,
            'bytes': entry.bytes,
            'allocated': await cache.allocatedBytes(entry),
            'complete': entry.complete,
            'lastUsed': entry.lastUsedAt.toIso8601String(),
          },
      ],
    };
  }

  /// Downloads or resumes one catalog OTA into the cache under [store].
  ///
  /// The request names `store` (where `ota-cache/` lives) and
  /// `ota: {"kind": "catalog", "entry": <release>}`; `apiBase` selects the
  /// same-origin proxy. Events are `started`, `progress` and a final `result`.
  /// The download is checked against the storage cap first and may evict the
  /// least recently used cached OTA to make room.
  @squadronMethod
  Stream<Map<String, Object?>> cacheOta(Map<String, Object?> req) async* {
    final input = req['ota'];
    if (input is! Map || input['kind'] != 'catalog') {
      throw const BuildException('Only a catalog OTA can be cached.');
    }
    final value = input['entry'];
    if (value is! Map) {
      throw const BuildException('Select an OTA catalog version.');
    }
    final entry = Map<String, dynamic>.from(value);
    final workspace = await _openStoreWorkspace(req['store']);
    final apiBase = req['apiBase'] as String? ?? '';
    final cache = _otaCache(
      workspace,
      apiBase,
    );
    final budget = _budgetFor(
      req['store'],
      evict: (needed) => cache.evict(bytesNeeded: needed),
    );
    final label = otaEntryLabel(entry);
    await for (final event in cache.download(entry, budget: budget)) {
      switch (event) {
        case OtaCacheStarted(:final key, :final total, :final resumedFrom):
          yield {
            'type': 'started',
            'key': key,
            'label': label,
            'total': total,
            'resumedFrom': resumedFrom,
          };
        case OtaCacheProgress(:final key, :final bytes, :final total):
          yield {
            'type': 'progress',
            'key': key,
            'label': label,
            'done': bytes,
            'total': total,
          };
        case OtaCacheFinished(:final entry):
          yield {
            'type': 'result',
            'key': entry.key,
            'label': entry.label,
            'bytes': entry.bytes,
            'complete': entry.complete,
            'sha256': entry.sha256,
            'etag': entry.etag,
            'lastUsed': entry.lastUsedAt.toIso8601String(),
          };
      }
    }
  }

  /// Copies one catalog OTA, byte for byte, into a file outside the stores.
  ///
  /// The request names `ota: {"kind": "catalog", "entry": <release>}`,
  /// `apiBase` and `destination` (the shapes `exportVirtual` accepts: a
  /// save-picker `FileSystemFileHandle`, the page's streamed download, or
  /// `{"kind": "path", "path": "<file>"}` on the VM). Events are `started`,
  /// `progress` and a final `result` with `label`, `bytes` and `sha256`. The
  /// copy needs no app storage and is not checked against the budget; a
  /// cancelled or failed copy leaves a partial file at the destination.
  @squadronMethod
  Stream<Map<String, Object?>> saveOta(Map<String, Object?> req) async* {
    final input = req['ota'];
    if (input is! Map || input['kind'] != 'catalog') {
      throw const BuildException('Only a catalog OTA can be downloaded.');
    }
    final value = input['entry'];
    if (value is! Map) {
      throw const BuildException('Select an OTA catalog version.');
    }
    final entry = Map<String, dynamic>.from(value);
    final label = otaEntryLabel(entry);
    final destination = req['destination'];
    final streamed = destination is Map && destination['kind'] == 'stream';
    final sources = _catalogSources(
      req['apiBase'] as String? ?? '',
    );
    if (!streamed) {
      final workspace = await openOtaDestination(
        destination,
        otaEntryDigest(entry),
      );
      final cache = OtaCache(workspace: workspace, sources: sources);
      await for (final event in cache.download(entry)) {
        switch (event) {
          case OtaCacheStarted(:final total, :final resumedFrom):
            yield {
              'type': 'started',
              'label': label,
              'total': total,
              'resumedFrom': resumedFrom,
            };
          case OtaCacheProgress(:final bytes, :final total):
            yield {
              'type': 'progress',
              'label': label,
              'done': bytes,
              'total': total,
            };
          case OtaCacheFinished(:final entry):
            yield {
              'type': 'result',
              'label': label,
              'bytes': entry.length,
              'sha256': entry.sha256,
            };
        }
      }
      return;
    }
    final declared = entry['size'] is int ? entry['size'] as int : 0;
    final reader = await CatalogOtaReader.open(sources, entry);
    ByteSink? sink;
    try {
      final total = reader.length;
      if (declared > 0 && declared != total) {
        throw BuildException(
          'The OTA server reports $total bytes but the catalog says $declared.',
        );
      }
      sink = await openExportSink(destination);
      yield {
        'type': 'started',
        'label': label,
        'total': total,
        'resumedFrom': 0,
      };
      final hasher = StreamingSha256();
      var written = 0;
      await for (final bytes in orderedOtaReads(
        reader,
        chunkBytes: _saveChunkBytes,
      )) {
        await sink.write(bytes, written);
        hasher.add(bytes);
        written += bytes.length;
        yield {
          'type': 'progress',
          'label': label,
          'done': written,
          'total': total,
        };
      }
      await sink.truncate(written);
      await sink.close();
      sink = null;
      yield {
        'type': 'result',
        'label': label,
        'bytes': written,
        'sha256': hasher.hex,
      };
    } finally {
      await sink?.close();
      await reader.close();
    }
  }

  /// Deletes one cached OTA by its catalog entry digest.
  @squadronMethod
  Future<Map<String, Object?>> evictCachedOta(Map<String, Object?> req) async {
    final key = req['key'];
    if (key is! String || key.isEmpty) {
      throw const BuildException('Missing cached OTA key.');
    }
    final workspace = await _openStoreWorkspace(req['store']);
    final cache = _otaCache(
      workspace,
      req['apiBase'] as String? ?? '',
    );
    final matching = (await cache.entries()).where(
      (entry) => entry.key == key,
    );
    final before = matching.isEmpty ? null : matching.first;
    final removed = await cache.remove(key);
    final report = await _budgetFor(req['store']).snapshot();
    return {
      'key': key,
      'removed': removed,
      'freed': removed ? before?.bytes ?? 0 : 0,
      'storage': _budgetMap(report),
    };
  }

  /// Streams the virtual package as a flasher ZIP into the destination the
  /// user picked, outside the app's stores.
  ///
  /// The request is the prepare request's `virtual` and `selection`, plus
  /// `destination`: the `FileSystemFileHandle` from the save picker on the web,
  /// or `{"kind": "path", "path": "<file>"}` on the VM. Events are a `step`
  /// line, `progress` while images stream and the export's own `result`
  /// (`job`, `format`, `sha256`, `bytes`, `entries`). A cancelled or failed
  /// export leaves a partial, invalid ZIP at the destination.
  @squadronMethod
  Stream<Map<String, Object?>> exportVirtual(Map<String, Object?> req) async* {
    final tables = await _readTables(req);
    final selectionMap = req['selection'];
    final selection = tables.selection(
      _stringArg(selectionMap, 'device', 'selection'),
      _stringArg(selectionMap, 'kind', 'selection'),
      _stringArg(selectionMap, 'region', 'selection'),
    );
    if (!await loadNative()) {
      throw const flash_model.FlashException(
        'The OTA decoder is unavailable in this place.',
      );
    }
    final package = await _openVirtualPackage(req, selection);
    ByteSink? sink;
    try {
      final upstream = UpstreamAssets(req['upstreamBase'] as String? ?? '');
      sink = await openExportSink(req['destination']);
      yield {
        'type': 'step',
        'index': 1,
        'total': 2,
        'title': 'Write flasher ZIP',
      };
      Map<String, Object?>? result;
      await for (final event in exportVirtualZip(
        package: package,
        upstream: upstream,
        sink: sink,
      )) {
        if (event['type'] == 'result') {
          result = event;
        } else {
          yield event;
        }
      }
      if (result == null) {
        throw const flash_model.FlashException(
          'The ZIP export ended without a result.',
        );
      }
      yield result;
    } finally {
      await sink?.close();
      await package.close();
    }
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

  /// Granted fastboot devices. Never opens a browser chooser.
  @squadronMethod
  Future<Map<String, Object?>> fastbootDevices() async {
    try {
      final devices = await _fastbootTransport().devices();
      return {
        'devices': [for (final device in devices) device.toMap()],
      };
    } on LinkFailure catch (error) {
      return {'devices': <Map<String, Object?>>[], 'error': error.toMap()};
    }
  }

  /// Read-only preparation of the OTA-direct package. Returns the plan,
  /// prompts and a token that binds the device, the exact request, and the
  /// inspected package.
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
      final virtual = _virtualArg(req);
      if (virtual == null) {
        throw const BuildException(
          'A virtual OTA source is required to prepare a flash.',
        );
      }
      final serial = req['serial'];
      if (serial is! String || serial.trim().isEmpty) {
        throw const BuildException('Choose a fastboot device serial.');
      }
      final answers = _flashAnswers(req['answers']);
      final required = await _productRequired(
        selection,
        answers,
        serial,
        _fastbootTransport(),
      );
      if (required != null) return required;
      final virtualPackage = await _openVirtualPackage(req, selection);
      final job = virtualPackage.job;
      final storeKey = 'virtual|${_storeKey(virtual['bloat'])}';
      if (req['job'] != null && req['job'] != job) {
        await virtualPackage.close();
        throw const flash_model.FlashException(
          'The virtual OTA identity changed. Prepare again.',
        );
      }
      final lockKey = '$storeKey|$job';
      if (_jobLocks.containsKey(lockKey)) {
        await virtualPackage.close();
        throw const flash_model.FlashException('This job is being flashed.');
      }
      try {
        final token = _newToken();
        final prepared = await flash_prepare.prepareFlash(
          package: virtualPackage,
          selection: selection,
          answers: answers,
          serial: serial,
          transport: _fastbootTransport(),
          job: job,
          upstreamBase: req['upstreamBase'] as String? ?? '',
          storeKey: storeKey,
          token: token,
        );
        if (prepared.resolved) {
          // One direct-flash confirmation is outstanding at a time: a new
          // preparation replaces every earlier token.
          _prepared.clear();
          _prepared[token] = _PreparedEntry(
            prepared,
            lockKey,
            Map<String, Object?>.unmodifiable(
              Map<String, Object?>.from(virtual['bloat']! as Map),
            ),
          );
        }
        return prepared.toMap();
      } finally {
        await virtualPackage.close();
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

  /// Explicitly resends the failed step from byte zero, then continues.
  @squadronMethod
  Stream<Map<String, Object?>> retryStep(Map<String, Object?> req) =>
    _resume(req, reboot: false);

  /// Reboots to the failed step's required mode before resending it.
  @squadronMethod
  Stream<Map<String, Object?>> rebootRetry(Map<String, Object?> req) =>
    _resume(req, reboot: true);

  Stream<Map<String, Object?>> _resume(Map<String, Object?> req, {required bool reboot}) {
    final controller = StreamController<Map<String, Object?>>();
    final run = _FlashRun(this, req, controller, retry: true, reboot: reboot);
    controller.onListen = () { unawaited(run.start()); };
    controller.onCancel = run.cancel;
    return controller.stream;
  }

  /// Ends an active or paused run; no further device commands are sent.
  @squadronMethod
  Future<Map<String, Object?>> stopRun(Map<String, Object?> req) async {
    final id = req['runId'];
    final active = _active[id];
    if (active != null) return {'receipt': await active.stop()};
    final paused = _paused.remove(id);
    if (paused == null) throw const flash_model.FlashException('Unknown flash run.');
    _jobLocks.remove(paused.entry.lockKey);
    return {'receipt': {...paused.receipt, 'status': 'stopped',
      'finishedAt': DateTime.now().toUtc().toIso8601String()}};
  }
}

final class _PreparedEntry {
  const _PreparedEntry(this.prepared, this.lockKey, this.store);
  final flash_prepare.PreparedFlash prepared;
  final String lockKey;
  final Map<String, Object?>? store;
}

final class _PausedFlash {
  const _PausedFlash(this.entry, this.req, this.receipt);
  final _PreparedEntry entry;
  final Map<String, Object?> req;
  final Map<String, Object?> receipt;
}

final class _FlashRun {
  _FlashRun(this._service, this._req, this._controller, {this.retry = false, this.reboot = false});
  final FlasherService _service;
  final Map<String, Object?> _req;
  final StreamController<Map<String, Object?>> _controller;
  final bool retry;
  final bool reboot;
  final FlashCancellation _cancellation = FlashCancellation();
  final Completer<void> _done = Completer<void>();
  Map<String, Object?>? _receipt;
  bool _cancelled = false;
  bool _stopped = false;
  void _emit(Map<String, Object?> event) {
    if (!_cancelled && !_controller.isClosed) _controller.add(event);
  }

  Future<void> start() async {
    VirtualFlashPackage? package;
    _PreparedEntry? entry;
    String? id;
    Map<String, Object?>? retryRequest;
    Map<String, Object?>? previous;
    var paused = false;
    try {
      Map<String, Object?> request;
      if (retry) {
        final rawId = _req['runId'];
        final saved = _service._paused.remove(rawId);
        if (saved == null) throw const flash_model.FlashException('Unknown or non-paused flash run.');
        id = rawId! as String;
        entry = saved.entry;
        request = saved.req;
        previous = saved.receipt;
        retryRequest = request;
      } else {
        final token = _req['confirmationToken'];
        if (token is! String || token.isEmpty) throw const flash_model.FlashException('A confirmation token from prepareFlash is required.');
        id = token;
        entry = _service._prepared.remove(token);
        if (entry == null) throw const flash_model.FlashException('Unknown, expired or used confirmation token.');
        request = Map<String, Object?>.from(_req);
      }
      _service._active[id] = this;
      _receipt = {
        'version': 1, 'runId': id, 'job': entry.prepared.job,
        'serial': entry.prepared.serial, 'device': entry.prepared.selection.device,
        'kind': entry.prepared.selection.kind, 'region': entry.prepared.selection.region,
        'otaVersion': entry.prepared.version, 'status': 'preparing',
        'package': (entry.prepared.package as VirtualFlashPackage).receipt(),
        'writes': <Map<String, Object?>>[], 'steps': <Map<String, Object?>>[],
        'verification': {'status': 'not-run'}, 'uncertain': false,
      };
      _emit({'type': 'run', 'runId': id});
      final virtual = _virtualArg(request);
      if (virtual == null) throw const flash_model.FlashException('The flash request has no virtual OTA source.');
      final storeKey = 'virtual|${_storeKey(virtual['bloat'])}';
      if (!entry.prepared.binding.matches(request, storeKey: storeKey)) {
        throw const flash_model.FlashException('The request no longer matches the confirmed plan.');
      }
      if (entry.store == null || !await sameFlashStore(entry.store!,
          Map<String, Object?>.from(virtual['bloat']! as Map))) {
        throw const flash_model.FlashException('The confirmed bloat store changed.');
      }
      package = await _openVirtualPackage(request, entry.prepared.selection);
      if (await flash_prepare.packageDigest(package) != entry.prepared.binding.packageDigest) {
        throw const flash_model.FlashException('The confirmed OTA, layout or bloat changed.');
      }
      await flash_prepare.verifyPreparedImages(entry.prepared, package: package);
      final owner = _service._jobLocks[entry.lockKey];
      if (owner != null && owner != id) throw const flash_model.FlashException('This job is already being flashed.');
      _service._jobLocks[entry.lockKey] = id;
      final receipt = await applyConfirmedFlash(entry.prepared.withPackage(package),
        _service._fastbootTransport(), await PlaceInfo.current(),
        emit: _emit, cancellation: _cancellation, previousReceipt: previous, rebootRetry: reboot);
      receipt['runId'] = id;
      receipt['virtual'] = await package.snapshot();
      receipt['persistenceWarnings'] = <String>[];
      if (_stopped) receipt['status'] = 'stopped';
      _receipt = receipt;
      paused = !_cancelled && !_stopped && (receipt['status'] == 'failed' || receipt['status'] == 'uncertain');
      if (paused) _service._paused[id] = _PausedFlash(entry, request, receipt);
      _emit({'type': 'result', 'runId': id, 'status': receipt['status'],
        'canRetry': paused, 'receipt': receipt});
    } on Object catch (error, stack) {
      if (retry && entry != null && id != null && previous != null && retryRequest != null && !_cancelled && !_stopped) {
        final failure = error is LinkFailure ? error.toMap()
          : error is flash_model.FlashException ? error.failure(stage: 'retry-preflight', stack: '$stack')
          : <String, Object?>{'message': '$error', 'stage': 'retry-preflight', 'stack': '$stack'};
        final receipt = <String, Object?>{...previous, 'reason': failure['message'],
          'failure': failure, 'finishedAt': DateTime.now().toUtc().toIso8601String()};
        _receipt = receipt;
        paused = true;
        _service._paused[id] = _PausedFlash(entry, retryRequest, receipt);
        _emit({'type': 'failure', 'stepIndex': receipt['stepIndex'],
          'status': receipt['status'], 'reason': receipt['reason']});
        _emit({'type': 'result', 'runId': id, 'status': receipt['status'],
          'canRetry': true, 'receipt': receipt});
      } else if (!_cancelled && !_controller.isClosed) {
        _controller.addError(error, stack);
      }
    } finally {
      try { await package?.close(); } on Object catch (error) {
        final cleanup = _receipt?['cleanupErrors'];
        if (cleanup is List) cleanup.add('$error');
      }
      if (id != null) {
        if (identical(_service._active[id], this)) _service._active.remove(id);
        if (!paused && entry != null && _service._jobLocks[entry.lockKey] == id) {
          _service._jobLocks.remove(entry.lockKey);
        }
      }
      if (!_done.isCompleted) _done.complete();
      if (!_controller.isClosed) await _controller.close();
    }
  }

  Future<Map<String, Object?>> stop() async {
    _stopped = true;
    _cancellation.cancel('user stopped the flash');
    await _done.future;
    final receipt = _receipt;
    if (receipt == null) throw const flash_model.FlashException('The flash stopped before an execution receipt existed.');
    return {...receipt, 'status': 'stopped'};
  }
  Future<void> cancel() async {
    _cancelled = true;
    _cancellation.cancel('subscriber cancelled the flash');
    await _done.future;
  }
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

Map<String, Object?>? _virtualArg(Map<String, Object?> req) {
  final value = req['virtual'];
  if (value == null) return null;
  if (value is! Map || value['ota'] is! Map || value['bloat'] is! Map) {
    throw const flash_model.FlashException('A virtual flash requires virtual.ota and virtual.bloat.');
  }
  if (req['output'] != null || req['hosted'] != null) {
    throw const flash_model.FlashException('A virtual flash cannot name output or hosted.');
  }
  return Map<String, Object?>.from(value);
}

Future<Map<String, Object?>?> _productRequired(
  Selection selection, Map<String, String> answers, String serial, FastbootTransport transport,
) async {
  if (deviceIdentities[selection.dev]?.product != null ||
      (answers['product'] ?? '').trim().isNotEmpty) {
    return null;
  }
  final device = await transport.open(serial);
  try {
    if (device.serial != serial) {
      throw const flash_model.FlashException('The connected serial changed.');
    }
    final product = await flash_prepare.readProduct(device);
    return {
      'productRequired': true,
      'serial': serial,
      'observedProduct': product,
      'message': 'Connected product: $product. No confirmed product mapping '
          'exists for ${selection.device}. Check the selected model, then '
          'type the product explicitly to continue.',
    };
  } finally {
    await device.close();
  }
}

Future<VirtualFlashPackage> _openVirtualPackage(
  Map<String, Object?> req, Selection selection,
) async {
  final opened = <OtaArchive>[];
  try {
    final virtual = _virtualArg(req)!;
    if (!await loadNative()) {
      throw const flash_model.FlashException('The OTA decoder is unavailable in this place.');
    }
    final conversion = selection.builder == 'BUILD_ACE6_OOS.sh';
    if (conversion && virtual['base'] is! Map) {
      throw const flash_model.FlashException('Ace 6 OxygenOS requires virtual.base.');
    }
    if (!conversion && virtual['base'] != null) {
      throw const flash_model.FlashException('This selection does not consume virtual.base.');
    }
    if (virtual['donor'] != null) {
      throw const flash_model.FlashException('The ODM donor is selected from the catalog, not supplied by the caller.');
    }
    final bloat = await _openStoreWorkspace(virtual['bloat']);
    Future<({OtaArchive archive, Map<String, Object?> identity})> open(Map<String, Object?> input) async {
      final identity = switch (input['kind']) {
        'file' => await localOtaIdentity(input['file']!),
        'url' => <String, Object?>{'kind': 'url', 'url': input['url']},
        'catalog' => <String, Object?>{'kind': 'catalog', 'entry': input['entry']},
        _ => throw flash_model.FlashException('Unknown virtual OTA input: ${input['kind']}.'),
      };
      final archive = await _openOtaArchive({...req, 'ota': input});
      opened.add(archive);
      final catalogEntry = input['entry'];
      if (input['kind'] == 'catalog' && catalogEntry is Map) {
        final size = catalogEntry['size'];
        if (size is int && size > 0 && archive.length != size) {
          throw const flash_model.FlashException('The OTA size differs from its catalog entry.');
        }
      }
      return (archive: archive, identity: identity);
    }
    final input = Map<String, Object?>.from(virtual['ota']! as Map);
    final target = await open(input);
    final base = conversion ? await open(Map<String, Object?>.from(virtual['base']! as Map)) : null;
    OtaArchive? donor;
    Map<String, Object?>? donorIdentity;
    if (needsMatchedOdm(selection.device, selection.kind, selection.region)) {
      final transport = HttpCatalogTransport();
      final Map<String, dynamic> data;
      try {
        data = await CatalogClient(transport: transport, base: _base(req['apiBase'] as String? ?? '')).loadCatalog();
      } finally { transport.close(); }
      final actualTarget = releaseFromMetadata(data, 'OP 15R', selection.region, target.archive.fields);
      final supplied = input['kind'] == 'catalog' ? Map<String, dynamic>.from(input['entry']! as Map) : null;
      if (supplied != null && supplied['id'] != actualTarget['id']) {
        throw const flash_model.FlashException('The target download returned a different OTA version. ODM matching stopped.');
      }
      final patch = patchDate(target.archive.fields['post-security-patch-level']);
      final release = supplied ?? actualTarget;
      if (patch != patchDate(release['security_patch'])) {
        throw const flash_model.FlashException('The target OTA security patch differs from its catalog entry.');
      }
      final matched = matchingOdm(data, release);
      final openedDonor = await open({'kind': 'catalog', 'entry': matched});
      donor = openedDonor.archive;
      donorIdentity = openedDonor.identity;
      if (patchDate(donor.fields['post-security-patch-level']) != patch ||
          releaseFromMetadata(data, 'OP ACE 6T', 'CN', donor.fields)['id'] != matched['id']) {
        throw const flash_model.FlashException('The donor OTA identity or security patch differs from its matched catalog entry.');
      }
    }
    final manifest = await _readBloatManifest(req);
    final tables = await _readTables(req);
    return await VirtualFlashPackage.load(
      ota: target.archive, selection: selection, bloat: bloat,
      bloatManifest: manifest, sourceIdentity: target.identity,
      base: base?.archive, baseIdentity: base?.identity,
      donor: donor, donorIdentity: donorIdentity,
      vulnerableAbl: virtual['vulnerableAbl'] as bool?,
      superSize: selection.kind.contains('Super') ? tables.superSize(selection.dev, selection.region) : null,
      // The package owns its decode workers: they start on its first decode
      // and stop when it closes.
      decoder: PoolOpDecoder(),
    );
  } on Object catch (error) {
    for (final archive in opened) { await archive.close(); }
    if (error is flash_model.FlashException) rethrow;
    throw flash_model.FlashException('Cannot open virtual package: $error');
  }
}

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

/// The OTA cache over [workspace], keyed by catalog entry digest.
///
/// The cache directory is `ota-cache/` inside the store that also holds the
/// bloat images, so a user who picks one folder gets one place for app data.
OtaCache _otaCache(
  Workspace workspace,
  String apiBase,
) => OtaCache(workspace: workspace, sources: _catalogSources(apiBase));

/// Catalog OTA bytes use the same edge block source on every host.
CatalogOtaSourceFactory _catalogSources(String apiBase) =>
    CatalogOtaSourceFactory(apiBase: apiBase);

/// Bytes per ranged read while a catalog OTA is copied to a file.
const int _saveChunkBytes = 8 << 20;

/// The storage budget for [store].
///
/// OPFS and a VM path have a platform capacity reading. A folder the user
/// picked is outside the origin's quota, so only the app cap applies; the
/// platform cannot report how full it is.
StorageBudget _budgetFor(
  Object? store, {
  Future<int> Function(int needed)? evict,
}) {
  final kind = store is Map ? '${store['kind']}' : '';
  if (kind == 'directory') {
    return StorageBudget(
      estimateSource: const UnknownStorageEstimate(),
      evictDefault: evict,
    );
  }
  return StorageBudget(
    estimateSource: PlatformStorageEstimateSource(path: _storePath(store)),
    evictDefault: evict,
  );
}

Map<String, Object?> _budgetMap(StorageBudgetReport report) => {
  'cap': report.cap,
  'usage': report.usage,
  'quota': report.quota,
  'available': report.available,
};

/// The volume or directory a store lives in, for the VM capacity reading.
String _storePath(Object? store) {
  final path = store is Map ? store['path'] : null;
  return path is String && path.isNotEmpty ? path : '.';
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
      final release = Map<String, dynamic>.from(entry);
      final remote = await CatalogOtaSourceFactory(
        apiBase: apiBase,
        bucketBase: req['otaBucketBase'] as String?,
      ).open(release);
      return _guarded(
        remote.source,
        () => OtaArchive.open(remote.source, remote: true),
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
