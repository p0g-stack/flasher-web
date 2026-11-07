import 'dart:convert';
import 'dart:io';

import 'package:flasher_web_hosted/src/job.dart';
import 'package:flasher_web_hosted/src/request.dart';
import 'package:flasher_web_hosted/src/store.dart';
import 'package:flasher_web_hosted/src/util.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late HostedStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hosted-store-');
    store = await HostedStore.open(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  HostedJob job({String? id}) => HostedJob(
    id: id ?? randomId(),
    request: const HostedJobRequest(
      device: 'Oneplus 13',
      kind: 'SuperHybrid Flasher',
      region: 'GLO',
      catalogId: 'release-1',
    ),
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
    lastUsedAt: DateTime.utc(2026, 1, 1),
  );

  test('publishes artifact and exact manifest atomically', () async {
    final entry = job();
    final artifact = File(joinPath(root.path, ['source.zip']));
    final bytes = utf8.encode('zip bytes');
    await artifact.writeAsBytes(bytes, flush: true);
    final sha = sha256Hex(bytes);
    final manifestBytes = utf8.encode('{"artifact":"flasher.zip"}\n');
    final buildJson = File(joinPath(root.path, ['build.json']));
    await buildJson.writeAsBytes(manifestBytes, flush: true);

    entry
      ..state = HostedState.succeeded
      ..artifactName = 'flasher.zip'
      ..sha256 = sha
      ..bytes = bytes.length
      ..manifest = {'artifact': 'flasher.zip'};

    final manifestSha = await store.publishSucceeded(
      job: entry,
      artifact: artifact,
      buildJson: buildJson,
    );
    expect(manifestSha, sha256Hex(manifestBytes));
    expect(entry.manifestSha256, manifestSha);

    final published = await store.artifactFile(entry.id).readAsBytes();
    expect(published, bytes);
    expect(await store.verifyArtifact(entry), sha);
    expect(
      await store.manifestFile(entry.id).readAsString(),
      utf8.decode(manifestBytes),
    );

    final loaded = await store.loadPublished();
    expect(loaded[entry.id]?.state, HostedState.succeeded);
    expect(loaded[entry.id]?.sha256, sha);
    expect(loaded[entry.id]?.manifestSha256, manifestSha);
  });

  test('an alias is a hard link that outlives the cache source', () async {
    final source = job();
    final artifact = File(joinPath(root.path, ['source.zip']));
    final bytes = utf8.encode('shared artifact');
    await artifact.writeAsBytes(bytes, flush: true);
    final buildJson = File(joinPath(root.path, ['build.json']));
    await buildJson.writeAsString(
      '{"artifact":"flasher.zip"}',
      flush: true,
    );
    source
      ..state = HostedState.succeeded
      ..artifactName = 'flasher.zip'
      ..sha256 = sha256Hex(bytes)
      ..bytes = bytes.length
      ..manifest = {'artifact': 'flasher.zip'};
    await store.publishSucceeded(
      job: source,
      artifact: artifact,
      buildJson: buildJson,
    );

    final alias = job();
    alias
      ..state = HostedState.succeeded
      ..artifactName = source.artifactName
      ..sha256 = source.sha256
      ..bytes = source.bytes
      ..manifest = source.manifest
      ..manifestSha256 = source.manifestSha256
      ..sourceJobId = source.id
      ..cacheHit = true;
    await store.publishAlias(job: alias, source: source);
    expect(await store.verifyArtifact(alias), source.sha256);

    await store.deleteJob(source.id);
    expect(await store.artifactFile(alias.id).readAsBytes(), bytes);
  });

  test('failed jobs keep log evidence and no artifact', () async {
    final failed = job()..state = HostedState.failed;
    failed
      ..error = 'build failed'
      ..errorCode = 'build_failed';
    final log = File(joinPath(root.path, ['build.log']));
    await log.writeAsString('first line\nsecond line\n', flush: true);
    await store.publishFailed(job: failed, buildLog: log);

    final loaded = await store.loadPublished();
    expect(loaded[failed.id]?.state, HostedState.failed);
    expect(loaded[failed.id]?.error, 'build failed');
    expect(await store.artifactFile(failed.id).exists(), isFalse);
    expect(
      await File(joinPath(store.jobDir(failed.id).path, ['build.log']))
          .readAsString(),
      contains('second line'),
    );
  });

  test('startup removes interrupted work and temporary publications', () async {
    final work = store.workDir(randomId());
    await work.create(recursive: true);
    await File(joinPath(work.path, ['job.json'])).writeAsString('{}');
    final temporary = Directory(
      joinPath(store.jobs.path, ['.tmp-${randomId()}']),
    );
    await temporary.create(recursive: true);

    await store.cleanupWorkOnStartup();
    expect(await work.exists(), isFalse);
    expect(await temporary.exists(), isFalse);
  });

  test('public metadata carries exact length, hash and retention', () {
    final completed = job()..state = HostedState.succeeded;
    completed
      ..artifactName = 'flasher.zip'
      ..sha256 = 'a' * 64
      ..bytes = 123
      ..lastUsedAt = DateTime.utc(2026, 1, 1);
    final json = completed.publicJson(
      retention: const Duration(days: 150),
    );
    expect(json['status'], 'succeeded');
    expect(json['sha256'], 'a' * 64);
    expect(json['bytes'], 123);
    expect(json['artifactUrl'], '/api/hosted/jobs/${completed.id}/artifact');
    final cache = json['cache'] as Map;
    expect(cache['hit'], isFalse);
    expect(cache['lastUsed'], '2026-01-01T00:00:00Z');
    expect(cache['retainedUntil'], '2026-05-31T00:00:00Z');
  });
}
