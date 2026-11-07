import 'package:flasher_web_hosted/src/errors.dart';
import 'package:flasher_web_hosted/src/leases.dart';
import 'package:flasher_web_hosted/src/util.dart';
import 'package:test/test.dart';

void main() {
  test('leases renew with the same id and remain pinned until release', () {
    var now = DateTime.utc(2026, 1, 1);
    final manager = LeaseManager(
      ttl: const Duration(seconds: 10),
      maxLifetime: const Duration(hours: 1),
      maxPerJob: 2,
      clock: () => now,
    );
    final lease = manager.acquire('job');
    expect(urlSafeId.hasMatch(lease.leaseId), isTrue);
    expect(manager.isPinned('job'), isTrue);
    now = now.add(const Duration(seconds: 5));
    final renewed = manager.renew('job', lease.leaseId);
    expect(renewed.leaseId, lease.leaseId);
    expect(renewed.expiresAt, now.add(const Duration(seconds: 10)));
    manager.release('job', lease.leaseId);
    expect(manager.isPinned('job'), isFalse);
  });

  test('lease TTL is bounded by the hard lifetime', () {
    var now = DateTime.utc(2026, 1, 1);
    final manager = LeaseManager(
      ttl: const Duration(hours: 2),
      maxLifetime: const Duration(hours: 3),
      maxPerJob: 2,
      clock: () => now,
    );
    final lease = manager.acquire('job');
    expect(lease.expiresAt, DateTime.utc(2026, 1, 1, 2));
    now = now.add(const Duration(hours: 1));
    final renewed = manager.renew('job', lease.leaseId);
    expect(renewed.expiresAt, DateTime.utc(2026, 1, 1, 3));
    now = now.add(const Duration(hours: 1, minutes: 50));
    final bounded = manager.renew('job', lease.leaseId);
    expect(bounded.expiresAt, DateTime.utc(2026, 1, 1, 3));
    now = now.add(const Duration(minutes: 10));
    expect(
      () => manager.renew('job', lease.leaseId),
      throwsA(
        isA<HostedException>().having(
          (error) => error.code,
          'code',
          'lease_max_lifetime',
        ),
      ),
    );
  });

  test('a soft-expired lease cannot be renewed before the hard deadline',
      () {
    var now = DateTime.utc(2026, 1, 1);
    final manager = LeaseManager(
      ttl: const Duration(seconds: 10),
      maxLifetime: const Duration(hours: 1),
      maxPerJob: 2,
      clock: () => now,
    );
    final lease = manager.acquire('job');
    now = now.add(const Duration(seconds: 11));
    expect(manager.isPinned('job'), isFalse);
    expect(
      () => manager.renew('job', lease.leaseId),
      throwsA(
        isA<HostedException>().having(
          (error) => error.code,
          'code',
          'lease_missing',
        ),
      ),
    );
  });

  test('per-job lease count and expiry are bounded', () {
    var now = DateTime.utc(2026, 1, 1);
    final manager = LeaseManager(
      ttl: const Duration(seconds: 10),
      maxLifetime: const Duration(minutes: 10),
      maxPerJob: 1,
      clock: () => now,
    );
    manager.acquire('job');
    expect(
      () => manager.acquire('job'),
      throwsA(
        isA<HostedException>().having(
          (error) => error.code,
          'code',
          'lease_limit',
        ),
      ),
    );
    now = now.add(const Duration(seconds: 11));
    expect(manager.isPinned('job'), isFalse);
    final next = manager.acquire('job');
    expect(next.leaseId, isNotEmpty);
  });

  test('internal leases pin without consuming the public limit', () {
    final manager = LeaseManager(
      ttl: const Duration(seconds: 10),
      maxLifetime: const Duration(minutes: 10),
      maxPerJob: 1,
    );
    final internal = manager.acquireInternal('job');
    expect(manager.isPinned('job'), isTrue);
    final publicLease = manager.acquire('job');
    expect(manager.activeCount('job'), 2);
    manager.release('job', publicLease.leaseId);
    expect(manager.isPinned('job'), isTrue);
    manager.releaseInternal(internal);
    expect(manager.isPinned('job'), isFalse);
  });
}
