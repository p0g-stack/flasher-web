import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flasher_web_core/src/service/flasher_service.dart';
import 'package:flasher_web_core/src/storage/block_ota_source.dart';
import 'package:test/test.dart';

const _id = 'catalog-id';
const _etag = '"upstream"';

void main() {
  test(
    'saveOta writes the pinned generation in order and reports it',
    () async {
      final bytes = Uint8List.fromList(List.generate(12, (n) => n * 3));
      final server = await _BlockServer.start(bytes);
      addTearDown(server.close);
      final directory = await Directory.systemTemp.createTemp(
        'flasher_save_ota_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final target = File('${directory.path}/ota.zip');

      final events = await FlasherService().saveOta({
        'apiBase': server.apiBase,
        'ota': {
          'kind': 'catalog',
          'entry': {'id': _id, 'size': bytes.length},
        },
        'destination': {'kind': 'path', 'path': target.path},
      }).toList();

      expect(events.first, {
        'type': 'started',
        'label': _id,
        'total': bytes.length,
      });
      expect(
        events.where((event) => event['type'] == 'progress'),
        isNotEmpty,
        reason: 'progress follows the bytes as they are written',
      );
      final result = events.last;
      expect(result['type'], 'result');
      expect(result['bytes'], bytes.length);
      expect(result['sha256'], sha256.convert(bytes).toString());
      expect(await target.readAsBytes(), bytes);
      expect(server.blockRequests, 1, reason: 'one block, read once');
    },
  );

  test(
    'saveOta refuses a generation whose length differs from the catalog',
    () async {
      final bytes = Uint8List.fromList(List.generate(12, (n) => n));
      final server = await _BlockServer.start(bytes);
      addTearDown(server.close);
      final directory = await Directory.systemTemp.createTemp(
        'flasher_save_ota_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final target = File('${directory.path}/ota.zip');

      await expectLater(
        FlasherService().saveOta({
          'apiBase': server.apiBase,
          'ota': {
            'kind': 'catalog',
            'entry': {'id': _id, 'size': bytes.length + 1},
          },
          'destination': {'kind': 'path', 'path': target.path},
        }).toList(),
        throwsA(isA<StateError>()),
      );
      expect(await target.exists(), isFalse, reason: 'no byte was written');
    },
  );
}

/// A loopback stand-in for the Worker's block routes over one pinned block.
final class _BlockServer {
  _BlockServer._(this._server, this._bytes);

  final HttpServer _server;
  final Uint8List _bytes;
  int blockRequests = 0;

  static Future<_BlockServer> start(Uint8List bytes) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = _BlockServer._(server, bytes);
    server.listen(result._handle);
    return result;
  }

  String get apiBase => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Map<String, Object> get _manifest => {
    'id': _id,
    'identity': sha256
        .convert(utf8.encode(jsonEncode([_id, _etag, _bytes.length])))
        .toString(),
    'etag': _etag,
    'length': _bytes.length,
    'blockSize': BlockOtaSource.blockSize,
    'created': '2026-11-09T00:00:00.000Z',
  };

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    switch (request.uri.path) {
      case '/api/block-config':
        response.headers.contentType = ContentType.json;
        response.write('{"publicBase":null}');
      case '/api/manifest':
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(_manifest));
      case '/api/block':
        blockRequests++;
        response.headers.set('x-amz-meta-ota-etag', _etag);
        response.contentLength = _bytes.length;
        response.add(_bytes);
      default:
        response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }
}
