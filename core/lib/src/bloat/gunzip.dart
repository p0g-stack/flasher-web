/// Incremental gzip decoding for the bloat store.
///
/// The store never needs the whole transport asset in memory: it pushes
/// chunks as they arrive and writes the decoder's output straight into the
/// workspace. On the web the Rust `GzipDecoder` implements this interface;
/// natively [createGunzip] returns dart:io's decoder.
library;

import 'gunzip_stub.dart' if (dart.library.io) 'gunzip_io.dart' as platform;

/// A streaming gzip decoder.
abstract interface class Gunzip {
  /// Decodes [bytes] and returns the output available so far.
  List<int> push(List<int> bytes);

  /// Finishes the stream, returning the remaining output.
  List<int> finish();
}

/// A native (dart:io) decoder, or a clear error on the web before the app
/// installs its Rust decoder.
Gunzip createGunzip() => platform.createGunzip();
