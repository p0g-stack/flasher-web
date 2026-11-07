import 'dart:io';

/// Capacity of the service's working volume, for the environment display.
Future<Map<String, Object?>> storageStatistics() async {
  final free = await _diskFreeBytes('.');
  return {'persisted': free != null, 'quota': free ?? 0, 'usage': 0};
}

Future<int?> availableStoreBytes(Map<String, Object?> store) async {
  final path = store['path'];
  if (store['kind'] != 'path' || path is! String || path.isEmpty) return null;
  return _diskFreeBytes(path);
}

Future<int?> _diskFreeBytes(String path) async {
  try {
    // A new output directory uses the volume of its nearest existing parent.
    var directory = Directory(path).absolute;
    while (!await directory.exists()) {
      final parent = directory.parent;
      if (parent.path == directory.path) return null;
      directory = parent;
    }
    final usage = await Process.run('df', ['-Pk', directory.path]);
    if (usage.exitCode == 0) {
      final lines = '${usage.stdout}'.trim().split('\n');
      if (lines.length > 1) {
        final fields = lines.last.split(RegExp(r'\s+'));
        final available = fields.length > 3 ? int.tryParse(fields[3]) : null;
        if (available != null) return available * 1024;
      }
    }
  } on Object {
    // Platforms without a capacity API must report unknown, not another disk.
  }
  return null;
}
