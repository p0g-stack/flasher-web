import 'package:flasher_web_core/src/storage/budget.dart';
import 'package:test/test.dart';

void main() {
  test('the cap is 10 GiB', () {
    expect(appStorageCapBytes, 10 * 1024 * 1024 * 1024);
  });

  test('available is the smaller of the cap and the quota', () async {
    Future<int> available(StorageEstimateSource source) =>
        StorageBudget(estimateSource: source, cap: 1000).available();

    expect(
      await available(_Estimate(usage: 100, quota: 5000)),
      900,
      reason: 'the cap binds',
    );
    expect(
      await available(_Estimate(usage: 100, quota: 600)),
      500,
      reason: 'the platform quota binds',
    );
    expect(
      await available(_Estimate(usage: 2000, quota: 5000)),
      0,
      reason: 'usage past the cap is never negative room',
    );
    expect(
      await available(_Estimate(usage: 100, quota: 0)),
      900,
      reason: 'an unknown quota leaves the cap',
    );
    expect(
      await available(_Unknown()),
      1000,
      reason: 'an unknown estimate leaves the cap alone',
    );
  });

  test('a planned write that fits passes without eviction', () async {
    final estimate = _Estimate(usage: 100, quota: 5000);
    var evictions = 0;
    final budget = StorageBudget(estimateSource: estimate, cap: 1000);
    await budget.ensure(900, evict: (needed) async {
      evictions++;
      return 0;
    });
    expect(evictions, 0);
    await budget.ensure(0);
  });

  test('eviction frees least recently used space until it fits', () async {
    final estimate = _Estimate(usage: 1000, quota: 0);
    final budget = StorageBudget(estimateSource: estimate, cap: 1000);
    final shortfalls = <int>[];
    await budget.ensure(500, evict: (needed) async {
      shortfalls.add(needed);
      estimate.usage -= 300;
      return 300;
    });
    expect(shortfalls, [500, 200]);
    expect(estimate.usage, 400);
  });

  test('freed bytes count even when the platform still reports them', () async {
    // navigator.storage.estimate() can lag a deletion. The evictor's returned
    // bytes keep the loop honest until the reading catches up.
    final estimate = _Estimate(usage: 1000, quota: 0);
    final budget = StorageBudget(estimateSource: estimate, cap: 1000);
    var calls = 0;
    await budget.ensure(500, evict: (needed) async {
      calls++;
      return 600;
    });
    expect(calls, 1);
    expect(estimate.usage, 1000, reason: 'the fake never updates');
  });

  test('a default evictor is used when the call passes none', () async {
    final estimate = _Estimate(usage: 1000, quota: 0);
    var calls = 0;
    final budget = StorageBudget(
      estimateSource: estimate,
      cap: 1000,
      evictDefault: (needed) async {
        calls++;
        estimate.usage -= 1000;
        return 1000;
      },
    );
    await budget.ensure(500);
    expect(calls, 1);
  });

  test('a shortfall names needed, available, cap, usage and quota', () async {
    final estimate = _Estimate(usage: 900, quota: 2000);
    final budget = StorageBudget(estimateSource: estimate, cap: 1000);
    await expectLater(
      budget.ensure(500, evict: (needed) async => 0),
      throwsA(
        isA<BudgetException>()
            .having((error) => error.needed, 'needed', 500)
            .having((error) => error.available, 'available', 100)
            .having((error) => error.cap, 'cap', 1000)
            .having((error) => error.usage, 'usage', 900)
            .having((error) => error.quota, 'quota', 2000)
            .having(
              (error) => error.toString(),
              'message',
              allOf(contains('500 bytes'), contains('100 bytes'), contains('app cap')),
            ),
      ),
    );
  });

  test('a write larger than the cap is refused before any eviction', () async {
    final budget = StorageBudget(
      estimateSource: _Estimate(usage: 0, quota: 0),
      cap: 1000,
    );
    var calls = 0;
    await expectLater(
      budget.ensure(2000, evict: (needed) async {
        calls++;
        return 2000;
      }),
      throwsA(isA<BudgetException>()),
    );
    expect(calls, 0);
  });

  test('a negative plan is an argument error', () async {
    final budget = StorageBudget(estimateSource: _Unknown(), cap: 1000);
    await expectLater(budget.ensure(-1), throwsArgumentError);
  });

  test('snapshot reads one estimate and reports the same arithmetic', () async {
    final estimate = _Estimate(usage: 300, quota: 800);
    final budget = StorageBudget(estimateSource: estimate, cap: 1000);
    final report = await budget.snapshot();
    expect(report.cap, 1000);
    expect(report.usage, 300);
    expect(report.quota, 800);
    expect(report.available, 500);
    expect(estimate.reads, 1);
  });
}

final class _Estimate implements StorageEstimateSource {
  _Estimate({required this.usage, required this.quota});

  int usage;
  int quota;
  int reads = 0;

  @override
  Future<StorageEstimate?> estimate() async {
    reads++;
    return StorageEstimate(usage: usage, quota: quota);
  }
}

final class _Unknown implements StorageEstimateSource {
  @override
  Future<StorageEstimate?> estimate() async => null;
}
