import 'package:web/web.dart' as web;

import 'contracts.dart';
import 'web/handle_sink.dart';

/// Opens the file behind the save picker's `FileSystemFileHandle`.
///
/// The handle arrives through the service call as a JS object, like a picked
/// store's `handle`. The sink truncates the file, matching `createWritable()`
/// on a destination the user already agreed to overwrite.
Future<ByteSink> openExportSink(Object? destination) async {
  try {
    return await HandleSink.open(destination as web.FileSystemFileHandle);
  } on TypeError {
    throw ArgumentError.value(
      destination,
      'destination',
      'must be the FileSystemFileHandle from the save picker',
    );
  }
}
