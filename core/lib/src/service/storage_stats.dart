/// Quota, usage and persistence for the `environment` method.
library;

import 'storage_stats_io.dart'
    if (dart.library.js_interop) 'storage_stats_web.dart'
    as platform;

/// `{"persisted", "quota", "usage"}` in bytes.
Future<Map<String, Object?>> storageStatistics() =>
    platform.storageStatistics();
