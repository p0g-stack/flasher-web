import 'dart:io';
import 'dart:typed_data';

import '../contracts.dart';
import 'serial_queue.dart';

/// A [ByteSink] over a file, written through one positional
/// [RandomAccessFile].
///
/// [open] creates the file. An existing file is replaced unless [keepExisting]
/// is true, which keeps its bytes for the workspace `update` contract. Writes
/// and truncations are serialized on the file's single cursor.
/// `RandomAccessFile.truncate` extends a file with zero bytes, and a write past
/// the old end leaves a zero-filled hole.
final class FileSink implements ByteSink {
  FileSink._(this._raf);

  /// Opens [file] for writing, truncating it unless [keepExisting] is true.
  static Future<FileSink> open(
    File file, {
    bool keepExisting = false,
  }) async {
    await file.parent.create(recursive: true);
    final raf = await file.open(
      mode: keepExisting ? FileMode.append : FileMode.writeOnly,
    );
    return FileSink._(raf);
  }

  final RandomAccessFile _raf;
  final SerialQueue _queue = SerialQueue();
  bool _closed = false;

  @override
  Future<void> write(Uint8List bytes, int offset) async {
    checkWriteOffset(offset);
    await _queue.run(() async {
      _checkOpen();
      await _raf.setPosition(offset);
      await _raf.writeFrom(bytes);
    });
  }

  @override
  Future<void> truncate(int length) async {
    checkTruncateLength(length);
    await _queue.run(() async {
      _checkOpen();
      await _raf.truncate(length);
    });
  }

  @override
  Future<void> close() => _queue.run(() async {
    if (_closed) return;
    _closed = true;
    await _raf.close();
  });

  void _checkOpen() {
    if (_closed) throw StateError('file sink is closed');
  }
}
