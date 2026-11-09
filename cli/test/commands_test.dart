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

  group('virtual request', () {
    test('a local OTA is absolute and a URL stays a URL', () {
      expect(fileOta('ota.zip'), {
        'kind': 'file',
        'file': File('ota.zip').absolute.path,
      });
      expect(otaInput('https://example.com/ota.zip'), {
        'kind': 'url',
        'url': 'https://example.com/ota.zip',
      });
      expect(otaInput('ota.zip')['kind'], 'file');
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

    const selection = [
      '--device',
      'Oneplus 13',
      '--kind',
      'RegionalHybrid Flasher',
      '--region',
      'GLO',
    ];

    test('flash requires a selection, serial and bloat folder', () async {
      expect(await run(['flash']), 64);
      expect(
        await run(['flash', ...selection, '--serial', 'SERIAL1']),
        64,
      );
    });

    test('flash requires exactly one OTA source', () async {
      expect(
        await run([
          'flash',
          ...selection,
          '--bloat-dir',
          '/tmp/bloat',
          '--serial',
          'SERIAL1',
        ]),
        64,
      );
      expect(
        await run([
          'flash',
          ...selection,
          '--bloat-dir',
          '/tmp/bloat',
          '--serial',
          'SERIAL1',
          '--ota',
          'ota.zip',
          '--catalog',
          '1.2.3',
        ]),
        64,
      );
    });

    test('flash rejects a malformed answer and API base', () async {
      expect(
        await run([
          'flash',
          ...selection,
          '--bloat-dir',
          '/tmp/bloat',
          '--serial',
          'SERIAL1',
          '--ota',
          'ota.zip',
          '--answer',
          'product',
        ]),
        64,
      );
      expect(
        await run([
          'flash',
          ...selection,
          '--bloat-dir',
          '/tmp/bloat',
          '--serial',
          'SERIAL1',
          '--ota',
          'ota.zip',
          '--api-base',
          '127.0.0.1:8787',
        ]),
        64,
      );
    });

    test('flash refuses a confirm serial that is not the serial', () async {
      expect(
        await run([
          'flash',
          ...selection,
          '--bloat-dir',
          '/tmp/bloat',
          '--serial',
          'SERIAL1',
          '--confirm-serial',
          'SERIAL2',
          '--ota',
          'ota.zip',
        ]),
        1,
      );
    });

    test('flash fails without a device or a readable upstream', () async {
      final directory = await Directory.systemTemp.createTemp('cli_flash_');
      addTearDown(() => directory.delete(recursive: true));
      expect(
        await run([
          'flash',
          ...selection,
          '--bloat-dir',
          directory.path,
          '--upstream',
          '${directory.path}/upstream',
          '--serial',
          'SERIAL1',
          '--confirm-serial',
          'SERIAL1',
          '--ota',
          '${directory.path}/ota.zip',
        ]),
        1,
      );
    });

    test('export requires a selection, bloat folder and output', () async {
      expect(await run(['export']), 64);
      expect(
        await run(['export', ...selection, '--bloat-dir', '/tmp/bloat']),
        64,
      );
    });

    test('export requires exactly one OTA source', () async {
      expect(
        await run([
          'export',
          ...selection,
          '--bloat-dir',
          '/tmp/bloat',
          '--out',
          'out.zip',
        ]),
        64,
      );
      expect(
        await run([
          'export',
          ...selection,
          '--bloat-dir',
          '/tmp/bloat',
          '--out',
          'out.zip',
          '--ota',
          'ota.zip',
          '--catalog',
          '1.2.3',
        ]),
        64,
      );
    });

    test('export fails without a readable upstream', () async {
      final directory = await Directory.systemTemp.createTemp('cli_export_');
      addTearDown(() => directory.delete(recursive: true));
      expect(
        await run([
          'export',
          ...selection,
          '--bloat-dir',
          directory.path,
          '--upstream',
          '${directory.path}/upstream',
          '--ota',
          '${directory.path}/ota.zip',
          '--out',
          '${directory.path}/out.zip',
        ]),
        1,
      );
    });
  });
}
