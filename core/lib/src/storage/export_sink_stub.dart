import 'contracts.dart';

/// The export sink when neither `dart:io` nor `dart:js_interop` exists.
///
/// This is the analyzer's default branch and the fallback for an unsupported
/// target; the signature matches the VM and web implementations.
Future<ByteSink> openExportSink(Object? destination) async =>
    throw UnsupportedError('an export needs dart:io or dart:js_interop');
