import 'errors.dart';

/// Non-expiring, bounded pins for operations that must finish before eviction
/// can delete their job. Time is deliberately not part of this pin: callers
/// release only after verification, publication, stream cancellation and close
/// have actually completed.
final class ActivePinManager {
  ActivePinManager({required this.maxPerJob, required this.maxTotal});

  final int maxPerJob;
  final int maxTotal;
  final Map<String, int> _counts = {};

  void acquire(String jobId) {
    final current = _counts[jobId] ?? 0;
    if (current >= maxPerJob) {
      throw const HostedException(
        'active_pin_limit',
        'This job has the maximum number of active operations.',
        status: 429,
      );
    }
    final total = _counts.values.fold<int>(0, (sum, value) => sum + value);
    if (total >= maxTotal) {
      throw const HostedException(
        'active_pin_limit',
        'The server has the maximum number of active operations.',
        status: 429,
      );
    }
    _counts[jobId] = current + 1;
  }

  void release(String jobId) {
    final current = _counts[jobId];
    if (current == null) return;
    if (current <= 1) {
      _counts.remove(jobId);
    } else {
      _counts[jobId] = current - 1;
    }
  }

  bool isPinned(String jobId) => (_counts[jobId] ?? 0) > 0;

  Set<String> pinnedJobs() => _counts.keys.toSet();

  void clear() => _counts.clear();
}
