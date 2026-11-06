import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../native/native.dart';
import 'facts.dart';

/// Checks the facts of the current browser context (page or Web Worker).
///
/// A browser context never has root, block devices, OS-level USB or process
/// spawning; the remaining facts are feature checks made here.
Future<Map<String, Object?>> checkFacts() async {
  final nav = globalContext['navigator'] as JSObject?;
  return {
    Fact.root: false,
    Fact.blockDevices: false,
    Fact.usbNative: false,
    Fact.usbWeb: nav != null && nav.has('usb'),
    Fact.processSpawn: false,
    Fact.fsPersistent: await _persisted(nav),
    Fact.fsPath: false,
    Fact.fsHandle: globalContext.has('FileSystemDirectoryHandle'),
    Fact.fsOpfs: await _hasOpfs(nav),
    Fact.fsPicker: _hasPicker(),
    Fact.net: nav != null && (nav['onLine'] as JSBoolean?)?.toDart == true,
    Fact.native: await nativeShipped(),
  };
}

bool _hasPicker() {
  if (!globalContext.has('showDirectoryPicker')) return false;
  final picker = globalContext['showDirectoryPicker'];
  return picker != null && picker.isA<JSFunction>();
}

Future<bool> _hasOpfs(JSObject? nav) async {
  try {
    if (nav == null || !nav.has('storage')) return false;
    final storage = nav['storage'] as web.StorageManager;
    await storage.getDirectory().toDart;
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> _persisted(JSObject? nav) async {
  try {
    if (nav == null || !nav.has('storage')) return false;
    final storage = nav['storage'] as web.StorageManager;
    return (await storage.persisted().toDart).toDart;
  } catch (_) {
    return false;
  }
}
