import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

Future<Map<String, Object?>> storageStatistics() async {
  final nav = globalContext['navigator'] as JSObject?;
  if (nav == null || !nav.has('storage')) {
    return {'persisted': false, 'quota': 0, 'usage': 0};
  }
  final storage = nav['storage'] as web.StorageManager;
  var persisted = false;
  var quota = 0;
  var usage = 0;
  try {
    persisted = (await storage.persisted().toDart).toDart;
  } catch (_) {}
  try {
    final estimate = await storage.estimate().toDart;
    quota = estimate.quota;
    usage = estimate.usage;
  } catch (_) {}
  return {'persisted': persisted, 'quota': quota, 'usage': usage};
}
