/// Test-support fixtures shared by the core tests and the e2e harness.
///
/// Nothing in the app, its workers or the CLI imports this library, so the
/// payload builder, the on-disk fixture workspace and their `dart:io` imports
/// never reach a production browser bundle. The e2e harness uses the same
/// bytes the core tests do.
library;

export 'src/e2e/compression_fixture.dart';
export 'src/e2e/ota_fixture.dart';
export 'src/e2e/virtual_fixture.dart';
