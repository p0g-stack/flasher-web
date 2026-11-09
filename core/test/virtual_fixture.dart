/// Fixtures shared by the virtual-package tests: a minimal upstream snapshot,
/// a verified bloat store and a recording fastboot transport.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:flasher_web_core/src/rust/api/zip.dart' as rust_zip;

import 'ota_fixture.dart' show FixtureExtent, FixtureOp, FixturePartition, OtaFixture, buildZip, fixtureBlock, pattern;

/// Reads a ZIP's central directory from [source], without extracting entries.
///
/// The source is read, not closed: the caller owns it.
Future<Map<String, rust_zip.ZipEntry>> parseZipEntries(ByteSource source) async {
  final length = source.length;
  final tailLength = math.min(length, 128 * 1024);
  final tail = await source.read(length - tailLength, tailLength);
  final directory = rust_zip.zipEntries(
    tail: tail,
    fileLen: BigInt.from(length),
  );
  List<rust_zip.ZipEntry> parsed = directory.entries;
  final needs = directory.needs;
  if (needs != null) {
    final (offset, size) = needs;
    final cd = await source.read(offset.toInt(), size.toInt());
    parsed = rust_zip.zipParseCentral(cd: cd);
  }
  return {
    for (final entry in parsed)
      if (!entry.name.endsWith('/')) entry.name: entry,
  };
}

/// The human device names the fixture tables list.
const Map<String, String> fixtureDevices = {
  'Oneplus 13': '13',
  'Oneplus Ace 5': 'Ace5',
  'Oneplus Ace 6': 'Ace6',
  'Oneplus Ace 6T': 'Ace6T',
  'OPPO Find X9 Ultra': 'X9U',
};

/// The physical super size every fixture device reports, per region group.
const int fixtureSuperSize = 1 << 34;

/// One workflow row: `["<kind>", "<dev>", "<region>", "<builder>"]`.
typedef FixtureBuilder = (String kind, String dev, String region, String script);

/// The `tables.json` a fixture snapshot serves.
///
/// [regionSizes] overrides the `[cn, other]` super sizes of a device id.
String tablesJson(
  List<FixtureBuilder> builders, {
  Map<String, (int, int)> regionSizes = const {},
}) => jsonEncode({
  'commit': 'fixture',
  'devices': fixtureDevices,
  'region_sizes': {
    for (final dev in fixtureDevices.values)
      dev: switch (regionSizes[dev]) {
        (final cn, final other) => [cn, other],
        null => [fixtureSuperSize, fixtureSuperSize],
      },
  },
  'builders': [
    for (final row in builders) [row.$1, row.$2, row.$3, row.$4],
  ],
});

/// The `bloat-manifest.json` describing [files] (manifest paths to bytes).
String bloatManifestJson(Map<String, Uint8List> files) {
  final assets = <String, Object?>{};
  final index = <String, String>{};
  var id = 1;
  for (final entry in files.entries) {
    final digest = sha256.convert(entry.value).toString();
    assets[digest] = {
      'raw_sha256': digest,
      'sha256': digest,
      'bytes': entry.value.length,
      'raw_bytes': entry.value.length,
      'encoding': 'identity',
      'asset_id': id,
      'asset_name': 'bloat-asset-$id.img',
    };
    index[entry.key] = digest;
    id++;
  }
  return jsonEncode({
    'schema_version': 1,
    'repository': 'koaaN/Flasher_Builder',
    'tag': 'fixture',
    'assets': assets,
    'files': index,
  });
}

/// Writes `tables.json`, `bloat-manifest.json`, the template packages and
/// `platform-tools.zip` into [directory] and returns its path.
///
/// [templates] maps a device ID to the files of `templates/<dev>.zip`, keyed by
/// their path inside `flasher_scripts/<dev>/`.
Future<String> writeUpstream(
  Directory directory, {
  required List<FixtureBuilder> builders,
  required Map<String, Map<String, Uint8List>> templates,
  Map<String, Uint8List> platformTools = const {},
  Map<String, Uint8List> bloatFiles = const {},
  Map<String, (int, int)> regionSizes = const {},
}) async {
  await _writeFile(
    directory,
    'tables.json',
    utf8.encode(tablesJson(builders, regionSizes: regionSizes)),
  );
  await _writeFile(
    directory,
    'bloat-manifest.json',
    utf8.encode(bloatManifestJson(bloatFiles)),
  );
  for (final device in templates.entries) {
    await _writeFile(
      directory,
      'templates/${device.key}.zip',
      buildZip([
        for (final file in device.value.entries)
          (name: file.key, bytes: file.value),
      ]),
    );
  }
  await _writeFile(
    directory,
    'platform-tools.zip',
    buildZip([
      for (final file in platformTools.entries)
        (name: file.key, bytes: file.value),
    ]),
  );
  return directory.path;
}

/// Writes the bloat store's copies of [files] (manifest paths to bytes).
Future<void> writeBloatStore(
  Workspace workspace,
  Map<String, Uint8List> files,
) async {
  for (final entry in files.entries) {
    final sink = await workspace.create(
      entry.key.substring('bloat/'.length),
    );
    try {
      await sink.write(entry.value, 0);
    } finally {
      await sink.close();
    }
  }
}

Future<void> _writeFile(
  Directory directory,
  String path,
  List<int> bytes,
) async {
  final file = File('${directory.path}/$path');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes);
}

/// A saved fixture set: the OTA in a workspace, the verified bloat store and
/// the upstream snapshot the export reads.
final class VirtualFixture {
  VirtualFixture._(
    this.root,
    this.otaWorkspace,
    this.bloatWorkspace,
    this.upstreamPath,
    this.bloatManifest,
    this.images,
    this.baseImages,
    this.donorImages,
    this.bloatFiles,
    this.regionSizes,
  );

  /// Creates a deterministic OTA over [partitions] (one REPLACE block each),
  /// a bloat store holding [bloatFiles] and an upstream snapshot.
  ///
  /// [basePartitions] and [donorPartitions] add `base.zip` and `donor.zip` to
  /// the OTA workspace, for the Ace 6 conversion and the Ace 6T ODM donor;
  /// their partition images appear in [baseImages] and [donorImages].
  static Future<VirtualFixture> create({
    required List<String> partitions,
    required Map<String, Uint8List> bloatFiles,
    Map<String, Map<String, Uint8List>> templates = const {},
    List<FixtureBuilder> builders = const [
      ('RegionalHybrid Flasher', '13', 'GLO', 'BUILD_REGIONAL.sh'),
    ],
    List<String> basePartitions = const [],
    List<String> donorPartitions = const [],
    Map<String, String> otaFields = const {},
    Map<String, String> baseFields = const {},
    Map<String, String> donorFields = const {},
    Map<String, (int, int)> regionSizes = const {},
    Map<String, Uint8List> otaBytes = const {},
    Map<String, Uint8List> baseBytes = const {},
    Map<String, Uint8List> donorBytes = const {},
    Map<String, int> otaBlocks = const {},
    Map<String, int> baseBlocks = const {},
    Map<String, int> donorBlocks = const {},
  }) async {
    final root = await Directory.systemTemp.createTemp('virtual_fixture_');
    final otaWorkspace = IoWorkspace(Directory('${root.path}/ota'));
    final bloatWorkspace = IoWorkspace(Directory('${root.path}/bloat'));
    final upstream = Directory('${root.path}/upstream');

    Future<Map<String, Uint8List>> writeOta(
      String file,
      List<String> names, {
      required int seed,
      Map<String, String> fields = const {},
      Map<String, Uint8List> overrides = const {},
      Map<String, int> blocks = const {},
    }) async {
      final images = <String, Uint8List>{};
      final ops = <FixturePartition>[];
      for (var index = 0; index < names.length; index++) {
        final name = names[index];
        final count = blocks[name] ?? 1;
        final data = overrides[name] ??
            pattern(count * fixtureBlock, seed: seed + index);
        images[name] = data;
        ops.add(
          FixturePartition(
            name: name,
            ops: [
              FixtureOp.replace([FixtureExtent(0, count)], data),
            ],
          ),
        );
      }
      final ota = OtaFixture(ops, fields: fields);
      final sink = await otaWorkspace.create(file);
      await sink.write(ota.build(), 0);
      await sink.close();
      return images;
    }

    final images = await writeOta(
      'ota.zip',
      partitions,
      seed: 1,
      fields: otaFields,
      overrides: otaBytes,
      blocks: otaBlocks,
    );
    final baseImages = basePartitions.isEmpty
        ? const <String, Uint8List>{}
        : await writeOta(
            'base.zip',
            basePartitions,
            seed: 1001,
            fields: baseFields,
            overrides: baseBytes,
            blocks: baseBlocks,
          );
    final donorImages = donorPartitions.isEmpty
        ? const <String, Uint8List>{}
        : await writeOta(
            'donor.zip',
            donorPartitions,
            seed: 2001,
            fields: donorFields,
            overrides: donorBytes,
            blocks: donorBlocks,
          );

    await writeBloatStore(bloatWorkspace, bloatFiles);
    final upstreamPath = await writeUpstream(
      upstream,
      builders: builders,
      templates: templates,
      platformTools: fixturePlatformTools(),
      bloatFiles: bloatFiles,
      regionSizes: regionSizes,
    );
    final manifest = BloatManifest.decode(
      utf8.decode(await File('$upstreamPath/bloat-manifest.json').readAsBytes()),
    );
    return VirtualFixture._(
      root,
      otaWorkspace,
      bloatWorkspace,
      upstreamPath,
      manifest,
      images,
      baseImages,
      donorImages,
      bloatFiles,
      regionSizes,
    );
  }

  final Directory root;
  final IoWorkspace otaWorkspace;
  final IoWorkspace bloatWorkspace;
  final String upstreamPath;
  final BloatManifest bloatManifest;

  /// Partition name to the image its operations decode to.
  final Map<String, Uint8List> images;

  /// The same for `base.zip`, when the fixture has one.
  final Map<String, Uint8List> baseImages;

  /// The same for `donor.zip`, when the fixture has one.
  final Map<String, Uint8List> donorImages;

  /// Bloat manifest path to the bytes the store holds.
  final Map<String, Uint8List> bloatFiles;

  /// `dev` to `[cn, other]` super sizes, as `tables.json` records them.
  final Map<String, (int, int)> regionSizes;

  UpstreamAssets get upstream => UpstreamAssets(upstreamPath);

  /// The physical super size this fixture's tables report for [dev]/[region].
  int superSize(String dev, String region) {
    final sizes = regionSizes[dev];
    if (sizes == null) return fixtureSuperSize;
    return region == 'CN' ? sizes.$1 : sizes.$2;
  }

  /// The OTA input identity `localOtaIdentity` would produce.
  Map<String, Object?> get identity => identityOf('ota.zip');

  Map<String, Object?> identityOf(String name) => {
    'kind': 'file',
    'name': name,
    'size': 0,
    'lastModified': 0,
  };

  /// Opens `ota.zip`, `base.zip` or `donor.zip` from the OTA workspace.
  ///
  /// [workspace] replaces the OTA workspace, so a test can count payload reads
  /// through a [CountingWorkspace].
  Future<OtaArchive> openOta(String name, {Workspace? workspace}) async {
    final source = await (workspace ?? otaWorkspace).open(name);
    try {
      return await OtaArchive.open(source);
    } on Object {
      await closeByteSource(source);
      rethrow;
    }
  }

  /// Opens a virtual package over this fixture.
  ///
  /// [bloat] overrides the workspace the package verifies and reads; a test
  /// passes a [CountingWorkspace] to observe how often bloat is read. [ota]
  /// does the same for the OTA workspace, which is how a test counts payload
  /// reads. [superSize] is required for a `Super` kind.
  Future<VirtualFlashPackage> open(
    Selection selection, {
    Map<String, Object?>? sourceIdentity,
    Workspace? bloat,
    Workspace? ota,
    OtaArchive? base,
    OtaArchive? donor,
    Map<String, Object?>? baseIdentity,
    Map<String, Object?>? donorIdentity,
    int? superSize,
    VirtualFlashPackage? preparedPackage,
  }) async {
    final source = await (ota ?? otaWorkspace).open('ota.zip');
    final archive = await OtaArchive.open(source);
    try {
      return await VirtualFlashPackage.load(
        ota: archive,
        selection: selection,
        bloat: bloat ?? bloatWorkspace,
        bloatManifest: bloatManifest,
        sourceIdentity: sourceIdentity ?? identity,
        base: base,
        baseIdentity: baseIdentity,
        donor: donor,
        donorIdentity: donorIdentity,
        superSize: superSize,
        preparedPackage: preparedPackage,
      );
    } on Object {
      await archive.close();
      rethrow;
    }
  }

  Future<void> dispose() => root.delete(recursive: true);
}

/// A [Workspace] decorator that counts the byte sources opened through it and
/// the bytes read from them.
final class CountingWorkspace implements Workspace {
  CountingWorkspace(this.inner);

  final Workspace inner;
  int opens = 0;
  int reads = 0;
  int bytesRead = 0;

  /// Forgets the counts so far.
  void reset() {
    opens = 0;
    reads = 0;
    bytesRead = 0;
  }

  @override
  Future<ByteSink> create(String path) => inner.create(path);

  @override
  Future<ByteSink> update(String path) => inner.update(path);

  @override
  Future<ByteSource> open(String path) async {
    opens++;
    return _CountingSource(await inner.open(path), this);
  }

  @override
  Future<bool> exists(String path) => inner.exists(path);

  @override
  Future<int> size(String path) => inner.size(path);

  @override
  Future<List<String>> list(String dir, {bool recursive = false}) =>
      inner.list(dir, recursive: recursive);

  @override
  Future<void> move(String from, String to) => inner.move(from, to);

  @override
  Future<void> delete(String path) => inner.delete(path);
}

final class _CountingSource implements ByteSource {
  _CountingSource(this.inner, this.counters);

  final ByteSource inner;
  final CountingWorkspace counters;

  @override
  int get length => inner.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    counters.reads++;
    final bytes = await inner.read(offset, length);
    counters.bytesRead += bytes.length;
    return bytes;
  }

  Future<void> close() => closeByteSource(inner);
}

/// A two-file Platform-Tools archive, one being an ELF so the ZIP mode check
/// has something to see.
Map<String, Uint8List> fixturePlatformTools() => {
  'fastboot.txt': Uint8List.fromList(utf8.encode('tools\n')),
  'fastboot': Uint8List.fromList([
    0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0, ...List<int>.filled(24, 0),
  ]),
};

/// One 4096-byte image a BASE OTA can carry as `vbmeta*.img`.
///
/// `make_vbmeta` needs a real vbmeta header to copy descriptors from: `AVB0`,
/// version 1.0, no authentication block and no descriptors. The reserved tail
/// is zero, so the parser sees an empty descriptor blob.
Uint8List fixtureVbmeta() {
  final bytes = Uint8List(4096);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, 'AVB0'.codeUnits);
  data.setUint32(4, 1, Endian.big); // version major
  data.setUint32(8, 0, Endian.big); // version minor
  data.setUint64(12, 0, Endian.big); // authentication block size
  data.setUint64(20, 0, Endian.big); // auxiliary block size
  data.setUint32(28, 0, Endian.big); // algorithm NONE
  data.setUint64(96, 0, Endian.big); // descriptors offset
  data.setUint64(104, 0, Endian.big); // descriptors size
  return bytes;
}

/// The `oos/regional` template of device 13, with CRLF files, an executable
/// script, a file outside the selected subtree and a file Platform-Tools also
/// ships.
Map<String, Uint8List> fixtureTemplate13() => {
  'oos/regional/updater-script': Uint8List.fromList(
    utf8.encode('#!/sbin/sh\r\nui_print "hello"\r\n'),
  ),
  'oos/regional/META-INF/com/google/android/update-binary':
      Uint8List.fromList([
        0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0, ...List<int>.filled(24, 0),
      ]),
  'oos/regional/flash.sh': Uint8List.fromList(
    utf8.encode('#!/bin/sh\r\nfastboot flash boot boot.img\r\n'),
  ),
  'oos/regional/notes.txt': Uint8List.fromList(utf8.encode('keep\r\nme\r\n')),
  'oos/regional/Platform-Tools/fastboot.txt': Uint8List.fromList(
    utf8.encode('template\n'),
  ),
  // Not selected: the build copies only the template subtree into the result.
  'oos/super/updater-script': Uint8List.fromList(utf8.encode('#!/sbin/sh\n')),
  'oos/regional-extra.txt': Uint8List.fromList(utf8.encode('outside\n')),
};

/// A device the fixture transport answers for.
final class FixtureDevice {
  FixtureDevice({
    this.serial = 'SERIAL-A',
    this.product = 'sun',
    this.maxDownloadSize = '0x4000',
  });

  final String serial;
  final String product;
  bool fastbootd = false;
  bool superFastboot = false;
  bool android = false;

  /// Reported `partition-size:<name>`, when a test sets one.
  int? partitionBytes;

  /// Reported `max-download-size`, as the getvar payload.
  String maxDownloadSize;

  /// A partition whose `flash:` command fails.
  String? failFlash;

  final commands = <String>[];
  final flashCommands = <String>[];

  /// What each partition received through the download commands.
  final delivered = <String, Uint8List>{};

  /// Every `flash:` payload for a partition, in order; a split image arrives
  /// as several parts.
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

/// The fake fastboot transport used by the executor tests, recording the
/// bytes each `flash:` command would have written.
final class FixtureTransport implements FastbootTransport {
  FixtureTransport(this.device);

  final FixtureDevice device;
  final opened = <String>[];

  @override
  Future<List<FastbootDevice>> devices() async => [
    FastbootDevice(serial: device.serial, label: 'phone', transport: 'fixture'),
  ];

  @override
  Future<FastbootSession> open(String serial) async {
    if (serial != device.serial) {
      throw const LinkFailure(
        blame: 'host',
        name: 'NoDevice',
        message: 'not connected',
        stage: 'open',
      );
    }
    opened.add(serial);
    return _FixtureSession(device);
  }
}

final class _FixtureSession implements FastbootSession {
  _FixtureSession(this.device);

  final FixtureDevice device;
  var _closed = false;

  @override
  String get serial => device.serial;

  @override
  Future<String> command(String command, {bool write = false}) async {
    if (_closed) throw StateError('closed');
    device.commands.add(command);
    if (command == 'getvar:product') return device.product;
    if (command == 'getvar:canoe-bds') {
      if (device.superFastboot) return '1';
      throw const LinkFailure(
        blame: 'device',
        name: 'FastbootFail',
        message: 'unknown variable',
        stage: 'command',
      );
    }
    if (command == 'getvar:is-userspace') {
      return device.fastbootd ? 'yes' : 'no';
    }
    if (command == 'getvar:max-download-size') return device.maxDownloadSize;
    if (command.startsWith('getvar:partition-size:') &&
        device.partitionBytes != null) {
      return '0x${device.partitionBytes!.toRadixString(16)}';
    }
    if (command == 'reboot-fastboot' || command == 'reboot') {
      if (command == 'reboot-fastboot') {
        device.fastbootd = true;
      } else {
        device.android = true;
      }
      return '';
    }
    if (command.startsWith('flash:')) {
      final partition = command.substring('flash:'.length);
      device.flashCommands.add(partition);
      final bytes = device.take();
      if (bytes != null) {
        device.delivered[partition] = bytes;
        (device.parts[partition] ??= <Uint8List>[]).add(bytes);
      }
      if (device.failFlash == partition) {
        throw const LinkFailure(
          blame: 'device',
          name: 'FastbootFail',
          message: 'flash failed',
          stage: 'flash',
        );
      }
      return '';
    }
    return '';
  }

  @override
  Future<void> beginDownload(int length) async {
    device.begin();
  }

  @override
  Future<void> writeDownload(Uint8List bytes) async {
    device.add(bytes);
  }

  @override
  Future<void> endDownload() async {}

  @override
  Future<void> close() async {
    _closed = true;
  }
}
