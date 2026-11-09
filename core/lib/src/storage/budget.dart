/// The hard cap on this app's browser storage, and the arithmetic that decides
/// whether one more file fits.
///
/// The cap exists because a local-first PWA keeps a bounded working set in the
/// origin's storage: verified bloat images (at most about 1.72 GiB raw), an
/// optional least-recently-used cache of catalog OTA ZIPs, small metadata and
/// the service-worker shell. Local OTA files are read in place, so they cost
/// nothing. [StorageBudget] answers one question before a write: after this
/// many more bytes, does the origin still fit?
///
/// The estimate is injected ([StorageEstimateSource]) because only the caller
/// knows where the bytes will go: the browser reports `navigator.storage`
/// estimate for its own origin, and a VM process measures the volume it writes
/// to. [StorageBudget] itself is pure Dart, so the arithmetic and the eviction
/// loop are tested without a browser.
library;

import 'dart:math' as math;

/// The most this app may ever keep in its browser storage: 10 GiB.
///
/// The origin usage reported by `navigator.storage.estimate()` counts every
/// byte the origin stores, including the service-worker shell and the OTA
/// cache. A write is refused once `usage + planned` would pass this cap, even
/// when the platform would allow more.
const int appStorageCapBytes = 10 * 1024 * 1024 * 1024;

/// A platform capacity reading.
final class StorageEstimate {
  const StorageEstimate({required this.usage, required this.quota});

  /// Bytes the origin (or volume) already holds.
  final int usage;

  /// Bytes the platform allows this origin, or 0 when it cannot say. A
  /// non-positive quota means "unknown": only [StorageBudget.cap] applies.
  final int quota;
}

/// Reports the usage and quota of the storage a budget guards.
///
/// Implementations: the browser's `navigator.storage.estimate()` on the web,
/// free volume space on the VM, and a fake in tests. A source that cannot
/// measure anything returns null, which the budget reads as "unbounded above
/// the cap" and documents in [StorageBudget.available].
abstract interface class StorageEstimateSource {
  Future<StorageEstimate?> estimate();
}

/// A source that cannot report anything, so only [StorageBudget.cap] applies.
///
/// A browser folder the user picked is outside the origin's quota: the platform
/// has no usage reading for it, and pretending the origin's reading describes
/// it would bound the wrong bytes.
final class UnknownStorageEstimate implements StorageEstimateSource {
  const UnknownStorageEstimate();

  @override
  Future<StorageEstimate?> estimate() async => null;
}

/// One reading of the budget, for a status display.
final class StorageBudgetReport {
  const StorageBudgetReport({
    required this.cap,
    required this.usage,
    required this.quota,
    required this.available,
  });

  final int cap;
  final int usage;
  final int quota;

  /// Bytes a new file may use: `min(cap - usage, quota - usage)`, never
  /// negative.
  final int available;
}

/// A planned write does not fit, even after eviction freed what it could.
final class BudgetException implements Exception {
  const BudgetException({
    required this.needed,
    required this.available,
    required this.cap,
    required this.usage,
    required this.quota,
  });

  /// Bytes the caller wanted to add.
  final int needed;

  /// Bytes the budget can still take, after eviction.
  final int available;

  /// [appStorageCapBytes], or the cap this budget was built with.
  final int cap;

  /// Current origin usage.
  final int usage;

  /// Platform quota, or 0 when unknown.
  final int quota;

  @override
  String toString() =>
      'Not enough storage: $needed bytes needed but only $available bytes '
      'are free under the ${_sizes(cap)} app cap '
      '(usage ${_sizes(usage)}, platform quota '
      '${quota > 0 ? _sizes(quota) : 'unknown'}). '
      'Free space by deleting a cached OTA or bloat image and retry.';
}

/// The cap, the platform estimate and the eviction loop in one place.
final class StorageBudget {
  StorageBudget({
    required this.estimateSource,
    this.cap = appStorageCapBytes,
    this.evictDefault,
  });

  /// Where usage and quota come from.
  final StorageEstimateSource estimateSource;

  /// The self-imposed ceiling on top of the platform quota.
  final int cap;

  /// The evictor [ensure] uses when the call passes none: it must free about
  /// [needed] bytes of disposable cache and return the bytes it freed. Wiring
  /// it to the OTA cache's least-recently-used eviction lets a bloat download
  /// make room for itself.
  final Future<int> Function(int needed)? evictDefault;

  /// How many eviction rounds one [ensure] may run before giving up.
  static const int _maxEvictionPasses = 32;

  Future<StorageEstimate?> estimate() => estimateSource.estimate();

  /// Bytes the origin already holds; 0 when the platform cannot report.
  Future<int> usage() async => (await estimateSource.estimate())?.usage ?? 0;

  /// Bytes the platform allows; 0 when the platform cannot report.
  Future<int> quota() async => (await estimateSource.estimate())?.quota ?? 0;

  /// Bytes a new file may use: `min(cap - usage, quota - usage)`, clamped at
  /// zero. An unknown estimate (null, or a non-positive quota) leaves the cap
  /// as the only limit, so a VM process without a capacity API is bounded by
  /// the cap alone.
  Future<int> available() async =>
      _availableFrom(await estimateSource.estimate());

  /// What [usage], [quota] and [available] say together, from one estimate.
  Future<StorageBudgetReport> snapshot() async {
    final estimate = await estimateSource.estimate();
    return StorageBudgetReport(
      cap: cap,
      usage: estimate?.usage ?? 0,
      quota: estimate?.quota ?? 0,
      available: _availableFrom(estimate),
    );
  }

  /// Makes room for [bytes] more bytes or throws [BudgetException].
  ///
  /// When the budget is short, [evict] (or the constructor's evictor) is
  /// asked to free at least the shortfall and returns the bytes it freed. The
  /// estimate is read again after each round, so an eviction that the platform
  /// has not accounted for yet is still counted through the returned bytes.
  /// A callback that frees nothing ends the loop and the exception names the
  /// shortfall: `needed`, `available`, `cap`, `usage` and `quota`.
  ///
  /// [bytes] is the planned increase, not the final file size, so a resumed
  /// download passes only the bytes it has still to write.
  Future<void> ensure(
    int bytes, {
    Future<int> Function(int needed)? evict,
  }) async {
    if (bytes < 0) {
      throw ArgumentError.value(bytes, 'bytes', 'must not be negative');
    }
    if (bytes == 0) return;

    final free = evict ?? evictDefault;
    var availableBytes = await available();
    if (bytes <= availableBytes) return;

    if (bytes > cap || free == null) {
      throw await _shortfall(bytes, availableBytes);
    }

    // Credit covers a platform whose usage reading lags a deletion. Once the
    // reading catches up, the credit is dropped so freed bytes are not counted
    // twice.
    var credit = 0;
    for (var pass = 0; pass < _maxEvictionPasses; pass++) {
      final shortfall = bytes - availableBytes - credit;
      if (shortfall <= 0) return;
      final freed = await free(shortfall);
      if (freed <= 0) break;
      final after = await available();
      if (after > availableBytes) {
        availableBytes = after;
        credit = 0;
      } else {
        credit += freed;
      }
    }
    if (bytes <= availableBytes + credit) return;
    throw await _shortfall(bytes, availableBytes + credit);
  }

  int _availableFrom(StorageEstimate? estimate) {
    final usage = estimate?.usage ?? 0;
    final quota = estimate?.quota ?? 0;
    final byCap = cap - usage;
    final byQuota = quota > 0 ? quota - usage : byCap;
    final free = math.min(byCap, byQuota);
    return free < 0 ? 0 : free;
  }

  Future<BudgetException> _shortfall(int needed, int availableBytes) async {
    final estimate = await estimateSource.estimate();
    final free = math.min(availableBytes, cap);
    return BudgetException(
      needed: needed,
      available: free < 0 ? 0 : free,
      cap: cap,
      usage: estimate?.usage ?? 0,
      quota: estimate?.quota ?? 0,
    );
  }
}

String _sizes(int value) {
  const kib = 1024;
  const mib = kib * 1024;
  const gib = mib * 1024;
  if (value >= gib) return '${(value / gib).toStringAsFixed(2)} GiB';
  if (value >= mib) return '${(value / mib).toStringAsFixed(2)} MiB';
  if (value >= kib) return '${(value / kib).toStringAsFixed(2)} KiB';
  return '$value bytes';
}
