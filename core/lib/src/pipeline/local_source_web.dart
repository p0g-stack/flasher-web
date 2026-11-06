import 'dart:js_interop';

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
