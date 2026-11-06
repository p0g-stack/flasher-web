/// Opens the user's local OTA as a [ByteSource] without copying it.
///
/// The web build receives the browser's `File`; the VM receives a path.
library;

import 'local_source_io.dart'
    if (dart.library.js_interop) 'local_source_web.dart'
    as platform;
import '../storage/contracts.dart';

/// Opens [file], a `File` on the web or a path [String] natively.
Future<ByteSource> openLocalOta(Object file) => platform.openLocalOta(file);
