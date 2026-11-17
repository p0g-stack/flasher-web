import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late IoWorkspace workspace;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('bloat_test_');
    workspace = IoWorkspace(temp);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  test('materialize verifies multipart and gzip images', () async {
    final fixture = _Fixture();
    final store = BloatStore(workspace: workspace, manifest: fixture.manifest);

    final before = await store.inspect(_Fixture.selection);
    expect(before.total, 3);
    expect(before.downloaded, 0);
    expect(before.ready, isFalse);
    expect(before.bytes, fixture.rawBytes);

    final events = await store
        .materialize(_Fixture.selection, fixture.fetch)
        .toList();
    final finished = events.whereType<BloatFinished>().single;
    expect(finished.paths, [
      '13/EU_BLOAT/gzip.img',
      '13/EU_BLOAT/multi.img',
      '13/EU_BLOAT/single.img',
    ]);
    expect(events.whereType<BloatStep>().last.completed, 3);

    expect(await _readAll(workspace, '13/EU_BLOAT/single.img'), fixture.single);
    expect(await _readAll(workspace, '13/EU_BLOAT/multi.img'), fixture.multi);
    expect(await _readAll(workspace, '13/EU_BLOAT/gzip.img'), fixture.zipped);

    final after = await store.inspect(_Fixture.selection);
    expect(after.downloaded, 3);
    expect(after.bytes, fixture.rawBytes);
    expect(after.ready, isTrue);

    final leftovers = [
      for (final path in await workspace.list('13', recursive: true))
        if (!path.endsWith('.img')) path,
    ];
    expect(leftovers, isEmpty);
  });

  test(
    'materialize replaces a corrupt image and keeps verified ones',
    () async {
      final fixture = _Fixture();
      final store = BloatStore(
        workspace: workspace,
        manifest: fixture.manifest,
      );
      final sink = await workspace.create('13/EU_BLOAT/single.img');
      await sink.write(Uint8List(fixture.single.length), 0);
      await sink.close();

      final status = await store.inspect(_Fixture.selection);
      expect(status.downloaded, 0);
      expect(status.ready, isFalse);

      await store.materialize(_Fixture.selection, fixture.fetch).drain<void>();
      expect(
        await _readAll(workspace, '13/EU_BLOAT/single.img'),
        fixture.single,
      );
      expect(fixture.fetched, contains('bloat-single.img'));
    },
  );

  test('a bad part checksum fails and leaves no destination', () async {
    final fixture = _Fixture();
    final store = BloatStore(workspace: workspace, manifest: fixture.manifest);
    final events = store.materialize(
      _Fixture.selection,
      (name) => _BytesSource(Uint8List.fromList(List<int>.filled(16, 7))),
    );
    await expectLater(
      events,
      emitsInOrder([
        isA<BloatStarted>(),
        isA<BloatStep>(),
        emitsError(isA<BloatError>()),
      ]),
    );
    expect(await workspace.exists('13/EU_BLOAT/single.img'), isFalse);
    expect(await workspace.exists('13/EU_BLOAT/multi.img'), isFalse);
    expect(await workspace.exists('13/EU_BLOAT/gzip.img'), isFalse);
  });

  test('staging moves instead of copying', () async {
    final fixture = _Fixture();
    final recording = _RecordingWorkspace(workspace);
    final store = BloatStore(workspace: recording, manifest: fixture.manifest);
    await store.materialize(_Fixture.selection, fixture.fetch).drain<void>();

    final creates = recording.calls
        .where((call) => call.startsWith('create:'))
        .toList();
    final updates = recording.calls
        .where((call) => call.startsWith('update:'))
        .where((call) => call.contains('.img'))
        .toList();
    final moves = recording.calls
        .where((call) => call.startsWith('move:'))
        .toList();
    // Nothing is staged through a second streaming copy: the transport file is
    // renamed into place, so HandleWorkspace's native move keeps the peak at
    // one copy of the image.
    expect(updates, isEmpty);

    final singleCreates = creates
        .where((call) => call.contains('single.img'))
        .toList();
    expect(singleCreates, hasLength(1));
    expect(singleCreates.single, contains('.part-'));
    final singleMoves = moves
        .where((call) => call.contains('single.img'))
        .toList();
    expect(singleMoves, hasLength(1));
    expect(singleMoves.single, endsWith('->13/EU_BLOAT/single.img'));

    final multiCreates = creates
        .where((call) => call.contains('multi.img'))
        .toList();
    expect(multiCreates, hasLength(1), reason: 'one transport file, one write');
    expect(multiCreates.single, contains('.transport-'));
    expect(
      moves.where((call) => call.contains('multi.img')),
      hasLength(2),
      reason: 'transport -> part -> destination are renames',
    );

    final gzipCreates = creates
        .where((call) => call.contains('gzip.img'))
        .toList();
    expect(
      gzipCreates,
      hasLength(2),
      reason: 'a gzip asset keeps its transport file while the image decodes',
    );
    expect(
      gzipCreates.where((call) => call.contains('.transport-')),
      hasLength(1),
    );
    expect(moves.where((call) => call.contains('gzip.img')), hasLength(1));
  });

  test('a budget refusal happens before any asset is fetched', () async {
    final fixture = _Fixture();
    final store = BloatStore(
      workspace: workspace,
      manifest: fixture.manifest,
      budget: StorageBudget(
        estimateSource: _FixedEstimate(usage: 0, quota: 0),
        cap: 1,
      ),
    );
    await expectLater(
      store.materialize(_Fixture.selection, fixture.fetch),
      emitsInOrder([
        isA<BloatStarted>(),
        isA<BloatStep>(),
        emitsError(isA<BudgetException>()),
      ]),
    );
    expect(fixture.fetched, isEmpty);
    expect(await workspace.exists('13/EU_BLOAT/single.img'), isFalse);
  });
}

final class _Fixture {
  _Fixture() {
    single = Uint8List.fromList(utf8.encode('single image payload'));
    multi = Uint8List.fromList(utf8.encode('multipart image payload'));
    zipped = Uint8List.fromList(List<int>.generate(70000, (i) => i % 251));

    final singleSha = _sha(single);
    final multiPart1 = Uint8List.sublistView(multi, 0, 9);
    final multiPart2 = Uint8List.sublistView(multi, 9);
    final multiSha = _sha(multi);
    final zippedRawSha = _sha(zipped);
    final gzipTransport = Uint8List.fromList(GZipCodec().encode(zipped));
    final gzipSha = _sha(gzipTransport);
    final second = Uint8List.sublistView(zipped, 0, 20000);
    final rest = Uint8List.sublistView(zipped, 20000);
    final firstGzip = Uint8List.fromList(GZipCodec().encode(second));
    final secondGzip = Uint8List.fromList(
      GZipCodec().encode(Uint8List.fromList(rest)),
    );

    final manifest = <String, dynamic>{
      'schema_version': 1,
      'repository': 'koaaN/Flasher_Builder',
      'tag': 'bloat-assets-v1',
      'assets': {
        singleSha: {
          'asset_id': 1,
          'asset_name': 'bloat-single.img',
          'bytes': single.length,
          'sha256': singleSha,
          'raw_bytes': single.length,
          'raw_sha256': singleSha,
          'encoding': 'identity',
        },
        multiSha: {
          'asset_id': 2,
          'asset_name': 'bloat-multi.img',
          'bytes': multi.length,
          'sha256': multiSha,
          'raw_bytes': multi.length,
          'raw_sha256': multiSha,
          'encoding': 'identity',
          'parts': [
            {
              'asset_id': 21,
              'asset_name': 'bloat-multi.img.001',
              'bytes': multiPart1.length,
              'sha256': _sha(multiPart1),
            },
            {
              'asset_id': 22,
              'asset_name': 'bloat-multi.img.002',
              'bytes': multiPart2.length,
              'sha256': _sha(multiPart2),
            },
          ],
        },
        zippedRawSha: {
          'asset_id': 3,
          'asset_name': 'bloat-zipped.img.gz',
          'bytes': gzipTransport.length,
          'sha256': gzipSha,
          'raw_bytes': zipped.length,
          'raw_sha256': zippedRawSha,
          'encoding': 'gzip',
        },
      },
      'files': {
        'bloat/13/EU_BLOAT/single.img': singleSha,
        'bloat/13/EU_BLOAT/multi.img': multiSha,
        'bloat/13/EU_BLOAT/gzip.img': zippedRawSha,
      },
    };

    final concatenatedGzip = Uint8List(
      gzipTransport.length + firstGzip.length + secondGzip.length,
    );
    concatenatedGzip.setAll(0, gzipTransport);
    concatenatedGzip.setAll(gzipTransport.length, firstGzip);
    concatenatedGzip.setAll(
      gzipTransport.length + firstGzip.length,
      secondGzip,
    );

    this.manifest = BloatManifest.fromJson(manifest);
    sources = {
      'bloat-single.img': single,
      'bloat-multi.img.001': multiPart1,
      'bloat-multi.img.002': multiPart2,
      'bloat-zipped.img.gz': gzipTransport,
      'bloat-concat.gz': concatenatedGzip,
    };
    rawBytes = single.length + multi.length + zipped.length;
  }

  late final Uint8List single;
  late final Uint8List multi;
  late final Uint8List zipped;
  late final int rawBytes;
  late final Map<String, Uint8List> sources;
  late final BloatManifest manifest;

  final Set<String> fetched = {};

  ByteSource fetch(String name) {
    fetched.add(name);
    final bytes = sources[name];
    if (bytes == null) throw StateError('missing fake asset $name');
    return _BytesSource(bytes);
  }

  static final Selection selection = const Selection(
    dev: '13',
    kind: 'Super Flasher',
    region: 'EU',
  );
}

final class _BytesSource implements ByteSource {
  _BytesSource(this._bytes);

  final Uint8List _bytes;

  @override
  int get length => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    checkReadRange(offset, length, _bytes.length);
    return Uint8List.fromList(
      Uint8List.sublistView(_bytes, offset, offset + length),
    );
  }
}

Future<Uint8List> _readAll(Workspace workspace, String path) async {
  final source = await workspace.open(path);
  return source.read(0, source.length);
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// Records the workspace calls a staging run makes, so a test can prove that
/// an image is written once and renamed, not streamed twice.
final class _RecordingWorkspace implements Workspace {
  _RecordingWorkspace(this._inner);

  final Workspace _inner;
  final List<String> calls = [];

  @override
  Future<ByteSink> create(String path) {
    calls.add('create:$path');
    return _inner.create(path);
  }

  @override
  Future<ByteSink> update(String path) {
    calls.add('update:$path');
    return _inner.update(path);
  }

  @override
  Future<ByteSource> open(String path) {
    calls.add('open:$path');
    return _inner.open(path);
  }

  @override
  Future<bool> exists(String path) => _inner.exists(path);

  @override
  Future<int> size(String path) => _inner.size(path);

  @override
  Future<List<String>> list(String dir, {bool recursive = false}) =>
      _inner.list(dir, recursive: recursive);

  @override
  Future<void> move(String from, String to) {
    calls.add('move:$from->$to');
    return _inner.move(from, to);
  }

  @override
  Future<void> delete(String path) {
    calls.add('delete:$path');
    return _inner.delete(path);
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
