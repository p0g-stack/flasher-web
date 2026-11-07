import 'errors.dart';
import 'util.dart';

/// A bounded lease over a finished job's artifact.
final class JobLease {
  JobLease._({
    required this.jobId,
    required this.leaseId,
    required this.createdAt,
    required this.hardDeadline,
    required this.expiresAt,
    required this.internal,
  });

  final String jobId;
  final String leaseId;
  final DateTime createdAt;
  final DateTime hardDeadline;
  final bool internal;
  DateTime expiresAt;

  Map<String, Object?> toJson(int ttlSeconds, int maxSeconds) => {
    'jobId': jobId,
    'leaseId': leaseId,
    'expiresAt': isoUtc(expiresAt),
    'ttlSeconds': ttlSeconds,
    'maxLifetimeSeconds': maxSeconds,
  };
}

/// Job leases prevent retention/eviction while a client reads or flashes an
/// artifact. Every renewal is bounded by one hard deadline from acquisition.
final class LeaseManager {
  LeaseManager({
    required this.ttl,
    required this.maxLifetime,
    required this.maxPerJob,
    this.internalTtl = const Duration(minutes: 15),
    this.maxInternalPerJob = 4,
    this.maxInternalTotal = 32,
    DateTime Function()? clock,
    this.onUse,
  }) : _clock = clock ?? (() => DateTime.now().toUtc());

  final Duration ttl;
  final Duration maxLifetime;
  final int maxPerJob;
  final Duration internalTtl;
  final int maxInternalPerJob;
  final int maxInternalTotal;
  final DateTime Function() _clock;
  final void Function(String jobId)? onUse;
  final Map<String, Map<String, JobLease>> _byJob = {};

  /// Acquires an external lease or throws when the job is pinned by too many.
  JobLease acquire(String jobId) {
    _prune(jobId);
    final leases = _byJob.putIfAbsent(jobId, () => {});
    final active = leases.values
        .where((lease) => !lease.internal && _alive(lease))
        .length;
    if (active >= maxPerJob) {
      throw const HostedException(
        'lease_limit',
        'This job already has the maximum number of active leases.',
        status: 429,
      );
    }
    final now = _clock();
    final lease = JobLease._(
      jobId: jobId,
      leaseId: randomId(bytes: 24),
      createdAt: now,
      hardDeadline: now.add(maxLifetime),
      expiresAt: now.add(ttl),
      internal: false,
    );
    leases[lease.leaseId] = lease;
    onUse?.call(jobId);
    return lease;
  }

  JobLease acquireInternal(String jobId, {Duration? ttl}) {
    final leaseTtl = ttl ?? internalTtl;
    _pruneAll();
    final leases = _byJob.putIfAbsent(jobId, () => {});
    final perJob = leases.values
        .where((lease) => lease.internal && _alive(lease))
        .length;
    if (perJob >= maxInternalPerJob) {
      throw const HostedException(
        'lease_limit',
        'This job has the maximum number of active transfers.',
        status: 429,
      );
    }
    final total = _byJob.values
        .expand((leases) => leases.values)
        .where((lease) => lease.internal && _alive(lease))
        .length;
    if (total >= maxInternalTotal) {
      throw const HostedException(
        'lease_limit',
        'The server has the maximum number of active transfers.',
        status: 429,
      );
    }
    final now = _clock();
    final lease = JobLease._(
      jobId: jobId,
      leaseId: randomId(bytes: 24),
      createdAt: now,
      hardDeadline: now.add(leaseTtl),
      expiresAt: now.add(leaseTtl),
      internal: true,
    );
    leases[lease.leaseId] = lease;
    return lease;
  }

  JobLease renew(String jobId, String leaseId) {
    final lease = _byJob[jobId]?[leaseId];
    if (lease == null || lease.internal) {
      throw const HostedException(
        'lease_missing',
        'The lease does not exist or has expired.',
        status: 404,
      );
    }
    final now = _clock();
    if (!now.isBefore(lease.hardDeadline)) {
      _remove(lease);
      throw const HostedException(
        'lease_max_lifetime',
        'The lease reached its maximum lifetime. Acquire a new lease.',
        status: 409,
      );
    }
    if (!lease.expiresAt.isAfter(now)) {
      _remove(lease);
      throw const HostedException(
        'lease_missing',
        'The lease does not exist or has expired.',
        status: 404,
      );
    }
    final requested = now.add(ttl);
    lease.expiresAt = requested.isBefore(lease.hardDeadline)
        ? requested
        : lease.hardDeadline;
    onUse?.call(jobId);
    return lease;
  }

  void release(String jobId, String leaseId) {
    final lease = _byJob[jobId]?[leaseId];
    if (lease == null) {
      throw const HostedException(
        'lease_missing',
        'The lease does not exist or has expired.',
        status: 404,
      );
    }
    _remove(lease);
  }

  void releaseInternal(JobLease lease) {
    if (lease.internal) _remove(lease);
  }

  /// Whether a job must not be evicted now.
  bool isPinned(String jobId) {
    _prune(jobId);
    final leases = _byJob[jobId];
    return leases != null && leases.values.any(_alive);
  }

  int activeCount(String jobId) {
    _prune(jobId);
    return _byJob[jobId]?.values.where(_alive).length ?? 0;
  }

  Set<String> pinnedJobs() {
    _pruneAll();
    return {
      for (final entry in _byJob.entries)
        if (entry.value.values.any(_alive)) entry.key,
    };
  }

  bool _alive(JobLease lease) => lease.expiresAt.isAfter(_clock());



  void _prune(String jobId) {
    final leases = _byJob[jobId];
    if (leases == null) return;
    leases.removeWhere((_, lease) => !_alive(lease));
    if (leases.isEmpty) _byJob.remove(jobId);
  }

  void _pruneAll() {
    for (final jobId in _byJob.keys.toList()) {
      _prune(jobId);
    }
  }

  void _remove(JobLease lease) {
    final leases = _byJob[lease.jobId];
    if (leases == null) return;
    leases.remove(lease.leaseId);
    if (leases.isEmpty) _byJob.remove(lease.jobId);
  }
}
