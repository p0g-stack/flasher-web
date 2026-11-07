@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:flasher_web_core/src/rust/api/zip.dart' show ZipCrc32;
import 'package:flasher_web_core/src/storage/range.dart'
    show RangeException, strongEtag, validatePinnedEtag;
import 'package:test/test.dart';

const String _jobId = 'hosted-job-0123456789abcdef';
final Uint8List _boot = Uint8List.fromList(
  List<int>.generate(512, (index) => (index * 31 + 7) & 0xff),
);

void main() {
  setUpAll(() async {
    expect(await loadNative(), isTrue);
  });

  group('hosted artifact input', () {
    Map<String, Object?> valid() => {
      'jobId': _jobId,
      'sha256': 'a' * 64,
      'bytes': 4096,
    };

    test('accepts exactly a capability id, digest and length', () {
      final artifact = HostedArtifact.tryParse(valid())!;
      expect(artifact.jobId, _jobId);
      expect(artifact.sha256, 'a' * 64);
      expect(artifact.bytes, 4096);
      expect(artifact.strongEtag, '"${'a' * 64}"');
    });

    test('refuses URLs, uploads and unknown fields', () {
      for (final field in ['url', 'file', 'upload', 'path', 'store']) {
        expect(
          () => HostedArtifact.tryParse({...valid(), field: 'x'}),
          throwsA(isA<FlashException>()),
          reason: 'hosted.$field must be refused',
        );
      }
    });

    test('refuses unsafe or out-of-range identities', () {
      for (final id in [
        'short',
        'a' * 15,
        'a' * 129,
        '../traversal-0123456789',
        'job/0123456789abcdef',
        'job?x=1',
      ]) {
        expect(
          () => HostedArtifact.tryParse({...valid(), 'jobId': id}),
          throwsA(isA<FlashException>()),
          reason: id,
        );
      }
      expect(
        () => HostedArtifact.tryParse({...valid(), 'sha256': 'abc'}),
        throwsA(isA<FlashException>()),
      );
      expect(
        () => HostedArtifact.tryParse({...valid(), 'bytes': 0}),
        throwsA(isA<FlashException>()),
      );
    });

    test('a stale digest or length is refused', () {
      final artifact = HostedArtifact.tryParse(valid())!;
      expect(
        parseHostedJobInfo({
          'status': 'succeeded',
          'sha256': 'a' * 64,
          'bytes': 4096,
        }, artifact).sha256,
        'a' * 64,
      );
      expect(
        () => parseHostedJobInfo({
          'status': 'succeeded',
          'sha256': 'b' * 64,
          'bytes': 4096,
        }, artifact),
        throwsA(isA<FlashException>()),
      );
      expect(
        () => parseHostedJobInfo({
          'status': 'succeeded',
          'sha256': 'a' * 64,
          'bytes': 4097,
        }, artifact),
        throwsA(isA<FlashException>()),
      );
      expect(
        () => parseHostedJobInfo({'status': 'running'}, artifact),
        throwsA(isA<FlashException>()),
      );
    });
  });

  group('hosted package', () {
    late Uint8List zip;
    late HostedArtifact artifact;

    setUp(() {
      zip = _buildZip({
        'build.json': utf8.encode(
          jsonEncode({
            'device': 'Oneplus 13',
            'flasher_type': 'Super Flasher',
            'region': 'EU',
            'version': '1.2.3',
            'artifact': 'pkg.zip',
            'output_format': 'zip',
            'image_sha256': {
              'OOS_FILES_HERE/boot.img': sha256.convert(_boot).toString(),
            },
          }),
        ),
        'OOS_FILES_HERE/boot.img': _boot,
      });
      artifact = HostedArtifact(
        jobId: _jobId,
        sha256: sha256.convert(zip).toString(),
        bytes: zip.length,
      );
    });

    test('reads the ZIP directory without a local file', () async {
      final package = await HostedFlashPackage.load(
        artifact: artifact,
        manifestBytes: _manifest(),
        source: _MemoryBytes(zip),
        etag: artifact.strongEtag,
      );
      expect(package.format, 'zip');
      expect(package.index.has('OOS_FILES_HERE/boot.img'), isTrue);
      expect(await package.size('OOS_FILES_HERE/boot.img'), _boot.length);
      final source = await package.open('OOS_FILES_HERE/boot.img');
      expect(await hashRawSource(source), sha256.convert(_boot).toString());
      expect(await source.read(0, 16), _boot.sublist(0, 16));
    });

    test('binds job, digest, length, ETag and manifest into its snapshot',
        () async {
      final package = await HostedFlashPackage.load(
        artifact: artifact,
        manifestBytes: _manifest(),
        source: _MemoryBytes(zip),
        etag: artifact.strongEtag,
      );
      final snapshot = await package.snapshot();
      expect(snapshot['format'], 'zip');
      expect(snapshot['etag'], artifact.strongEtag);
      expect(snapshot['manifestSha256'], sha256.convert(_manifest()).toString());
      final hosted = snapshot['hosted']! as Map;
      expect(hosted['jobId'], _jobId);
      expect(hosted['sha256'], artifact.sha256);
      expect(hosted['bytes'], artifact.bytes);
      expect(await packageDigest(package), await packageDigest(package));
    });

    test('a changed manifest changes the bound package digest', () async {
      final first = await HostedFlashPackage.load(
        artifact: artifact,
        manifestBytes: _manifest(),
        source: _MemoryBytes(zip),
        etag: artifact.strongEtag,
      );
      final changed = utf8.encode(
        jsonEncode({
          'device': 'Oneplus 13',
          'flasher_type': 'Super Flasher',
          'region': 'EU',
          'version': '9.9.9',
          'artifact': 'pkg.zip',
          'output_format': 'zip',
        }),
      );
      final second = await HostedFlashPackage.load(
        artifact: artifact,
        manifestBytes: changed,
        source: _MemoryBytes(zip),
        etag: artifact.strongEtag,
      );
      expect(
        await packageDigest(first),
        isNot(await packageDigest(second)),
      );
    });

    test('changed image bytes are refused while streaming', () async {
      final mutated = Uint8List.fromList(zip);
      final at = _indexOf(mutated, _boot);
      expect(at, greaterThan(0));
      mutated[at + 3] ^= 0xff;
      final changedPackage = await HostedFlashPackage.load(
        artifact: artifact,
        manifestBytes: _manifest(),
        source: _MemoryBytes(mutated),
        etag: artifact.strongEtag,
      );
      final source = await changedPackage.open('OOS_FILES_HERE/boot.img');
      await expectLater(
        hashRawSource(source),
        throwsA(isA<FlashException>()),
      );
    });

    test('a lost lease refuses the next read', () async {
      var leaseValid = true;
      final package = await HostedFlashPackage.load(
        artifact: artifact,
        manifestBytes: _manifest(),
        source: _MemoryBytes(zip),
        etag: artifact.strongEtag,
        leaseValid: () => leaseValid,
      );
      final source = await package.open('OOS_FILES_HERE/boot.img');
      expect(await source.read(0, 8), _boot.sublist(0, 8));
      leaseValid = false;
      await expectLater(source.read(0, 8), throwsA(isA<FlashException>()));
    });

    test('wrong length or a non-ZIP manifest is refused', () async {
      await expectLater(
        HostedFlashPackage.load(
          artifact: HostedArtifact(
            jobId: _jobId,
            sha256: artifact.sha256,
            bytes: zip.length + 1,
          ),
          manifestBytes: _manifest(),
          source: _MemoryBytes(zip),
        ),
        throwsA(isA<FlashException>()),
      );
      await expectLater(
        HostedFlashPackage.load(
          artifact: artifact,
          manifestBytes: utf8.encode(
            jsonEncode({'artifact': 'pkg', 'output_format': 'folder'}),
          ),
          source: _MemoryBytes(zip),
        ),
        throwsA(isA<FlashException>()),
      );
    });
  });

  group('hosted session', () {
    test('releases its lease and source when closed', () async {
      final zip = _buildZip({
        'build.json': utf8.encode(
          jsonEncode({
            'device': 'Oneplus 13',
            'flasher_type': 'Super Flasher',
            'region': 'EU',
            'version': '1.2.3',
            'artifact': 'pkg.zip',
            'output_format': 'zip',
          }),
        ),
        'OOS_FILES_HERE/boot.img': _boot,
      });
      final artifact = HostedArtifact(
        jobId: _jobId,
        sha256: sha256.convert(zip).toString(),
        bytes: zip.length,
      );
      final fakeLease = _FakeLease();
      final transport = _FakeTransport(zip, _manifest(), lease: fakeLease);
      final session = await HostedFlashSession.open(
        artifact: artifact,
        transport: transport,
      );
      expect(session.package.index.has('OOS_FILES_HERE/boot.img'), isTrue);
      expect(transport.jobReads, 1);
      expect(fakeLease.released, isFalse);
      await session.close();
      expect(fakeLease.released, isTrue);
      expect(transport.source.closed, isTrue);
    });

    test('renewal is bounded and always shorter than the lease', () {
      expect(
        HostedFlashSession.clampRenewInterval(const Duration(minutes: 1)),
        const Duration(seconds: 20),
      );
      expect(
        HostedFlashSession.clampRenewInterval(const Duration(hours: 1)),
        const Duration(minutes: 5),
      );
      final short = HostedFlashSession.clampRenewInterval(
        const Duration(seconds: 5),
      );
      expect(short, lessThan(const Duration(seconds: 5)));
      expect(short, greaterThan(const Duration(seconds: 1)));
      expect(
        HostedFlashSession.renewTimeout(const Duration(seconds: 5)),
        lessThan(const Duration(seconds: 5)),
      );
      expect(
        HostedFlashSession.boundedRenewalCount(
          const Duration(minutes: 1),
          const Duration(hours: 12),
        ),
        2160,
      );
    });

    test('a hung renewal cannot keep the session usable past expiry', () async {
      final zip = _buildZip({
        'build.json': utf8.encode(
          jsonEncode({
            'device': 'Oneplus 13',
            'flasher_type': 'Super Flasher',
            'region': 'EU',
            'version': '1.2.3',
            'artifact': 'pkg.zip',
            'output_format': 'zip',
          }),
        ),
        'OOS_FILES_HERE/boot.img': _boot,
      });
      final artifact = HostedArtifact(
        jobId: _jobId,
        sha256: sha256.convert(zip).toString(),
        bytes: zip.length,
      );
      final transport = _FakeTransport(
        zip,
        _manifest(),
        lease: _HungLease(const Duration(milliseconds: 800)),
      );
      final session = await HostedFlashSession.open(
        artifact: artifact,
        transport: transport,
      );
      final device = _RecordingTransport();
      final guarded = session.guardedTransport(device);
      final deviceSession = await guarded.open('SERIAL123');

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(session.leaseValid, isFalse);
      expect(
        () => session.assertLease(),
        throwsA(isA<FlashException>()),
      );
      await expectLater(guarded.devices(), throwsA(isA<FlashException>()));
      await expectLater(
        deviceSession.command('getvar:product'),
        throwsA(isA<FlashException>()),
      );
      expect(device.devicesCalls, 0);
      expect(device.session.commandCalls, 0);
      await session.close();
    });
  });

  group('range ETag pinning', () {
    test('requires a strong, unchanged validator', () {
      expect(strongEtag('"abc"'), '"abc"');
      expect(strongEtag('W/"abc"'), isNull);
      expect(strongEtag(null), isNull);
      expect(
        () => validatePinnedEtag(
          expected: '"abc"',
          actual: 'W/"abc"',
          context: 'artifact',
        ),
        throwsA(isA<RangeException>()),
      );
      expect(
        () => validatePinnedEtag(
          expected: '"abc"',
          actual: '"def"',
          context: 'artifact',
        ),
        throwsA(isA<RangeException>()),
      );
      validatePinnedEtag(
        expected: '"abc"',
        actual: ' "abc" ',
        context: 'artifact',
      );
    });
  });
}

Uint8List _manifest() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'device': 'Oneplus 13',
      'flasher_type': 'Super Flasher',
      'region': 'EU',
      'version': '1.2.3',
      'artifact': 'pkg.zip',
      'output_format': 'zip',
    }),
  ),
);

int _indexOf(Uint8List haystack, Uint8List needle) {
  outer:
  for (var index = 0; index + needle.length <= haystack.length; index++) {
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[index + offset] != needle[offset]) continue outer;
    }
    return index;
  }
  return -1;
}

/// A stored-method ZIP, sufficient for the directory parser and entry source.
Uint8List _buildZip(Map<String, List<int>> files) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final entry in files.entries) {
    final name = utf8.encode(entry.key);
    final data = Uint8List.fromList(entry.value);
    final crc = _crc32(data);
    final offset = out.length;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, 0, Endian.little)
      ..setUint16(10, 0, Endian.little)
      ..setUint16(12, 0, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, data.length, Endian.little)
      ..setUint32(22, data.length, Endian.little)
      ..setUint16(26, name.length, Endian.little)
      ..setUint16(28, 0, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(data);
    final cd = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0, Endian.little)
      ..setUint16(10, 0, Endian.little)
      ..setUint16(12, 0, Endian.little)
      ..setUint16(14, 0, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, data.length, Endian.little)
      ..setUint32(24, data.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint16(30, 0, Endian.little)
      ..setUint16(32, 0, Endian.little)
      ..setUint16(34, 0, Endian.little)
      ..setUint16(36, 0, Endian.little)
      ..setUint32(38, 0, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(cd.buffer.asUint8List())
      ..add(name);
  }
  final cdOffset = out.length;
  final cdBytes = central.takeBytes();
  out.add(cdBytes);
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(4, 0, Endian.little)
    ..setUint16(6, 0, Endian.little)
    ..setUint16(8, files.length, Endian.little)
    ..setUint16(10, files.length, Endian.little)
    ..setUint32(12, cdBytes.length, Endian.little)
    ..setUint32(16, cdOffset, Endian.little)
    ..setUint16(20, 0, Endian.little);
  out.add(eocd.buffer.asUint8List());
  return out.takeBytes();
}

int _crc32(Uint8List bytes) {
  final crc = ZipCrc32();
  crc.update(bytes: bytes);
  return crc.finish();
}

final class _MemoryBytes implements ByteSource {
  _MemoryBytes(this._bytes);

  final Uint8List _bytes;
  bool closed = false;

  @override
  int get length => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async =>
      Uint8List.sublistView(_bytes, offset, offset + length);

  Future<void> close() async {
    closed = true;
  }
}

final class _FakeTransport implements HostedTransport {
  _FakeTransport(this.zip, this.manifest, {HostedLease? lease})
    : lease = lease ?? _FakeLease();

  final Uint8List zip;
  final Uint8List manifest;
  final HostedLease lease;
  late final _MemoryBytes source = _MemoryBytes(zip);
  int jobReads = 0;

  @override
  Future<HostedJobInfo> readJob(HostedArtifact artifact) async {
    jobReads++;
    return HostedJobInfo(
      status: 'succeeded',
      sha256: artifact.sha256,
      bytes: artifact.bytes,
    );
  }

  @override
  Future<Uint8List> readManifest(HostedArtifact artifact) async => manifest;

  @override
  Future<ByteSource> openArtifact(HostedArtifact artifact) async => source;

  @override
  Future<HostedLease> acquireLease(HostedArtifact artifact) async => lease;
}

final class _FakeLease implements HostedLease {
  bool released = false;
  var _expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 5));

  @override
  DateTime get expiresAt => _expiresAt;

  @override
  Future<DateTime> renew() async {
    _expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 5));
    return _expiresAt;
  }

  @override
  Future<void> release() async {
    released = true;
  }
}

/// A lease whose renew request never completes, like a stalled HTTP call.
final class _HungLease implements HostedLease {
  _HungLease(Duration ttl)
    : expiresAt = DateTime.now().toUtc().add(ttl);

  @override
  final DateTime expiresAt;

  @override
  Future<DateTime> renew() => Completer<DateTime>().future;

  @override
  Future<void> release() async {}
}

final class _RecordingTransport implements FastbootTransport {
  int devicesCalls = 0;
  int openCalls = 0;
  final session = _RecordingSession();

  @override
  Future<List<FastbootDevice>> devices() async {
    devicesCalls++;
    return const [];
  }

  @override
  Future<FastbootSession> open(String serial) async {
    openCalls++;
    return session;
  }
}

final class _RecordingSession implements FastbootSession {
  int commandCalls = 0;

  @override
  String get serial => 'SERIAL123';

  @override
  Future<String> command(String command, {bool write = false}) async {
    commandCalls++;
    return 'OKAY';
  }

  @override
  Future<void> beginDownload(int length) async {}

  @override
  Future<void> writeDownload(Uint8List bytes) async {}

  @override
  Future<void> endDownload() async {}

  @override
  Future<void> close() async {}
}
