import '../rust/api/payload.dart' show GzipDecoder;
import 'gunzip.dart';

/// A streaming gzip decoder backed by the app's Rust library.
///
/// The web has no `dart:io` decoder; a caller awaits `loadNative()` before
/// constructing this, then the worker decodes bloat assets as they arrive.
final class RustGunzip implements Gunzip {
  RustGunzip() : _decoder = GzipDecoder();

  final GzipDecoder _decoder;

  @override
  List<int> push(List<int> bytes) => _decoder.push(bytes: bytes);

  @override
  List<int> finish() => _decoder.finish();
}
