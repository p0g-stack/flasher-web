import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:downloadx/downloadx.dart' as dlx;

import 'contracts.dart';
import 'ota_cache.dart';
import 'paths.dart';

/// downloadx owns scheduling, chunk layout, retries and resume metadata. This
/// adapter reuses our strict HTTP range reader, so its large logical chunks
/// become bounded HTTP reads rather than file-sized response buffers.
final class DownloadxWorkspaceIo extends dlx.DownloadxIo {
  DownloadxWorkspaceIo({
    required this.workspace,
    required this.reader,
    this.readBytes = 8 * 1024 * 1024,
  });

  final Workspace workspace;
  final CatalogOtaReader reader;
  final int readBytes;
  ByteSink? _sink;
  String? _sinkPath;
  Future<void> _tail = Future<void>.value();
  int _dirty = 0;
  DateTime _checkpointAt = DateTime.now();
  List<int>? _pendingMeta;
  String? _pendingMetaPath;
  final List<List<int>> _metaWrites = [];
  bool forceCheckpoint = false;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<dlx.FetchResponse> fetch(String url, [dlx.FetchInit? init]) async {
    final headers = <String, String>{
      'content-length': '${reader.length}',
      'accept-ranges': 'bytes',
      if (reader.etag != null) 'etag': reader.etag!,
    };
    if (init?.method == 'HEAD') {
      return _Response(200, headers, const Stream.empty());
    }
    String? requested;
    init?.headers?.forEach((key, value) {
      if (key.toLowerCase() == 'range') requested = value;
    });
    final match = requested == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(requested!);
    if (requested != null && match == null) {
      throw ArgumentError('unsupported downloadx range: $requested');
    }
    final start = match == null ? 0 : int.parse(match.group(1)!);
    final end = match == null || match.group(2)!.isEmpty
        ? reader.length - 1
        : int.parse(match.group(2)!);
    checkReadRange(start, end - start + 1, reader.length);
    headers['content-length'] = '${end - start + 1}';
    if (requested != null) {
      headers['content-range'] = 'bytes $start-$end/${reader.length}';
    }
    return _Response(
      requested == null ? 200 : 206,
      headers,
      _body(start, end + 1, init?.signal),
    );
  }

  Stream<List<int>> _body(int offset, int end, dlx.CancelToken? signal) async* {
    while (offset < end) {
      if (signal?.isCancelled ?? false) throw signal!.reason;
      final bytes = await reader.read(
        offset,
        min(readBytes, end - offset),
        cancelled: signal?.whenCancelled,
      );
      if (signal?.isCancelled ?? false) throw signal!.reason;
      yield bytes;
      offset += bytes.length;
    }
  }

  Future<ByteSink> _open(String path) async {
    if (_sinkPath != null && _sinkPath != path) {
      throw StateError('one downloadx adapter may write only one OTA');
    }
    _sinkPath = path;
    return _sink ??= await workspace.update(path);
  }

  @override
  Future<void> writeChunk(String path, int offset, List<int> buffer) =>
      _serial(() async {
        final sink = await _open(path);
        await sink.write(
          buffer is Uint8List ? buffer : Uint8List.fromList(buffer),
          offset,
        );
        _dirty += buffer.length;
      });

  @override
  Future<List<int>> readFile(String path) async {
    final source = await workspace.open(path);
    try {
      if (source.length > 1024 * 1024) {
        throw StateError('oversized download metadata');
      }
      return await source.read(0, source.length);
    } finally {
      await closeByteSource(source);
    }
  }

  Future<void> _write(String path, List<int> buffer) async {
    final sink = await workspace.create(path);
    try {
      await sink.write(
        buffer is Uint8List ? buffer : Uint8List.fromList(buffer),
        0,
      );
    } finally {
      await sink.close();
    }
  }

  @override
  Future<void> writeFile(String path, List<int> buffer) => _serial(() async {
    if (path.endsWith('${dlx.metaExt}.tmp')) {
      // Capture the engine's already-written chunk prefixes. If a checkpoint
      // is deferred, leave the previous durable sidecar unchanged.
      _metaWrites.add(buffer);
    } else {
      await _write(path, buffer);
    }
  });

  bool get _checkpointDue {
    final sink = _sink;
    if (forceCheckpoint || sink == null || _dirty == 0) return true;
    if (sink is! CheckpointByteSink) return true;
    if (_dirty >= sink.checkpointBytes) return true;
    // Never turn a staged FSA file's expensive copy into a time-based loop.
    return sink.checkpointBytes <= 8 * 1024 * 1024 &&
        DateTime.now().difference(_checkpointAt).inSeconds >= 30;
  }

  Future<void> _checkpoint() async {
    final sink = _sink;
    if (sink != null && _dirty > 0) {
      if (sink is CheckpointByteSink) {
        await sink.checkpoint();
      } else {
        await sink.close();
        _sink = null;
      }
    }
    _dirty = 0;
    _checkpointAt = DateTime.now();
  }

  Future<void> _publishMeta(String destination) async {
    final bytes = _pendingMeta;
    final temporary = _pendingMetaPath;
    if (bytes == null || temporary == null) return;
    await _checkpoint();
    await _write(temporary, bytes);
    await workspace.move(temporary, destination);
    _pendingMeta = null;
    _pendingMetaPath = null;
  }

  @override
  Future<void> rename(String from, String to) => _serial(() async {
    if (from.endsWith('${dlx.metaExt}.tmp')) {
      if (_metaWrites.isEmpty) {
        throw StateError('metadata rename without write');
      }
      _pendingMeta = _metaWrites.removeAt(0);
      _pendingMetaPath = from;
      if (_checkpointDue) await _publishMeta(to);
      return;
    }
    if (from == _sinkPath) {
      await _sink?.close();
      _sink = null;
      _dirty = 0;
      _sinkPath = null;
    }
    await workspace.move(from, to);
  });

  /// Commit the latest engine snapshot after pause/failure. No network worker
  /// may still be writing when this is called.
  Future<void> close() => _serial(() async {
    await _sink?.close();
    _sink = null;
    _dirty = 0;
    final path = _pendingMetaPath;
    if (path != null) await _publishMeta(path.substring(0, path.length - 4));
  });

  @override
  Future<void> mkdir(String path) async {} // Workspace writes create parents.
  @override
  Future<bool> exists(String path) => workspace.exists(path);
  @override
  Future<void> unlink(String path) => _serial(() async {
    if (_sinkPath == path) {
      await _sink?.close();
      _sink = null;
      _sinkPath = null;
      _dirty = 0;
    }
    await workspace.delete(path);
  });
  @override
  String joinPath(List<String> segments) =>
      normalizeWorkspacePath(segments.where((s) => s.isNotEmpty).join('/'));
  @override
  Future<List<String>> listDir(String path) async =>
      (await workspace.list(path)).map(baseWorkspacePath).toList();
  @override
  Future<int> Function(String)? get fileSize =>
      (path) => _serial(() async {
        // FSA staged bytes are invisible until close, including size.
        if (_sinkPath == path && _sink != null) {
          await _sink!.close();
          _sink = null;
          _dirty = 0;
        }
        return workspace.size(path);
      });
}

final class _Response implements dlx.FetchResponse {
  _Response(this.status, Map<String, String> headers, this.body)
    : headers = dlx.MapFetchHeaders(headers);
  @override
  final int status;
  @override
  final dlx.FetchHeaders headers;
  @override
  final Stream<List<int>> body;
  @override
  String get statusText => 'OK';
  @override
  bool get ok => true;
  @override
  String? get url => null;
  @override
  Future<List<int>> bytes() async =>
      throw StateError('OTA responses must be streamed');
  @override
  Future<String> text() async => utf8.decode(await bytes());
}
