import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flasher_web_core/flasher_web_core.dart'
    hide OtaCache, OtaCacheEntry;

import 'active_pins.dart';
import 'bloat_cache.dart';
import 'build_runner.dart';
import 'catalog_gateway.dart';
import 'config.dart';
import 'errors.dart';
import 'job.dart';
import 'leases.dart';
import 'loopback_host.dart';
import 'ota_cache.dart';
import 'request.dart';
import 'store.dart';
import 'upstream_snapshot.dart';
import 'util.dart';

final class SubmitResult {
  const SubmitResult({
    required this.job,
    required this.reused,
    required this.statusCode,
  });

  final HostedJob job;
  final bool reused;
  final int statusCode;
}

/// Owns the queue, input caches, build processes, publication and eviction.
final class HostedService {
  HostedService({
    required this.config,
    required this.snapshot,
    required this.store,
    required this.catalog,
    required this.otaCache,
    required this.bloatCache,
    required this.launcher,
    required this.leases,
    DateTime Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().toUtc());

  final HostedConfig config;
  final UpstreamSnapshot snapshot;
  final HostedStore store;
  final CatalogGateway catalog;
  final OtaCache otaCache;
  final BloatCache bloatCache;
  final BuildLauncher launcher;
  final LeaseManager leases;
  final DateTime Function() _clock;

  final Map<String, HostedJob> _jobs = {};
  final Map<String, String> _requestIndex = {};
  final Map<String, String> _cacheIndex = {};
  final Map<String, Future<void>> _sharedBuilds = {};
  final Map<String, BuildProcess> _running = {};
  final Map<String, Set<String>> _activeResources = {};
  final Map<String, DateTime> _lastPersist = {};
  final Map<String, _LockEntry> _submitLocks = {};
  final Map<String, int> _jobReservations = {};
  final _Mutex _admission = _Mutex();
  final _Mutex _evictionLock = _Mutex();
  Future<void>? _evictionTask;
  int? _pendingEvictionTarget;
  final Map<String, JobLease> _handoffPins = {};
  late final ActivePinManager _activePins = ActivePinManager(
    maxPerJob: config.maxActiveOperationsPerJob,
    maxTotal: config.maxActiveOperationsTotal,
  );
  late final _Semaphore _gate = _Semaphore(config.concurrency);
  Timer? _maintenance;
  int _usedBytes = 0;
  int _freeCache = 0;
  DateTime _freeCheckedAt = DateTime.fromMillisecondsSinceEpoch(0);
  final Set<Future<void>> _tasks = {};
  bool _closing = false;

  /// Loads published jobs and removes interrupted work.
  Future<void> open() async {
    await store.cleanupWorkOnStartup();
    await otaCache.cleanupTemp();
    _jobs.addAll(await store.loadPublished());
    for (final job in _jobs.values) {
      _requestIndex[job.request.fingerprint] = job.id;
      if (job.state == HostedState.succeeded && job.cacheKey != null) {
        _cacheIndex[job.cacheKey!] = job.id;
      }
    }
    _usedBytes = await _measureUsed();
    await _evict(target: config.cacheBudgetBytes - config.minFreeBytes);
  }

  /// Starts the periodic retention/budget pass.
  void startMaintenance() {
    _maintenance ??= Timer.periodic(
      const Duration(minutes: 5),
      (_) => _track(maintenance()),
    );
  }

  Future<void> close() async {
    _closing = true;
    _maintenance?.cancel();
    for (final process in _running.values.toList()) {
      process.kill();
    }
    final eviction = _evictionTask;
    if (eviction != null) await eviction;
    // Drain publication, eviction, touch and build tasks before the caller
    // removes the data root. The timeout prevents a wedged fake build from
    // blocking process shutdown forever.
    for (var pass = 0; pass < 10; pass++) {
      final pending = _tasks.toList();
      if (pending.isEmpty) break;
      await Future.wait(
        [for (final task in pending) task.catchError((Object _, StackTrace _) {})],
      ).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    }
  }

  Future<void> _pinResource(String jobId, String resource) =>
      _evictionLock.run(() async {
        _activeResources.putIfAbsent(jobId, () => {}).add(resource);
      });

  Future<void> _unpinResources(String jobId) =>
      _evictionLock.run(() async {
        _activeResources.remove(jobId);
      });

  Future<void> _endActive(String jobId) =>
      _evictionLock.run(() async => _activePins.release(jobId));

  Future<bool> _beginSourceOperation(HostedJob source) =>
      _evictionLock.run(() async {
        if (!await _reusable(source)) return false;
        _activePins.acquire(source.id);
        return true;
      });

  Future<JobLease> beginInternalOperation(
    String jobId, {
    Duration? ttl,
  }) => _evictionLock.run(() async {
    _activePins.acquire(jobId);
    try {
      return leases.acquireInternal(jobId, ttl: ttl);
    } on Object {
      _activePins.release(jobId);
      rethrow;
    }
  });

  Future<void> endInternalOperation(JobLease lease) async {
    leases.releaseInternal(lease);
    await _endActive(lease.jobId);
  }

  /// Coalesces one short handoff pin per job. Cache hits do not consume one
  /// internal lease each, and pin exhaustion is propagated instead of
  /// dropping the validated cache index and rebuilding.
  Future<bool> _handoffPin(HostedJob job) =>
      _evictionLock.run(() async {
        final now = _clock();
        final existing = _handoffPins[job.id];
        if (existing != null && existing.expiresAt.isAfter(now)) {
          if (await _reusable(job)) return true;
          _handoffPins.remove(job.id);
          return false;
        }
        if (existing != null) _handoffPins.remove(job.id);
        if (!await _reusable(job)) return false;
        final lease = leases.acquireInternal(
          job.id,
          ttl: config.cacheHandoffTtl,
        );
        _handoffPins[job.id] = lease;
        return true;
      });

  void _track(Future<void> task) {
    _tasks.add(task);
    unawaited(
      task
          .then<void>((_) {}, onError: (Object _, StackTrace _) {})
          .whenComplete(() => _tasks.remove(task)),
    );
  }

  Future<SubmitResult> submit(HostedJobRequest request) {
    final fingerprint = request.fingerprint;
    final entry = _submitLocks.putIfAbsent(fingerprint, _LockEntry.new);
    entry.references++;
    return entry.mutex
        .run(() => _submitLocked(request))
        .whenComplete(() {
          entry.references--;
          if (entry.references == 0 &&
              identical(_submitLocks[fingerprint], entry)) {
            _submitLocks.remove(fingerprint);
          }
        });
  }

  Future<SubmitResult> _submitLocked(HostedJobRequest request) =>
      _admission.run(() => _submitLockedBody(request));

  Future<SubmitResult> _submitLockedBody(HostedJobRequest request) async {
    final selection = _selection(request);
    final targetMap = _targets(request);
    final otaTarget = targetMap['ota']!;
    final baseTarget = targetMap['base'];
    if (baseTarget != null && request.baseCatalogId == null) {
      throw const HostedException(
        'base_required',
        'This selection also needs a BASE OTA catalog id.',
      );
    }
    if (baseTarget == null && request.baseCatalogId != null) {
      throw const HostedException(
        'base_unused',
        'This selection does not use a BASE OTA.',
      );
    }
    if (selection.dev == 'X9U' && request.vulnerableAbl == null) {
      throw const HostedException(
        'vulnerable_abl_required',
        'Choose vulnerableAbl true or false for X9U.',
      );
    }
    if (request.vulnerableAbl == true && selection.dev != 'X9U') {
      throw const HostedException(
        'vulnerable_abl_unused',
        'vulnerableAbl is available only for X9U.',
      );
    }

    // Only an identical request that is still queued or running is joined.
    // Completed artifacts must be revalidated through the full input key.
    final existing = _requestIndex[request.fingerprint];
    if (existing != null) {
      final job = _jobs[existing];
      if (job != null &&
          (job.state == HostedState.queued ||
              job.state == HostedState.running)) {
        _track(_useJob(job, force: true));
        return SubmitResult(job: job, reused: true, statusCode: 202);
      }
      if (job == null || job.finished) {
        _requestIndex.remove(request.fingerprint);
      }
    }

    final otaRelease = await catalog.release(
      role: 'ota',
      target: otaTarget,
      id: request.catalogId,
    );
    CatalogRelease? baseRelease;
    if (baseTarget != null) {
      baseRelease = await catalog.release(
        role: 'base',
        target: baseTarget,
        id: request.baseCatalogId!,
      );
    }

    final requiredBytes = _requiredStorage(
      request: request,
      selection: selection,
      ota: otaRelease,
      base: baseRelease,
    );
    // A finished artifact can be reused before any download when every OTA
    // input is already retained and no dynamic ODM lookup is involved.
    if (!needsMatchedOdm(request.device, request.kind, request.region)) {
      final otaLookup = await otaCache.lookup(otaRelease);
      CachedOta? baseLookup;
      if (baseRelease != null) {
        baseLookup = await otaCache.lookup(baseRelease);
      }
      if (otaLookup != null && (baseRelease == null || baseLookup != null)) {
        final key = _cacheKey(
          request: request,
          ota: otaLookup.descriptor,
          base: baseLookup?.descriptor,
          odm: null,
          bloat: _selectedBloatHashes(selection),
        );
        final cachedId = _cacheIndex[key];
        final cached = cachedId == null ? null : _jobs[cachedId];
        if (cached != null && await _handoffPin(cached)) {
          await _useJob(cached, force: true);
          return SubmitResult(job: cached, reused: true, statusCode: 200);
        }
        if (cachedId != null) _cacheIndex.remove(key);
      }
    }

    final active = _jobs.values
        .where(
          (job) =>
              job.state == HostedState.queued || job.state == HostedState.running,
        )
        .length;
    if (active >= config.maxQueue) {
      throw const HostedException(
        'queue_full',
        'The hosted build queue is full. Try again later.',
        status: 429,
      );
    }
    await _ensureCapacity(requiredBytes);
    final now = _clock();
    final job = HostedJob(
      id: randomId(),
      request: request,
      createdAt: now,
      updatedAt: now,
      lastUsedAt: now,
    );
    _jobs[job.id] = job;
    _jobReservations[job.id] = requiredBytes;
    _requestIndex[request.fingerprint] = job.id;
    try {
      await store.saveActive(job);
    } on Object {
      _jobs.remove(job.id);
      _jobReservations.remove(job.id);
      _requestIndex.remove(request.fingerprint);
      rethrow;
    }
    final task = _runJob(job, otaRelease, baseRelease);
    _track(task);
    unawaited(task);
    return SubmitResult(job: job, reused: false, statusCode: 202);
  }

  HostedJob? job(String id) {
    if (!urlSafeId.hasMatch(id)) return null;
    return _jobs[id];
  }

  Map<String, Object?>? publicJob(String id, {bool? hitOverride}) {
    final job = _jobs[id];
    if (job == null) return null;
    _track(_useJob(job));
    final json = job.publicJson(retention: config.retention);
    if (hitOverride != null) {
      final cache = json['cache'];
      if (cache is Map<String, Object?>) cache['hit'] = hitOverride;
    }
    return json;
  }

  Future<File> artifact(String id) async {
    final job = _jobs[id];
    if (job == null || job.state != HostedState.succeeded) {
      throw const HostedException(
        'artifact_missing',
        'The job has no retained artifact.',
        status: 404,
      );
    }
    final file = store.artifactFile(id);
    await store.verifyArtifact(job);
    await _useJob(job);
    return file;
  }

  Future<Uint8List> manifest(String id) async {
    final job = _jobs[id];
    if (job == null ||
        job.state != HostedState.succeeded ||
        job.manifestSha256 == null) {
      throw const HostedException(
        'manifest_missing',
        'The job has no retained manifest.',
        status: 404,
      );
    }
    final file = store.manifestFile(id);
    if (!await file.exists()) {
      throw const HostedException(
        'manifest_missing',
        'The job has no retained manifest.',
        status: 404,
      );
    }
    final bytes = await readBounded(file, 1024 * 1024);
    if (sha256Hex(bytes) != job.manifestSha256) {
      throw const HostedException(
        'manifest_changed',
        'The manifest no longer matches its record.',
        status: 500,
      );
    }
    await _useJob(job);
    return bytes;
  }

  Future<JobLease> acquireLease(String id) =>
      _evictionLock.run(() async {
    final job = _jobs[id];
    if (job == null || job.state != HostedState.succeeded) {
      throw const HostedException(
        'lease_not_ready',
        'The job has no artifact to lease.',
        status: 409,
      );
    }
    if (!store.artifactFile(id).existsSync()) {
      throw const HostedException(
        'artifact_missing',
        'The artifact is no longer retained.',
        status: 410,
      );
    }
    final lease = leases.acquire(id);
    _track(_useJob(job, force: true));
    return lease;
      });

  Future<JobLease> renewLease(String id, String leaseId) =>
      _evictionLock.run(() async {
    final job = _jobs[id];
    if (job == null ||
        job.state != HostedState.succeeded ||
        !store.artifactFile(id).existsSync()) {
      try {
        leases.release(id, leaseId);
      } on Object {
        // The expired lease is already gone.
      }
      throw const HostedException(
        'lease_expired',
        'The job is no longer retained; renew the selection.',
        status: 410,
      );
    }
    final lease = leases.renew(id, leaseId);
    _track(_useJob(job, force: true));
    return lease;
      });

  void releaseLease(String id, String leaseId) {
    leases.release(id, leaseId);
    final job = _jobs[id];
    if (job != null) _track(_useJob(job, force: true));
  }

  Future<JobLease> acquireInternalLease(String id, {Duration? ttl}) =>
      _evictionLock.run(
        () async => leases.acquireInternal(id, ttl: ttl),
      );

  void releaseInternalLease(JobLease lease) => leases.releaseInternal(lease);

  Future<void> maintenance() async {
    try {
      await _evict(target: config.cacheBudgetBytes - _reservedTotal);
    } on Object catch (error, stack) {
      stderr.writeln('hosted maintenance failed: $error\n$stack');
    }
  }

  Future<void> _runJob(
    HostedJob job,
    CatalogRelease otaRelease,
    CatalogRelease? baseRelease,
  ) async {
    LoopbackOtaHost? loopback;
    var gate = false;
    try {
      await _gate.acquire();
      gate = true;
      job.state = HostedState.running;
      job.event({
        'type': 'log',
        'text': 'Hosted job started; preparing approved inputs.',
      });
      await store.saveActive(job);

      await _pinResource(job.id, 'ota-id:${otaRelease.id}');
      final ota = await otaCache.materialize(otaRelease);
      await _pinResource(job.id, 'ota:${ota.sha256}');
      _consumeReservation(job.id, ota.size);
      if (!ota.cacheHit) _usedBytes += ota.size;
      job.event({
        'type': 'log',
        'text': ota.cacheHit
            ? 'Using the retained catalog OTA.'
            : 'Downloaded and cached the catalog OTA.',
      });

      CachedOta? base;
      if (baseRelease != null) {
        await _pinResource(job.id, 'ota-id:${baseRelease.id}');
        base = await otaCache.materialize(baseRelease);
        await _pinResource(job.id, 'ota:${base.sha256}');
        _consumeReservation(job.id, base.size);
        if (!base.cacheHit) _usedBytes += base.size;
        job.event({
          'type': 'log',
          'text': base.cacheHit
              ? 'Using the retained BASE OTA.'
              : 'Downloaded and cached the BASE OTA.',
        });
      }

      final selections = _selection(job.request);
      final catalogData = await catalog.loadCatalog(na: false);
      CachedOta? odm;
      if (needsMatchedOdm(
        job.request.device,
        job.request.kind,
        job.request.region,
      )) {
        odm = await _matchedOdm(job, ota, catalogData);
        await _pinResource(job.id, 'ota:${odm.sha256}');
        _consumeReservation(job.id, odm.size);
        if (!odm.cacheHit) _usedBytes += odm.size;
      }

      await _pinResource(job.id, 'bloat:${snapshot.manifestSha256}');
      final bloat = await bloatCache.prepare(
        manifest: snapshot.manifest,
        manifestSha256: snapshot.manifestSha256,
        selection: selections,
      );
      _consumeReservation(job.id, _bloatBytesForSelected(bloat.selected));
      job.event({
        'type': 'log',
        'text': 'Bloat images verified for ${selections.dev}.',
      });

      final key = _cacheKey(
        request: job.request,
        ota: ota.descriptor,
        base: base?.descriptor,
        odm: odm?.descriptor,
        bloat: bloat.selected,
      );
      job.cacheKey = key;
      final inputs = _identity(
        request: job.request,
        ota: ota,
        base: base,
        odm: odm,
        bloat: bloat.selected,
      );
      job.inputs = inputs;
      await store.saveActive(job);

      final cachedId = _cacheIndex[key];
      final cached = cachedId == null ? null : _jobs[cachedId];
      if (cached != null &&
          cached.id != job.id &&
          await _beginSourceOperation(cached)) {
        try {
          await _adopt(job, cached);
          return;
        } finally {
          await _endActive(cached.id);
        }
      }
      final shared = _sharedBuilds[key];
      if (shared != null) {
        job.event({
          'type': 'log',
          'text': 'Waiting for an identical build already in flight.',
        });
        await shared;
        final completedId = _cacheIndex[key];
        final completed = completedId == null ? null : _jobs[completedId];
        if (completed != null &&
            completed.id != job.id &&
            await _beginSourceOperation(completed)) {
          try {
            await _adopt(job, completed);
            return;
          } finally {
            await _endActive(completed.id);
          }
        }
        throw const HostedException(
          'shared_build_failed',
          'The identical build in flight did not produce an artifact.',
          status: 422,
        );
      }

      final released = Completer<void>();
      _sharedBuilds[key] = released.future;
      try {
        loopback = await LoopbackOtaHost.start(catalogData);
        if (odm != null) {
          loopback.register(odm.descriptor.catalogId, odm.file);
        }
        final work = store.workDir(job.id);
        final output = Directory(joinPath(work.path, ['out']));
        await output.create(recursive: true);
        final requestFile = File(
          joinPath(work.path, ['request.json']),
        );
        await atomicWriteJson(requestFile, {
          'selection': job.request.selection(),
          'ota': fileOta(ota.file.path),
          if (base != null) 'base': fileOta(base.file.path),
          if (job.request.vulnerableAbl != null)
            'vulnerableAbl': job.request.vulnerableAbl,
          'zip': true,
          'bloat': pathStore(bloat.directory.path),
          'output': pathStore(output.path),
          'apiBase': loopback.baseUri.toString(),
          'upstreamBase': snapshot.base,
        });

        var lastSave = _clock();
        final active = await launcher.start(
          jobId: job.id,
          requestFile: requestFile,
          onEvent: (event) {
            job.event(event);
            final now = _clock();
            if (now.difference(lastSave) >= const Duration(seconds: 2)) {
              lastSave = now;
              _track(_saveQuietly(job));
            }
          },
        );
        _running[job.id] = active;
        var workspaceExceeded = false;
        var guardBusy = false;
        final guard = Timer.periodic(const Duration(seconds: 1), (_) async {
          if (guardBusy) return;
          guardBusy = true;
          try {
            final bytes = await store.bytesOf(output);
            if (bytes > config.jobDiskBytes) {
              workspaceExceeded = true;
              active.kill();
            }
          } on Object {
            // A transient stat failure is retried on the next tick.
          } finally {
            guardBusy = false;
          }
        });
        final BuildOutcome outcome;
        try {
          outcome = await active.finish();
        } on HostedException {
          if (workspaceExceeded) {
            throw const HostedException(
              'workspace_limit',
              'The build exceeded its per-job workspace limit.',
              status: 507,
            );
          }
          rethrow;
        } finally {
          guard.cancel();
        }
        if (workspaceExceeded) {
          throw const HostedException(
            'workspace_limit',
            'The build exceeded its per-job workspace limit.',
            status: 507,
          );
        }
        await _publishSuccess(job, outcome, work);
      } finally {
        released.complete();
        _sharedBuilds.remove(key);
      }
    } on HostedException catch (error) {
      await _fail(job, error.code, _sanitize(error.message));
    } on CatalogException catch (error) {
      await _fail(job, 'catalog_failed', _sanitize(error.message));
    } on UpstreamException catch (error) {
      await _fail(job, 'selection_invalid', _sanitize(error.message));
    } on BuildException catch (error) {
      await _fail(job, 'build_input_failed', _sanitize(error.message));
    } on Object catch (error, stack) {
      stderr.writeln('hosted job ${job.id} failed: $error\n$stack');
      await _fail(job, 'internal', 'The build could not be completed.');
    } finally {
      _running.remove(job.id);
      await _unpinResources(job.id);
      _jobReservations.remove(job.id);
      _lastPersist.remove(job.id);
      if (!_closing) _track(_evict(target: config.cacheBudgetBytes - _reservedTotal));
      await loopback?.close();
      if (gate) _gate.release();
      if (job.state == HostedState.failed) {
        _requestIndex.remove(job.request.fingerprint);
      }
      try {
        await store.removeWork(job.id);
      } on Object {
        // Best effort after publication or failure evidence.
      }
    }
  }

  Future<CachedOta> _matchedOdm(
    HostedJob job,
    CachedOta ota,
    Map<String, dynamic> catalogData,
  ) async {
    OtaArchive? archive;
    final source = await FileSource.open(ota.file);
    try {
      archive = await OtaArchive.open(source);
      final target = releaseFromMetadata(
        catalogData,
        'OP 15R',
        job.request.region,
        archive.fields,
      );
      final patch = patchDate(archive.fields['post-security-patch-level']);
      if (patch != patchDate(target['security_patch'])) {
        throw const HostedException(
          'odm_patch_mismatch',
          'The target OTA security patch does not match its catalog entry.',
          status: 422,
        );
      }
      final donor = matchingOdm(catalogData, target);
      job.event({
        'type': 'log',
        'text': 'Resolving the matched ODM donor OTA.',
      });
      await _pinResource(job.id, 'ota-id:${donor['id']}');
      final donorRelease = CatalogRelease(
        role: 'odm',
        entry: donor,
        entryDigest: releaseDigest(donor),
        feedSha256: canonicalSha256(catalogData),
        stale: false,
      );
      return await otaCache.materialize(donorRelease);
    } finally {
      if (archive != null) {
        await archive.close();
      } else {
        await closeByteSource(source);
      }
    }
  }

  Future<void> _publishSuccess(
    HostedJob job,
    BuildOutcome outcome,
    Directory work,
  ) async {
    final output = Directory(joinPath(work.path, ['out']));
    final artifact = File(
      joinPath(output.path, [outcome.jobName, outcome.artifactName]),
    );
    final buildJson = File(
      joinPath(output.path, [outcome.jobName, 'build.json']),
    );
    if (!await artifact.exists() || !await buildJson.exists()) {
      throw const HostedInternalException(
        'build_output_missing',
        'The build did not produce its artifact and manifest.',
      );
    }
    final length = await artifact.length();
    if (length <= 0 || length > config.maxArtifactBytes) {
      throw HostedException(
        'artifact_too_large',
        'The generated artifact exceeds this server\'s limit.',
        status: 507,
      );
    }
    final actual = await sha256File(artifact);
    if (actual != outcome.sha256) {
      throw const HostedInternalException(
        'artifact_hash_mismatch',
        'The generated artifact does not match its reported SHA-256.',
      );
    }
    job
      ..state = HostedState.succeeded
      ..artifactName = outcome.artifactName
      ..sha256 = actual
      ..bytes = length
      ..manifest = outcome.manifest
      ..cacheHit = false
      ..updatedAt = _clock()
      ..lastUsedAt = _clock();
    await store.publishSucceeded(
      job: job,
      artifact: artifact,
      buildJson: buildJson,
    );
    _usedBytes += await store.bytesOf(store.jobDir(job.id));
    _consumeReservation(job.id, 1 << 62);
    if (job.cacheKey != null) _cacheIndex[job.cacheKey!] = job.id;
    job.event({'type': 'step', 'index': 5, 'total': 5, 'title': 'Complete'});
    job.event({'type': 'log', 'text': 'Artifact published.'});
    await store.touch(job);
  }

  Future<void> _adopt(HostedJob job, HostedJob source) async {
    job
      ..state = HostedState.succeeded
      ..artifactName = source.artifactName
      ..sha256 = source.sha256
      ..bytes = source.bytes
      ..manifest = source.manifest
      ..manifestSha256 = source.manifestSha256
      ..cacheKey = source.cacheKey
      ..inputs = source.inputs
      ..sourceJobId = source.id
      ..cacheHit = true
      ..updatedAt = _clock()
      ..lastUsedAt = _clock();
    await store.publishAlias(job: job, source: source);
    _usedBytes += await store.bytesOf(store.jobDir(job.id));
    job.event({
      'type': 'log',
      'text': 'Reused an identical completed build.',
    });
    await store.touch(job);
    if (job.cacheKey != null) _cacheIndex[job.cacheKey!] = job.id;
  }

  Future<void> _fail(HostedJob job, String code, String message) async {
    if (job.state == HostedState.succeeded &&
        await store.jobDir(job.id).exists()) {
      return;
    }
    job
      ..state = HostedState.failed
      ..error = message
      ..errorCode = code
      ..updatedAt = _clock()
      ..lastUsedAt = _clock();
    job.event({'type': 'log', 'text': 'Build failed: $message'});
    try {
      final work = store.workDir(job.id);
      File? log;
      final output = Directory(joinPath(work.path, ['out']));
      if (await output.exists()) {
        await for (final entity in output.list(recursive: true, followLinks: false)) {
          if (entity is File && entity.path.endsWith('build.log')) {
            log = entity;
          }
        }
      }
      await store.publishFailed(job: job, buildLog: log);
      _usedBytes += await store.bytesOf(store.jobDir(job.id));
    } on Object catch (error, stack) {
      stderr.writeln('hosted job ${job.id} could not publish failure: $error\n$stack');
      try {
        await store.saveActive(job);
      } on Object {
        // The in-memory error remains visible for this process.
      }
    }
  }

  Future<void> _saveQuietly(HostedJob job) async {
    try {
      await store.saveActive(job);
    } on Object {
      // Progress persistence is best effort; the child still owns the build.
    }
  }

  Future<bool> _reusable(HostedJob job) async {
    if (job.state != HostedState.succeeded) return false;
    final file = store.artifactFile(job.id);
    return await file.exists() &&
        job.bytes != null &&
        await file.length() == job.bytes;
  }

  Future<void> _useJob(HostedJob job, {bool force = false}) async {
    if (!job.finished) return;
    final now = _clock();
    job.lastUsedAt = now;
    final last = _lastPersist[job.id];
    if (!force &&
        last != null &&
        now.difference(last) < const Duration(seconds: 60)) {
      return;
    }
    _lastPersist[job.id] = now;
    try {
      await store.touch(job);
    } on Object {
      // A failed touch does not fail a read.
    }
  }

  Future<int> _measureUsed() async {
    var total = 0;
    for (final directory in [store.jobs, store.bloat, store.otaBlobs]) {
      total += await store.bytesOf(directory);
    }
    return total;
  }

  int get _reservedTotal =>
      _jobReservations.values.fold<int>(0, (sum, value) => sum + value);

  int _requiredStorage({
    required HostedJobRequest request,
    required Selection selection,
    required CatalogRelease ota,
    required CatalogRelease? base,
  }) {
    var bytes = config.jobDiskBytes + _selectedBloatBytes(selection);
    // Reserve every input even when it is currently cached: eviction between
    // admission and materialization must not leave a signed job underfunded.
    bytes += _inputBytes(ota);
    if (base != null) bytes += _inputBytes(base);
    if (needsMatchedOdm(request.device, request.kind, request.region)) {
      // The donor is selected only after OTA metadata is read. Reserve the
      // largest legal input so a matched build cannot bypass admission.
      bytes += config.maxOtaBytes;
    }
    return bytes;
  }

  int _selectedBloatBytes(Selection selection) {
    var total = 0;
    for (final relative in selectedPaths(snapshot.manifest.source, selection)) {
      final key = snapshot.manifest.files[relative];
      final asset = key == null ? null : snapshot.manifest.assets[key];
      if (asset != null) total += asset.rawBytes + asset.bytes;
    }
    return total;
  }

  int _bloatBytesForSelected(Map<String, String> selected) {
    var total = 0;
    for (final rawSha in selected.values) {
      final asset = snapshot.manifest.assets[rawSha];
      if (asset != null) total += asset.rawBytes + asset.bytes;
    }
    return total;
  }

  int _inputBytes(CatalogRelease release) {
    final declared = release.size;
    if (declared == null || declared <= 0) return config.maxOtaBytes;
    if (declared > config.maxOtaBytes) {
      throw const HostedException(
        'ota_too_large',
        'The catalog OTA is larger than this server allows.',
        status: 413,
      );
    }
    return declared;
  }

  Future<int> _effectiveReserved() async {
    // Snapshot before the first await; reservations are mutable during builds.
    final entries = _jobReservations.entries
        .map((entry) => MapEntry(entry.key, entry.value))
        .toList();
    var total = 0;
    for (final entry in entries) {
      final job = _jobs[entry.key];
      var consumed = 0;
      if (job != null) {
        final output = Directory(
          joinPath(store.workDir(job.id).path, ['out']),
        );
        if (await output.exists()) consumed = await store.bytesOf(output);
      }
      final remaining = entry.value - consumed;
      total += remaining < 0 ? 0 : remaining;
    }
    return total;
  }

  Future<void> _ensureCapacity(int required) async {
    final reserved = await _effectiveReserved();
    final target = config.cacheBudgetBytes - config.minFreeBytes - reserved - required;
    await _evict(target: target < 0 ? 0 : target);
    if (_usedBytes + reserved + required + config.minFreeBytes >
        config.cacheBudgetBytes) {
      throw const HostedException(
        'cache_full',
        'The hosted cache has no room for another build. Try again later.',
        status: 507,
      );
    }
    final free = await _availableDisk();
    if (free < required + config.minFreeBytes + reserved) {
      throw const HostedException(
        'disk_full',
        'The host does not have enough free disk space for this build.',
        status: 507,
      );
    }
  }

  void _consumeReservation(String jobId, int bytes) {
    final current = _jobReservations[jobId];
    if (current == null) return;
    _jobReservations[jobId] = current - bytes < 0 ? 0 : current - bytes;
  }

  Future<int> _availableDisk() async {
    final now = _clock();
    if (now.difference(_freeCheckedAt) < const Duration(seconds: 1)) {
      return _freeCache;
    }
    final ProcessResult result;
    try {
      result = await Process.run(
        'df',
        ['-B1', '--output=avail', config.root.path],
      );
    } on Object {
      throw const HostedException(
        'disk_probe_failed',
        'The host free-space probe is unavailable.',
        status: 507,
      );
    }
    if (result.exitCode != 0) {
      throw const HostedException(
        'disk_probe_failed',
        'The host free-space probe failed.',
        status: 507,
      );
    }
    final lines = result.stdout.toString()
        .split(RegExp(r'\s+'))
        .where((value) => value.isNotEmpty)
        .toList();
    final value = lines.isEmpty ? null : int.tryParse(lines.last);
    if (value == null || value < 0) {
      throw const HostedException(
        'disk_probe_failed',
        'The host free-space probe returned an invalid value.',
        status: 507,
      );
    }
    _freeCache = value;
    _freeCheckedAt = now;
    return value;
  }

  Future<void> _evict({required int target}) {
    final active = _evictionTask;
    if (active != null) {
      final pending = _pendingEvictionTarget;
      _pendingEvictionTarget = pending == null || target < pending
          ? target
          : pending;
      return active;
    }
    late final Future<void> wrapped;
    final core = () async {
      var wanted = target;
      while (true) {
        final pending = _pendingEvictionTarget;
        if (pending != null && pending < wanted) wanted = pending;
        _pendingEvictionTarget = null;
        // Release the gate between scans so cache pins and lease claims can
        // interleave instead of waiting behind an unbounded eviction convoy.
        await _evictionLock.run(() => _evictLocked(wanted));
        if (_pendingEvictionTarget == null) break;
      }
    }();
    wrapped = core.whenComplete(() {
      if (identical(_evictionTask, wrapped)) _evictionTask = null;
    });
    _evictionTask = wrapped;
    return wrapped;
  }

  Future<void> _evictLocked(int target) async {
    final now = _clock();
    final pinnedJobs = leases.pinnedJobs()..addAll(_activePins.pinnedJobs());
    for (final job in _jobs.values) {
      if (job.state == HostedState.queued || job.state == HostedState.running) {
        pinnedJobs.add(job.id);
      }
    }
    final activeOta = <String>{};
    final activeOtaIds = <String>{};
    final activeBloat = <String>{};
    for (final resources in _activeResources.values) {
      for (final resource in resources) {
        if (resource.startsWith('ota:')) activeOta.add(resource.substring(4));
        if (resource.startsWith('ota-id:')) {
          activeOtaIds.add(resource.substring('ota-id:'.length));
        }
        if (resource.startsWith('bloat:')) {
          activeBloat.add(resource.substring('bloat:'.length));
        }
      }
    }

    final candidates = <_EvictionCandidate>[];
    for (final job in _jobs.values) {
      if (!job.finished || pinnedJobs.contains(job.id)) continue;
      final bytes = await store.bytesOf(store.jobDir(job.id));
      candidates.add(
        _EvictionCandidate(
          kind: _EvictionKind.job,
          key: job.id,
          bytes: bytes,
          lastUsed: job.lastUsedAt,
          expireAt: job.lastUsedAt.add(config.retention),
        ),
      );
    }
    for (final entry in await otaCache.entries()) {
      if (activeOta.contains(entry.descriptor.sha256) ||
          activeOtaIds.contains(entry.descriptor.catalogId)) {
        continue;
      }
      candidates.add(
        _EvictionCandidate(
          kind: _EvictionKind.ota,
          key: entry.descriptor.catalogId,
          bytes: entry.bytes,
          lastUsed: entry.descriptor.lastUsedAt,
          expireAt: entry.descriptor.lastUsedAt.add(config.otaRetention),
          entry: entry,
        ),
      );
    }
    if (await store.bloat.exists()) {
      await for (final entity in store.bloat.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!isSha256Hex(name) || activeBloat.contains(name)) continue;
        final marker = File(joinPath(entity.path, ['.hosted-bloat.json']));
        DateTime? lastUsed;
        try {
          final json = await readJsonObject(marker, limit: 64 * 1024);
          lastUsed = parseIsoUtc(json?['lastUsedAt']);
        } on Object {
          lastUsed = null;
        }
        final modified = (await entity.stat()).modified.toUtc();
        final used = lastUsed ?? modified;
        candidates.add(
          _EvictionCandidate(
            kind: _EvictionKind.bloat,
            key: name,
            bytes: await store.bytesOf(entity),
            lastUsed: used,
            expireAt: used.add(config.otaRetention),
          ),
        );
      }
    }

    candidates.sort((left, right) {
      final leftExpired = now.isAfter(left.expireAt) ? 0 : 1;
      final rightExpired = now.isAfter(right.expireAt) ? 0 : 1;
      if (leftExpired != rightExpired) return leftExpired - rightExpired;
      return left.lastUsed.compareTo(right.lastUsed);
    });

    for (final candidate in candidates) {
      final expired = now.isAfter(candidate.expireAt);
      if (!expired && _usedBytes <= target) break;
      if (candidate.lastUsed.isAfter(now)) continue;
      try {
        switch (candidate.kind) {
          case _EvictionKind.job:
            await store.deleteJob(candidate.key);
            final removed = _jobs.remove(candidate.key);
            _handoffPins.remove(candidate.key);
            _lastPersist.remove(candidate.key);
            if (removed != null) {
              _requestIndex.remove(removed.request.fingerprint);
              final removedKey = removed.cacheKey;
              if (removedKey != null &&
                  _cacheIndex[removedKey] == removed.id) {
                _cacheIndex.remove(removedKey);
              }
            }
            break;
          case _EvictionKind.ota:
            await otaCache.deleteEntry(candidate.entry!);
            break;
          case _EvictionKind.bloat:
            await store.deleteBloat(candidate.key);
            break;
        }
        _usedBytes -= candidate.bytes;
        if (_usedBytes < 0) _usedBytes = 0;
      } on Object catch (error) {
        stderr.writeln('hosted eviction skipped ${candidate.kind.name} ${candidate.key}: $error');
      }
    }
    _usedBytes = await _measureUsed();
  }

  Selection _selection(HostedJobRequest request) {
    try {
      return snapshot.tables.selection(
        request.device,
        request.kind,
        request.region,
      );
    } on UpstreamException catch (error) {
      throw HostedException(
        'selection_invalid',
        _sanitize(error.message),
      );
    }
  }

  Map<String, ({String device, String region})> _targets(
    HostedJobRequest request,
  ) {
    try {
      return targets(request.device, request.kind, request.region);
    } on CatalogException catch (error) {
      throw HostedException('selection_invalid', _sanitize(error.message));
    }
  }

  Map<String, String> _selectedBloatHashes(Selection selection) {
    final result = <String, String>{};
    for (final relative in selectedPaths(
      snapshot.manifest.source,
      selection,
    )) {
      final key = snapshot.manifest.files[relative];
      final asset = key == null ? null : snapshot.manifest.assets[key];
      if (asset == null) {
        throw const HostedInternalException(
          'bloat_selection_invalid',
          'The bloat manifest does not cover this selection.',
        );
      }
      result[relative] = asset.rawSha256;
    }
    final keys = result.keys.toList()..sort();
    return {for (final key in keys) key: result[key]!};
  }

  String _cacheKey({
    required HostedJobRequest request,
    required OtaDescriptor ota,
    required OtaDescriptor? base,
    required OtaDescriptor? odm,
    required Map<String, String> bloat,
  }) => canonicalSha256({
    'schema': 1,
    'builder': config.builderRevision,
    'selection': request.selection(),
    'ota': _otaIdentity(ota),
    'base': base == null ? null : _otaIdentity(base),
    'odm': odm == null ? null : _otaIdentity(odm),
    'vulnerableAbl': request.vulnerableAbl == true,
    'zip': true,
    'upstream': {
      'commit': snapshot.commit,
      'snapshot': snapshot.snapshotSha256,
    },
    'bloat': {
      'manifest': snapshot.manifestSha256,
      'selected': bloat,
    },
  });

  Map<String, Object?> _identity({
    required HostedJobRequest request,
    required CachedOta ota,
    required CachedOta? base,
    required CachedOta? odm,
    required Map<String, String> bloat,
  }) => {
    'schema': 1,
    'builder': config.builderRevision,
    'selection': request.selection(),
    'ota': {..._otaIdentity(ota.descriptor), 'cacheHit': ota.cacheHit},
    'base': base == null
        ? null
        : {..._otaIdentity(base.descriptor), 'cacheHit': base.cacheHit},
    'odm': odm == null
        ? null
        : {..._otaIdentity(odm.descriptor), 'cacheHit': odm.cacheHit},
    'vulnerableAbl': request.vulnerableAbl == true,
    'zip': true,
    'upstream': {
      'commit': snapshot.commit,
      'snapshot': snapshot.snapshotSha256,
      'manifest': snapshot.manifestSha256,
    },
    'bloat': {'manifest': snapshot.manifestSha256, 'selected': bloat},
  };

  Map<String, Object?> _otaIdentity(OtaDescriptor descriptor) => {
    'catalogId': descriptor.catalogId,
    'entryDigest': descriptor.entryDigest,
    'sha256': descriptor.sha256,
    'size': descriptor.size,
  };

  String _sanitize(String message) {
    var value = message;
    for (final path in [config.root.path, store.work.path, snapshot.base]) {
      if (path.isNotEmpty) value = value.replaceAll(path, '<hosted>');
    }
    value = value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (value.length > 500) value = value.substring(0, 500);
    return value;
  }
}

final class _Semaphore {
  _Semaphore(this.max);

  final int max;
  int _active = 0;
  final List<Completer<void>> _waiting = [];

  Future<void> acquire() {
    if (_active < max) {
      _active++;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
      return;
    }
    if (_active > 0) _active--;
  }
}

final class _LockEntry {
  final _Mutex mutex = _Mutex();
  int references = 0;
}

final class _Mutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }
}

enum _EvictionKind { job, ota, bloat }

final class _EvictionCandidate {
  const _EvictionCandidate({
    required this.kind,
    required this.key,
    required this.bytes,
    required this.lastUsed,
    required this.expireAt,
    this.entry,
  });

  final _EvictionKind kind;
  final String key;
  final int bytes;
  final DateTime lastUsed;
  final DateTime expireAt;
  final OtaCacheEntry? entry;
}
