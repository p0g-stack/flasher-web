import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flasher_web_core/flasher_web_core.dart';

import 'catalog_gateway.dart';
import 'config.dart';
import 'errors.dart';
import 'strict_http.dart';
import 'util.dart';

/// One cached full OTA.
final class CachedOta {
  const CachedOta({
    required this.descriptor,
    required this.file,
    required this.cacheHit,
  });

  final OtaDescriptor descriptor;
  final File file;
  final bool cacheHit;

  int get size => descriptor.size;
  String get sha256 => descriptor.sha256;
}

final class OtaCacheEntry {
  const OtaCacheEntry({
    required this.descriptor,
    required this.index,
    required this.blob,
    required this.bytes,
  });

  final OtaDescriptor descriptor;
  final File index;
  final File blob;
  final int bytes;
}

final class OtaDescriptor {
  const OtaDescriptor({
    required this.catalogId,
    required this.entryDigest,
    required this.feedSha256,
    required this.size,
    required this.sha256,
    required this.createdAt,
    required this.lastUsedAt,
  });

  factory OtaDescriptor.fromJson(Map<String, dynamic> json) {
    final catalogId = json['catalogId'];
    final entryDigest = json['entryDigest'];
    final feedSha = json['feedSha256'];
    final size = json['size'];
    final sha = json['sha256'];
    final createdAt = parseIsoUtc(json['createdAt']);
    final lastUsed = parseIsoUtc(json['lastUsedAt']);
    if (json['schema'] != 1 ||
        catalogId is! String ||
        entryDigest is! String ||
        feedSha is! String ||
        size is! int ||
        size < 0 ||
        sha is! String ||
        !isSha256Hex(sha) ||
        createdAt == null ||
        lastUsed == null) {
      throw const FormatException('invalid OTA cache descriptor');
    }
    return OtaDescriptor(
      catalogId: catalogId,
      entryDigest: entryDigest,
      feedSha256: feedSha,
      size: size,
      sha256: sha,
      createdAt: createdAt,
      lastUsedAt: lastUsed,
    );
  }

  final String catalogId;
  final String entryDigest;
  final String feedSha256;
  final int size;
  final String sha256;
  final DateTime createdAt;
  final DateTime lastUsedAt;

  OtaDescriptor copyWith({DateTime? lastUsedAt}) => OtaDescriptor(
    catalogId: catalogId,
    entryDigest: entryDigest,
    feedSha256: feedSha256,
    size: size,
    sha256: sha256,
    createdAt: createdAt,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
  );

  Map<String, Object?> toJson() => {
    'schema': 1,
    'catalogId': catalogId,
    'entryDigest': entryDigest,
    'feedSha256': feedSha256,
    'size': size,
    'sha256': sha256,
    'createdAt': isoUtc(createdAt),
    'lastUsedAt': isoUtc(lastUsedAt),
  };
}

/// Content-addressed OTA cache. A catalog id is bound to one entry digest and
/// one SHA-256 for its whole retained life, so a changed upstream release can
/// never be quietly substituted into an artifact.
final class OtaCache {
  OtaCache({
    required this.config,
    required this.http,
    required this.catalog,
    required this.root,
  });

  final HostedConfig config;
  final StrictHttp http;
  final CatalogGateway catalog;
  final Directory root;
  final Map<String, ({int length, DateTime modified, String sha256})> _verified =
      {};
  final Map<String, _Mutex> _locks = {};
  static const int _chunk = 16 * 1024 * 1024;
  static final Random _random = Random.secure();

  Directory get _blobs => Directory(joinPath(root.path, ['blobs']));
  Directory get _byCatalog => Directory(joinPath(root.path, ['by-catalog']));
  Directory get _temp => Directory(joinPath(root.path, ['tmp']));

  /// Returns a verified local file for [release], downloading it once.
  Future<CachedOta> materialize(CatalogRelease release) {
    final lock = _locks.putIfAbsent(release.id, _Mutex.new);
    return lock.run(() => _materialize(release));
  }

  Future<CachedOta> _materialize(CatalogRelease release) async {
    if (release.id.isEmpty) {
      throw const HostedInternalException(
        'catalog_id_empty',
        'The catalog entry has no id.',
      );
    }
    final index = File(
      joinPath(_byCatalog.path, ['${sha256Hex(utf8.encode(release.id))}.json']),
    );
    final descriptor = await _readDescriptor(index);
    if (descriptor != null && descriptor.entryDigest != release.entryDigest) {
      throw const CatalogChangedException();
    }

    if (descriptor != null) {
      final file = _blob(descriptor.sha256);
      if (await file.exists() && await file.length() == descriptor.size) {
        final actual = await _verifiedSha(file, descriptor.sha256);
        if (actual == descriptor.sha256) {
          final touched = descriptor.copyWith(lastUsedAt: DateTime.now().toUtc());
          await _writeDescriptor(index, touched);
          return CachedOta(descriptor: touched, file: file, cacheHit: true);
        }
      }
      // A retained descriptor is authoritative. A missing or damaged blob is
      // repaired only when the new bytes reproduce the pinned SHA-256.
      final repaired = await _download(release, expected: descriptor);
      return CachedOta(descriptor: repaired, file: _blob(repaired.sha256), cacheHit: false);
    }

    final downloaded = await _download(release, expected: null);
    return CachedOta(
      descriptor: downloaded,
      file: _blob(downloaded.sha256),
      cacheHit: false,
    );
  }

  /// Updates the last-use stamp after a build or a cache hit.
  Future<void> touch(CatalogRelease release) async {
    final index = File(
      joinPath(_byCatalog.path, ['${sha256Hex(utf8.encode(release.id))}.json']),
    );
    final descriptor = await _readDescriptor(index);
    if (descriptor == null) return;
    await _writeDescriptor(
      index,
      descriptor.copyWith(lastUsedAt: DateTime.now().toUtc()),
    );
  }

  Future<OtaDescriptor> _download(
    CatalogRelease release, {
    required OtaDescriptor? expected,
  }) async {
    final resolved = await catalog.resolve(release.entry);
    var currentLink = resolved;
    Future<StrictRangeResponse> open(int start, int end) async {
      try {
        return await _openRange(currentLink, start, end);
      } on _LinkExpired {
        currentLink = await catalog.resolve(release.entry);
        try {
          return await _openRange(currentLink, start, end);
        } on _LinkExpired {
          throw const HostedException(
            'ota_link_expired',
            'The OTA download link expired repeatedly.',
            status: 502,
          );
        }
      }
    }

    final probe = await open(0, 0);
    final total = _total(probe, 0, 0);
    await _discard(probe);
    if (total > config.maxOtaBytes) {
      throw const HostedException(
        'ota_too_large',
        'The catalog OTA is larger than this server allows.',
        status: 413,
      );
    }
    final declared = release.size;
    if (declared != null && declared > 0 && declared != total) {
      throw const HostedException(
        'ota_size_mismatch',
        'The OTA server reports a different size than the catalog.',
        status: 502,
      );
    }
    if (expected != null && expected.size != total) {
      throw const HostedException(
        'ota_immutable_violation',
        'The OTA size differs from the retained immutable entry.',
        status: 502,
      );
    }

    await _temp.create(recursive: true);
    final suffix =
        '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(0x7fffffff)}';
    final partial = File(joinPath(_temp.path, ['${sha256Hex(utf8.encode(release.id))}-$suffix.part']));
    final hasher = HashWriter();
    final sink = await partial.open(mode: FileMode.write);
    var written = 0;
    var success = false;
    try {
      while (written < total) {
        final end = min(total - 1, written + _chunk - 1);
        final response = await open(written, end);
        final range = _validateRange(response, written, end, total);
        if (response.status != 206 || range == null) {
          await _discard(response);
          throw const HostedException(
            'ota_range_invalid',
            'The OTA server did not return the requested byte range.',
            status: 502,
          );
        }
        final builder = Uint8List(range.end! - range.start! + 1);
        var offset = 0;
        await for (final chunk in response.response) {
          if (offset + chunk.length > builder.length) {
            throw const HostedException(
              'ota_range_oversized',
              'The OTA server returned more bytes than requested.',
              status: 502,
            );
          }
          builder.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        if (offset != builder.length) {
          throw const HostedException(
            'ota_range_short',
            'The OTA server ended a byte range early.',
            status: 502,
          );
        }
        hasher.add(builder);
        await sink.writeFrom(builder);
        written += builder.length;
      }
      await sink.flush();
      success = true;
    } finally {
      await sink.close();
      if (!success) await _deleteQuietly(partial);
    }

    final digest = hasher.finish();
    if (written != total) {
      await _deleteQuietly(partial);
      throw const HostedException(
        'ota_download_incomplete',
        'The OTA download did not finish.',
        status: 502,
      );
    }
    if (expected != null && digest != expected.sha256) {
      await _deleteQuietly(partial);
      throw const HostedException(
        'ota_immutable_violation',
        'The OTA bytes differ from the retained immutable entry.',
        status: 502,
      );
    }

    await _blobs.create(recursive: true);
    final blob = _blob(digest);
    if (await blob.exists()) {
      final existing = await _verifiedSha(blob, digest);
      if (existing == digest) {
        await _deleteQuietly(partial);
      } else {
        await blob.delete();
        await partial.rename(blob.path);
      }
    } else {
      await partial.rename(blob.path);
    }
    final now = DateTime.now().toUtc();
    final descriptor = OtaDescriptor(
      catalogId: release.id,
      entryDigest: release.entryDigest,
      feedSha256: release.feedSha256,
      size: total,
      sha256: digest,
      createdAt: expected?.createdAt ?? now,
      lastUsedAt: now,
    );
    final index = File(
      joinPath(_byCatalog.path, ['${sha256Hex(utf8.encode(release.id))}.json']),
    );
    await _writeDescriptor(index, descriptor);
    _verified[blob.path] = (
      length: total,
      modified: await blob.lastModified(),
      sha256: digest,
    );
    return descriptor;
  }

  Future<StrictRangeResponse> _openRange(
    Uri resolved,
    int start,
    int end,
  ) async {
    final proxy = http.resolve('api/ota', {'u': resolved.toString()});
    try {
      return await http.range(proxy, start: start, end: end);
    } on HostedUpstreamStatus catch (error) {
      if (error.status == 401 || error.status == 403 || error.status == 410) {
        throw const _LinkExpired();
      }
      throw HostedException(
        'ota_unavailable',
        'The OTA server returned HTTP ${error.status}.',
        status: 502,
      );
    }
  }

  ContentRange? _validateRange(
    StrictRangeResponse response,
    int start,
    int end,
    int total,
  ) {
    try {
      final range = ContentRange.parse(response.header('content-range'));
      if (!range.isSatisfied ||
          range.start != start ||
          range.end != end ||
          range.total != total) {
        return null;
      }
      final length = response.header('content-length');
      if (length != null && int.tryParse(length) != end - start + 1) {
        return null;
      }
      return range;
    } on Object {
      return null;
    }
  }

  int _total(StrictRangeResponse response, int start, int end) {
    final ContentRange range;
    try {
      range = ContentRange.parse(response.header('content-range'));
    } on Object {
      throw const HostedException(
        'ota_range_invalid',
        'The OTA server did not report the file length.',
        status: 502,
      );
    }
    if (!range.isSatisfied ||
        range.start != start ||
        range.end != end ||
        range.total < 1) {
      throw const HostedException(
        'ota_range_invalid',
        'The OTA server did not report the file length.',
        status: 502,
      );
    }
    final length = response.header('content-length');
    if (length != null && int.tryParse(length) != 1) {
      throw const HostedException(
        'ota_range_invalid',
        'The OTA server returned an invalid probe length.',
        status: 502,
      );
    }
    return range.total;
  }

  Future<void> _discard(StrictRangeResponse response) => response.discard();

  /// Returns a verified descriptor without downloading, or null when the
  /// catalog id has no retained OTA yet.
  Future<CachedOta?> lookup(CatalogRelease release) async {
    final index = File(
      joinPath(_byCatalog.path, ['${sha256Hex(utf8.encode(release.id))}.json']),
    );
    final descriptor = await _readDescriptor(index);
    if (descriptor == null) return null;
    if (descriptor.entryDigest != release.entryDigest) {
      throw const CatalogChangedException();
    }
    final file = _blob(descriptor.sha256);
    if (!await file.exists() || await file.length() != descriptor.size) {
      return null;
    }
    return CachedOta(descriptor: descriptor, file: file, cacheHit: true);
  }

  Future<List<OtaCacheEntry>> entries() async {
    final result = <OtaCacheEntry>[];
    if (!await _byCatalog.exists()) return result;
    await for (final entity in _byCatalog.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final descriptor = await _readDescriptor(entity);
        if (descriptor == null) continue;
        final blob = _blob(descriptor.sha256);
        if (!await blob.exists()) continue;
        result.add(
          OtaCacheEntry(
            descriptor: descriptor,
            index: entity,
            blob: blob,
            bytes: await blob.length(),
          ),
        );
      } on Object {
        // An unreadable index is not evictable through this path.
      }
    }
    return result;
  }

  /// Deletes one descriptor and its content when no other descriptor shares it.
  Future<void> deleteEntry(OtaCacheEntry entry) async {
    try {
      if (await entry.index.exists()) await entry.index.delete();
    } on Object {
      // Continue to the content check.
    }
    final remaining = await entries();
    final shared = remaining.any(
      (other) => other.descriptor.sha256 == entry.descriptor.sha256,
    );
    if (!shared) {
      try {
        if (await entry.blob.exists()) await entry.blob.delete();
      } on Object {
        // A content delete failure is handled by the next budget pass.
      }
    }
  }

  /// Removes interrupted download files from a previous process.
  Future<void> cleanupTemp() async {
    if (!await _temp.exists()) return;
    await for (final entity in _temp.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        await entity.delete();
      } on Object {
        // A stale temp file must not prevent startup.
      }
    }
  }

  Future<OtaDescriptor?> _readDescriptor(File index) async {
    try {
      final json = await readJsonObject(index, limit: 64 * 1024);
      return json == null ? null : OtaDescriptor.fromJson(json);
    } on Object {
      return null;
    }
  }

  Future<void> _writeDescriptor(File index, OtaDescriptor descriptor) =>
      atomicWriteJson(index, descriptor.toJson());

  File _blob(String sha256) =>
      File(joinPath(_blobs.path, ['$sha256.zip']));

  Future<String> _verifiedSha(File file, String expected) async {
    final modified = await file.lastModified();
    final length = await file.length();
    final known = _verified[file.path];
    if (known != null &&
        known.length == length &&
        known.modified == modified &&
        known.sha256 == expected) {
      return expected;
    }
    final actual = await sha256File(file);
    if (actual == expected) {
      _verified[file.path] = (
        length: length,
        modified: modified,
        sha256: actual,
      );
    }
    return actual;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // A stale temp file must not hide the download error.
    }
  }
}

final class _LinkExpired implements Exception {
  const _LinkExpired();
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
