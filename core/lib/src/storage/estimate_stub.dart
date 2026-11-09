import 'budget.dart';

/// The capacity source when neither `dart:io` nor `dart:js_interop` exists.
///
/// This is the analyzer's default branch and the fallback for an unsupported
/// target. The class keeps the public name and constructor of the VM and web
/// implementations so callers type-check; [estimate] throws.
final class PlatformStorageEstimateSource implements StorageEstimateSource {
  const PlatformStorageEstimateSource({this.path = '.'});

  final String path;

  @override
  Future<StorageEstimate?> estimate() async => throw UnsupportedError(
    'storage budget needs dart:io or dart:js_interop',
  );
}
