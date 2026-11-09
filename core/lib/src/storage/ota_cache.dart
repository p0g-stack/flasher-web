/// An optional local cache of catalog OTA ZIPs.
///
/// The virtual flash path never stores an OTA: it reads the redirect target
/// through HTTP ranges. A user who flashes the same release repeatedly can let
/// the app keep one complete ZIP instead, under the origin's storage cap. The
/// cache is deliberately small and disposable:
///
/// * `ota-cache/<digest>.zip` — the OTA bytes, written positionally, so an
///   interrupted download resumes at its last recorded offset instead of
///   starting over;
/// * `ota-cache/<digest>.json` — the sidecar: entry digest, label, catalog
///   size, observed length, ETag, bytes written, complete flag, the full-file
///   SHA-256 and the use timestamps.
///
/// `<digest>` is [otaEntryDigest], a canonical digest of the catalog entry, so
/// two releases never share a key and a changed entry is a different release.
/// The cache records the full-file SHA-256 it computed while downloading to
/// identify the bytes it holds; payload op hashes are still checked when the
/// virtual core reads the OTA, so a corrupt cache cannot corrupt a flash.
/// Least-recently-used eviction frees space for a new write.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'budget.dart';
import 'contracts.dart';
import 'hashing.dart';
import 'paths.dart';

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
/// and must change when the entry does. It matches the hosted service's
/// `releaseDigest`.
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

  /// Bytes this entry occupies now: the whole OTA once complete, the partial
  /// download before that.
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
    'schema': 1,
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
    if (value is! Map || value['schema'] != 1) return null;
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
    if (complete &&
        (sha256 == null || length == 0 || written != length)) {
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
    DateTime Function()? clock,
  }) : _directory = normalizeWorkspacePath(directory),
       _clock = clock ?? DateTime.now {
    if (chunkBytes <= 0) {
      throw ArgumentError.value(chunkBytes, 'chunkBytes', 'must be positive');
    }
  }

  /// Where the ZIP and its sidecar live.
  final Workspace workspace;

  /// How a catalog entry becomes a ranged byte source.
  final OtaSourceFactory sources;

  /// Bytes per ranged read and per persisted progress step.
  final int chunkBytes;

  final String _directory;
  final DateTime Function() _clock;
  final Set<String> _active = {};

  static final RegExp _hexKey = RegExp(r'^[a-f0-9]{64}$');
  static const int _maxMetadataBytes = 64 * 1024;
  static const int _maxRefreshes = 2;

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
  }) async* {
    final key = otaEntryDigest(entry);
    final label = otaEntryLabel(entry);
    final declared = entry['size'] is int ? entry['size'] as int : 0;
    if (!_active.add(key)) {
      throw StateError('an OTA download for $key is already running');
    }
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
      if (cached != null && cached.complete) {
        // The sidecar claimed a complete OTA whose bytes are gone or short.
        // Serving them would be worse than downloading again.
        await _deleteFiles(key);
        cached = null;
      }

      final remote = await sources.open(entry);
      var source = remote.source;
      var etag = remote.etag;
      final total = source.length;
      try {
        if (declared > 0 && declared != total) {
          throw OtaCacheException(
            'The OTA server reports $total bytes but the catalog says '
            '$declared. Fetch versions again and retry.',
          );
        }
        if (cached != null) {
          if (cached.length != total) {
            throw OtaCacheException(
              'The interrupted download is for ${cached.length} bytes but the '
              'server now reports $total. Delete the cached OTA and retry.',
            );
          }
          if (cached.etag != null && etag != null && cached.etag != etag) {
            throw OtaCacheException(
              'The OTA changed on the server since the download started '
              '(ETag $etag, was ${cached.etag}). Delete the cached OTA and '
              'retry.',
            );
          }
          etag ??= cached.etag;
        }
        var written = cached?.written ?? 0;
        if (written < 0 || written > total) written = 0;

        var record = OtaCacheEntry(
          key: key,
          label: label,
          size: declared,
          length: total,
          written: written,
          complete: false,
          etag: etag,
          createdAt: cached?.createdAt ?? _now(),
          lastUsedAt: _now(),
        );
        await _write(record);

        final remaining = total - written;
        if (budget != null && remaining > 0) {
          await budget.ensure(
            remaining,
            evict: (needed) => evict(bytesNeeded: needed),
          );
        }
        yield OtaCacheStarted(
          key: key,
          label: label,
          total: total,
          resumedFrom: written,
        );

        final hasher = StreamingSha256();
        if (written > 0) await _hashPrefix(key, written, hasher);
        if (remaining > 0) {
          final sink = await workspace.update(_archive(key));
          try {
            await sink.truncate(written);
            var refreshes = 0;
            while (written < total) {
              final want = min(chunkBytes, total - written);
              final Uint8List bytes;
              try {
                bytes = await source.read(written, want);
              } on Object {
                if (refreshes++ >= _maxRefreshes) rethrow;
                // A signed URL can expire mid-download; resolve a fresh one
                // and read the same range again.
                await closeByteSource(source);
                final reopened = await sources.open(entry);
                source = reopened.source;
                if (source.length != total) {
                  throw OtaCacheException(
                    'The OTA server now reports ${source.length} bytes, was '
                    '$total. Delete the cached OTA and retry.',
                  );
                }
                if (etag != null &&
                    reopened.etag != null &&
                    reopened.etag != etag) {
                  throw OtaCacheException(
                    'The OTA changed on the server during the download. '
                    'Delete the cached OTA and retry.',
                  );
                }
                etag ??= reopened.etag;
                continue;
              }
              if (bytes.length != want) {
                throw OtaCacheException(
                  'The OTA server ended a range early at $written of $total '
                  'bytes.',
                );
              }
              await sink.write(bytes, written);
              hasher.add(bytes);
              written += want;
              record = OtaCacheEntry(
                key: key,
                label: label,
                size: declared,
                length: total,
                written: written,
                complete: false,
                etag: etag,
                createdAt: record.createdAt,
                lastUsedAt: _now(),
              );
              await _write(record);
              yield OtaCacheProgress(key: key, bytes: written, total: total);
            }
          } finally {
            await sink.close();
          }
        }
        if (await workspace.size(_archive(key)) != total) {
          throw OtaCacheException(
            'The cached OTA is not $total bytes after the download.',
          );
        }
        final now = _now();
        final complete = OtaCacheEntry(
          key: key,
          label: label,
          size: declared,
          length: total,
          written: total,
          complete: true,
          etag: etag,
          sha256: hasher.hex,
          createdAt: record.createdAt,
          completedAt: now,
          lastUsedAt: now,
        );
        await _write(complete);
        yield OtaCacheFinished(complete);
      } finally {
        await closeByteSource(source);
      }
    } finally {
      _active.remove(key);
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
      return entry == null || entry.key != key ? null : entry;
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
  }

  /// Feeds the bytes already on disk into [hasher], so a resumed download
  /// records the SHA-256 of the whole file rather than only its tail.
  Future<void> _hashPrefix(
    String key,
    int length,
    StreamingSha256 hasher,
  ) async {
    final source = await workspace.open(_archive(key));
    try {
      var offset = 0;
      while (offset < length) {
        final bytes = await source.read(offset, min(chunkBytes, length - offset));
        hasher.add(bytes);
        offset += bytes.length;
      }
    } finally {
      await closeByteSource(source);
    }
  }
}
