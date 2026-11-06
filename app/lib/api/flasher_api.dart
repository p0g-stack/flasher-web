/// The app-facing view of the build service's map protocol.
///
/// The concrete implementation in `service/squadron_api.dart` forwards to the
/// generated Squadron worker; widget tests use a scripted fake. Keeping the
/// interface here means the UI never depends on generated code directly.
library;

import 'package:squadron/squadron.dart';

/// One event from a `build` or `downloadBloat` stream.
typedef FlasherEvent = Map<String, Object?>;

/// The six methods of `docs/service.md`, unchanged.
abstract interface class FlasherApi {
  /// Facts, Rust availability and storage space in the place the service runs.
  Future<Map<String, Object?>> environment();

  /// Whether every bloat image the selection needs is present and verified.
  Future<Map<String, Object?>> bloatStatus(Map<String, Object?> request);

  /// Downloads and verifies bloat images; the last event is a result.
  Stream<Map<String, Object?>> downloadBloat(Map<String, Object?> request);

  /// Validates a full AB OTA and reports what a build would use.
  Future<Map<String, Object?>> inspectOta(Map<String, Object?> request);

  /// Builds a flasher; step, log and progress events, then one result.
  Stream<Map<String, Object?>> build(Map<String, Object?> request);

  /// `build.json` of every finished job in the output store, newest first.
  Future<List<Map<String, Object?>>> history(Map<String, Object?> request);

  /// Releases the worker behind this API, if any.
  void dispose();
}

/// Whether [worker] is a Squadron worker the app must terminate itself.
bool isTerminableWorker(Object service) => service is Worker;
