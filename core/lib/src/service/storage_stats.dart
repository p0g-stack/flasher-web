/// Quota, usage and persistence for the `environment` method.
library;

import 'storage_stats_io.dart'
    if (dart.library.js_interop) 'storage_stats_web.dart'
    as platform;

/// `{"persisted", "quota", "usage"}` in bytes.
Future<Map<String, Object?>> storageStatistics() =>
    platform.storageStatistics();

/// Available bytes for this store, or null when its capacity cannot be queried.
/// Browser origin quota applies only to OPFS, never to a picked folder.
Future<int?> availableStoreBytes(Map<String, Object?> store) =>
    platform.availableStoreBytes(store);
