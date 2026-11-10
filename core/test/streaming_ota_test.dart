import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:downloadx/downloadx.dart' as dlx;
import 'package:flasher_web_core/src/storage/downloadx_io.dart';
import 'package:flasher_web_core/src/storage/ota_cache.dart';
import 'package:flasher_web_core/src/storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late IoWorkspace workspace;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('streaming_ota_');
    workspace = IoWorkspace(temp);
  });
  tearDown(() => temp.delete(recursive: true));

  test(
    'body bytes reach engine progress before the HTTP range completes',
    () async {
      final release = Completer<void>();
      final firstProgress = Completer<void>();
      final server = await _Server.open(512, (
        request,
        start,
        count,
        bytes,
      ) async {
        request.response.add(bytes.sublist(start, start + 64));
        await request.response.flush();
        await release.future;
        request.response.add(bytes.sublist(start + 64, start + count));
      });
      addTearDown(server.close);
      final session = await _Session.open(server, workspace);
      addTearDown(session.close);
      session.download.emitter.onType<dlx.ChunkProgressEvent>((event) {
        if (!firstProgress.isCompleted) firstProgress.complete();
      });
      final running = session.download.start();
      try {
        await firstProgress.future.timeout(const Duration(seconds: 2));
        expect(session.download.downloadedBytes, 64);
        expect(session.download.state, dlx.DownloadState.downloading);
        expect(server.finished, 0);
      } finally {
        release.complete();
        await running;
      }
      expect(session.download.state, dlx.DownloadState.completed);
      expect(
        await File('${temp.path}/data/file.zip').readAsBytes(),
        server.bytes,
      );
    },
  );

  test('a range taking longer than idle timeout completes while bytes keep arriving', () async {
    final server = await _Server.open(512, (
      request,
      start,
      count,
      bytes,
    ) async {
      for (var offset = start; offset < start + count; offset += 64) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        request.response.add(bytes.sublist(offset, offset + 64));
        await request.response.flush();
      }
    });
    addTearDown(server.close);
    final session = await _Session.open(server, workspace, idleTimeout: 150);
    addTearDown(session.close);
    await session.download.start().timeout(const Duration(seconds: 3));
    expect(session.download.state, dlx.DownloadState.completed);
    expect(server.ranges, [(0, 512)]);
    expect(session.factory.opens, 1);
  });

  test('mid-body failure resumes at the written offset without refreshing the link', () async {
    final written = Completer<void>();
    var failed = false;
    final server = await _Server.open(256, (
      request,
      start,
      count,
      bytes,
    ) async {
      if (!failed) {
        failed = true;
        request.response.add(bytes.sublist(start, start + 64));
        await request.response.flush();
        await written.future;
        request.response.deadline = const Duration(milliseconds: 1);
      } else {
        request.response.add(bytes.sublist(start, start + count));
      }
    });
    addTearDown(server.close);
    final session = await _Session.open(server, workspace);
    addTearDown(session.close);
    session.download.emitter.onType<dlx.ChunkProgressEvent>((event) {
      if (!written.isCompleted) written.complete();
    });
    await session.download.start().timeout(const Duration(seconds: 3));
    expect(session.download.state, dlx.DownloadState.completed);
    expect(server.ranges, [(0, 256), (64, 192)]);
    expect(session.factory.opens, 1);
    expect(
      await File('${temp.path}/data/file.zip').readAsBytes(),
      server.bytes,
    );
  });

  test(
    'small writes and repeated snapshots flush no more than once per second',
    () async {
      var now = DateTime.utc(2026);
      final counted = _CountingWorkspace(workspace, 8 * 1024 * 1024);
      final reader = await CatalogOtaReader.open(_MemoryFactory(), const {});
      final io = DownloadxWorkspaceIo(
        workspace: counted,
        reader: reader,
        clock: () => now,
      );
      addTearDown(io.close);
      addTearDown(reader.close);
      final metadata = dlx.createEmptyMeta(
        id: 'file',
        url: 'https://test/file',
      );
      const locator = dlx.MetaLocator(dir: 'data', id: 'file');
      final block = Uint8List(1024 * 1024);
      for (var i = 0; i < 32; i++) {
        await io.writeChunk('data/file.part', 0, block);
        await dlx.persistMeta(io, locator, metadata);
      }
      expect(
        counted.checkpoints,
        0,
        reason: 'byte count must not bypass the time floor',
      );
      now = now.add(const Duration(seconds: 1));
      expect(io.checkpointDue, isTrue);
      await dlx.persistMeta(io, locator, metadata);
      expect(counted.checkpoints, 1);
      for (var i = 0; i < 100; i++) {
        await io.writeChunk(
          'data/file.part',
          0,
          Uint8List.sublistView(block, 0, 1024),
        );
        await dlx.persistMeta(io, locator, metadata);
      }
      expect(counted.checkpoints, 1);
      now = now.add(const Duration(seconds: 1));
      await dlx.persistMeta(io, locator, metadata);
      expect(counted.checkpoints, 2);
    },
  );

  test(
    'staged writable checkpoints remain byte based, never time based',
    () async {
      var now = DateTime.utc(2026);
      final counted = _CountingWorkspace(workspace, 512 * 1024 * 1024);
      final reader = await CatalogOtaReader.open(_MemoryFactory(), const {});
      final io = DownloadxWorkspaceIo(
        workspace: counted,
        reader: reader,
        clock: () => now,
      );
      addTearDown(io.close);
      addTearDown(reader.close);
      final metadata = dlx.createEmptyMeta(
        id: 'file',
        url: 'https://test/file',
      );
      const locator = dlx.MetaLocator(dir: 'data', id: 'file');
      final block = Uint8List(1024 * 1024);
      await io.writeChunk('data/file.part', 0, block);
      now = now.add(const Duration(hours: 1));
      await dlx.persistMeta(io, locator, metadata);
      expect(counted.checkpoints, 0);
      for (var i = 1; i < 512; i++) {
        await io.writeChunk('data/file.part', 0, block);
      }
      await dlx.persistMeta(io, locator, metadata);
      expect(counted.checkpoints, 1);
    },
  );
}

class _Server {
  _Server(this.server, this.bytes);
  final HttpServer server;
  final Uint8List bytes;
  final ranges = <(int, int)>[];
  int finished = 0;
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/ota');
  static Future<_Server> open(
    int length,
    Future<void> Function(HttpRequest, int, int, Uint8List) body,
  ) async {
    final socket = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _Server(
      socket,
      Uint8List.fromList(List.generate(length, (i) => i % 251)),
    );
    socket.listen((request) async {
      try {
        final match = RegExp(r'^bytes=(\d+)-(\d+)$')
            .firstMatch(request.headers.value('range')!)!;
        final start = int.parse(match.group(1)!);
        final count = int.parse(match.group(2)!) - start + 1;
        request.response.statusCode = 206;
        request.response.headers.set('etag', '"v1"');
        request.response.headers.set(
          'content-range',
          'bytes $start-${start + count - 1}/$length',
        );
        request.response.contentLength = count;
        request.response.bufferOutput = false;
        if (start == 0 && count == 1) {
          request.response.add([server.bytes[0]]);
        } else {
          server.ranges.add((start, count));
          await body(request, start, count, server.bytes);
          server.finished++;
        }
        await request.response.close();
      } on Object {
        // Disconnects are intentional in the mid-body retry test.
      }
    });
    return server;
  }

  Future<void> close() async => server.close(force: true);
}

class _HttpFactory implements OtaSourceFactory {
  _HttpFactory(this.server);
  final _Server server;
  int opens = 0;
  @override
  Future<OtaRemoteSource> open(Map<String, dynamic> entry) async {
    opens++;
    final source = await HttpRangeSource.open(server.uri);
    return OtaRemoteSource(source: source, etag: source.observedEtag);
  }
}

class _Session {
  _Session(this.factory, this.reader, this.io, this.download);
  final _HttpFactory factory;
  final CatalogOtaReader reader;
  final DownloadxWorkspaceIo io;
  final dlx.Download download;
  static Future<_Session> open(
    _Server server,
    Workspace workspace, {
    int idleTimeout = 1000,
  }) async {
    final factory = _HttpFactory(server);
    final reader = await CatalogOtaReader.open(factory, const {});
    final io = DownloadxWorkspaceIo(workspace: workspace, reader: reader);
    final manager = dlx.DownloadX(
      dlx.DownloadXConfig(
        io: io,
        targetPath: 'data',
        targetChunkCount: 1,
        minChunkSize: 64,
        requestTimeout: idleTimeout,
        maxRetries: 2,
        retryDelay: 1,
      ),
    );
    final download = await manager.addUrl(
      'https://test/file.zip',
      const dlx.DownloadOptions(id: 'file', filename: 'file.zip'),
    );
    return _Session(factory, reader, io, download);
  }

  Future<void> close() async {
    await reader.close();
    await io.close();
  }
}

class _CountingWorkspace implements Workspace {
  _CountingWorkspace(this.inner, this.interval);
  final Workspace inner;
  final int interval;
  int checkpoints = 0;
  @override
  Future<ByteSink> create(String path) => inner.create(path);
  @override
  Future<ByteSink> update(String path) async =>
      _CountingSink(await inner.update(path), this);
  @override
  Future<ByteSource> open(String path) => inner.open(path);
  @override
  Future<bool> exists(String path) => inner.exists(path);
  @override
  Future<int> size(String path) => inner.size(path);
  @override
  Future<List<String>> list(String path, {bool recursive = false}) =>
      inner.list(path, recursive: recursive);
  @override
  Future<void> move(String from, String to) => inner.move(from, to);
  @override
  Future<void> delete(String path) => inner.delete(path);
}

class _CountingSink implements CheckpointByteSink {
  _CountingSink(this.inner, this.owner);
  final ByteSink inner;
  final _CountingWorkspace owner;
  @override
  int get checkpointBytes => owner.interval;
  @override
  Future<void> checkpoint() async {
    owner.checkpoints++;
    await (inner as CheckpointByteSink).checkpoint();
  }

  @override
  Future<void> write(Uint8List bytes, int offset) => inner.write(bytes, offset);
  @override
  Future<void> truncate(int length) => inner.truncate(length);
  @override
  Future<void> close() => inner.close();
}

class _MemoryFactory implements OtaSourceFactory {
  @override
  Future<OtaRemoteSource> open(Map<String, dynamic> entry) async =>
      OtaRemoteSource(source: _MemorySource(), etag: '"v1"');
}

class _MemorySource implements ByteSource {
  @override
  int get length => 1;
  @override
  Future<Uint8List> read(int offset, int length) async => Uint8List(length);
}
