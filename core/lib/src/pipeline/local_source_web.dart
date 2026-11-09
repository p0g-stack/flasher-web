import 'dart:js_interop';
import 'package:web/web.dart' as web;

import '../storage/contracts.dart';
import '../storage/web/blob_source.dart';
import 'errors.dart';

/// Wraps the browser's `File` (or `Blob`) without copying its bytes.
Future<ByteSource> openLocalOta(Object file) async {
  try {
    return BlobSource(file as JSObject);
  } on TypeError {
    throw const BuildException('Choose a full OTA file.');
  }
}

Future<Map<String, Object?>> localOtaIdentity(Object file) async {
  try {
    final selected = file as web.File;
    return {
      'kind': 'file',
      'name': selected.name,
      'size': selected.size,
      'lastModified': selected.lastModified,
    };
  } on Object catch (error) {
    throw BuildException('Choose a full OTA File with metadata: $error');
  }
}
