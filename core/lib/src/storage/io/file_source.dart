import 'dart:io';
import 'dart:typed_data';

import '../contracts.dart';
import 'serial_queue.dart';

/// A [ByteSource] over a file, read through one positional
/// [RandomAccessFile].
///
/// The length is captured when the source is created. Reads are serialized on
/// the file's single cursor, so callers may issue them concurrently. The file
/// is opened lazily; [close] releases the handle, and a source that is never
/// closed is reclaimed when the process ends.
final class FileSource implements ByteSource {
  FileSource(File file) : this._(file, file.lengthSync());

  FileSource._(this._file, this.length);

  /// Opens [file] after reading its length.
  static Future<FileSource> open(File file) async =>
      FileSource._(file, await file.length());

  final File _file;
  final SerialQueue _queue = SerialQueue();
  RandomAccessFile? _raf;
  bool _closed = false;

  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    checkReadRange(offset, length, this.length);
    if (length == 0) return Uint8List(0);
    return _queue.run(() async {
      final raf = await _open();
      await raf.setPosition(offset);
      final bytes = await raf.read(length);
      if (bytes.length != length) {
        throw StateError(
          'short read from ${_file.path} at $offset: '
          'got ${bytes.length} of $length bytes',
        );
      }
      return bytes;
    });
  }

  Future<RandomAccessFile> _open() async {
    if (_closed) throw StateError('file source is closed: ${_file.path}');
    return _raf ??= await _file.open(mode: FileMode.read);
  }

  /// Releases the underlying handle. Further reads throw [StateError].
  Future<void> close() => _queue.run(() async {
    if (_closed) return;
    _closed = true;
    final raf = _raf;
    _raf = null;
    await raf?.close();
  });
}
