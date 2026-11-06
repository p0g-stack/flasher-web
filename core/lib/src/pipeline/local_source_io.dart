import 'dart:io';

import '../storage/io/file_source.dart';
import '../storage/contracts.dart';
import 'errors.dart';

/// Opens a local path in place.
Future<ByteSource> openLocalOta(Object file) async {
  if (file is! String) {
    throw const BuildException('Choose a full OTA file.');
  }
  final path = File(file).absolute;
  if (!await path.exists()) {
    throw BuildException('OTA file not found: ${path.path}');
  }
  return FileSource.open(path);
}
