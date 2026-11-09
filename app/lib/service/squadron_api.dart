import 'package:flasher_web_core/flasher_web_core.dart';

import '../api/flasher_api.dart';

/// Forwards the app's build and flash methods to the generated Squadron worker.
final class SquadronFlasherApi implements FlasherApi {
  SquadronFlasherApi(this._worker);

  final FlasherServiceWorker _worker;

  @override
  Future<Map<String, Object?>> environment() => _worker.environment();

  @override
  Future<Map<String, Object?>> bloatStatus(Map<String, Object?> request) =>
      _worker.bloatStatus(request);

  @override
  Stream<Map<String, Object?>> downloadBloat(Map<String, Object?> request) =>
      _worker.downloadBloat(request);

  @override
  Future<Map<String, Object?>> inspectOta(Map<String, Object?> request) =>
      _worker.inspectOta(request);

  @override
  Stream<Map<String, Object?>> build(Map<String, Object?> request) =>
      _worker.build(request);

  @override
  Future<List<Map<String, Object?>>> history(Map<String, Object?> request) =>
      _worker.history(request);

  @override
  Future<Map<String, Object?>> fastbootDevices() => _worker.fastbootDevices();

  @override
  Future<Map<String, Object?>> prepareFlash(Map<String, Object?> request) =>
      _worker.prepareFlash(request);

  @override
  Stream<Map<String, Object?>> flash(Map<String, Object?> request) =>
      _worker.flash(request);

  @override
  Future<Map<String, Object?>> storageBudget(Map<String, Object?> request) =>
      _worker.storageBudget(request);

  @override
  Stream<Map<String, Object?>> cacheOta(Map<String, Object?> request) =>
      _worker.cacheOta(request);

  @override
  Future<Map<String, Object?>> evictCachedOta(Map<String, Object?> request) =>
      _worker.evictCachedOta(request);

  @override
  Stream<Map<String, Object?>> exportVirtual(Map<String, Object?> request) =>
      _worker.exportVirtual(request);

  @override
  void dispose() => _worker.terminate();
}
