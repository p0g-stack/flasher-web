import 'dart:async';
import 'dart:io';

import 'package:flasher_web_core/flasher_web_core.dart'
    hide OtaCache, OtaCacheEntry;
import 'package:flasher_web_hosted/hosted.dart';
import 'package:flasher_web_hosted/src/bloat_cache.dart';
import 'package:flasher_web_hosted/src/build_runner.dart';
import 'package:flasher_web_hosted/src/catalog_gateway.dart';
import 'package:flasher_web_hosted/src/cpu_limiter.dart';
import 'package:flasher_web_hosted/src/ota_cache.dart';
import 'package:flasher_web_hosted/src/store.dart';
import 'package:flasher_web_hosted/src/strict_http.dart';
import 'package:flasher_web_hosted/src/upstream_snapshot.dart';

Future<void> main() async {
  HostedConfig config;
  try {
    config = HostedConfig.fromEnvironment(Platform.environment);
    await config.checkForServer();
  } on Object catch (error) {
    stderr.writeln('hosted configuration error: $error');
    exitCode = 64;
    return;
  }

  if (!await loadNative()) {
    stderr.writeln(
      'hosted startup refused: the flasher_web native library is unavailable. '
      'Set P0G_NATIVE_LIB or install libflasher_web.so beside the executable.',
    );
    exitCode = 69;
    return;
  }

  final UpstreamSnapshot snapshot;
  final HostedStore store;
  try {
    snapshot = await UpstreamSnapshot.load(config.upstreamDir);
    store = await HostedStore.open(config.root);
  } on Object catch (error) {
    stderr.writeln('hosted storage error: $error');
    exitCode = 69;
    return;
  }

  final http = StrictHttp(config.apiOrigin);
  final catalog = CatalogGateway(
    config: config,
    http: http,
    cacheDir: store.catalog,
  );
  final otaCache = OtaCache(
    config: config,
    http: http,
    catalog: catalog,
    root: store.otaRoot,
  );
  final bloatCache = BloatCache(
    config: config,
    http: http,
    root: store.bloat,
  );
  final CpuLimiter cpuLimiter;
  try {
    cpuLimiter = await CpuLimiter.open(config);
  } on Object catch (error) {
    stderr.writeln('hosted CPU-limit error: $error');
    exitCode = 69;
    return;
  }
  final launcher = BuildRunner(config, cpuLimiter);
  try {
    await BuildRunner.checkTooling(config);
  } on Object catch (error) {
    stderr.writeln('hosted resource-limit error: $error');
    exitCode = 69;
    return;
  }
  final leases = LeaseManager(
    ttl: config.leaseTtl,
    maxLifetime: config.leaseMaxLifetime,
    maxPerJob: config.maxLeasesPerJob,
    internalTtl: config.internalLeaseTtl,
    maxInternalPerJob: config.maxInternalLeasesPerJob,
    maxInternalTotal: config.maxInternalLeasesTotal,
  );
  final service = HostedService(
    config: config,
    snapshot: snapshot,
    store: store,
    catalog: catalog,
    otaCache: otaCache,
    bloatCache: bloatCache,
    launcher: launcher,
    leases: leases,
  );
  await service.open();
  service.startMaintenance();

  final api = HostedApi(service: service, config: config);
  final HttpServer server;
  try {
    server = await HttpServer.bind(
      InternetAddress(config.bindAddress),
      config.port,
    );
    server.autoCompress = false;
    server.serverHeader = 'flasher-web-hosted';
  } on Object catch (error) {
    stderr.writeln('hosted bind error: $error');
    await service.close();
    http.close();
    exitCode = 69;
    return;
  }

  var stopping = false;
  Future<void> stop() async {
    if (stopping) return;
    stopping = true;
    await server.close(force: true);
    await service.close();
    http.close();
    exitCode = 0;
  }

  final signals = <StreamSubscription<ProcessSignal>>[];
  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    try {
      signals.add(signal.watch().listen((_) => unawaited(stop())));
    } on Object {
      // Signal watching is unavailable on this platform.
    }
  }

  stderr.writeln(
    'hosted server listening on ${config.bindAddress}:${server.port}; '
    'root=${config.root.path}',
  );
  await for (final request in server) {
    unawaited(_handleRequest(api, request));
  }
  for (final subscription in signals) {
    await subscription.cancel();
  }
  await stop();
}

Future<void> _handleRequest(HostedApi api, HttpRequest request) async {
  try {
    await api.handle(request);
  } on Object catch (error, stack) {
    stderr.writeln('hosted request failed: $error\n$stack');
    try {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"error":"Internal server error."}');
      await request.response.close();
    } on Object {
      // The client may already be gone.
    }
  }
}
