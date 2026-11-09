import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'budget.dart';

/// The origin's `navigator.storage.estimate()`.
///
/// The browser accounts the whole origin, so [path] is ignored: OPFS, the
/// service-worker shell and every other same-origin store share one usage and
/// one quota. Available in the page and in the Web Worker the service runs in.
final class PlatformStorageEstimateSource implements StorageEstimateSource {
  const PlatformStorageEstimateSource({this.path = '.'});

  /// Ignored on the web; the origin is the unit of accounting.
  final String path;

  @override
  Future<StorageEstimate?> estimate() async {
    final navigator = globalContext['navigator'] as JSObject?;
    if (navigator == null || !navigator.has('storage')) return null;
    try {
      final storage = navigator['storage'] as web.StorageManager;
      final estimate = await storage.estimate().toDart;
      return StorageEstimate(usage: estimate.usage, quota: estimate.quota);
    } on Object {
      return null;
    }
  }
}
