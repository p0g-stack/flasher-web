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
// Inert unless the build defines FLASHER_FAKE_USB=true: the service's default
// transport factory keeps it behind a constant branch, so a production bundle
// treeshakes the fake and its marker. The e2e harness and the page's chooser
// names it under the define.
export 'src/e2e/fake_fastboot.dart'
    show
        configureFakeFastboot,
        fakeFastbootChannelName,
        fakeFastbootMarker,
        fakeFastbootSerial,
        fakeFastbootState,
        fakeFastbootTransport;
export 'src/facts/facts.dart';
export 'src/flash/executor.dart';
export 'src/flash/flow.dart';
export 'src/flash/wipe_super.dart';
export 'src/flash/model.dart';
export 'src/flash/ota_source.dart';
export 'src/flash/package.dart';
export 'src/flash/package_index.dart';
export 'src/flash/plan.dart';
export 'src/flash/prepare.dart';
export 'src/flash/sparse.dart';
export 'src/flash/virtual.dart';
export 'src/flash/virtual_export.dart';
export 'src/log.dart';
export 'src/native/native.dart'
    show loadNative, NativeLoadFailure, nativeLoadFailure;
export 'src/pipeline/assets.dart';
export 'src/pipeline/errors.dart';
export 'src/pipeline/local_source.dart';
export 'src/pipeline/ota.dart';
export 'src/places/webui_launcher.dart';
export 'src/service/flasher_service.dart';
// The pipeline's device/flasher selection wins the name; the strategy picker
// is internal to `objective.dart` and its callers use inference.
export 'src/strategy/objective.dart';
export 'src/strategy/store.dart';
export 'src/strategy/strategy.dart' hide Selection;
export 'src/storage/block_ota_source.dart';
export 'src/storage/budget.dart';
export 'src/storage/estimate.dart';
export 'src/storage/storage.dart';
export 'src/upstream/bloat_selection.dart';
export 'src/upstream/device_layout.dart';
export 'src/upstream/tables.dart';

// p0g:exports (bricks insert exports above this line)
