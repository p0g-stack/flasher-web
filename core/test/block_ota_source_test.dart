import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flasher_web_core/src/storage/block_ota_source.dart';
import 'package:flasher_web_core/src/storage/contracts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const id = 'catalog-id';
const etag = '"official-upstream"';
const api = 'https://worker.example/';
const bucket = 'https://bucket.example/';

Map<String, Object> manifest({int length = 12, String tag = etag}) => {
  'id': id,
  'identity': sha256.convert(utf8.encode(jsonEncode([id, tag, length]))).toString(),
  'etag': tag,
  'length': length,
  'blockSize': BlockOtaSource.blockSize,
  'created': '2026-11-09T00:00:00.000Z',
};
http.Response metadata(Map<String, Object> value) => http.Response(jsonEncode(value), 200);
http.Response block(List<int> bytes, {String tag = etag}) => http.Response.bytes(bytes, 200, headers: {'x-amz-meta-ota-etag': tag});

void main() {
  test('reads public manifest and blocks without touching Worker; retains blocks', () async {
    final calls = <Uri>[];
    final client = MockClient((request) async {
      calls.add(request.url);
      expect(request.url.host, 'bucket.example');
      return request.url.path.endsWith('manifest.json') ? metadata(manifest()) : block(List.generate(12, (n) => n));
    });
    final source = await BlockOtaSource.open(id: id, apiBase: api, bucketBase: bucket, client: client);
    expect(await source.read(3, 4), [3, 4, 5, 6]);
    expect(await source.read(0, 2), [0, 1]);
    expect(calls, hasLength(2));
    expect(calls.last.path, endsWith('/${manifest()['identity']}/0'));
    await source.close();
  });

  test('public misses request manifest/block from Worker with pinned generation', () async {
    final calls = <Uri>[];
    final source = await BlockOtaSource.open(id: id, apiBase: api, bucketBase: bucket, client: MockClient((request) async {
      calls.add(request.url);
      if (request.url.host == 'bucket.example') return http.Response('not found', 404);
      if (request.url.path == '/api/manifest') return metadata(manifest());
      expect(request.url.queryParameters, {'id': id, 'v': manifest()['identity'], 'n': '0'});
      return block(List.filled(12, 7));
    }));
    expect(await source.read(4, 3), [7, 7, 7]);
    expect(calls.map((uri) => uri.host), ['bucket.example', 'worker.example', 'bucket.example', 'worker.example']);
    await source.close();
  });

  test('public network failures use the same Worker fallback', () async {
    var fallbacks = 0;
    final source = await BlockOtaSource.open(id: id, apiBase: api, bucketBase: bucket, client: MockClient((request) async {
      if (request.url.host == 'bucket.example') throw http.ClientException('public endpoint offline');
      fallbacks++;
      return request.url.path == '/api/manifest' ? metadata(manifest()) : block(List.filled(12, 9));
    }));
    expect(await source.read(0, 1), [9]);
    expect(fallbacks, 2);
    await source.close();
  });

  test('discovers null public base and reads Worker-only on any host', () async {
    final paths = <String>[];
    final source = await BlockOtaSource.open(id: id, apiBase: api, client: MockClient((request) async {
      expect(request.url.host, 'worker.example');
      paths.add(request.url.path);
      if (request.url.path == '/api/block-config') return http.Response('{"publicBase":null}', 200);
      return request.url.path == '/api/manifest' ? metadata(manifest()) : block(List.filled(12, 2));
    }));
    expect(await source.read(0, 2), [2, 2]);
    expect(paths, ['/api/block-config', '/api/manifest', '/api/block']);
    await source.close();
  });

  test('arbitrary reads cross aligned blocks and use exact short final block', () async {
    final size = BlockOtaSource.blockSize;
    final requested = <String>[];
    final source = await BlockOtaSource.open(id: id, apiBase: api, bucketBase: bucket, client: MockClient((request) async {
      if (request.url.path.endsWith('manifest.json')) return metadata(manifest(length: size + 4));
      requested.add(request.url.path.split('/').last);
      return request.url.path.endsWith('/0') ? block(Uint8List(size)..fillRange(0, size, 1)) : block([2, 3, 4, 5]);
    }));
    expect(await source.read(size - 2, 6), [1, 1, 2, 3, 4, 5]);
    expect(requested, ['0', '1']);
    expect(await source.read(size + 4, 0), isEmpty);
    await expectLater(source.read(size + 3, 2), throwsRangeError);
    await source.close();
    await expectLater(source.read(0, 1), throwsStateError);
  });

  test('refuses a block whose upstream ETag differs; never refills corrupt hits', () async {
    var workerCalls = 0;
    final source = await BlockOtaSource.open(id: id, apiBase: api, bucketBase: bucket, client: MockClient((request) async {
      if (request.url.host != 'bucket.example') workerCalls++;
      return request.url.path.endsWith('manifest.json') ? metadata(manifest()) : block(List.filled(12, 0), tag: '"changed"');
    }));
    await expectLater(source.read(0, 1), throwsStateError);
    expect(workerCalls, 0);
    await source.close();
  });

  test('refuses short blocks and inconsistent manifest identity or catalog size', () async {
    final source = await BlockOtaSource.open(id: id, apiBase: api, bucketBase: bucket, client: MockClient((request) async =>
      request.url.path.endsWith('manifest.json') ? metadata(manifest()) : block([1, 2])));
    await expectLater(source.read(0, 1), throwsStateError);
    await source.close();
    await expectLater(BlockOtaSource.open(id: id, apiBase: api, bucketBase: bucket, client: MockClient((_) async => metadata({...manifest(), 'identity': 'a' * 64}))), throwsFormatException);
    await expectLater(BlockOtaSource.open(id: id, apiBase: api, bucketBase: bucket, expectedLength: 13, client: MockClient((_) async => metadata(manifest()))), throwsStateError);
  });

  test('shows the Worker setup action when the S3 backend is missing', () async {
    await expectLater(
      BlockOtaSource.open(
        id: id, apiBase: api, bucketBase: '',
        client: MockClient((_) async => http.Response(
          '{"error":"Run ./tool/dev_garage.sh from the repository root."}', 503,
        )),
      ),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('./tool/dev_garage.sh'))),
    );
  });

  test('stalled parallel windows share the eight-block resident limit', () async {
    final size = BlockOtaSource.blockSize;
    final requested = <int>[];
    final source = await BlockOtaSource.open(id: id, apiBase: api, bucketBase: bucket, client: MockClient((request) async {
      if (request.url.path.endsWith('manifest.json')) return metadata(manifest(length: 9 * size));
      final n = int.parse(request.url.path.split('/').last);
      requested.add(n);
      return block(Uint8List(size)..[0] = n);
    }));
    final stream = StreamIterator(source.streamRange(0, 9 * size));
    expect(await stream.moveNext(), isTrue);
    final ninth = source.read(8 * size, 1);
    await Future<void>.delayed(Duration.zero);
    expect(requested, hasLength(8));
    expect(requested, isNot(contains(8)));
    await stream.cancel();
    expect(await ninth, [8]);
    await source.close();
  });

  test('concurrent reads share one block request', () async {
    var blocks = 0;
    final source = await BlockOtaSource.open(id: id, apiBase: api, bucketBase: bucket, client: MockClient((request) async {
      if (request.url.path.endsWith('manifest.json')) return metadata(manifest());
      blocks++;
      await Future<void>.delayed(Duration.zero);
      return block(List.filled(12, 8));
    }));
    final reads = await Future.wait([source.read(0, 1), source.read(1, 1)]);
    expect(reads, [[8], [8]]);
    expect(blocks, 1);
    await source.close();
  });

  test('ordered reads emit file order within the window', () async {
    final bytes = Uint8List.fromList(List.generate(20, (n) => n));
    final source = _MemorySource(bytes);
    final chunks = await orderedReads(source, chunkBytes: 4, window: 3).toList();
    expect(chunks.map((chunk) => chunk.toList()), [
      [0, 1, 2, 3],
      [4, 5, 6, 7],
      [8, 9, 10, 11],
      [12, 13, 14, 15],
      [16, 17, 18, 19],
    ]);
    expect(source.peak, lessThanOrEqualTo(3), reason: 'the window is a bound');
    expect(source.requested, [0, 4, 8, 12, 16]);
  });

  test('ordered reads fail at the failing range and never widen', () async {
    final bytes = Uint8List.fromList(List.generate(20, (n) => n));
    final source = _MemorySource(bytes, failAt: 8);
    final seen = <List<int>>[];
    await expectLater(
      orderedReads(source, chunkBytes: 4, window: 2).forEach(
        (chunk) => seen.add(chunk.toList()),
      ),
      throwsA(isA<StateError>()),
    );
    expect(seen, [
      [0, 1, 2, 3],
      [4, 5, 6, 7],
    ]);
    await expectLater(
      orderedReads(source, chunkBytes: 8 << 20, window: 9).toList(),
      throwsArgumentError,
    );
    await expectLater(
      orderedReads(source, chunkBytes: 16 << 20, window: 5).toList(),
      throwsArgumentError,
    );
  });
}

final class _MemorySource implements ByteSource {
  _MemorySource(this.bytes, {this.failAt});

  final Uint8List bytes;
  final int? failAt;
  final requested = <int>[];
  int active = 0;
  int peak = 0;

  @override
  int get length => bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    requested.add(offset);
    active++;
    if (active > peak) peak = active;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    active--;
    if (offset == failAt) throw StateError('range $offset failed');
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}
