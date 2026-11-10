/// Optional catalog OTA cache with parallel, positional downloads.
///
/// `ota-cache/<digest>.downloadx.part` holds in-progress bytes; downloadx's
/// `<digest>.downloadx.json` records durable chunk prefixes, including gaps.
/// Completed data is renamed to `<digest>.zip`; `<digest>.json` (schema 2)
/// holds release identity, aggregate progress, timestamps and full-file SHA-256.
/// Schema-1 sequential sidecars are discarded and restarted.
///
/// The SHA-256 is computed in one bounded read-back pass after committing the
/// file. Payload-operation hashes are still checked when the virtual core
/// consumes it. Least-recently-used eviction frees space for a new download.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:downloadx/downloadx.dart' as dlx;

import 'budget.dart';
import 'contracts.dart';
import 'hashing.dart';
import 'paths.dart';
import 'downloadx_io.dart';
import 'range.dart';

/// A cache operation that cannot continue honestly.
class OtaCacheException implements Exception {
  const OtaCacheException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Stable release identity: signed URL query strings and ranking hints are
/// excluded, every other catalog field participates.
///
/// This is the cache key, so it must never change for the same catalog entry
/// and must change when the entry does.
String otaEntryDigest(Map<String, dynamic> entry) {
  final stable = <String, Object?>{};
  for (final item in entry.entries) {
    if (item.key == 'source_url' || item.key == 'is_latest') continue;
    stable[item.key] = item.value;
  }
  final source = entry['source_url'];
  if (source is String) {
    final uri = Uri.tryParse(source);
    if (uri != null) {
      stable['source_origin'] = {
        'scheme': uri.scheme,
        'host': uri.host,
        'path': uri.path,
      };
    }
  }
  return canonicalSha256(stable);
}

/// A short human label for a catalog entry: device, region and version.
String otaEntryLabel(Map<String, dynamic> entry) {
  final parts = <String>[];
  for (final field in ['device', 'region', 'version']) {
    final value = entry[field];
    if (value is String && value.isNotEmpty) parts.add(value);
  }
  if (parts.isNotEmpty) return parts.join(' / ');
  final id = entry['id'];
  return id is String && id.isNotEmpty ? id : 'OTA';
}

/// A remote OTA opened for ranged reads.
final class OtaRemoteSource {
  const OtaRemoteSource({required this.source, this.etag});

  /// The bytes. [ByteSource.read] must return exactly the requested range.
  final ByteSource source;

  /// The strong ETag the server reported, or null when it sent none.
  final String? etag;
}

/// Opens a catalog OTA for ranged reads through a resolvable URL.
///
/// The production implementation is `CatalogOtaSourceFactory` (catalog
/// `POST /api/resolve` plus the `/api/ota` range proxy); tests inject fakes so
/// resume, ETag and length behaviour are exercised without a network.
abstract interface class OtaSourceFactory {
  Future<OtaRemoteSource> open(Map<String, dynamic> entry);
}

/// Concurrent reads of one immutable catalog OTA, sharing link refresh.
///
/// Each HTTP source pins its probe's strong ETag on every response. Refresh
/// keeps old sources alive for their in-flight reads, but never accepts a
/// changed or missing pinned validator. Without a strong validator callers
/// must use one connection and discard cross-session progress.
final class CatalogOtaReader {
  CatalogOtaReader._(this._sources, this._entry, this._source, this._etag)
    : length = _source.length {
    _opened.add(_source);
  }

  static Future<CatalogOtaReader> open(
    OtaSourceFactory sources,
    Map<String, dynamic> entry, {
    String? etag,
  }) async {
    final remote = await sources.open(entry);
    final actual = strongEtag(remote.etag);
    if (etag != null && actual != etag) {
      await closeByteSource(remote.source);
      throw const OtaCacheException(
        'The OTA ETag changed since the download started.',
      );
    }
    return CatalogOtaReader._(sources, entry, remote.source, actual);
  }

  static const int maxRefreshes = 2;
  final OtaSourceFactory _sources;
  final Map<String, dynamic> _entry;
  ByteSource _source;
  final String? _etag;
  final Set<ByteSource> _opened = {};
  int _refreshes = 0;
  Future<void>? _refreshing;
  Object? _identityFailure;
  bool _closed = false;
  final int length;
  String? get etag => _etag;

  Future<Uint8List> read(
    int offset,
    int count, {
    Future<void>? cancelled,
  }) async {
    var aborted = false;
    cancelled?.then((_) => aborted = true);
    while (true) {
      if (_closed || aborted) throw StateError('OTA read cancelled');
      final fatal = _identityFailure;
      if (fatal != null) throw fatal;
      final attempted = _source;
      try {
        final bytes = await (attempted is CancellableByteSource
            ? attempted.readCancellable(offset, count, cancelled)
            : attempted.read(offset, count));
        if (_closed || aborted) throw StateError('OTA read cancelled');
        if (_identityFailure case final Object fatal) throw fatal;
        if (bytes.length != count) {
          throw OtaCacheException(
            'The OTA server ended a range early at $offset.',
          );
        }
        return bytes;
      } on Object {
        if (_closed || aborted || _identityFailure != null) rethrow;
        if (!identical(attempted, _source)) continue;
        final refreshing = _refreshing;
        if (refreshing != null) {
          await refreshing;
        } else {
          if (_refreshes >= maxRefreshes) rethrow;
          final refresh = _reopen();
          _refreshing = refresh;
          try {
            await refresh;
          } finally {
            _refreshing = null;
          }
        }
      }
    }
  }

  Future<void> _reopen() async {
    _refreshes++;
    // Without an identity validator, a fresh signed URL cannot safely be
    // combined with bytes from the old URL, even in a single session.
    if (_etag == null) {
      throw const OtaCacheException(
        'The OTA has no strong ETag; restart the download.',
      );
    }
    final remote = await _sources.open(_entry);
    _opened.add(remote.source);
    if (_closed) {
      await closeByteSource(remote.source);
      throw StateError('OTA reader closed during link refresh');
    }
    if (remote.source.length != length || strongEtag(remote.etag) != _etag) {
      final error = const OtaCacheException(
        'The OTA changed on the server during the download (length or ETag).',
      );
      _identityFailure = error;
      throw error;
    }
    _source = remote.source;
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait(_opened.map(closeByteSource));
  }
}

/// One catalog OTA the cache knows about: complete, partial or damaged.
final class OtaCacheEntry {
  const OtaCacheEntry({
    required this.key,
    required this.label,
    required this.size,
    required this.length,
    required this.written,
    required this.complete,
    required this.createdAt,
    required this.lastUsedAt,
    this.etag,
    this.sha256,
    this.completedAt,
  });

  /// [otaEntryDigest] of the catalog entry this OTA is cached under.
  final String key;

  /// Device, region and version, for a listing.
  final String label;

  /// The catalog's declared size in bytes, or 0 when the entry has none.
  final int size;

  /// The total OTA length the server reported, in bytes.
  final int length;

  /// Bytes written so far; [length] once complete.
  final int written;

  /// The download reached [length] and recorded [sha256].
  final bool complete;

  /// The server's strong ETag, when it sent one.
  final String? etag;

  /// SHA-256 of the whole OTA, recorded when the download completed.
  final String? sha256;

  final DateTime createdAt;
  final DateTime? completedAt;

  /// When the cache last served or resumed this entry; eviction order.
  final DateTime lastUsedAt;

  /// Durable downloaded data, not the logical allocation of a sparse file.
  int get bytes => complete ? length : written;

  /// The same entry with a fresh use stamp.
  OtaCacheEntry usedAt(DateTime time) => OtaCacheEntry(
    key: key,
    label: label,
    size: size,
    length: length,
    written: written,
    complete: complete,
    createdAt: createdAt,
    completedAt: completedAt,
    etag: etag,
    sha256: sha256,
    lastUsedAt: time,
  );

  Map<String, Object?> toJson() => {
    'schema': 2,
    'entryDigest': key,
    'label': label,
    'size': size,
    'length': length,
    'written': written,
    'complete': complete,
    'etag': etag,
    'sha256': sha256,
    'createdAt': createdAt.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
    'lastUsedAt': lastUsedAt.toIso8601String(),
  };

  /// Parses a sidecar, or returns null when it is malformed or inconsistent.
  static OtaCacheEntry? fromJson(Object? value) {
    if (value is! Map || value['schema'] != 2) return null;
    final key = value['entryDigest'];
    final label = value['label'];
    final size = value['size'];
    final length = value['length'];
    final written = value['written'];
    final complete = value['complete'];
    final etag = value['etag'];
    final sha256 = value['sha256'];
    final createdAt = _date(value['createdAt']);
    final completedAt = _date(value['completedAt']);
    final lastUsedAt = _date(value['lastUsedAt']);
    if (key is! String ||
        label is! String ||
        size is! int ||
        size < 0 ||
        length is! int ||
        length < 0 ||
        written is! int ||
        written < 0 ||
        written > length ||
        complete is! bool ||
        (etag != null && etag is! String) ||
        (sha256 != null && sha256 is! String) ||
        createdAt == null ||
        lastUsedAt == null) {
      return null;
    }
    if (complete && (sha256 == null || length == 0 || written != length)) {
      return null;
    }
    if (value['completedAt'] != null && completedAt == null) return null;
    return OtaCacheEntry(
      key: key,
      label: label,
      size: size,
      length: length,
      written: written,
      complete: complete,
      etag: etag as String?,
      sha256: sha256 as String?,
      createdAt: createdAt,
      completedAt: completedAt,
      lastUsedAt: lastUsedAt,
    );
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

/// Progress and results from [OtaCache.download].
sealed class OtaCacheEvent {
  const OtaCacheEvent();
}

/// The download is starting, either fresh or from [resumedFrom] bytes.
final class OtaCacheStarted extends OtaCacheEvent {
  const OtaCacheStarted({
    required this.key,
    required this.label,
    required this.total,
    required this.resumedFrom,
  });

  final String key;
  final String label;
  final int total;
  final int resumedFrom;
}

/// [bytes] of [total] bytes are on disk.
final class OtaCacheProgress extends OtaCacheEvent {
  const OtaCacheProgress({
    required this.key,
    required this.bytes,
    required this.total,
  });

  final String key;
  final int bytes;
  final int total;
}

/// The OTA is complete and cached.
final class OtaCacheFinished extends OtaCacheEvent {
  const OtaCacheFinished(this.entry);

  final OtaCacheEntry entry;
}

/// The OTA cache over a [Workspace] (OPFS on the web).
///
/// One instance per workspace. A download is guarded in memory, so a second
/// concurrent download of the same release is refused rather than interleaved;
/// [evict] never touches a key that is downloading now. Eviction only removes
/// entries under [directory], so bloat images in the same workspace are out of
/// its reach.
final class OtaCache {
  OtaCache({
    required this.workspace,
    required this.sources,
    String directory = 'ota-cache',
    this.chunkBytes = 8 * 1024 * 1024,
    this.connections = 8,
    DateTime Function()? clock,
  }) : _directory = normalizeWorkspacePath(directory),
       _clock = clock ?? DateTime.now {
    if (chunkBytes <= 0) {
      throw ArgumentError.value(chunkBytes, 'chunkBytes', 'must be positive');
    }
    if (connections < 1 || connections > 8) {
      throw ArgumentError.value(connections, 'connections', 'must be 1..8');
    }
  }

  /// Where the ZIP and its sidecar live.
  final Workspace workspace;

  /// How a catalog entry becomes a ranged byte source.
  final OtaSourceFactory sources;

  /// Bytes per ranged read and per persisted progress step.
  final int chunkBytes;
  final int connections;

  final String _directory;
  final DateTime Function() _clock;
  final Set<String> _active = {};

  static final RegExp _hexKey = RegExp(r'^[a-f0-9]{64}$');
  static const int _maxMetadataBytes = 64 * 1024;

  /// The cache directory inside [workspace].
  String get directory => _directory;

  /// A catalog entry's cache key.
  String keyFor(Map<String, dynamic> entry) => otaEntryDigest(entry);

  /// Every entry the cache knows, least recently used first, so the first one
  /// is the next eviction candidate.
  ///
  /// A complete record whose ZIP is missing or the wrong size is reported as
  /// incomplete with no bytes written; [download] restarts it.
  Future<List<OtaCacheEntry>> entries() async {
    if (!await _exists(_directory)) return const [];
    final found = <OtaCacheEntry>[];
    for (final path in await workspace.list(_directory)) {
      if (!path.endsWith('.json')) continue;
      final name = path.substring(path.lastIndexOf('/') + 1);
      final key = name.substring(0, name.length - '.json'.length);
      if (!_hexKey.hasMatch(key)) continue;
      final entry = await _read(key);
      if (entry == null) continue;
      found.add(await _present(entry));
    }
    found.sort((left, right) => left.lastUsedAt.compareTo(right.lastUsedAt));
    return found;
  }

  /// Logical file extent already charged to storage for this entry.
  ///
  /// A partial download can have large unwritten holes: its allocation is
  /// distinct from [OtaCacheEntry.bytes], the durable downloaded data.
  Future<int> allocatedBytes(OtaCacheEntry entry) async {
    final path = entry.complete
        ? _archive(entry.key)
        : '$_directory/${entry.key}${dlx.tempExt}';
    try {
      return await workspace.exists(path) ? await workspace.size(path) : 0;
    } on Object {
      return 0;
    }
  }

  /// The complete, intact entry for a catalog [entry], or null.
  ///
  /// A hit updates [OtaCacheEntry.lastUsedAt], so a release that is used is
  /// kept ahead of one that is not.
  Future<OtaCacheEntry?> lookup(Map<String, dynamic> entry) async {
    final key = otaEntryDigest(entry);
    final cached = await _read(key);
    if (cached == null || !await _intact(cached)) return null;
    return _touch(cached);
  }

  /// A [ByteSource] over the cached OTA for a catalog [entry], or null when it
  /// is not cached intact.
  ///
  /// This is the function the virtual flash path calls: a complete cache hit is
  /// transparent, and a miss falls back to streaming ranges from the server.
  /// The source reads exactly [OtaCacheEntry.length] bytes; the virtual core
  /// still checks every payload op hash while it reads them.
  Future<ByteSource?> openCachedCatalogOta(Map<String, dynamic> entry) async {
    final cached = await lookup(entry);
    if (cached == null) return null;
    return workspace.open(_archive(cached.key));
  }

  /// Downloads (or resumes) [entry] and yields progress, then the result.
  ///
  /// Before the first byte is written the length is pinned to the catalog's
  /// declared size and to any ETag the server reports; a server that changed
  /// the file is refused rather than mixed into a cache entry. [budget], when
  /// given, must approve the remaining bytes first and may free cached space
  /// through [evict].
  Stream<OtaCacheEvent> download(
    Map<String, dynamic> entry, {
    StorageBudget? budget,
  }) {
    final cancellation = _DownloadCancellation();
    StreamSubscription<OtaCacheEvent>? subscription;
    late final StreamController<OtaCacheEvent> controller;
    controller = StreamController<OtaCacheEvent>(
      onListen: () {
        subscription = _download(entry, budget, cancellation).listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        try {
          await cancellation.cancel();
        } finally {
          await subscription?.cancel();
        }
      },
    );
    return controller.stream;
  }

  Stream<OtaCacheEvent> _download(
    Map<String, dynamic> entry,
    StorageBudget? budget,
    _DownloadCancellation cancellation,
  ) async* {
    final key = otaEntryDigest(entry);
    final label = otaEntryLabel(entry);
    final declared = entry['size'] is int ? entry['size'] as int : 0;
    if (!_active.add(key)) {
      throw StateError('an OTA download for $key is already running');
    }
    CatalogOtaReader? reader;
    DownloadxWorkspaceIo? io;
    try {
      var cached = await _read(key);
      if (cached != null && await _intact(cached)) {
        cached = await _touch(cached);
        yield OtaCacheStarted(
          key: key,
          label: label,
          total: cached.length,
          resumedFrom: cached.length,
        );
        yield OtaCacheFinished(cached);
        return;
      }
      reader = await CatalogOtaReader.open(sources, entry, etag: cached?.etag);
      cancellation.reader = reader;
      if (cancellation.cancelled) return;
      final total = reader.length;
      if (declared > 0 && total != declared) {
        throw OtaCacheException(
          'The OTA server reports $total bytes but the catalog says $declared.',
        );
      }
      if (cached != null && cached.length != total) {
        throw OtaCacheException(
          'The interrupted download is for ${cached.length} bytes but the server now reports $total.',
        );
      }
      io = DownloadxWorkspaceIo(
        workspace: workspace,
        reader: reader,
        readBytes: chunkBytes,
      );
      final locator = dlx.MetaLocator(dir: _directory, id: key);
      var meta = await dlx.loadMeta(io, locator);
      final part = '$_directory/$key${dlx.tempExt}';
      if (reader.etag == null ||
          meta == null ||
          !await workspace.exists(part)) {
        await workspace.delete(part);
        await workspace.delete(dlx.metaPath(io, locator));
        meta = null;
      } else {
        if (meta.totalSize != total || strongEtag(meta.etag) != reader.etag) {
          throw const OtaCacheException(
            'The OTA changed since the interrupted download (length or ETag).',
          );
        }
        _validateLayout(meta, total);
        final requiredLength = meta.chunks.fold<int>(
          0,
          (end, c) => c.downloadedBytes == 0 ? end : max(end, c.offset + c.downloadedBytes),
        );
        if (await workspace.size(part) < requiredLength) {
          // A save picker can return the same handle after truncating its
          // file. Identity is not evidence that the recorded bytes survived.
          await workspace.delete(part);
          await workspace.delete(dlx.metaPath(io, locator));
          meta = null;
        }
      }
      final resumed =
          meta?.chunks.fold<int>(0, (sum, c) => sum + c.downloadedBytes) ?? 0;
      // OPFS charges a sparse file's logical length, including holes. Those
      // bytes are already in the quota estimate, not new storage to reserve.
      final allocated = meta == null ? 0 : await workspace.size(part);
      if (budget != null && total > allocated) {
        await budget.ensure(
          total - allocated,
          evict: (needed) => evict(bytesNeeded: needed),
        );
      }
      final record = OtaCacheEntry(
        key: key,
        label: label,
        size: declared,
        length: total,
        written: resumed,
        complete: false,
        etag: reader.etag,
        createdAt: cached?.createdAt ?? _now(),
        lastUsedAt: _now(),
      );
      await _write(record);
      final manager = dlx.DownloadX(
        dlx.DownloadXConfig(
          io: io,
          targetPath: _directory,
          cachePath: _directory,
          targetChunkCount: reader.etag == null ? 1 : connections,
          minChunkSize: chunkBytes,
          maxRetries: 3,
          retryDelay: 250,
          retryBackoff: 2,
          requestTimeout: 30000,
        ),
      );
      final download = meta == null
          ? await manager.addUrl(
              'https://catalog.invalid/$key.zip',
              dlx.DownloadOptions(id: key, filename: '$key.zip'),
            )
          : dlx.Download.fromMeta(meta, manager);
      cancellation.download = download;
      if (cancellation.cancelled) return;
      yield OtaCacheStarted(
        key: key,
        label: label,
        total: total,
        resumedFrom: resumed,
      );
      // 0.3.0 persists on completion/split/pause, not during a long chunk.
      // Use its public snapshots, leaving all chunk planning to the engine.
      var persisting = false;
      Future<void> persist() async {
        if (persisting) return;
        persisting = true;
        try {
          download.meta.chunks = download.getChunkSnapshots();
          await dlx.persistMeta(io!, locator, download.meta);
        } finally {
          persisting = false;
        }
      }

      final progress = StreamController<OtaCacheEvent>();
      void checkpointProgress() {
        unawaited(persist().catchError((Object error, StackTrace stack) {
          download.pause();
          progress.addError(error, stack);
        }));
      }
      final removeChunkProgress = download.emitter.onType<dlx.ChunkProgressEvent>(
        (_) => checkpointProgress(),
      );
      final removeProgress = download.emitter.onType<dlx.ProgressEvent>((
        event,
      ) {
        progress.add(
          OtaCacheProgress(
            key: key,
            bytes: download.downloadedBytes,
            total: total,
          ),
        );
        checkpointProgress();
      });
      final running = download.start();
      unawaited(running.whenComplete(progress.close));
      try {
        yield* progress.stream;
        await running;
      } finally {
        removeProgress();
        removeChunkProgress();
        download.cancel();
        await running;
        while (persisting) {
          await Future<void>.delayed(Duration.zero);
        }
        io.forceCheckpoint = true;
        await persist();
        await io.close();
      }
      if (cancellation.cancelled) return;
      if (download.state != dlx.DownloadState.completed) {
        throw OtaCacheException(
          download.meta.errorMessage ??
              download
                  .getChunkSnapshots()
                  .map((c) => c.lastError)
                  .whereType<String>()
                  .firstOrNull ??
              'The OTA download did not complete.',
        );
      }
      if (await workspace.size(_archive(key)) != total) {
        throw OtaCacheException(
          'The cached OTA is not $total bytes after the download.',
        );
      }
      // One bounded disk pass hashes exactly the committed, positional file.
      final hasher = StreamingSha256();
      await _hashPrefix(key, total, hasher, cancellation);
      if (cancellation.cancelled) return;
      final now = _now();
      final complete = OtaCacheEntry(
        key: key,
        label: label,
        size: declared,
        length: total,
        written: total,
        complete: true,
        etag: reader.etag,
        sha256: hasher.hex,
        createdAt: record.createdAt,
        completedAt: now,
        lastUsedAt: now,
      );
      await _write(complete);
      yield OtaCacheFinished(complete);
    } finally {
      try {
        await reader?.close();
      } finally {
        try {
          await io?.close();
        } finally {
          _active.remove(key);
        }
      }
    }
  }

  static void _validateLayout(dlx.MetaFile meta, int total) {
    final chunks = [...meta.chunks]
      ..sort((a, b) => a.offset.compareTo(b.offset));
    var end = 0;
    final ids = <String>{};
    for (final chunk in chunks) {
      if (chunk.offset != end ||
          chunk.length <= 0 ||
          chunk.downloadedBytes < 0 ||
          chunk.downloadedBytes > chunk.length ||
          !ids.add(chunk.id)) {
        throw const OtaCacheException('Invalid OTA resume chunk layout.');
      }
      end += chunk.length;
    }
    if (end != total) {
      throw const OtaCacheException('Incomplete OTA resume chunk layout.');
    }
  }

  /// Runs [download] to completion and returns the cached entry.
  Future<OtaCacheEntry> cache(
    Map<String, dynamic> entry, {
    StorageBudget? budget,
  }) async {
    await for (final event in download(entry, budget: budget)) {
      if (event is OtaCacheFinished) return event.entry;
    }
    throw StateError('the OTA download ended without a result');
  }

  /// Deletes one entry's ZIP and sidecar. Returns whether a ZIP existed.
  Future<bool> remove(String key) async {
    if (!_hexKey.hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'must be a catalog entry digest');
    }
    final existed = await _exists(_archive(key));
    await _deleteFiles(key);
    return existed;
  }

  /// Deletes least-recently-used entries until [bytesNeeded] are free and
  /// returns the bytes removed.
  ///
  /// An entry that is downloading now is never touched, and nothing outside
  /// [directory] (bloat images, the job workspace) can be reached. A partial
  /// download is a candidate like any other: its bytes are resumable, not
  /// precious.
  Future<int> evict({required int bytesNeeded}) async {
    if (bytesNeeded <= 0) return 0;
    var freed = 0;
    for (final entry in await entries()) {
      if (freed >= bytesNeeded) break;
      if (_active.contains(entry.key)) continue;
      var bytes = entry.bytes;
      try {
        if (await _exists(_archive(entry.key))) {
          bytes = await workspace.size(_archive(entry.key));
        } else {
          final part = '$_directory/${entry.key}${dlx.tempExt}';
          if (await _exists(part)) bytes = await workspace.size(part);
        }
      } on Object {
        // Fall back to the recorded size; the delete below decides.
      }
      try {
        await _deleteFiles(entry.key);
      } on Object {
        // An entry that cannot be deleted is skipped, not fatal.
        continue;
      }
      freed += bytes;
    }
    return freed;
  }

  String _archive(String key) => '$_directory/$key.zip';

  String _metadata(String key) => '$_directory/$key.json';

  DateTime _now() => _clock().toUtc();

  Future<bool> _exists(String path) async {
    try {
      return await workspace.exists(path);
    } on Object {
      return false;
    }
  }

  /// Whether a complete record matches the bytes on disk.
  Future<bool> _intact(OtaCacheEntry entry) async {
    if (!entry.complete || entry.length <= 0) return false;
    try {
      return await _exists(_archive(entry.key)) &&
          await workspace.size(_archive(entry.key)) == entry.length;
    } on Object {
      return false;
    }
  }

  /// Reports a damaged complete entry as an empty partial one.
  Future<OtaCacheEntry> _present(OtaCacheEntry entry) async {
    if (!entry.complete || await _intact(entry)) return entry;
    return OtaCacheEntry(
      key: entry.key,
      label: entry.label,
      size: entry.size,
      length: entry.length,
      written: 0,
      complete: false,
      etag: entry.etag,
      createdAt: entry.createdAt,
      lastUsedAt: entry.lastUsedAt,
    );
  }

  Future<OtaCacheEntry> _touch(OtaCacheEntry entry) async {
    final touched = entry.usedAt(_now());
    await _write(touched);
    return touched;
  }

  Future<OtaCacheEntry?> _read(String key) async {
    final path = _metadata(key);
    try {
      if (!await workspace.exists(path)) return null;
      final size = await workspace.size(path);
      if (size <= 0 || size > _maxMetadataBytes) return null;
      final source = await workspace.open(path);
      final Uint8List bytes;
      try {
        bytes = await source.read(0, size);
      } finally {
        await closeByteSource(source);
      }
      final entry = OtaCacheEntry.fromJson(jsonDecode(utf8.decode(bytes)));
      if (entry == null || entry.key != key) return null;
      if (entry.complete) return entry;
      final chunksPath = '$_directory/$key${dlx.metaExt}';
      if (!await workspace.exists(chunksPath)) return entry;
      final chunksSource = await workspace.open(chunksPath);
      final Object? raw;
      try {
        if (chunksSource.length > 1024 * 1024) return entry;
        raw = jsonDecode(
          utf8.decode(await chunksSource.read(0, chunksSource.length)),
        );
      } finally {
        await closeByteSource(chunksSource);
      }
      if (raw is! Map || raw['chunks'] is! List) return entry;
      var written = 0;
      for (final chunk in raw['chunks'] as List) {
        if (chunk is! Map || chunk['downloadedBytes'] is! int) return entry;
        written += chunk['downloadedBytes'] as int;
      }
      if (written < 0 || written > entry.length) return entry;
      return OtaCacheEntry(
        key: entry.key,
        label: entry.label,
        size: entry.size,
        length: entry.length,
        written: written,
        complete: false,
        etag: entry.etag,
        createdAt: entry.createdAt,
        lastUsedAt: entry.lastUsedAt,
      );
    } on Object {
      // A corrupt sidecar is a miss; the ZIP decides what can be reused.
      return null;
    }
  }

  Future<void> _write(OtaCacheEntry entry) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(entry.toJson())));
    final sink = await workspace.create(_metadata(entry.key));
    try {
      await sink.write(bytes, 0);
    } finally {
      await sink.close();
    }
  }

  Future<void> _deleteFiles(String key) async {
    await workspace.delete(_archive(key));
    await workspace.delete(_metadata(key));
    await workspace.delete('$_directory/$key${dlx.tempExt}');
    await workspace.delete('$_directory/$key${dlx.metaExt}');
    await workspace.delete('$_directory/$key${dlx.metaExt}.tmp');
  }

  /// Feeds the bytes already on disk into [hasher], so a resumed download
  /// records the SHA-256 of the whole file rather than only its tail.
  Future<void> _hashPrefix(
    String key,
    int length,
    StreamingSha256 hasher,
    _DownloadCancellation cancellation,
  ) async {
    final source = await workspace.open(_archive(key));
    try {
      var offset = 0;
      while (offset < length) {
        if (cancellation.cancelled) return;
        final bytes = await source.read(
          offset,
          min(chunkBytes, length - offset),
        );
        hasher.add(bytes);
        offset += bytes.length;
      }
    } finally {
      await closeByteSource(source);
    }
  }
}

final class _DownloadCancellation {
  bool cancelled = false;
  CatalogOtaReader? reader;
  dlx.Download? download;
  Future<void> cancel() async {
    cancelled = true;
    download?.cancel();
    await reader?.close();
  }
}

/// Fetches one bounded window ahead, but emits bytes in file order. This
/// destination has no random-access handle or cross-session resume state.
/// Cancelling the subscription aborts the reader's active network requests.
Stream<Uint8List> orderedOtaReads(
  CatalogOtaReader reader, {
  int connections = 8,
  int chunkBytes = 8 * 1024 * 1024,
}) {
  if (connections < 1 || connections > 8 || chunkBytes <= 0) {
    throw ArgumentError('invalid OTA read window');
  }
  StreamSubscription<Uint8List>? subscription;
  var cancelled = false;
  late final StreamController<Uint8List> controller;
  Stream<Uint8List> run() async* {
    final pending =
        <Future<({Uint8List? bytes, Object? error, StackTrace? stack})>>[];
    var offset = 0;
    final count = reader.etag == null ? 1 : connections;
    void fill() {
      while (pending.length < count && offset < reader.length) {
        final length = min(chunkBytes, reader.length - offset);
        final future = reader.read(offset, length);
        // A later range can fail before the ordered consumer reaches it.
        pending.add(
          future.then<({Uint8List? bytes, Object? error, StackTrace? stack})>(
            (bytes) => (bytes: bytes, error: null, stack: null),
            onError: (Object error, StackTrace stack) =>
                (bytes: null, error: error, stack: stack),
          ),
        );
        offset += length;
      }
    }

    try {
      fill();
      while (pending.isNotEmpty) {
        var result = await pending.removeAt(0);
        if (cancelled) return;
        if (result.error != null) {
          Error.throwWithStackTrace(result.error!, result.stack!);
        }
        yield result.bytes!;
        result = (bytes: null, error: null, stack: null);
        fill();
      }
    } finally {
      await reader.close();
    }
  }

  controller = StreamController<Uint8List>(
    onListen: () {
      subscription = run().listen(
        controller.add,
        onError: (Object error, StackTrace stack) {
          if (!cancelled) controller.addError(error, stack);
        },
        onDone: controller.close,
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () async {
      cancelled = true;
      await reader.close();
      await subscription?.cancel();
    },
  );
  return controller.stream;
}
