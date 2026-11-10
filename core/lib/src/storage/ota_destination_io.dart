import 'dart:io';

import 'contracts.dart';
import 'io/file_sink.dart';
import 'io/file_source.dart';
import 'io/io_workspace.dart';
import 'ota_file_workspace.dart';

Future<Workspace> openOtaDestination(Object? destination, String key) async {
  final path = destination is Map ? destination['path'] : null;
  if (path is! String || path.isEmpty) {
    throw ArgumentError('OTA destination must name a file path');
  }
  final file = File(path);
  return OtaFileWorkspace(
    metadata: IoWorkspace(Directory('$path.ota-download')),
    openFile: () => FileSource.open(file),
    writeFile: (keep) => FileSink.open(file, keepExisting: keep),
    fileSize: () async => await file.exists() ? file.length() : 0,
  );
}
