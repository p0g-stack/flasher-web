import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flasher_web_core/src/storage/budget.dart';
import 'package:flasher_web_core/src/storage/ota_cache.dart';
import 'package:flasher_web_core/src/storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late IoWorkspace workspace;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('flasher_ota_cache_');
    workspace = IoWorkspace(temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('the entry digest is stable and entry-scoped', () {
    final entry = _entry();
    expect(
      otaEntryDigest(Map<String, dynamic>.fromEntries(
        entry.entries.toList().reversed,
      )),
      otaEntryDigest(entry),
      reason: 'member order must not matter',
    );
    expect(
      otaEntryDigest({...entry, 'source_url': 'https://example.com/ota.zip?sig=other'}),
      otaEntryDigest(entry),
      reason: 'signed URLs and ranking hints are not identity',
    );
    expect(
      otaEntryDigest({...entry, 'is_latest': false}),
      otaEntryDigest(entry),
    );
    expect(
      otaEntryDigest({...entry, 'version': 'other'}),
      isNot(otaEntryDigest(entry)),
    );
    expect(otaEntryDigest(entry), matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(otaEntryLabel(entry), 'OP 15 / NA / CPH2653_15.0.0.1');
  });

  test('a fresh download records identity and serves exact bytes', () async {
    final bytes = _bytes(256);
    final remote = _RemoteOta(bytes, etag: '"v1"');
    final cache = _cache(workspace, remote);
    final events = await cache.download(_entry(size: bytes.length)).toList();

    final started = events.first;
    expect(started, isA<OtaCacheStarted>());
    expect((started as OtaCacheStarted).resumedFrom, 0);
    expect(started.total, 256);
    expect(events.whereType<OtaCacheProgress>(), isNotEmpty);

    final finished = events.last as OtaCacheFinished;
    final entry = finished.entry;
    expect(entry.complete, isTrue);
    expect(entry.bytes, 256);
    expect(entry.written, 256);
    expect(entry.etag, '"v1"');
    expect(entry.sha256, sha256.convert(bytes).toString());
    expect(entry.completedAt, isNotNull);
    expect(
      await _readAll(workspace, 'ota-cache/${entry.key}.zip'),
      bytes,
    );
  });

  test('an interrupted download resumes at its recorded offset', () async {
    final bytes = _bytes(256);
    final remote = _RemoteOta(bytes, failAtAll: 128);
    final cache = _cache(workspace, remote);
    final entryMap = _entry(size: bytes.length);

    await expectLater(
      cache.download(entryMap).forEach((_) {}),
      throwsA(isA<RangeException>()),
    );
    final partial = await cache.entries();
    expect(partial, hasLength(1));
    expect(partial.single.complete, isFalse);
    expect(partial.single.written, 128);
    expect(partial.single.length, 256);

    remote.failAtAll = null;
    final events = await cache.download(entryMap).toList();
    expect((events.first as OtaCacheStarted).resumedFrom, 128);
    final finished = events.last as OtaCacheFinished;
    expect(finished.entry.complete, isTrue);
    expect(
      finished.entry.sha256,
      sha256.convert(bytes).toString(),
      reason: 'the prefix on disk is hashed again, so the digest covers '
          'the whole file, not only the resumed tail',
    );
    expect(await _readAll(workspace, 'ota-cache/${finished.entry.key}.zip'),
        bytes);
  });

  test('a resumed download refuses a changed remote length', () async {
    final bytes = _bytes(256);
    final remote = _RemoteOta(bytes, failAtAll: 128);
    final cache = _cache(workspace, remote);
    final entryMap = _entry();

    await expectLater(
      cache.download(entryMap).forEach((_) {}),
      throwsA(isA<RangeException>()),
    );

    final grown = _cache(workspace, _RemoteOta(_bytes(300)));
    await expectLater(
      grown.download(entryMap).forEach((_) {}),
      throwsA(
        isA<OtaCacheException>().having(
          (error) => error.message,
          'message',
          contains('256 bytes'),
        ),
      ),
    );
    expect((await cache.entries()).single.written, 128);
  });

  test('a resumed download refuses a changed ETag', () async {
    final bytes = _bytes(256);
    final remote = _RemoteOta(bytes, etag: '"v1"', failAtAll: 128);
    final cache = _cache(workspace, remote);
    final entryMap = _entry();

    await expectLater(
      cache.download(entryMap).forEach((_) {}),
      throwsA(isA<RangeException>()),
    );

    final changed = _cache(workspace, _RemoteOta(bytes, etag: '"v2"'));
    await expectLater(
      changed.download(entryMap).forEach((_) {}),
      throwsA(
        isA<OtaCacheException>().having(
          (error) => error.message,
          'message',
          contains('ETag'),
        ),
      ),
    );
  });

  test('a complete entry is served without opening the network', () async {
    var now = DateTime.utc(2026, 1, 1, 12);
    final bytes = _bytes(192);
    final remote = _RemoteOta(bytes, etag: '"v1"');
    final cache = _cache(workspace, remote, clock: () => now);
    final entryMap = _entry(size: bytes.length);
    final first = await cache.cache(entryMap);

    now = now.add(const Duration(minutes: 5));
    final opened = await cache.openCachedCatalogOta(entryMap);
    expect(opened, isNotNull);
    try {
      expect(await opened!.read(0, opened.length), bytes);
    } finally {
      await closeByteSource(opened!);
    }
    final touched = await cache.lookup(entryMap);
    expect(touched!.lastUsedAt, now);
    expect(touched.lastUsedAt.isAfter(first.lastUsedAt), isTrue);

    final opensBefore = remote.opens;
    final again = await cache.cache(entryMap);
    expect(again.sha256, first.sha256);
    expect(remote.opens, opensBefore, reason: 'a hit never resolves a link');
  });

  test('a missing cache reports a miss', () async {
    final cache = _cache(workspace, _RemoteOta(_bytes(64)));
    expect(await cache.openCachedCatalogOta(_entry()), isNull);
    expect(await cache.lookup(_entry()), isNull);
    expect(await cache.entries(), isEmpty);
  });

  test('eviction removes least recently used entries first', () async {
    var now = DateTime.utc(2026, 1, 1, 12);
    final bytes = _bytes(128);
    final cache = _cache(workspace, _RemoteOta(bytes), clock: () => now);
    final v1 = await cache.cache(_entry(version: 'v1'));
    now = now.add(const Duration(minutes: 1));
    final v2 = await cache.cache(_entry(version: 'v2'));
    now = now.add(const Duration(minutes: 1));
    final v3 = await cache.cache(_entry(version: 'v3'));

    expect(
      (await cache.entries()).map((entry) => entry.key),
      [v1.key, v2.key, v3.key],
      reason: 'least recently used first',
    );
    expect(await cache.evict(bytesNeeded: 128), 128);
    expect(await cache.lookup(_entry(version: 'v1')), isNull);
    expect(await cache.lookup(_entry(version: 'v2')), isNotNull);
    expect(await cache.evict(bytesNeeded: 1000), 256);
    expect(await cache.entries(), isEmpty);
    expect(await cache.evict(bytesNeeded: 1), 0);
  });

  test('an in-progress download is never evicted', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final bytes = _bytes(256);
    final remote = _RemoteOta(
      bytes,
      gate: gate,
      onRead: () {
        if (!started.isCompleted) started.complete();
      },
    );
    final cache = _cache(workspace, remote);
    final running = cache.download(_entry(size: bytes.length)).toList();
    await started.future;

    expect(await cache.evict(bytesNeeded: 1 << 30), 0);
    gate.complete();
    final events = await running;
    expect((events.last as OtaCacheFinished).entry.complete, isTrue);
    expect(await cache.evict(bytesNeeded: 1 << 30), bytes.length);
  });

  test('the budget is checked before the first byte is written', () async {
    final bytes = _bytes(256);
    final budget = StorageBudget(
      estimateSource: _FixedEstimate(usage: 0, quota: 0),
      cap: 100,
    );
    final cache = _cache(workspace, _RemoteOta(bytes));
    final entryMap = _entry(size: bytes.length);
    await expectLater(
      cache.download(entryMap, budget: budget).forEach((_) {}),
      throwsA(isA<BudgetException>()),
    );
    expect(await cache.lookup(entryMap), isNull);
    final key = otaEntryDigest(entryMap);
    expect(await workspace.exists('ota-cache/$key.zip'), isFalse);
  });

  test('a corrupt sidecar is ignored and the download starts over', () async {
    final bytes = _bytes(64);
    final cache = _cache(workspace, _RemoteOta(bytes));
    final entryMap = _entry(size: bytes.length);
    final key = otaEntryDigest(entryMap);
    final sink = await workspace.create('ota-cache/$key.json');
    await sink.write(Uint8List.fromList([0x7b, 0x7b, 0x7b]), 0);
    await sink.close();

    expect(await cache.lookup(entryMap), isNull);
    final entry = await cache.cache(entryMap);
    expect(entry.complete, isTrue);
  });
}

OtaCache _cache(
  IoWorkspace workspace,
  OtaSourceFactory sources, {
  DateTime Function()? clock,
}) => OtaCache(
  workspace: workspace,
  sources: sources,
  chunkBytes: 64,
  clock: clock,
);

Map<String, dynamic> _entry({String version = 'CPH2653_15.0.0.1', int size = 0}) => {
  'id': 'op15-na-$version',
  'device': 'OP 15',
  'region': 'NA',
  'version': version,
  'size': size,
  'sha256': 'a' * 64,
  'security_patch': '2026-01-01',
  'source_url': 'https://example.com/ota.zip?sig=abc',
  'is_latest': true,
};

Uint8List _bytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 7 + 3) % 256));

Future<Uint8List> _readAll(Workspace workspace, String path) async {
  final source = await workspace.open(path);
  try {
    return await source.read(0, source.length);
  } finally {
    await closeByteSource(source);
  }
}

final class _RemoteOta implements OtaSourceFactory {
  _RemoteOta(
    this.bytes, {
    this.etag,
    this.failAtAll,
    this.gate,
    this.onRead,
  });

  Uint8List bytes;
  String? etag;
  int? failAtAll;
  final Completer<void>? gate;
  final void Function()? onRead;
  int opens = 0;

  @override
  Future<OtaRemoteSource> open(Map<String, dynamic> entry) async {
    opens++;
    return OtaRemoteSource(
      source: _RemoteSource(
        bytes,
        failAt: failAtAll,
        gate: gate,
        onRead: onRead,
      ),
      etag: etag,
    );
  }
}

final class _RemoteSource implements ByteSource {
  _RemoteSource(this._bytes, {this.failAt, this.gate, this.onRead});

  final Uint8List _bytes;
  final int? failAt;
  final Completer<void>? gate;
  final void Function()? onRead;

  @override
  int get length => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    onRead?.call();
    final waiting = gate;
    if (waiting != null) await waiting.future;
    checkReadRange(offset, length, _bytes.length);
    final limit = failAt;
    if (limit != null && offset >= limit) {
      throw RangeException('the signed link expired at $offset');
    }
    return Uint8List.sublistView(_bytes, offset, offset + length);
  }
}

final class _FixedEstimate implements StorageEstimateSource {
  _FixedEstimate({required this.usage, required this.quota});

  final int usage;
  final int quota;

  @override
  Future<StorageEstimate?> estimate() async =>
      StorageEstimate(usage: usage, quota: quota);
}
