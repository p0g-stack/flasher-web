import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../contracts.dart';

/// A [ByteSink] over a `FileSystemFileHandle`.
///
/// A dedicated worker's `createSyncAccessHandle()` is preferred: its reads and
/// writes are positional and immediate. On the page, or for a user-picked
/// directory, that call is unavailable, so the sink falls back to
/// `createWritable()` with `seek` before every write. The fallback's writes
/// become visible when [close] closes the stream, as the File System Access
/// API specifies.
final class HandleSink {
  /// Opens [handle], truncating an existing file, and picks the best backend.
  static Future<ByteSink> open(web.FileSystemFileHandle handle) async {
    web.FileSystemSyncAccessHandle? sync;
    try {
      sync = await handle.createSyncAccessHandle().toDart;
      sync.truncate(0);
      return SyncAccessSink(sync);
    } on Object {
      try {
        sync?.close();
      } on Object {
        // The handle never opened or already closed.
      }
    }
    final writable = await handle.createWritable().toDart;
    try {
      await writable.truncate(0).toDart;
    } on Object {
      await writable.close().toDart;
      rethrow;
    }
    return WritableSink(writable);
  }
}

/// Positional writes through a worker-only `FileSystemSyncAccessHandle`.
final class SyncAccessSink implements ByteSink {
  SyncAccessSink(this._handle);

  final web.FileSystemSyncAccessHandle _handle;
  bool _closed = false;

  @override
  Future<void> write(Uint8List bytes, int offset) async {
    checkWriteOffset(offset);
    _checkOpen();
    final written = _handle.write(
      bytes.toJS,
      web.FileSystemReadWriteOptions(at: offset),
    );
    if (written != bytes.length) {
      throw StateError('short write: wrote $written of ${bytes.length} bytes');
    }
  }

  @override
  Future<void> truncate(int length) async {
    checkTruncateLength(length);
    _checkOpen();
    _handle.truncate(length);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _handle.flush();
    } finally {
      _handle.close();
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('file sink is closed');
  }
}

/// Positional writes through a `FileSystemWritableFileStream`.
final class WritableSink implements ByteSink {
  WritableSink(this._stream);

  final web.FileSystemWritableFileStream _stream;
  bool _closed = false;
  Future<void> _tail = Future<void>.value();

  @override
  Future<void> write(Uint8List bytes, int offset) async {
    checkWriteOffset(offset);
    await _serial(() async {
      _checkOpen();
      await _stream.seek(offset).toDart;
      await _stream.write(bytes.toJS).toDart;
    });
  }

  @override
  Future<void> truncate(int length) async {
    checkTruncateLength(length);
    await _serial(() async {
      _checkOpen();
      await _stream.truncate(length).toDart;
    });
  }

  @override
  Future<void> close() => _serial(() async {
    if (_closed) return;
    _closed = true;
    await _stream.close().toDart;
  });

  Future<void> _serial(Future<void> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _checkOpen() {
    if (_closed) throw StateError('file sink is closed');
  }
}
