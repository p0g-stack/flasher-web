import 'dart:io';

import 'package:flasher_web_hosted/src/config.dart';
import 'package:test/test.dart';

void main() {
  Map<String, String> environment({
    String token = 'tttttttttttttttttttttttttttttttt',
    String origin = 'https://edge.example.com',
    String bind = '127.0.0.1',
  }) => {
    'HOSTED_ROOT': '/tmp/hosted-root',
    'HOSTED_UPSTREAM_DIR': '/tmp/hosted-upstream',
    'HOSTED_TOKEN': token,
    'HOSTED_BUILDER_REVISION': 'builder-smoke-1',
    'HOSTED_API_ORIGIN': origin,
    'HOSTED_BIND': bind,
  };

  test('parses a complete private environment', () {
    final config = HostedConfig.fromEnvironment(environment());
    expect(config.bindAddress, '127.0.0.1');
    expect(config.concurrency, 2);
    expect(config.retentionDays, 150);
    expect(config.otaRetentionDays, 150);
    expect(config.leaseTtl, const Duration(seconds: 900));
    expect(config.leaseMaxLifetime, const Duration(hours: 12));
    expect(config.otaHostAllowed('foo.allawnofs.com'), isTrue);
    expect(config.otaHostAllowed('evilallawnofs.com'), isFalse);
  });

  test('never accepts a public bind address or a non-private HTTP origin', () {
    expect(
      () => HostedConfig.fromEnvironment(environment(bind: '0.0.0.0')),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => HostedConfig.fromEnvironment(
        environment(origin: 'http://edge.example.com'),
      ),
      throwsA(isA<HostedConfigException>()),
    );
    expect(
      () => HostedConfig.fromEnvironment(
        environment(origin: 'https://edge.example.com/path'),
      ),
      throwsA(isA<HostedConfigException>()),
    );
  });

  test('requires a strong token and a loopback/private bind', () {
    expect(
      () => HostedConfig.fromEnvironment(environment(token: 'short')),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => HostedConfig.fromEnvironment(environment(bind: '8.8.8.8')),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => HostedConfig.fromEnvironment(environment(bind: '192.168.1.2')),
      returnsNormally,
    );
  });

  test('OTA URL policy enforces scheme, host, path and credentials', () {
    final config = HostedConfig.fromEnvironment(environment());
    expect(
      config
          .checkOtaUrl(
            'https://roms.danielspringer.at/download.php?token=x',
          )
          .host,
      'roms.danielspringer.at',
    );
    for (final url in [
      'http://roms.danielspringer.at/download.php',
      'https://roms.danielspringer.at/not-download',
      'https://user:pass@roms.danielspringer.at/download.php',
      'https://roms.danielspringer.at:8443/download.php',
      'https://evil.example.com/file.zip',
    ]) {
      expect(
        () => config.checkOtaUrl(url),
        throwsA(isA<HostedConfigException>()),
        reason: url,
      );
    }
  });

  test('rejects a minimum free space larger than the cache budget', () {
    expect(
      () => HostedConfig.fromEnvironment({
        ...environment(),
        'HOSTED_CACHE_BYTES': '${1024 * 1024 * 1024}',
        'HOSTED_MIN_FREE_BYTES': '${2 * 1024 * 1024 * 1024}',
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('internal lease TTL must exceed the artifact stream timeout', () async {
    final config = HostedConfig(
      root: Directory('/tmp/hosted-root'),
      token: 't' * 32,
      apiOrigin: Uri.parse('https://edge.example.com'),
      upstreamDir: Directory('/tmp/hosted-upstream'),
      builderRevision: 'builder-smoke-1',
      internalLeaseTtl: const Duration(seconds: 5),
      artifactStreamTimeout: const Duration(seconds: 10),
    );
    await expectLater(
      config.checkForServer(),
      throwsA(isA<HostedConfigException>()),
    );
  });

  test('directories must exist and be writable', () async {
    final root = await Directory.systemTemp.createTemp('hosted-config-');
    final upstream = await Directory.systemTemp.createTemp('hosted-up-');
    try {
      await File('${upstream.path}/tables.json').writeAsString('{}');
      await File('${upstream.path}/bloat-manifest.json').writeAsString('{}');
      await File('${upstream.path}/platform-tools.zip').writeAsString('');
      final config = HostedConfig(
        root: root,
        token: 't' * 32,
        apiOrigin: Uri.parse('https://edge.example.com'),
        upstreamDir: upstream,
        builderRevision: 'builder-smoke-1',
      );
      await config.checkForServer();
    } finally {
      await root.delete(recursive: true);
      await upstream.delete(recursive: true);
    }
  });
}
