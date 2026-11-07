import 'dart:io';

import 'package:flasher_web_cli/flasher_web_cli.dart';
import 'package:flasher_web_cli/src/service_args.dart';
import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

void main() {
  group('service maps', () {
    test('a selection uses upstream display names', () {
      expect(
        selectionMap(
          device: 'Oneplus 13',
          kind: 'SuperHybrid Flasher',
          region: 'GLO',
        ),
        {
          'device': 'Oneplus 13',
          'kind': 'SuperHybrid Flasher',
          'region': 'GLO',
        },
      );
    });

    test('a path store and a file OTA are absolute', () {
      final store = pathStore('bloat');
      expect(store['kind'], 'path');
      expect((store['path'] as String).endsWith('/bloat'), isTrue);
      expect((store['path'] as String).startsWith('/'), isTrue);

      final ota = fileOta('ota.zip');
      expect(ota['kind'], 'file');
      expect((ota['file'] as String).endsWith('/ota.zip'), isTrue);
    });

    test('inspect picks a URL or a file', () {
      expect(otaInput('https://example.com/OTA.zip'), {
        'kind': 'url',
        'url': 'https://example.com/OTA.zip',
      });
      expect((otaInput('/tmp/OTA.zip')['kind']), 'file');
    });

    test('upstream is a URL or an absolute directory', () {
      expect(
        upstreamBase('https://example.com/upstream/'),
        'https://example.com/upstream/',
      );
      expect(
        upstreamBase('app/web/upstream'),
        Directory('app/web/upstream').absolute.path,
      );
    });

    test('an API base must be HTTP(S)', () {
      expect(
        apiBaseUri('http://127.0.0.1:8787'),
        Uri.parse('http://127.0.0.1:8787/'),
      );
      expect(() => apiBaseUri('127.0.0.1:8787'), throwsFormatException);
      expect(() => apiBaseUri('ftp://example.com'), throwsFormatException);
    });
  });

  group('build request', () {
    test('carries the required service fields and omits optional ones', () {
      final request = buildRequest(
        selection: selectionMap(
          device: 'Oneplus 13',
          kind: 'SuperHybrid Flasher',
          region: 'GLO',
        ),
        ota: fileOta('/tmp/ota.zip'),
        base: null,
        vulnerableAbl: null,
        zip: true,
        bloatDir: '/tmp/bloat',
        outputDir: '/tmp/output',
        apiBase: 'http://127.0.0.1:8787',
        upstream: 'app/web/upstream',
      );

      expect(request['selection'], {
        'device': 'Oneplus 13',
        'kind': 'SuperHybrid Flasher',
        'region': 'GLO',
      });
      expect(request['ota'], {
        'kind': 'file',
        'file': File('/tmp/ota.zip').absolute.path,
      });
      expect(request.containsKey('base'), isFalse);
      expect(request.containsKey('vulnerableAbl'), isFalse);
      expect(request['zip'], isTrue);
      expect(request['bloat'], {
        'kind': 'path',
        'path': Directory('/tmp/bloat').absolute.path,
      });
      expect(request['output'], {
        'kind': 'path',
        'path': Directory('/tmp/output').absolute.path,
      });
      expect(request['apiBase'], 'http://127.0.0.1:8787');
      expect(
        request['upstreamBase'],
        Directory('app/web/upstream').absolute.path,
      );
    });

    test('bloat and inspect requests carry the service contract', () {
      final bloat = bloatRequest(
        selection: selectionMap(
          device: 'Oneplus 13',
          kind: 'SuperHybrid Flasher',
          region: 'GLO',
        ),
        bloatDir: '/tmp/bloat',
        apiBase: 'http://127.0.0.1:8787',
        upstream: 'app/web/upstream',
      );
      expect(bloat['selection'], {
        'device': 'Oneplus 13',
        'kind': 'SuperHybrid Flasher',
        'region': 'GLO',
      });
      expect(bloat['store'], {
        'kind': 'path',
        'path': Directory('/tmp/bloat').absolute.path,
      });
      expect(bloat['apiBase'], 'http://127.0.0.1:8787');
      expect(
        bloat['upstreamBase'],
        Directory('app/web/upstream').absolute.path,
      );

      final inspect = inspectRequest(
        ota: urlOta('https://example.com/OTA.zip'),
        apiBase: 'http://127.0.0.1:8787',
      );
      expect(inspect['ota'], {
        'kind': 'url',
        'url': 'https://example.com/OTA.zip',
      });
      expect(inspect['apiBase'], 'http://127.0.0.1:8787');
    });

    test('conversion carries a URL base and the ABL choice', () {
      final request = buildRequest(
        selection: selectionMap(
          device: 'Oneplus Ace 6',
          kind: 'SuperHybrid Flasher',
          region: 'IN',
        ),
        ota: urlOta('https://example.com/target.zip'),
        base: urlOta('https://example.com/base.zip'),
        vulnerableAbl: false,
        zip: false,
        bloatDir: 'bloat',
        outputDir: 'builds',
        apiBase: 'https://example.com',
        upstream: 'https://example.com/upstream/',
      );

      expect(request['base'], {
        'kind': 'url',
        'url': 'https://example.com/base.zip',
      });
      expect(request['vulnerableAbl'], isFalse);
      expect(request['zip'], isFalse);
      expect(request['upstreamBase'], 'https://example.com/upstream/');
    });
  });

  group('catalog roles', () {
    test(
      'a selection without a BASE target fails before any request',
      () async {
        await expectLater(
          resolveCatalogEntry(
            apiBase: 'http://127.0.0.1:8787',
            device: 'Oneplus 13',
            kind: 'SuperHybrid Flasher',
            region: 'GLO',
            id: 'release',
            role: 'base',
          ),
          throwsA(isA<CatalogException>()),
        );
      },
    );

    test('an unknown device fails before any request', () async {
      await expectLater(
        resolveCatalogEntry(
          apiBase: 'http://127.0.0.1:8787',
          device: 'Not A Device',
          kind: 'SuperHybrid Flasher',
          region: 'GLO',
          id: 'release',
          role: 'ota',
        ),
        throwsA(isA<CatalogException>()),
      );
    });
  });

  group('usage', () {
    const baseArgs = [
      'build',
      '--device',
      'Oneplus 13',
      '--kind',
      'SuperHybrid Flasher',
      '--region',
      'GLO',
      '--bloat-dir',
      '/tmp/bloat',
      '--output',
      '/tmp/output',
    ];

    Future<int> run(List<String> args) => AppRunner().run(args);

    test('build requires device, kind, region, bloat and output', () async {
      expect(await run(['build']), 64);
      expect(await run(['build', '--device', 'Oneplus 13']), 64);
    });

    test('build needs exactly one OTA source', () async {
      expect(await run([...baseArgs]), 64);
      expect(
        await run([...baseArgs, '--ota', 'ota.zip', '--catalog-id', 'id']),
        64,
      );
    });

    test('build takes at most one ABL choice', () async {
      expect(
        await run([
          ...baseArgs,
          '--ota',
          'ota.zip',
          '--vulnerable-abl',
          '--stock-abl',
        ]),
        64,
      );
    });

    test('build takes at most one BASE source', () async {
      expect(
        await run([
          ...baseArgs,
          '--ota',
          'ota.zip',
          '--base',
          'base.zip',
          '--base-catalog-id',
          'id',
        ]),
        64,
      );
    });

    test('build rejects an unknown option and an invalid API base', () async {
      expect(await run([...baseArgs, '--ota', 'ota.zip', '--nope']), 64);
      expect(
        await run([
          ...baseArgs,
          '--ota',
          'ota.zip',
          '--api-base',
          '127.0.0.1:8787',
        ]),
        64,
      );
    });

    test('flash requires the job, device and serial arguments', () async {
      expect(await run(['flash']), 64);
      expect(
        await run([
          'flash',
          '--output',
          '/tmp/output',
          '--job',
          'job',
          '--device',
          'Oneplus 13',
          '--kind',
          'Super Flasher',
          '--region',
          'EU',
        ]),
        64,
      );
      expect(
        await run([
          'flash',
          '--output',
          '/tmp/output',
          '--job',
          'job',
          '--device',
          'Oneplus 13',
          '--kind',
          'Super Flasher',
          '--region',
          'EU',
          '--serial',
          'SERIAL',
          '--answer',
          'not-an-answer',
        ]),
        64,
      );
    });

    test('inspect takes exactly one ZIP or URL', () async {
      expect(await run(['inspect']), 64);
      expect(await run(['inspect', 'a.zip', 'b.zip']), 64);
      expect(
        await run(['inspect', 'a.zip', '--api-base', '127.0.0.1:8787']),
        64,
      );
    });

    test('bloat requires a device, flasher, region and folder', () async {
      expect(await run(['bloat']), 64);
      expect(await run(['bloat', '--device', 'Oneplus 13']), 64);
    });
  });
}
