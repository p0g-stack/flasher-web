import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Structured cloning creates new wrappers; compare the underlying directory.
Future<bool> sameFlashStore(
  Map<String, Object?> left,
  Map<String, Object?> right,
) async {
  if (left['kind'] != right['kind'] || left['path'] != right['path']) {
    return false;
  }
  final a = left['handle'];
  final b = right['handle'];
  if (a == null || b == null) return a == b;
  return (await (a as web.FileSystemDirectoryHandle)
          .isSameEntry(b as web.FileSystemHandle)
          .toDart)
      .toDart;
}
