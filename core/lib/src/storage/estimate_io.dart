import 'dart:io';

import 'budget.dart';

/// Free space on the volume [path] lives on.
///
/// A VM process has no origin quota and no existing usage reading. Free space
/// on the volume is the limit a caller actually hits, so it becomes the quota
/// and usage is reported as 0: the available space is then
/// `min(cap, free space)`. When `df` cannot be run the estimate is null, which
/// leaves [appStorageCapBytes] as the only limit (the documented unbounded
/// semantics).
final class PlatformStorageEstimateSource implements StorageEstimateSource {
  PlatformStorageEstimateSource({this.path = '.'});

  /// A file or directory whose volume is measured. A path that does not exist
  /// yet uses its nearest existing parent, so a fresh output directory is
  /// measured on the volume it will be created on.
  final String path;

  @override
  Future<StorageEstimate?> estimate() async {
    final free = await _diskFreeBytes(path);
    if (free == null) return null;
    return StorageEstimate(usage: 0, quota: free);
  }
}

Future<int?> _diskFreeBytes(String path) async {
  try {
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
