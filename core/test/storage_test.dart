@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flasher_web_core/src/storage/storage.dart';
import 'package:test/test.dart';

Uint8List bytesOf(String text) => Uint8List.fromList(text.codeUnits);

String textOf(Uint8List bytes) => String.fromCharCodes(bytes);

Future<Uint8List> readAll(ByteSource source) => source.read(0, source.length);

/// [ByteSource] has no `close` in the contract; VM file sources do.
Future<void> closeSource(ByteSource source) async {
  if (source is FileSource) await source.close();
}

void main() {
  late Directory temp;
  late IoWorkspace workspace;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('flasher_storage_');
    workspace = IoWorkspace(temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('workspace', () {
    test(
      'creates parents, writes positionally and replaces on create',
      () async {
        final sink = await workspace.create('a/b/c.bin');
        await sink.write(bytesOf('hello'), 10);
        await sink.close();

        expect(await workspace.exists('a/b/c.bin'), isTrue);
        expect(await workspace.size('a/b/c.bin'), 15);
        final source = await workspace.open('a/b/c.bin');
        final all = await readAll(source);
        expect(all.length, 15);
        expect(all.sublist(0, 10), List.filled(10, 0));
        expect(textOf(all.sublist(10)), 'hello');
        await closeSource(source);

        final replaced = await workspace.create('a/b/c.bin');
        await replaced.write(bytesOf('x'), 0);
        await replaced.close();
        expect(await workspace.size('a/b/c.bin'), 1);
        expect(textOf(await readAll(await workspace.open('a/b/c.bin'))), 'x');
      },
    );

    test('truncate extends with zeros and shrinks', () async {
      final sink = await workspace.create('zero.bin');
      await sink.write(bytesOf('abc'), 0);
      await sink.truncate(8);
      await sink.close();

      final source = await workspace.open('zero.bin');
      expect(source.length, 8);
      expect(await source.read(0, 8), [97, 98, 99, 0, 0, 0, 0, 0]);
      await closeSource(source);

      final shrunk = await workspace.create('zero.bin');
      await shrunk.write(Uint8List.fromList(List.generate(20, (i) => i)), 0);
      await shrunk.truncate(4);
      await shrunk.close();
      expect(await workspace.size('zero.bin'), 4);
      expect(await readAll(await workspace.open('zero.bin')), [0, 1, 2, 3]);
    });

    test('writes at an offset leave a zero-filled hole', () async {
      final sink = await workspace.create('hole.bin');
      await sink.write(bytesOf('A'), 0);
      await sink.write(bytesOf('B'), 5);
      await sink.close();

      final all = await readAll(await workspace.open('hole.bin'));
      expect(all, [65, 0, 0, 0, 0, 66]);
    });

    test('concurrent positional writes and reads stay separate', () async {
      final sink = await workspace.create('parallel.bin');
      await sink.truncate(200);
      await Future.wait([
        for (var i = 0; i < 20; i++)
          sink.write(Uint8List.fromList([i, i + 1]), i * 10),
      ]);
      await sink.close();

      final source = await workspace.open('parallel.bin');
      final reads = await Future.wait([
        for (var i = 0; i < 20; i++) source.read(i * 10, 2),
      ]);
      for (var i = 0; i < 20; i++) {
        expect(reads[i], [i, i + 1]);
      }
      await closeSource(source);
    });

    test('move overwrites an existing file', () async {
      final old = await workspace.create('old.bin');
      await old.write(bytesOf('old'), 0);
      await old.close();
      final fresh = await workspace.create('fresh.bin');
      await fresh.write(bytesOf('fresh'), 0);
      await fresh.close();

      await workspace.move('fresh.bin', 'old.bin');

      expect(await workspace.exists('fresh.bin'), isFalse);
      expect(textOf(await readAll(await workspace.open('old.bin'))), 'fresh');
    });

    test('move renames a directory', () async {
      final sink = await workspace.create('dir/a.txt');
      await sink.write(bytesOf('a'), 0);
      await sink.close();
      final nested = await workspace.create('dir/sub/b.txt');
      await nested.write(bytesOf('b'), 0);
      await nested.close();

      await workspace.move('dir', 'moved');

      expect(await workspace.exists('dir'), isFalse);
      expect(await workspace.list('moved', recursive: true), [
        'moved/a.txt',
        'moved/sub/b.txt',
      ]);
    });

    test(
      'move rejects an ancestor destination and a directory target',
      () async {
        final sink = await workspace.create('dir/sub/f.txt');
        await sink.close();
        final other = await workspace.create('other/keep.txt');
        await other.close();

        await expectLater(
          workspace.move('dir', 'dir/sub'),
          throwsArgumentError,
        );
        await expectLater(
          workspace.move('dir/sub/f.txt', 'dir'),
          throwsArgumentError,
        );
        await expectLater(
          workspace.move('dir/sub/f.txt', 'other'),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test('lists files recursively with workspace-relative paths', () async {
      for (final path in ['root.txt', 'sub/a.txt', 'sub/deep/b.txt']) {
        final sink = await workspace.create(path);
        await sink.close();
      }

      expect(await workspace.list(''), ['root.txt']);
      expect(await workspace.list('', recursive: true), [
        'root.txt',
        'sub/a.txt',
        'sub/deep/b.txt',
      ]);
      expect(await workspace.list('sub'), ['sub/a.txt']);
      expect(await workspace.list('sub', recursive: true), [
        'sub/a.txt',
        'sub/deep/b.txt',
      ]);
    });

    test('delete removes files and directories recursively', () async {
      for (final path in ['root.txt', 'sub/a.txt', 'sub/deep/b.txt']) {
        final sink = await workspace.create(path);
        await sink.close();
      }

      await workspace.delete('sub');
      expect(await workspace.exists('sub'), isFalse);
      expect(await workspace.list('', recursive: true), ['root.txt']);

      await workspace.delete('root.txt');
      expect(await workspace.exists('root.txt'), isFalse);
      await workspace.delete('missing');
    });

    test('rejects paths that could escape the root', () async {
      for (final path in [
        '../escape',
        '/absolute',
        'a/../../escape',
        r'a\b',
        'C:/escape',
        'a//b',
        './a',
        '.',
      ]) {
        await expectLater(
          workspace.create(path),
          throwsArgumentError,
          reason: path,
        );
      }
      await expectLater(workspace.list('../'), throwsArgumentError);
      await expectLater(workspace.move('../a', 'b'), throwsArgumentError);
      await expectLater(workspace.delete(''), throwsArgumentError);
    });

    test('root path works for exists and list', () async {
      expect(await workspace.exists(''), isTrue);
      expect(await workspace.list(''), isEmpty);
    });

    test('IoWorkspace.path builds from a path', () async {
      final fromPath = IoWorkspace.path(temp.path);
      final sink = await fromPath.create('path.bin');
      await sink.write(bytesOf('p'), 0);
      await sink.close();
      expect(await fromPath.exists('path.bin'), isTrue);
      expect(fromPath.root.path, temp.path);
    });

    test('closed sources and sinks reject further work', () async {
      final sink = await workspace.create('closed.bin');
      await sink.write(bytesOf('x'), 0);
      await sink.close();
      await expectLater(sink.write(bytesOf('x'), 0), throwsStateError);

      final source = await workspace.open('closed.bin');
      await closeSource(source);
      await expectLater(source.read(0, 1), throwsStateError);
    });

    test('reads outside the source are rejected', () async {
      final sink = await workspace.create('short.bin');
      await sink.write(bytesOf('abc'), 0);
      await sink.close();
      final source = await workspace.open('short.bin');
      await expectLater(source.read(2, 2), throwsRangeError);
      await expectLater(source.read(-1, 1), throwsRangeError);
      expect(await source.read(3, 0), isEmpty);
      await closeSource(source);
    });

    test('opening a missing file fails', () async {
      await expectLater(
        workspace.open('nope'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        workspace.size('nope'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('HTTP range source', () {
    late HttpServer server;
    late Uri base;
    late Uint8List payload;
    var ignoreRange = false;
    var badRange = false;
    var reportedTotal = -1;
    String? seenTestHeader;
    String? etag = '"v1"';
    String? seenIfRange;

    setUp(() async {
      payload = Uint8List.fromList(List<int>.generate(1000, (i) => i & 0xff));
      ignoreRange = false;
      badRange = false;
      reportedTotal = -1;
      seenTestHeader = null;
      etag = '"v1"';
      seenIfRange = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      unawaited(
        server.forEach((request) async {
          try {
            seenTestHeader = request.headers.value('x-test');
            seenIfRange = request.headers.value('if-range');
            if (etag != null) request.response.headers.set('etag', etag!);
            final path = request.uri.path;
            if (path == '/empty') {
              request.response.statusCode = 416;
              request.response.headers.set('content-range', 'bytes */0');
              await request.response.close();
              return;
            }
            if (path == '/ignore' || ignoreRange) {
              request.response.statusCode = 200;
              request.response.headers.contentLength = payload.length;
              request.response.add(payload);
              await request.response.close();
              return;
            }
            final header = request.headers.value('range') ?? 'bytes=0-0';
            final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(header);
            var start = int.parse(match!.group(1)!);
            var end = int.parse(match.group(2)!);
            if (badRange) {
              start = 0;
              end = 0;
            }
            if (start >= payload.length) {
              request.response.statusCode = 416;
              request.response.headers.set(
                'content-range',
                'bytes */${payload.length}',
              );
              await request.response.close();
              return;
            }
            end = math.min(end, payload.length - 1);
            final total = reportedTotal >= 0 ? reportedTotal : payload.length;
            request.response.statusCode = 206;
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/$total',
            );
            final body = payload.sublist(start, end + 1);
            request.response.headers.contentLength = body.length;
            request.response.add(body);
            await request.response.close();
          } on Object {
            // The client may have detached an unwanted response.
          }
        }),
      );
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('reads exact ranges and reports the total length', () async {
      final source = await HttpRangeSource.open(
        base.resolve('/payload'),
        headers: {'x-test': 'yes'},
      );
      addTearDown(source.close);
      expect(source.length, 1000);
      expect(await source.read(10, 5), payload.sublist(10, 15));
      expect(await source.read(999, 1), [payload[999]]);
      expect(await source.read(0, 0), isEmpty);
      expect(seenTestHeader, 'yes');
      expect(seenIfRange, '"v1"');
    });

    test('an empty resource has length zero', () async {
      final source = await HttpRangeSource.open(base.resolve('/empty'));
      addTearDown(source.close);
      expect(source.length, 0);
      expect(await source.read(0, 0), isEmpty);
      await expectLater(source.read(0, 1), throwsRangeError);
    });

    test('rejects a server that ignores Range', () async {
      await expectLater(
        HttpRangeSource.open(base.resolve('/ignore')),
        throwsA(isA<RangeException>()),
      );
    });

    test('rejects a Content-Range that does not match the request', () async {
      final source = await HttpRangeSource.open(base.resolve('/payload'));
      addTearDown(source.close);
      badRange = true;
      await expectLater(source.read(10, 5), throwsA(isA<RangeException>()));
    });

    test('rejects a changed remote length', () async {
      final source = await HttpRangeSource.open(base.resolve('/payload'));
      addTearDown(source.close);
      reportedTotal = 999;
      await expectLater(source.read(10, 5), throwsA(isA<RangeException>()));
    });

    for (final changed in <String?>['"v2"', null, 'W/"v1"']) {
      test('rejects changed or missing per-response ETag: $changed', () async {
        final source = await HttpRangeSource.open(base.resolve('/payload'));
        addTearDown(source.close);
        etag = changed;
        await expectLater(source.read(10, 5), throwsA(isA<RangeException>()));
      });
    }

    test('reads outside the remote length are rejected', () async {
      final source = await HttpRangeSource.open(base.resolve('/payload'));
      addTearDown(source.close);
      await expectLater(source.read(995, 10), throwsRangeError);
      await expectLater(source.read(-1, 1), throwsRangeError);
    });
  });
}
