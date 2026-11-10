import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:downloadx/downloadx.dart' show tempExt;
import 'package:flasher_web_core/src/storage/budget.dart';
import 'package:flasher_web_core/src/service/flasher_service.dart';
import 'package:flasher_web_core/src/storage/ota_cache.dart';
import 'package:flasher_web_core/src/storage/ota_destination_io.dart';
import 'package:flasher_web_core/src/storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late IoWorkspace workspace;
  final bytes = Uint8List.fromList(List.generate(1024, (i) => i % 251));
  final entry = <String, dynamic>{'id': 'parallel', 'size': bytes.length};
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('parallel_ota_');
    workspace = IoWorkspace(temp);
  });
  tearDown(() => temp.delete(recursive: true));
  OtaCache cache(OtaSourceFactory factory) => OtaCache(
    workspace: workspace,
    sources: factory,
    chunkBytes: 32,
    connections: 4,
  );

  test(
    'out-of-order completion is positional and hashes the committed file',
    () async {
      final finished = <int>[];
      final factory = _Factory(
        (generation) => _Source(bytes, (offset, count) async {
          if (offset == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
          finished.add(offset);
        }),
      );
      final result = await cache(factory).cache(entry);
      expect(finished.first, isNot(0));
      expect(result.sha256, sha256.convert(bytes).toString());
      expect(
        await File('${temp.path}/ota-cache/${result.key}.zip').readAsBytes(),
        bytes,
      );
    },
  );

  test('gap-pattern resume fetches only missing chunk prefixes', () async {
    var failing = true;
    final reads = <({int offset, int count})>[];
    final factory = _Factory(
      (generation) => _Source(bytes, (offset, count) async {
        reads.add((offset: offset, count: count));
        if (failing && (offset == 32 || offset == 544)) {
          throw StateError('offline');
        }
      }),
    );
    final first = cache(factory);
    await expectLater(first.cache(entry), throwsA(isA<OtaCacheException>()));
    final key = otaEntryDigest(entry);
    final meta = jsonDecode(
      await File('${temp.path}/ota-cache/$key.downloadx.json').readAsString(),
    ) as Map;
    final chunks = (meta['chunks'] as List).cast<Map>();
    expect(
      chunks.where((c) => c['downloadedBytes'] == c['length']).length,
      greaterThan(0),
    );
    final expected = <int>[];
    for (final chunk in chunks) {
      for (
        var at = (chunk['offset'] as int) + (chunk['downloadedBytes'] as int);
        at < (chunk['offset'] as int) + (chunk['length'] as int);
        at++
      ) {
        expected.add(at);
      }
    }
    failing = false;
    reads.clear();
    final events = await cache(factory).download(entry).toList();
    expect(
      (events.first as OtaCacheStarted).resumedFrom,
      bytes.length - expected.length,
    );
    final fetched = <int>[
      for (final read in reads)
        for (var at = read.offset; at < read.offset + read.count; at++) at,
    ]..sort();
    expect(fetched, expected..sort());
    expect(
      (events.last as OtaCacheFinished).entry.sha256,
      sha256.convert(bytes).toString(),
    );
  });

  test('concurrent failures share one link refresh', () async {
    final gate = Completer<void>();
    var failed = 0;
    final factory = _Factory(
      (generation) => _Source(bytes, (offset, count) async {
        if (generation == 1) {
          if (++failed == 4) gate.complete();
          await gate.future;
          throw StateError('expired');
        }
      }),
    );
    expect((await cache(factory).cache(entry)).complete, isTrue);
    expect(factory.opens, 2);
  });

  test('ETag change on a concurrent link refresh is refused', () async {
    final factory = _Factory(
      (generation) => _Source(bytes, (offset, count) async {
        if (generation == 1) throw StateError('expired');
      }),
      etag: (generation) => generation == 1 ? '"v1"' : '"v2"',
    );
    await expectLater(
      cache(factory).cache(entry),
      throwsA(isA<OtaCacheException>()),
    );
    expect(await cache(factory).lookup(entry), isNull);
    expect(factory.opens, 2);
  });

  test(
    'cancel aborts in-flight reads and leaves durable resumable chunks',
    () async {
      var block = true;
      final blocked = Completer<void>();
      final gate = Completer<void>();
      final factory = _Factory(
        (generation) => _Source(bytes, (offset, count) async {
          if (block && offset >= 64) {
            if (!blocked.isCompleted) blocked.complete();
            await gate.future;
          }
        }),
      );
      final downloaded = cache(factory);
      final subscription = downloaded.download(entry).listen((_) {});
      await blocked.future;
      // Allow the already-returned ranges to reach the serialized disk writes.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await subscription.cancel().timeout(const Duration(seconds: 2));
      final partial = (await downloaded.entries()).single;
      expect(partial.written, greaterThan(0));
      expect(partial.written, lessThan(bytes.length));
      block = false;
      gate.complete();
      final events = await downloaded.download(entry).toList();
      expect((events.first as OtaCacheStarted).resumedFrom, partial.written);
      expect(
        (events.last as OtaCacheFinished).entry.sha256,
        sha256.convert(bytes).toString(),
      );
    },
  );

  test('ordered stream emits in order under out-of-order completion', () async {
    final factory = _Factory(
      (_) => _Source(bytes, (offset, count) async {
        if (offset == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }),
    );
    final reader = await CatalogOtaReader.open(factory, entry);
    final chunks = await orderedOtaReads(
      reader,
      connections: 4,
      chunkBytes: 32,
    ).toList();
    expect(chunks.expand((c) => c).toList(), bytes);
  });

  test(
    'ordered window stays bounded and cancellation frees pending reads',
    () async {
      var reads = 0;
      final started = Completer<void>();
      final gate = Completer<void>();
      final sources = <_Source>[];
      final factory = _Factory((_) {
        final source = _Source(bytes, (offset, count) async {
          if (++reads == 4) started.complete();
          if (offset == 0) await gate.future;
        });
        sources.add(source);
        return source;
      });
      final reader = await CatalogOtaReader.open(factory, entry);
      final subscription = orderedOtaReads(
        reader,
        connections: 4,
        chunkBytes: 32,
      ).listen((_) {});
      await started.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(reads, 4, reason: 'no refill past a blocked first range');
      await subscription.cancel().timeout(const Duration(seconds: 2));
      expect(sources.every((s) => s.closed.isCompleted), isTrue);
      gate.complete();
    },
  );

  test(
    'without strong ETag reads are sequential and partial copies restart',
    () async {
      var active = 0;
      var peak = 0;
      var fail = true;
      final factory = _Factory(
        (_) => _Source(bytes, (offset, count) async {
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(Duration.zero);
          active--;
          if (fail && offset >= 64) throw StateError('offline');
        }),
        etag: (_) => null,
      );
      await expectLater(
        cache(factory).cache(entry),
        throwsA(isA<OtaCacheException>()),
      );
      fail = false;
      final events = await cache(factory).download(entry).toList();
      expect((events.first as OtaCacheStarted).resumedFrom, 0);
      expect(peak, 1);
    },
  );

  for (final truncatedLength in [0, 1]) {
    test('same picked destination truncated to $truncatedLength restarts safely', () async {
      final file = File('${temp.path}/picked-ota.zip');
      var failing = true;
      final reads = <int>[];
      final factory = _Factory((_) => _Source(bytes, (offset, count) async {
        reads.add(offset);
        if (failing && offset >= 64) throw StateError('offline');
      }));
      Future<OtaCache> pickedCache() async => OtaCache(
        workspace: await openOtaDestination(
          {'kind': 'path', 'path': file.path}, otaEntryDigest(entry)),
        sources: factory, chunkBytes: 32, connections: 1,
      );
      await expectLater((await pickedCache()).cache(entry), throwsA(isA<OtaCacheException>()));
      expect(await file.length(), 64);
      // The handle/path still identifies the same file, but bytes are gone.
      await file.writeAsBytes(bytes.sublist(0, truncatedLength));
      failing = false;
      reads.clear();
      final events = await (await pickedCache()).download(entry).toList();
      expect((events.first as OtaCacheStarted).resumedFrom, 0);
      expect(reads.first, 0);
      expect(await file.readAsBytes(), bytes);
      expect((events.last as OtaCacheFinished).entry.sha256, sha256.convert(bytes).toString());
    });
  }

  test('resume does not reserve already charged sparse file length again', () async {
    var failing = true;
    final factory = _Factory((_) => _Source(bytes, (offset, count) async {
      if (failing && offset == 0) throw StateError('offline');
    }));
    final downloaded = cache(factory);
    await expectLater(downloaded.cache(entry), throwsA(isA<OtaCacheException>()));
    final key = otaEntryDigest(entry);
    final part = File('${temp.path}/ota-cache/$key$tempExt');
    expect(await part.length(), bytes.length);
    final partial = (await downloaded.entries()).single;
    expect(partial.written, lessThan(bytes.length));
    expect(await downloaded.allocatedBytes(partial), bytes.length);
    final status = await FlasherService().storageBudget({
      'store': {'kind': 'path', 'path': temp.path},
    });
    final item = (status['items'] as List).single as Map;
    expect(item['bytes'], partial.written);
    expect(item['allocated'], bytes.length);
    failing = false;
    final budget = StorageBudget(
      estimateSource: _Estimate(bytes.length), cap: bytes.length,
    );
    final result = await downloaded.cache(entry, budget: budget);
    expect(result.sha256, sha256.convert(bytes).toString());
    expect(await downloaded.allocatedBytes(result), bytes.length);
    await File('${temp.path}/ota-cache/$key.zip').delete();
    expect(await downloaded.allocatedBytes(result), 0);
  });

  test('an error before started reaches the subscriber before stream done', () async {
    final downloaded = cache(_Factory((_) => _Source(bytes, (_, _) async {})));
    final events = <OtaCacheEvent>[];
    final errors = <Object>[];
    final done = Completer<void>();
    downloaded.download(entry, budget: StorageBudget(
      estimateSource: _Estimate(0), cap: 0,
    )).listen(events.add, onError: errors.add, onDone: done.complete);
    await done.future;
    expect(events, isEmpty);
    expect(errors, [isA<BudgetException>()]);
  });

  test('concurrent same-key download refuses with an error, not an empty stream', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final downloaded = cache(_Factory((_) => _Source(bytes, (_, _) async {
      if (!started.isCompleted) started.complete();
      await gate.future;
    })));
    final running = downloaded.cache(entry);
    await started.future;
    await expectLater(downloaded.download(entry).toList(), throwsStateError);
    gate.complete();
    expect((await running).complete, isTrue);
  });
}

class _Factory implements OtaSourceFactory {
  _Factory(this.make, {String? Function(int)? etag})
    : tag = etag ?? ((_) => '"v1"');
  final _Source Function(int) make;
  final String? Function(int) tag;
  int opens = 0;
  @override
  Future<OtaRemoteSource> open(Map<String, dynamic> entry) async {
    opens++;
    return OtaRemoteSource(source: make(opens), etag: tag(opens));
  }
}

class _Source implements CancellableByteSource {
  _Source(this.bytes, this.before);
  final Uint8List bytes;
  final Future<void> Function(int, int) before;
  final closed = Completer<void>();
  @override
  int get length => bytes.length;
  @override
  Future<Uint8List> read(int offset, int length) =>
      readCancellable(offset, length, null);
  @override
  Future<Uint8List> readCancellable(
    int offset,
    int length,
    Future<void>? cancelled,
  ) async {
    await Future.any([
      before(offset, length),
      closed.future.then((_) => throw StateError('closed')),
      if (cancelled != null)
        cancelled.then((_) => throw StateError('cancelled')),
    ]);
    return Uint8List.sublistView(bytes, offset, offset + length);
  }

  Future<void> close() async {
    if (!closed.isCompleted) closed.complete();
  }
}

class _Estimate implements StorageEstimateSource {
  _Estimate(this.usage);
  final int usage;
  @override
  Future<StorageEstimate> estimate() async => StorageEstimate(usage: usage, quota: 1024);
}
