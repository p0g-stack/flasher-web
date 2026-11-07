/// The app-facing view of the build and flash service's map protocol.
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

  /// Granted fastboot devices in the place the service runs.
  ///
  /// Returns `{devices: List<Map>}` plus an optional structured `error` map
  /// (`LinkFailure.toMap()`), so a failed probe keeps its original evidence
  /// instead of being stringified by Squadron. This never opens a browser
  /// chooser; the page grants permission and the service lists what is
  /// already granted.
  Future<Map<String, Object?>> fastbootDevices();

  /// Read-only flash preparation: inspects the job and device and returns a
  /// token, the ordered plan and any prompts that still need an answer.
  ///
  /// Link failures come back as `{error: LinkFailure.toMap()}` and are not a
  /// prepared plan. Validation failures still throw.
  Future<Map<String, Object?>> prepareFlash(Map<String, Object?> request);

  /// Executes a prepared flash. Step, progress, log and waiting events, then
  /// one result carrying the receipt.
  Stream<Map<String, Object?>> flash(Map<String, Object?> request);

  /// Releases the worker behind this API, if any.
  void dispose();
}

/// Whether [worker] is a Squadron worker the app must terminate itself.
bool isTerminableWorker(Object service) => service is Worker;
