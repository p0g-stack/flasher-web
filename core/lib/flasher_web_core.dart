/// The logic of flasher_web, shared by the Flutter app, its workers
/// and the CLI.
///
/// Pure Dart: this library never imports `package:flutter`, because the CLI
/// runs it on the plain Dart VM.
library;

export 'package:logging/logging.dart' show Level, LogRecord, Logger;

export 'src/bloat/bloat_store.dart';
export 'src/bloat/gunzip.dart';
export 'src/bloat/manifest.dart';
export 'src/catalog/catalog_client.dart';
export 'src/catalog/http_transport.dart';
export 'src/catalog/ota_catalog.dart';
export 'src/facts/facts.dart';
export 'src/log.dart';
export 'src/native/native.dart' show loadNative;
export 'src/pipeline/assets.dart';
export 'src/pipeline/build.dart';
export 'src/pipeline/errors.dart';
export 'src/pipeline/extract.dart';
export 'src/pipeline/local_source.dart';
export 'src/pipeline/ota.dart';
export 'src/pipeline/package.dart';
export 'src/places/webui_launcher.dart';
export 'src/service/flasher_service.dart';
// The pipeline's device/flasher selection wins the name; the strategy picker
// is internal to `objective.dart` and its callers use inference.
export 'src/strategy/objective.dart';
export 'src/strategy/store.dart';
export 'src/strategy/strategy.dart' hide Selection;
export 'src/storage/storage.dart';
export 'src/upstream/bloat_selection.dart';
export 'src/upstream/device_layout.dart';
export 'src/upstream/tables.dart';

// p0g:exports (bricks insert exports above this line)
