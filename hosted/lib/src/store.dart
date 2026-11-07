import 'dart:convert';
import 'dart:io';

import 'errors.dart';
import 'job.dart';
import 'util.dart';

/// Persistent layout and atomic publication for hosted jobs.
final class HostedStore {
  HostedStore._(this.root);

  final Directory root;
  final Map<String, ({int length, DateTime modified, String sha256})>
  _verifiedArtifacts = {};

  static Future<HostedStore> open(Directory root) async {
    await root.create(recursive: true);
    final store = HostedStore._(root);
    await store.jobs.create(recursive: true);
    await store.work.create(recursive: true);
    await store.bloat.create(recursive: true);
    await store.otaBlobs.create(recursive: true);
    return store;
  }

  Directory get jobs => Directory(joinPath(root.path, ['jobs']));
  Directory get work => Directory(joinPath(root.path, ['work']));
  Directory get bloat => Directory(joinPath(root.path, ['bloat']));
  Directory get catalog =>
      Directory(joinPath(root.path, ['catalog']));
  Directory get otaRoot => Directory(joinPath(root.path, ['ota']));
  Directory get otaBlobs => Directory(joinPath(otaRoot.path, ['blobs']));

  Directory jobDir(String id) {
    if (!urlSafeId.hasMatch(id)) {
      throw const HostedInternalException(
        'job_id_invalid',
        'An internal job id is invalid.',
      );
    }
    return Directory(joinPath(jobs.path, [id]));
  }

  File artifactFile(String id) => File(joinPath(jobDir(id).path, ['artifact.zip']));

  File manifestFile(String id) => File(joinPath(jobDir(id).path, ['build.json']));

  File recordFile(String id) => File(joinPath(jobDir(id).path, ['job.json']));

  Directory workDir(String id) {
    if (!urlSafeId.hasMatch(id)) {
      throw const HostedInternalException(
        'job_id_invalid',
        'An internal job id is invalid.',
      );
    }
    return Directory(joinPath(work.path, [id]));
  }

  Future<Map<String, HostedJob>> loadPublished() async {
    final result = <String, HostedJob>{};
    await for (final entity in jobs.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = entity.path.split(Platform.pathSeparator).last;
      if (!urlSafeId.hasMatch(id)) continue;
      try {
        final json = await readJsonObject(
          File(joinPath(entity.path, ['job.json'])),
          limit: 4 * 1024 * 1024,
        );
        if (json == null) continue;
        final job = HostedJob.fromRecord(json);
        if (job.id != id) continue;
        if (job.state == HostedState.succeeded) {
          final artifact = artifactFile(id);
          if (!await artifact.exists() ||
              job.bytes == null ||
              await artifact.length() != job.bytes) {
            continue;
          }
        }
        result[id] = job;
      } on Object {
        // A partial or foreign directory is not a published job.
      }
    }
    return result;
  }

  /// Removes work directories from a previous process. They are never reused:
  /// an interrupted build has no committed artifact.
  Future<void> cleanupWorkOnStartup() async {
    await for (final entity in work.list(followLinks: false)) {
      if (entity is! Directory && entity is! File) continue;
      try {
        await entity.delete(recursive: true);
      } on Object {
        // A stale work directory must not prevent startup.
      }
    }
    await for (final entity in jobs.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.tmp-')) {
        try {
          await entity.delete(recursive: true);
        } on Object {
          // Best effort.
        }
      }
    }
  }

  Future<void> saveActive(HostedJob job) async {
    final directory = workDir(job.id);
    await directory.create(recursive: true);
    await atomicWriteJson(
      File(joinPath(directory.path, ['job.json'])),
      job.recordJson(),
    );
  }

  /// Publishes a finished artifact and its exact build.json atomically.
  Future<String> publishSucceeded({
    required HostedJob job,
    required File artifact,
    required File buildJson,
  }) async {
    final manifestBytes = await readBounded(buildJson, 1024 * 1024);
    final manifestSha = sha256Hex(manifestBytes);
    final temporary = Directory(
      joinPath(jobs.path, ['.tmp-${job.id}-${randomId(bytes: 6)}']),
    );
    await temporary.create(recursive: true);
    try {
      await _adoptFile(artifact, File(joinPath(temporary.path, ['artifact.zip'])));
      await atomicWriteBytes(
        File(joinPath(temporary.path, ['build.json'])),
        manifestBytes,
      );
      job.manifestSha256 = manifestSha;
      await atomicWriteJson(
        File(joinPath(temporary.path, ['job.json'])),
        job.recordJson(),
      );
      final finalDirectory = jobDir(job.id);
      if (await finalDirectory.exists()) {
        throw const HostedInternalException(
          'job_publish_conflict',
          'A job with this id is already published.',
        );
      }
      await temporary.rename(finalDirectory.path);
      if (job.sha256 != null && job.bytes != null) {
        final published = artifactFile(job.id);
        _verifiedArtifacts[job.id] = (
          length: job.bytes!,
          modified: await published.lastModified(),
          sha256: job.sha256!,
        );
      }
      return manifestSha;
    } on Object {
      try {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      } on Object {
        // The publication error wins.
      }
      rethrow;
    }
  }

  /// Publishes a failed job's metadata and any build log as evidence.
  Future<void> publishFailed({
    required HostedJob job,
    File? buildLog,
  }) async {
    final temporary = Directory(
      joinPath(jobs.path, ['.tmp-${job.id}-${randomId(bytes: 6)}']),
    );
    await temporary.create(recursive: true);
    try {
      if (buildLog != null && await buildLog.exists()) {
        await _copyBounded(
          buildLog,
          File(joinPath(temporary.path, ['build.log'])),
          4 * 1024 * 1024,
        );
      }
      await atomicWriteJson(
        File(joinPath(temporary.path, ['job.json'])),
        job.recordJson(),
      );
      final finalDirectory = jobDir(job.id);
      if (await finalDirectory.exists()) {
        throw const HostedInternalException(
          'job_publish_conflict',
          'A job with this id is already published.',
        );
      }
      await temporary.rename(finalDirectory.path);
    } on Object {
      try {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      } on Object {
        // The publication error wins.
      }
      rethrow;
    }
  }

  /// Publishes [job] as a Linux hard-link alias of [source]'s artifact. The
/// source is held by an active operation pin; failure to link fails closed
/// rather than creating a symlink whose target eviction could break.
  Future<void> publishAlias({
    required HostedJob job,
    required HostedJob source,
  }) async {
    final sourceArtifact = artifactFile(source.id);
    final sourceManifest = manifestFile(source.id);
    if (!await sourceArtifact.exists() || !await sourceManifest.exists()) {
      throw const HostedException(
        'artifact_missing',
        'The cache source is no longer retained.',
        status: 410,
      );
    }
    final temporary = Directory(
      joinPath(jobs.path, ['.tmp-${job.id}-${randomId(bytes: 6)}']),
    );
    await temporary.create(recursive: true);
    try {
      final destination = File(joinPath(temporary.path, ['artifact.zip']));
      final link = await Process.run(
        'ln',
        ['--', sourceArtifact.path, destination.path],
      );
      if (link.exitCode != 0) {
        throw const HostedInternalException(
          'alias_link_failed',
          'A hard link for the cached artifact could not be created.',
        );
      }
      final manifestBytes = await readBounded(sourceManifest, 1024 * 1024);
      await atomicWriteBytes(
        File(joinPath(temporary.path, ['build.json'])),
        manifestBytes,
      );
      await atomicWriteJson(
        File(joinPath(temporary.path, ['job.json'])),
        job.recordJson(),
      );
      final finalDirectory = jobDir(job.id);
      if (await finalDirectory.exists()) {
        throw const HostedInternalException(
          'job_publish_conflict',
          'A job with this id is already published.',
        );
      }
      await temporary.rename(finalDirectory.path);
      if (job.sha256 != null && job.bytes != null) {
        final published = artifactFile(job.id);
        _verifiedArtifacts[job.id] = (
          length: job.bytes!,
          modified: await published.lastModified(),
          sha256: job.sha256!,
        );
      }
    } on Object {
      try {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      } on Object {
        // The publication error wins.
      }
      rethrow;
    }
  }

  Future<void> touch(HostedJob job) async {
    job.lastUsedAt = DateTime.now().toUtc();
    final directory = jobDir(job.id);
    if (!await directory.exists()) return;
    await atomicWriteJson(File(joinPath(directory.path, ['job.json'])), job.recordJson());
  }

  Future<void> deleteJob(String id) async {
    final directory = jobDir(id);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<void> removeWork(String id) async {
    final directory = workDir(id);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<void> deleteBloat(String manifestSha) async {
    if (!isSha256Hex(manifestSha)) return;
    final directory = Directory(joinPath(bloat.path, [manifestSha]));
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<int> bytesOf(Directory directory) async {
    var total = 0;
    if (!await directory.exists()) return total;
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on Object {
          // A vanished file contributes nothing.
        }
      }
    }
    return total;
  }

  Future<String> verifyArtifact(HostedJob job) async {
    final file = artifactFile(job.id);
    if (!await file.exists()) {
      throw const HostedException(
        'artifact_missing',
        'The artifact is no longer retained.',
        status: 410,
      );
    }
    final length = await file.length();
    if (job.bytes == null || length != job.bytes) {
      throw const HostedException(
        'artifact_changed',
        'The artifact no longer matches its record.',
        status: 500,
      );
    }
    final modified = await file.lastModified();
    final known = _verifiedArtifacts[job.id];
    if (known != null &&
        known.length == length &&
        known.modified == modified &&
        job.sha256 != null &&
        known.sha256 == job.sha256) {
      return known.sha256;
    }
    final actual = await sha256File(file);
    if (job.sha256 == null || actual != job.sha256) {
      throw const HostedException(
        'artifact_changed',
        'The artifact no longer matches its record.',
        status: 500,
      );
    }
    _verifiedArtifacts[job.id] = (
      length: length,
      modified: modified,
      sha256: actual,
    );
    return actual;
  }

  Future<void> _adoptFile(File source, File destination) async {
    try {
      await source.rename(destination.path);
    } on FileSystemException {
      await _copyBounded(source, destination, 64 * 1024 * 1024 * 1024);
      await source.delete();
    }
  }

  Future<void> _copyBounded(File source, File destination, int limit) async {
    final length = await source.length();
    if (length > limit) {
      throw const HostedInternalException(
        'artifact_too_large',
        'A generated file exceeds the configured limit.',
      );
    }
    await destination.parent.create(recursive: true);
    final sink = destination.openWrite();
    try {
      await sink.addStream(source.openRead());
      await sink.flush();
    } finally {
      await sink.close();
    }
  }
}

/// Builds a path store map for the core pipeline.
Map<String, Object?> pathStore(String path) => {
  'kind': 'path',
  'path': Directory(path).absolute.path,
};

/// Builds a local OTA input map for the core pipeline.
Map<String, Object?> fileOta(String path) => {
  'kind': 'file',
  'file': File(path).absolute.path,
};

String encodeManifest(Map<String, Object?> manifest) =>
    const JsonEncoder.withIndent('  ').convert(manifest);
