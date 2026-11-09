import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

void main() {
  group('flash preparation', () {
    test('parses decimal and hexadecimal download sizes', () {
      expect(parseDownloadSize('0x4000'), 16384);
      expect(parseDownloadSize('max-download-size: 0x10000000'), 268435456);
      expect(parseDownloadSize('67108864'), 67108864);
      expect(parseDownloadSize('0x100000000'), 0xffffffff);
      expect(() => parseDownloadSize('0'), throwsA(isA<FlashException>()));
      expect(
        () => parseDownloadSize('nonsense'),
        throwsA(isA<FlashException>()),
      );
    });

    test('a cable swap is refused before the plan is prepared', () async {
      final package = _package();
      final transport = _Transport(_State(serial: 'OTHER'), 'OTHER');
      await expectLater(
        prepareFlash(
          package: package,
          selection: _selection,
          answers: _answers,
          serial: 'SERIAL-A',
          transport: transport,
          job: 'job',
        ),
        throwsA(
          isA<FlashException>().having(
            (error) => error.message,
            'message',
            contains('not connected or not granted'),
          ),
        ),
      );
      expect(transport.opened, isEmpty);
    });

    test('a product mismatch is refused', () async {
      final package = _package();
      final transport = _Transport(_State(product: 'moon'), 'SERIAL-A');
      await expectLater(
        prepareFlash(
          package: package,
          selection: _selection,
          answers: _answers,
          serial: 'SERIAL-A',
          transport: transport,
          job: 'job',
        ),
        throwsA(
          isA<FlashException>().having(
            (error) => error.message,
            'message',
            contains('reports product'),
          ),
        ),
      );
    });

    test('Super Fastboot is distinguished from the bootloader', () async {
      final package = _package();
      final state = _State()..superFastboot = true;
      final transport = _Transport(state, 'SERIAL-A');
      final prepared = await prepareFlash(
        package: package,
        selection: _selection,
        answers: _answers,
        serial: 'SERIAL-A',
        transport: transport,
        job: 'job',
      );
      expect(prepared.mode, FlashMode.superFastboot);
      expect(prepared.modeOk, isFalse);
    });

    test('an unresolved plan returns no usable ticket', () async {
      final package = _package();
      final transport = _Transport(_State(), 'SERIAL-A');
      final prepared = await prepareFlash(
        package: package,
        selection: _selection,
        answers: const {'product': 'sun'},
        serial: 'SERIAL-A',
        transport: transport,
        job: 'job',
      );
      expect(prepared.resolved, isFalse);
      expect(prepared.images, isEmpty);
    });

    test('a changed answer or package no longer matches the ticket', () async {
      final package = _package();
      final transport = _Transport(_State(), 'SERIAL-A');
      final prepared = await prepareFlash(
        package: package,
        selection: _selection,
        answers: _answers,
        serial: 'SERIAL-A',
        transport: transport,
        job: 'job',
        storeKey: 'path|/tmp/output',
      );
      final request = _request();
      expect(
        prepared.binding.matches(request, storeKey: 'path|/tmp/output'),
        isTrue,
      );
      expect(
        prepared.binding.matches({
          ...request,
          'answers': {'product': 'sun', 'root': 'flash-signal'},
        }, storeKey: 'path|/tmp/output'),
        isFalse,
      );
      expect(
        prepared.binding.matches({
          ...request,
          'serial': 'SERIAL-B',
        }, storeKey: 'path|/tmp/output'),
        isFalse,
      );
      expect(
        prepared.binding.matches(request, storeKey: 'path|/tmp/other'),
        isFalse,
      );
      final before = await packageDigest(package);
      package.files['OOS_FILES_HERE/boot.img'] = Uint8List.fromList([
        9,
        9,
        9,
        9,
      ]);
      expect(await packageDigest(package), isNot(before));
      await expectLater(
        verifyPreparedImages(prepared),
        throwsA(isA<FlashException>()),
      );
    });

    test('a truncated sparse image is refused before writes', () async {
      final package = _package();
      final sparse = _sparseImage(
        totalBlocks: 2,
        chunks: [_chunk(sparseRaw, 2, Uint8List(8192))],
      );
      package.files['OOS_FILES_HERE/boot.img'] = sparse.sublist(0, 30);
      final transport = _Transport(_State(), 'SERIAL-A');
      await expectLater(
        prepareFlash(
          package: package,
          selection: _selection,
          answers: _answers,
          serial: 'SERIAL-A',
          transport: transport,
          job: 'job',
        ),
        throwsA(isA<FlashException>()),
      );
    });
  });

  test(
    'final-image digests reject modified packaged bytes before any write',
    () async {
      final package = _package();
      package.imageSha256 = {
        for (final entry in package.files.entries)
          entry.key: sha256.convert(entry.value).toString(),
      };
      package.files['OOS_FILES_HERE/boot.img'] = Uint8List.fromList([4, 5, 6]);
      final state = _State();
      await expectLater(
        prepareFlash(
          package: package,
          selection: _selection,
          answers: _answers,
          serial: 'SERIAL-A',
          transport: _Transport(state, 'SERIAL-A'),
          job: 'job',
        ),
        throwsA(
          isA<FlashException>().having(
            (e) => e.message,
            'message',
            contains('final-image SHA-256'),
          ),
        ),
      );
      expect(state.flashCommands, isEmpty);
    },
  );

  test('a too-small physical partition is refused before writes', () async {
    final state = _State()..partitionBytes = 2;
    await expectLater(
      prepareFlash(
        package: _package(),
        selection: _selection,
        answers: _answers,
        serial: 'SERIAL-A',
        transport: _Transport(state, 'SERIAL-A'),
        job: 'job',
      ),
      throwsA(
        isA<FlashException>().having(
          (e) => e.message,
          'message',
          contains('expanded image'),
        ),
      ),
    );
    expect(state.flashCommands, isEmpty);
  });

  test('host probe failures are not treated as an unsupported mode', () async {
    final state = _State()..probeFailure = true;
    await expectLater(
      prepareFlash(
        package: _package(),
        selection: _selection,
        answers: _answers,
        serial: 'SERIAL-A',
        transport: _Transport(state, 'SERIAL-A'),
        job: 'job',
      ),
      throwsA(
        isA<LinkFailure>().having((e) => e.name, 'name', 'SecurityError'),
      ),
    );
    expect(state.flashCommands, isEmpty);
  });

  group('flash execution safety', () {
    test('a swapped cable at execution time sends no write', () async {
      final package = _package();
      final transport = _Transport(_State(), 'SERIAL-A');
      final prepared = await prepareFlash(
        package: package,
        selection: _selection,
        answers: _answers,
        serial: 'SERIAL-A',
        transport: transport,
        job: 'job',
      );
      final otherState = _State(serial: 'SERIAL-B');
      final other = _Transport(otherState, 'SERIAL-B');
      final receipt = await executePreparedFlash(prepared, other, emit: (_) {});
      expect(receipt['status'], 'failed');
      expect(otherState.flashCommands, isEmpty);
      expect(otherState.commands, isEmpty);
    });

    test('an uncertain write is reported and never resent automatically', () async {
      final package = _package();
      final state = _State();
      final transport = _Transport(state, 'SERIAL-A');
      final prepared = await prepareFlash(
        package: package,
        selection: _selection,
        answers: _answers,
        serial: 'SERIAL-A',
        transport: transport,
        job: 'job',
      );
      state.loseFlashReply = true;
      final receipt = await executePreparedFlash(
        prepared,
        transport,
        emit: (_) {},
      );
      expect(receipt['status'], 'uncertain');
      expect(receipt['uncertain'], isTrue);
      expect(receipt['stepIndex'], isNotNull);
      expect(state.flashCommands, ['boot_a']);
      final writes = receipt['writes'] as List;
      expect(writes, hasLength(1));
      expect(writes.single['status'], 'uncertain');
      expect(
        (receipt['package'] as Map)['image_sha256'],
        isNot(contains('super.img')),
        reason: 'the run stopped before the super stream',
      );

      // An explicit retry rewrites the failed step from byte zero.
      state.loseFlashReply = false;
      final retried = await executePreparedFlash(
        prepared,
        transport,
        emit: (_) {},
        previousReceipt: receipt,
      );
      expect(retried['status'], 'succeeded', reason: '${retried['failure']}');
      expect(
        state.parts['boot_a']!.first,
        package.files['OOS_FILES_HERE/boot.img'],
        reason: 'the first attempt wrote the whole image',
      );
      expect(
        state.parts['boot_a']!.last,
        package.files['OOS_FILES_HERE/boot.img'],
        reason: 'the retry rewrote it from byte zero',
      );
      expect(
        state.flashCommands.where((name) => name == 'boot_a'),
        hasLength(2),
      );
      final retriedWrites = (retried['writes'] as List).cast<Map>();
      expect(retriedWrites.first['status'], 'uncertain');
      expect(retriedWrites.first['partition'], 'boot_a');
      expect(retriedWrites[1]['status'], 'ok');
      expect(retriedWrites[1]['partition'], 'boot_a',
          reason: 'the retried step rewrote boot_a');
      expect(retried['stepIndex'], isNull);
      expect(retried['job'], 'job');
      expect(retried['serial'], 'SERIAL-A');
      expect(
        (retried['steps'] as List).cast<Map>().every(
              (step) => step['status'] == 'ok',
            ),
        isTrue,
        reason: 'every step of the finished run is recorded as ok',
      );
    });

    test('a retry continues from the failed step without replaying earlier steps', () async {
      final package = _package();
      final state = _State(failFlash: 'boot_b');
      final transport = _Transport(state, 'SERIAL-A');
      final prepared = await prepareFlash(
        package: package,
        selection: _selection,
        answers: _answers,
        serial: 'SERIAL-A',
        transport: transport,
        job: 'job',
      );
      final receipt = await executePreparedFlash(
        prepared,
        transport,
        emit: (_) {},
      );
      expect(receipt['status'], 'failed');
      final failedStep = receipt['stepIndex'] as int;
      expect(state.flashCommands, ['boot_a', 'boot_b']);

      state.failFlash = null;
      final retried = await executePreparedFlash(
        prepared,
        transport,
        emit: (_) {},
        previousReceipt: receipt,
      );
      expect(retried['status'], 'succeeded', reason: '${retried['failure']}');
      expect(
        state.flashCommands.take(3).toList(),
        ['boot_a', 'boot_b', 'boot_b'],
        reason: 'only the failed step is resent',
      );
      final steps = (retried['steps'] as List).cast<Map>();
      expect(steps, hasLength(prepared.plan.executionSteps.length));
      expect(
        steps.firstWhere((step) => step['index'] == failedStep + 1)['status'],
        'ok',
        reason: 'the retried step is recorded once, from its successful run',
      );
      expect(
        steps.where((step) => step['index'] == failedStep + 1),
        hasLength(1),
        reason: 'the retry does not duplicate the step',
      );
    });

    test(
      'a reboot retry reboots to the failed step mode and rechecks identity',
      () async {
        final state = _State()..loseRebootReply = 'reboot-fastboot';
        final transport = _Transport(state, 'SERIAL-A');
        final prepared = await prepareFlash(
          package: _package(),
          selection: _selection,
          answers: _answers,
          serial: 'SERIAL-A',
          transport: transport,
          job: 'job',
        );
        final receipt = await executePreparedFlash(
          prepared,
          transport,
          emit: (_) {},
        );
        expect(receipt['status'], 'uncertain');
        final failedStep = receipt['stepIndex'] as int;
        final flashesSoFar = state.flashCommands.length;
        final boots = state.flashCommands.where((name) => name == 'boot_a').length;

        // The user plugs the phone back in: the retry reboots to the mode the
        // failed step needs, then continues from that step.
        state.loseRebootReply = null;
        state.fastbootd = false;
        final retried = await executePreparedFlash(
          prepared,
          transport,
          emit: (_) {},
          previousReceipt: receipt,
          rebootRetry: true,
        );
        expect(retried['status'], 'succeeded', reason: '${retried['failure']}');
        expect(
          state.commands.where((command) => command == 'reboot-bootloader'),
          hasLength(1),
          reason: 'the device is put in the mode the failed step requires',
        );
        expect(
          state.commands.where((command) => command == 'reboot-fastboot'),
          hasLength(2),
          reason: 'the failed reboot step itself is sent again',
        );
        expect(retried['steps'], isNot(isEmpty));
        expect(
          state.flashCommands.length,
          flashesSoFar,
          reason: 'no earlier flash is replayed',
        );
        expect(
          state.flashCommands.where((name) => name == 'boot_a'),
          hasLength(boots),
        );
        expect(state.commands, contains('set_active:a'));
        expect(state.android, isTrue);
        expect(failedStep, lessThan(prepared.plan.executionSteps.length));
      },
    );

    test('a retry refuses a changed serial, product or mode', () async {
      final package = _package();
      final state = _State(failFlash: 'boot_b');
      final transport = _Transport(state, 'SERIAL-A');
      final prepared = await prepareFlash(
        package: package,
        selection: _selection,
        answers: _answers,
        serial: 'SERIAL-A',
        transport: transport,
        job: 'job',
      );
      final receipt = await executePreparedFlash(
        prepared,
        transport,
        emit: (_) {},
      );
      expect(receipt['status'], 'failed');

      // Another cable: only the confirmed serial is opened.
      final otherState = _State(serial: 'SERIAL-B');
      final other = _Transport(otherState, 'SERIAL-B');
      final wrongSerial = await executePreparedFlash(
        prepared,
        other,
        emit: (_) {},
        previousReceipt: receipt,
      );
      expect(wrongSerial['status'], 'failed');
      expect(otherState.flashCommands, isEmpty);
      expect(otherState.commands, isEmpty);

      // A product change while the device opened is refused before writes.
      state.failFlash = null;
      state.product = 'moon';
      final wrongProduct = await executePreparedFlash(
        prepared,
        transport,
        emit: (_) {},
        previousReceipt: receipt,
      );
      expect(wrongProduct['status'], 'failed');
      expect(
        (wrongProduct['failure'] as Map)['message'],
        contains('reports product "moon"'),
      );
      expect(state.flashCommands, ['boot_a', 'boot_b']);

      // A product change during the retried step is caught afterwards.
      state.product = 'sun';
      state.productAfterFlash = 'moon';
      final changed = await executePreparedFlash(
        prepared,
        transport,
        emit: (_) {},
        previousReceipt: receipt,
      );
      expect(changed['status'], 'failed');
      expect(
        (changed['failure'] as Map)['message'],
        contains('identity or mode changed after the retried step'),
      );
    });

    test('the first failed write stops every later command', () async {
      final package = _package();
      final state = _State(failFlash: 'boot_a');
      final transport = _Transport(state, 'SERIAL-A');
      final prepared = await prepareFlash(
        package: package,
        selection: _selection,
        answers: _answers,
        serial: 'SERIAL-A',
        transport: transport,
        job: 'job',
      );
      final receipt = await executePreparedFlash(
        prepared,
        transport,
        emit: (_) {},
      );
      expect(receipt['status'], 'failed');
      expect(state.flashCommands, contains('boot_a'));
      expect(state.flashCommands, isNot(contains('boot_b')));
      expect(
        state.commands.where((command) => command == 'flash:boot_b'),
        isEmpty,
      );
    });

    test(
      'a lost final Android reboot acknowledgement remains uncertain',
      () async {
        final state = _State()..loseRebootReply = 'reboot';
        final transport = _Transport(state, 'SERIAL-A');
        final prepared = await prepareFlash(
          package: _package(),
          selection: _selection,
          answers: _answers,
          serial: 'SERIAL-A',
          transport: transport,
          job: 'job',
        );
        final receipt = await executePreparedFlash(
          prepared,
          transport,
          emit: (_) {},
        );
        expect(receipt['status'], 'uncertain');
        expect(receipt['uncertain'], isTrue);
        expect((receipt['failure'] as Map)['name'], 'NetworkError');
        expect(
          state.commands.where((command) => command == 'reboot'),
          hasLength(1),
        );
        expect(state.android, isTrue);
        expect(state.flashCommands, containsAll(['boot_a', 'boot_b', 'super']));
      },
    );

    test('a sparse split keeps block offsets and stays under the limit', () {
      final parts = splitRawImage(5 * sparseBlockBytes, 16384);
      expect(parts, hasLength(2));
      expect(parts.every((part) => part.length <= 16384), isTrue);
      expect(parts.first.pieces.first.type, sparseRaw);
      expect(parts.first.pieces.first.blocks, 3);
      expect(parts.last.pieces.first.type, sparseDontCare);
      expect(parts.last.pieces.first.blocks, 3);
      for (final part in parts) {
        expect(
          part.pieces.fold<int>(0, (sum, piece) => sum + piece.blocks),
          part.totalBlocks,
          reason: 'Every sparse download must cover the full image geometry',
        );
      }
    });

    test(
      'a sparse image split preserves every block and its fill value',
      () async {
        final sparse = _sparseImage(
          totalBlocks: 5,
          chunks: [
            _chunk(sparseRaw, 4, Uint8List(4 * 4096)),
            _chunk(sparseFill, 1, _fill(0x11223344)),
          ],
        );
        final scan = await scanSparse(_MemorySource(sparse));
        final parts = splitSparseScan(scan, 16384);
        expect(parts, hasLength(2));
        expect(parts.every((part) => part.length <= 16384), isTrue);
        expect(parts.first.pieces.first.blocks, 3);
        expect(parts.last.pieces.first.type, sparseDontCare);
        expect(parts.last.pieces.first.blocks, 3);
        expect(parts.last.pieces.last.type, sparseFill);
        expect(parts.last.pieces.last.fill, 0x11223344);
      },
    );

    test('cancellation stops before the next command', () async {
      final package = _package();
      final state = _State();
      final transport = _Transport(state, 'SERIAL-A');
      final prepared = await prepareFlash(
        package: package,
        selection: _selection,
        answers: _answers,
        serial: 'SERIAL-A',
        transport: transport,
        job: 'job',
      );
      final cancellation = FlashCancellation()..cancel();
      final receipt = await executePreparedFlash(
        prepared,
        transport,
        emit: (_) {},
        cancellation: cancellation,
      );
      expect(receipt['status'], 'cancelled');
      expect(state.flashCommands, isEmpty);
    });
  });
}

Selection get _selection => const Selection(
  dev: '13',
  kind: 'Super Flasher',
  region: 'EU',
  device: 'Oneplus 13',
);

Map<String, String> get _answers => const {
  'product': 'sun',
  'root': 'prepare-root',
  'wipe': 'reboot',
};

Map<String, Object?> _request() => {
  'selection': {
    'device': 'Oneplus 13',
    'kind': 'Super Flasher',
    'region': 'EU',
  },
  'job': 'job',
  'serial': 'SERIAL-A',
  'answers': _answers,
  'upstreamBase': '',
};

_FakePackage _package() {
  final files = <String, Uint8List>{'super.img': Uint8List(5 * 4096)};
  for (final name in const [
    'boot',
    'dtbo',
    'init_boot',
    'modem',
    'recovery',
    'vbmeta',
    'vbmeta_system',
    'vbmeta_vendor',
    'vendor_boot',
  ]) {
    files['OOS_FILES_HERE/$name.img'] = Uint8List.fromList([1, 2, 3]);
  }
  return _FakePackage(files);
}

final class _FakePackage implements FlashPackage {
  _FakePackage(this.files);

  final Map<String, Uint8List> files;
  Map<String, String>? imageSha256;

  @override
  late final PackageIndex index = PackageIndex.fromEntries(files.keys);

  @override
  Map<String, Object?> get buildJson => {
    'device': 'Oneplus 13',
    'flasher_type': 'Super Flasher',
    'region': 'EU',
    'version': '1.2.3',
    'artifact': 'pkg',
    'output_format': 'folder',
    'test_fixture': true,
    if (imageSha256 != null) 'image_sha256': imageSha256,
  };

  @override
  String get format => 'folder';

  @override
  Future<int> size(String path) async => files[path]!.length;

  @override
  Future<FlashSource> open(String path) async => _MemorySource(files[path]!);

  @override
  Future<Map<String, Object?>> snapshot() async => {
    'format': format,
    'entries': {
      for (final entry in files.entries) entry.key: entry.value.length,
    },
    'buildJson': buildJson,
  };
}

final class _MemorySource implements FlashSource {
  _MemorySource(this.bytes);

  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async =>
      Uint8List.sublistView(bytes, offset, offset + length);

  @override
  Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    var offset = 0;
    while (offset < bytes.length) {
      final size = offset + chunkSize > bytes.length
          ? bytes.length - offset
          : chunkSize;
      yield Uint8List.sublistView(bytes, offset, offset + size);
      offset += size;
    }
  }

  @override
  Future<FlashCursor> cursor() async => _MemoryCursor(bytes);

  @override
  Future<void> close() async {}
}

final class _MemoryCursor implements FlashCursor {
  _MemoryCursor(this.bytes);
  final Uint8List bytes;
  var position = 0;

  @override
  Future<Uint8List> readExact(int length) async {
    final value = Uint8List.sublistView(bytes, position, position + length);
    position += length;
    return value;
  }

  @override
  Future<void> skipTo(int offset) async {
    if (offset < position) throw StateError('backwards');
    position = offset;
  }

  @override
  Future<void> close() async {}
}

final class _State {
  _State({this.serial = 'SERIAL-A', this.product = 'sun', this.failFlash});
  String serial;
  String product;
  String? failFlash;
  bool fastbootd = false;
  bool superFastboot = false;
  bool android = false;
  bool loseFlashReply = false;
  String? loseRebootReply;
  int? partitionBytes;
  bool probeFailure = false;

  /// Sets [product] after a successful `flash:` command, so a test can prove
  /// the post-step identity check.
  String? productAfterFlash;
  final commands = <String>[];
  final flashCommands = <String>[];

  /// The bytes each `flash:` command received, in order. A split image keeps
  /// one entry per part.
  final parts = <String, List<Uint8List>>{};

  BytesBuilder? _download;

  void begin() {
    _download = BytesBuilder(copy: false);
  }

  void add(List<int> bytes) {
    _download?.add(bytes);
  }

  Uint8List? take() {
    final builder = _download;
    _download = null;
    return builder?.takeBytes();
  }
}

final class _Transport implements FastbootTransport {
  _Transport(this.state, this.connectedSerial);

  final _State state;
  final String connectedSerial;
  final opened = <String>[];

  @override
  Future<List<FastbootDevice>> devices() async => [
    FastbootDevice(serial: connectedSerial, label: 'phone', transport: 'test'),
  ];

  @override
  Future<FastbootSession> open(String serial) async {
    if (serial != connectedSerial) {
      throw const LinkFailure(
        blame: 'host',
        name: 'NoDevice',
        message: 'not connected',
        stage: 'open',
      );
    }
    opened.add(serial);
    return _Session(state);
  }
}

final class _Session implements FastbootSession {
  _Session(this.state);

  final _State state;
  var _closed = false;

  @override
  String get serial => state.serial;

  @override
  Future<String> command(String command, {bool write = false}) async {
    if (_closed) throw StateError('closed');
    state.commands.add(command);
    if (command == 'getvar:product') return state.product;
    if (state.probeFailure && command == 'getvar:canoe-bds') {
      throw const LinkFailure(
        blame: 'host',
        name: 'SecurityError',
        message: 'access denied',
        stage: 'probe',
      );
    }
    if (command.startsWith('getvar:partition-size:') &&
        state.partitionBytes != null) {
      return '0x${state.partitionBytes!.toRadixString(16)}';
    }
    if (command == 'getvar:canoe-bds') {
      if (state.superFastboot) return '1';
      throw const LinkFailure(
        blame: 'device',
        name: 'FastbootFail',
        message: 'unknown variable',
        stage: 'command',
      );
    }
    if (command == 'getvar:is-userspace') {
      return state.fastbootd ? 'yes' : 'no';
    }
    if (command == 'getvar:max-download-size') return '0x4000';
    if (command == 'reboot-fastboot' || command == 'reboot' || command == 'reboot-bootloader') {
      if (command == 'reboot-fastboot') {
        state.fastbootd = true;
      } else if (command == 'reboot-bootloader') {
        state.fastbootd = false;
      } else {
        state.android = true;
      }
      if (state.loseRebootReply == command) {
        throw const LinkFailure(
          blame: 'host',
          name: 'NetworkError',
          message: 'acknowledgement lost after reboot',
          stage: 'reboot',
          uncertain: true,
        );
      }
      return '';
    }
    if (command.startsWith('flash:')) {
      final partition = command.substring('flash:'.length);
      state.flashCommands.add(partition);
      final bytes = state.take();
      if (bytes != null) {
        (state.parts[partition] ??= <Uint8List>[]).add(bytes);
      }
      if (state.loseFlashReply) {
        throw const LinkFailure(
          blame: 'host',
          name: 'NetworkError',
          message: 'acknowledgement lost after flash',
          stage: 'flash',
          uncertain: true,
        );
      }
      if (state.failFlash == partition) {
        throw const LinkFailure(
          blame: 'device',
          name: 'FastbootFail',
          message: 'flash failed',
          stage: 'flash',
        );
      }
      if (state.productAfterFlash != null) {
        state.product = state.productAfterFlash!;
      }
      return '';
    }
    return '';
  }

  @override
  Future<void> beginDownload(int length) async {
    state.begin();
  }

  @override
  Future<void> writeDownload(Uint8List bytes) async {
    state.add(bytes);
  }

  @override
  Future<void> endDownload() async {}

  @override
  Future<void> close() async {
    _closed = true;
  }
}

Uint8List _sparseImage({
  required int totalBlocks,
  required List<Uint8List> chunks,
}) {
  final bytes = BytesBuilder();
  bytes.add(
    sparseFileHeader(
      blockSize: 4096,
      totalBlocks: totalBlocks,
      totalChunks: chunks.length,
    ),
  );
  for (final chunk in chunks) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Uint8List _chunk(int type, int blocks, Uint8List payload) {
  final header = sparseChunkHeader(
    type: type,
    blocks: blocks,
    totalSize: 12 + payload.length,
  );
  return Uint8List.fromList([...header, ...payload]);
}

Uint8List _fill(int value) => fillBytes(value);
