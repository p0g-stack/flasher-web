import 'dart:io';

import 'contracts.dart';
import 'io/file_sink.dart';

/// Opens the file named by a `{"kind": "path", "path": "..."}` destination.
///
/// The path is absolute or relative to the process working directory, and its
/// parents are created. This is the user's own choice of where the export
/// lands, so there is no workspace root to guard.
Future<ByteSink> openExportSink(Object? destination) async {
  final path = destination is Map ? destination['path'] : null;
  if (path is! String || path.isEmpty) {
    throw ArgumentError.value(
      destination,
      'destination',
      'must be {"kind": "path", "path": "<file>"}',
    );
  }
  return FileSink.open(File(path));
}
