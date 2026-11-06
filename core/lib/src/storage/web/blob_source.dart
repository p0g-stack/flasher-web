import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../contracts.dart';

/// A [ByteSource] over a browser `Blob` or `File`.
///
/// [blob] is the browser object itself, so a file the user picked is never
/// copied into Dart before it is read: [read] slices only the requested range
/// and copies exactly that range out.
final class BlobSource implements ByteSource {
  BlobSource(JSObject blob) : this._(blob as web.Blob);

  BlobSource._(this._blob) : length = _blob.size;

  final web.Blob _blob;

  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    checkReadRange(offset, length, this.length);
    if (length == 0) return Uint8List(0);
    final buffer = await _blob
        .slice(offset, offset + length)
        .arrayBuffer()
        .toDart;
    final bytes = buffer.toDart.asUint8List();
    if (bytes.length != length) {
      throw StateError(
        'short read from blob at $offset: got ${bytes.length} of '
        '$length bytes',
      );
    }
    return bytes;
  }
}
