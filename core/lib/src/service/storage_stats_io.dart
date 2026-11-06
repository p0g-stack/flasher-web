import 'dart:io';

/// The output volume's free space, as a quota.
Future<Map<String, Object?>> storageStatistics() async {
  try {
    final usage = await Process.run('df', ['-k', '.']);
    if (usage.exitCode == 0) {
      final lines = '${usage.stdout}'.trim().split('\n');
      if (lines.length > 1) {
        final fields = lines[1].split(RegExp(r'\s+'));
        final available = fields.length > 3 ? int.tryParse(fields[3]) : null;
        if (available != null) {
          return {'persisted': true, 'quota': available * 1024, 'usage': 0};
        }
      }
    }
  } catch (_) {}
  return {'persisted': false, 'quota': 0, 'usage': 0};
}
