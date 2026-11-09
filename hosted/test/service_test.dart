import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flasher_web_core/flasher_web_core.dart'
    hide OtaCache, OtaCacheEntry;
import 'package:flasher_web_hosted/src/bloat_cache.dart';
import 'package:flasher_web_hosted/src/build_runner.dart';
import 'package:flasher_web_hosted/src/catalog_gateway.dart';
import 'package:flasher_web_hosted/src/errors.dart';
import 'package:flasher_web_hosted/src/config.dart';
import 'package:flasher_web_hosted/src/http_api.dart';
import 'package:flasher_web_hosted/src/job.dart';
import 'package:flasher_web_hosted/src/jobs.dart';
import 'package:flasher_web_hosted/src/leases.dart';
import 'package:flasher_web_hosted/src/ota_cache.dart';
import 'package:flasher_web_hosted/src/request.dart';
import 'package:flasher_web_hosted/src/store.dart';
import 'package:flasher_web_hosted/src/strict_http.dart';
import 'package:flasher_web_hosted/src/upstream_snapshot.dart';
import 'package:flasher_web_hosted/src/util.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory upstream;
  late HttpServer server;
  late StrictHttp http;
  late HostedConfig config;
  late HostedService service;
  late FakeLauncher launcher;
  late UpstreamSnapshot snapshot;
  late HostedStore store;
  late CatalogGateway catalog;
  late OtaCache otaCache;
  late BloatCache bloatCache;
  var catalogVersion = '1.0.0';
  final otaBytes = Uint8List.fromList(List<int>.generate(128, (value) => value));

  setUp(() async {
    catalogVersion = '1.0.0';
    root = await Directory.systemTemp.createTemp('hosted-e2e-');
    upstream = Directory(joinPath(root.path, ['upstream']));
    await upstream.create(recursive: true);
    await File(joinPath(upstream.path, ['tables.json'])).writeAsString('{}');
    await File(
      joinPath(upstream.path, ['bloat-manifest.json']),
    ).writeAsString('{}');
    await File(
      joinPath(upstream.path, ['platform-tools.zip']),
    ).writeAsString('');

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/api/catalog':
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({
            'api_version': '1',
            'releases': [
              {
                'id': 'rel-1',
                'device': 'OP 13',
                'region': 'GLO',
                'version': catalogVersion,
                'source_url':
                    'https://roms.danielspringer.at/download.php?token=fresh',
                'size': otaBytes.length,
              },
            ],
          }));
          await response.close();
          break;
        case '/api/resolve':
          await request.drain<void>();
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({
            'url': 'https://roms.danielspringer.at/download.php?token=fresh',
          }));
          await response.close();
          break;
        case '/api/ota':
          final range = request.headers.value(HttpHeaders.rangeHeader);
          final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range ?? '');
          if (match == null) {
            response.statusCode = 400;
            await response.close();
            break;
          }
          final start = int.parse(match.group(1)!);
          final end = int.parse(match.group(2)!);
          response.statusCode = 206;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${otaBytes.length}',
          );
          response.contentLength = end - start + 1;
          response.add(otaBytes.sublist(start, end + 1));
          await response.close();
          break;
        default:
          response.statusCode = 404;
          await response.close();
          break;
      }
    });

    http = StrictHttp(Uri.parse('http://127.0.0.1:${server.port}'));
    config = HostedConfig(
      root: root,
      token: 'x' * 32,
      apiOrigin: Uri.parse('http://127.0.0.1:${server.port}'),
      upstreamDir: upstream,
      builderRevision: 'builder-smoke-1',
      cacheBudgetBytes: 1024 * 1024 * 1024,
      minFreeBytes: 0,
      maxOtaBytes: 1024 * 1024,
      jobDiskBytes: 1024 * 1024,
    );
    store = await HostedStore.open(root);
    final manifest = BloatManifest.fromJson({
      'schema_version': 1,
      'repository': 'p0g-stack/fixtures',
      'tag': 'fixture',
      'assets': <String, dynamic>{},
      'files': <String, dynamic>{},
    });
    snapshot = UpstreamSnapshot(
      directory: upstream,
      tables: UpstreamTables(
        commit: 'fixture-commit',
        devices: {'Oneplus 13': '13'},
        regionSizes: {},
        builders: const [
          BuilderEntry(
            type: 'SuperHybrid Flasher',
            dev: '13',
            region: 'GLO',
            builder: 'BUILD_SUPER.sh',
          ),
        ],
      ),
      manifest: manifest,
      manifestSha256: 'a' * 64,
      snapshotSha256: 'b' * 64,
    );
    catalog = CatalogGateway(
      config: config,
      http: http,
      cacheDir: Directory(joinPath(root.path, ['catalog'])),
    );
    otaCache = OtaCache(
      config: config,
      http: http,
      catalog: catalog,
      root: store.otaRoot,
    );
    bloatCache = BloatCache(
      config: config,
      http: http,
      root: store.bloat,
    );
    launcher = FakeLauncher();
    service = HostedService(
      config: config,
      snapshot: snapshot,
      store: store,
      catalog: catalog,
      otaCache: otaCache,
      bloatCache: bloatCache,
      launcher: launcher,
      leases: LeaseManager(
        ttl: const Duration(seconds: 60),
        maxLifetime: const Duration(hours: 1),
        maxPerJob: 4,
      ),
    );
    await service.open();
  });

  tearDown(() async {
    await service.close();
    http.close();
    await server.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('runs a fake local build and returns the published artifact', () async {
    final result = await service.submit(
      const HostedJobRequest(
        device: 'Oneplus 13',
        kind: 'SuperHybrid Flasher',
        region: 'GLO',
        catalogId: 'rel-1',
      ),
    );
    expect(result.statusCode, 202);
    final done = await _waitFor(service, result.job.id);
    expect(done.state, HostedState.succeeded, reason: done.error);
    expect(done.sha256, sha256Hex(launcher.bytes));
    expect(done.bytes, launcher.bytes.length);
    expect(done.manifest?['device'], 'Oneplus 13');
    final artifact = await service.artifact(result.job.id);
    expect(await artifact.readAsBytes(), launcher.bytes);
    final manifest = await service.manifest(result.job.id);
    expect(jsonDecode(utf8.decode(manifest))['artifact'], 'flasher.zip');
    expect(service.publicJob(result.job.id)?['status'], 'succeeded');
  });

  test('identical completed work is reused without a second build', () async {
    final first = await service.submit(
      const HostedJobRequest(
        device: 'Oneplus 13',
        kind: 'SuperHybrid Flasher',
        region: 'GLO',
        catalogId: 'rel-1',
      ),
    );
    await _waitFor(service, first.job.id);
    final second = await service.submit(
      const HostedJobRequest(
        device: 'Oneplus 13',
        kind: 'SuperHybrid Flasher',
        region: 'GLO',
        catalogId: 'rel-1',
        vulnerableAbl: false,
      ),
    );
    expect(second.reused, isTrue);
    expect(second.job.id, first.job.id);
    expect(launcher.builds, 1);
    final reused = service.publicJob(second.job.id, hitOverride: true);
    final cache = reused?['cache'] as Map;
    expect(cache['hit'], isTrue);
    expect(cache['lastUsed'], isA<String>());
    expect(cache['retainedUntil'], isA<String>());
  });

  HostedConfig secondConfig({required String builder}) => HostedConfig(
    root: root,
    token: config.token,
    apiOrigin: config.apiOrigin,
    upstreamDir: upstream,
    builderRevision: builder,
    cacheBudgetBytes: 1024 * 1024 * 1024,
    minFreeBytes: 0,
    maxOtaBytes: 1024 * 1024,
    jobDiskBytes: 1024 * 1024,
  );

  HostedService spawn({
    required HostedConfig cfg,
    required FakeLauncher buildLauncher,
    UpstreamSnapshot? snap,
    CatalogGateway? catalogOverride,
    OtaCache? otaOverride,
  }) => HostedService(
    config: cfg,
    snapshot: snap ?? snapshot,
    store: store,
    catalog: catalogOverride ?? catalog,
    otaCache: otaOverride ?? otaCache,
    bloatCache: bloatCache,
    launcher: buildLauncher,
    leases: LeaseManager(
      ttl: const Duration(seconds: 60),
      maxLifetime: const Duration(hours: 1),
      maxPerJob: 4,
    ),
  );

  test('repeated cache hits share one handoff pin and never rebuild', () async {
    final request = const HostedJobRequest(
      device: 'Oneplus 13',
      kind: 'SuperHybrid Flasher',
      region: 'GLO',
      catalogId: 'rel-1',
    );
    final first = await service.submit(request);
    await _waitFor(service, first.job.id);
    for (var index = 0; index < 8; index++) {
      final hit = await service.submit(request);
      expect(hit.reused, isTrue, reason: 'hit $index');
      expect(hit.job.id, first.job.id);
    }
    expect(launcher.builds, 1);
  });

  test('completed request is rebuilt after a builder revision change', () async {
    final request = const HostedJobRequest(
      device: 'Oneplus 13',
      kind: 'SuperHybrid Flasher',
      region: 'GLO',
      catalogId: 'rel-1',
    );
    final first = await service.submit(request);
    await _waitFor(service, first.job.id);
    await service.close();

    final secondLauncher = FakeLauncher();
    final second = spawn(
      cfg: secondConfig(builder: 'builder-smoke-2'),
      buildLauncher: secondLauncher,
    );
    await second.open();
    try {
      final result = await second.submit(request);
      expect(result.job.id, isNot(first.job.id));
      final done = await _waitFor(second, result.job.id);
      expect(done.state, HostedState.succeeded, reason: done.error);
      expect(secondLauncher.builds, 1);
    } finally {
      await second.close();
    }
  });

  test('completed request is rebuilt after an upstream snapshot change',
      () async {
    final request = const HostedJobRequest(
      device: 'Oneplus 13',
      kind: 'SuperHybrid Flasher',
      region: 'GLO',
      catalogId: 'rel-1',
    );
    final first = await service.submit(request);
    await _waitFor(service, first.job.id);
    await service.close();

    final changed = UpstreamSnapshot(
      directory: snapshot.directory,
      tables: snapshot.tables,
      manifest: snapshot.manifest,
      manifestSha256: snapshot.manifestSha256,
      snapshotSha256: 'c' * 64,
    );
    final secondLauncher = FakeLauncher();
    final second = spawn(
      cfg: secondConfig(builder: 'builder-smoke-1'),
      buildLauncher: secondLauncher,
      snap: changed,
    );
    await second.open();
    try {
      final result = await second.submit(request);
      expect(result.job.id, isNot(first.job.id));
      final done = await _waitFor(second, result.job.id);
      expect(done.state, HostedState.succeeded, reason: done.error);
      expect(secondLauncher.builds, 1);
    } finally {
      await second.close();
    }
  });

  test('changed catalog metadata never returns the old completed artifact',
      () async {
    final request = const HostedJobRequest(
      device: 'Oneplus 13',
      kind: 'SuperHybrid Flasher',
      region: 'GLO',
      catalogId: 'rel-1',
    );
    final first = await service.submit(request);
    await _waitFor(service, first.job.id);
    await service.close();

    catalogVersion = '2.0.0';
    final changedCatalog = CatalogGateway(
      config: config,
      http: http,
      cacheDir: Directory(joinPath(root.path, ['catalog-two'])),
    );
    final changedOta = OtaCache(
      config: config,
      http: http,
      catalog: changedCatalog,
      root: store.otaRoot,
    );
    final secondLauncher = FakeLauncher();
    final second = spawn(
      cfg: secondConfig(builder: 'builder-smoke-1'),
      buildLauncher: secondLauncher,
      catalogOverride: changedCatalog,
      otaOverride: changedOta,
    );
    await second.open();
    try {
      await expectLater(
        second.submit(request),
        throwsA(isA<CatalogChangedException>()),
      );
      expect(secondLauncher.builds, 0);
    } finally {
      await second.close();
    }
  });

  test('HTTP API requires the token, serves ranges and leases', () async {
    final submitted = await service.submit(
      const HostedJobRequest(
        device: 'Oneplus 13',
        kind: 'SuperHybrid Flasher',
        region: 'GLO',
        catalogId: 'rel-1',
      ),
    );
    final done = await _waitFor(service, submitted.job.id);
    final apiServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = HostedApi(service: service, config: config);
    apiServer.listen(api.handle);
    final client = HttpClient();
    try {
      Future<HttpClientResponse> send(
        String method,
        String path, {
        bool token = true,
        Map<String, String> headers = const {},
      }) async {
        final request = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:${apiServer.port}$path'),
        );
        if (token) request.headers.set('X-Hosted-Token', config.token);
        for (final entry in headers.entries) {
          request.headers.set(entry.key, entry.value);
        }
        return request.close();
      }

      final unauthorized = await send(
        'GET',
        '/api/hosted/jobs/${done.id}',
        token: false,
      );
      expect(unauthorized.statusCode, 401);
      await unauthorized.drain<void>();

      final metadata = await send('GET', '/api/hosted/jobs/${done.id}');
      expect(metadata.statusCode, 200);
      expect(metadata.headers.value(HttpHeaders.cacheControlHeader), contains('no-store'));
      final json =
          jsonDecode(await metadata.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(json['status'], 'succeeded');
      expect(json['bytes'], launcher.bytes.length);
      expect(json['sha256'], sha256Hex(launcher.bytes));
      expect(json['manifestSha256'], isA<String>());

      final etag = '"${sha256Hex(launcher.bytes)}"';
      final range = await send(
        'GET',
        '/api/hosted/jobs/${done.id}/artifact',
        headers: {'Range': 'bytes=0-3'},
      );
      expect(range.statusCode, 206);
      expect(range.headers.value(HttpHeaders.etagHeader), etag);
      expect(range.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-3/${launcher.bytes.length}');
      final rangeBytes = <int>[];
      await for (final chunk in range) {
        rangeBytes.addAll(chunk);
      }
      expect(rangeBytes, launcher.bytes.sublist(0, 4));

      final leaseResponse = await send(
        'POST',
        '/api/hosted/jobs/${done.id}/lease',
      );
      expect(leaseResponse.statusCode, 201);
      final lease =
          jsonDecode(await leaseResponse.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(urlSafeId.hasMatch(lease['leaseId'] as String), isTrue);
      final expiresAt = DateTime.parse(lease['expiresAt'] as String);
      expect(expiresAt.isUtc, isTrue);

      final renew = await send(
        'POST',
        '/api/hosted/jobs/${done.id}/lease/${lease['leaseId']}/renew',
      );
      expect(renew.statusCode, 200);
      final renewed =
          jsonDecode(await renew.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(renewed['leaseId'], lease['leaseId']);

      final release = await send(
        'DELETE',
        '/api/hosted/jobs/${done.id}/lease/${lease['leaseId']}',
      );
      expect(release.statusCode, 204);
      await release.drain<void>();
    } finally {
      client.close(force: true);
      await apiServer.close(force: true);
    }
  });
}

Future<HostedJob> _waitFor(HostedService service, String id) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final job = service.job(id);
    if (job != null && job.finished) return job;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('job did not finish');
}

final class FakeLauncher implements BuildLauncher {
  final Uint8List bytes = Uint8List.fromList(utf8.encode('fake flasher zip'));
  int builds = 0;

  @override
  Future<BuildProcess> start({
    required String jobId,
    required File requestFile,
    required void Function(Map<String, Object?> event) onEvent,
  }) async {
    builds++;
    final request =
        jsonDecode(await requestFile.readAsString()) as Map<String, dynamic>;
    final output = (request['output'] as Map)['path'] as String;
    final jobName = 'fixture-$jobId';
    final directory = Directory(joinPath(output, [jobName]));
    await directory.create(recursive: true);
    await File(
      joinPath(directory.path, ['flasher.zip']),
    ).writeAsBytes(bytes, flush: true);
    await File(
      joinPath(directory.path, ['build.json']),
    ).writeAsString(
      jsonEncode({
        'device': 'Oneplus 13',
        'artifact': 'flasher.zip',
      }),
      flush: true,
    );
    onEvent({
      'type': 'step',
      'index': 1,
      'total': 5,
      'title': 'Prepare OTA',
    });
    return _FakeProcess(
      BuildOutcome(
        manifest: {'device': 'Oneplus 13', 'artifact': 'flasher.zip'},
        jobName: jobName,
        artifactName: 'flasher.zip',
        sha256: sha256Hex(bytes),
      ),
    );
  }
}

final class _FakeProcess implements BuildProcess {
  _FakeProcess(this.outcome);

  final BuildOutcome outcome;

  @override
  Future<BuildOutcome> finish() async => outcome;

  @override
  void kill() {}
}
