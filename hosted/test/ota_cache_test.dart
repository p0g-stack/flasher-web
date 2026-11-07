import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flasher_web_hosted/src/catalog_gateway.dart';
import 'package:flasher_web_hosted/src/config.dart';
import 'package:flasher_web_hosted/src/errors.dart';
import 'package:flasher_web_hosted/src/ota_cache.dart';
import 'package:flasher_web_hosted/src/strict_http.dart';
import 'package:flasher_web_hosted/src/util.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory feedOne;
  late Directory feedTwo;
  late HttpServer server;
  late StrictHttp http;
  late HostedConfig config;
  late Uint8List otaBytes;
  var catalogVersion = '1.0.0';
  var otaRequests = 0;

  Map<String, Object?> release() => {
    'id': 'rel-1',
    'device': 'OP 15R',
    'region': 'IN',
    'version': catalogVersion,
    'source_url': 'https://roms.danielspringer.at/download.php?token=fresh',
    'security_patch': '2026-01-01',
    'size': otaBytes.length,
  };

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hosted-ota-');
    feedOne = Directory(joinPath(root.path, ['feed-one']));
    feedTwo = Directory(joinPath(root.path, ['feed-two']));
    otaBytes = Uint8List.fromList(List<int>.generate(100, (index) => index));
    catalogVersion = '1.0.0';
    otaRequests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/api/catalog':
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({
            'api_version': '1',
            'releases': [release()],
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
          otaRequests++;
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
      upstreamDir: root,
      builderRevision: 'builder-smoke-1',
      cacheBudgetBytes: 1024 * 1024 * 1024,
      minFreeBytes: 0,
      maxOtaBytes: 1024 * 1024,
    );
  });

  tearDown(() async {
    http.close();
    await server.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('downloads a catalog OTA once and reuses its verified bytes', () async {
    final gateway = CatalogGateway(
      config: config,
      http: http,
      cacheDir: feedOne,
    );
    final cache = OtaCache(
      config: config,
      http: http,
      catalog: gateway,
      root: Directory(joinPath(root.path, ['ota'])),
    );
    final releaseRecord = await gateway.release(
      role: 'ota',
      target: (device: 'OP 15R', region: 'IN'),
      id: 'rel-1',
    );
    final first = await cache.materialize(releaseRecord);
    expect(first.cacheHit, isFalse);
    expect(await first.file.readAsBytes(), otaBytes);
    expect(first.size, otaBytes.length);
    expect(first.sha256, sha256Hex(otaBytes));
    expect(otaRequests, 2); // probe plus one body range

    final second = await cache.materialize(releaseRecord);
    expect(second.cacheHit, isTrue);
    expect(second.file.path, first.file.path);
    expect(otaRequests, 2);
  });

  test('a changed catalog entry for the same id fails closed', () async {
    final firstGateway = CatalogGateway(
      config: config,
      http: http,
      cacheDir: feedOne,
    );
    final cache = OtaCache(
      config: config,
      http: http,
      catalog: firstGateway,
      root: Directory(joinPath(root.path, ['ota'])),
    );
    final original = await firstGateway.release(
      role: 'ota',
      target: (device: 'OP 15R', region: 'IN'),
      id: 'rel-1',
    );
    await cache.materialize(original);

    catalogVersion = '2.0.0';
    final secondGateway = CatalogGateway(
      config: config,
      http: http,
      cacheDir: feedTwo,
    );
    final changed = await secondGateway.release(
      role: 'ota',
      target: (device: 'OP 15R', region: 'IN'),
      id: 'rel-1',
    );
    expect(changed.entryDigest, isNot(original.entryDigest));
    await expectLater(
      cache.materialize(changed),
      throwsA(isA<CatalogChangedException>()),
    );
  });
}
