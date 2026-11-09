import 'dart:io';

import 'package:flasher_web_cli/flasher_web_cli.dart';
import 'package:flasher_web_cli/src/service_args.dart';
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

    test('a path store is absolute', () {
      final store = pathStore('bloat');
      expect(store['kind'], 'path');
      expect((store['path'] as String).endsWith('/bloat'), isTrue);
      expect((store['path'] as String).startsWith('/'), isTrue);
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

  group('bloat request', () {
    test('carries the service contract', () {
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
    });
  });

  group('usage', () {
    Future<int> run(List<String> args) => AppRunner().run(args);

    test('bloat requires a device, flasher, region and folder', () async {
      expect(await run(['bloat']), 64);
      expect(await run(['bloat', '--device', 'Oneplus 13']), 64);
      expect(
        await run([
          'bloat',
          '--device',
          'Oneplus 13',
          '--kind',
          'SuperHybrid Flasher',
          '--region',
          'GLO',
          '--bloat-dir',
          '/tmp/bloat',
          '--api-base',
          '127.0.0.1:8787',
        ]),
        64,
      );
    });
  });
}
