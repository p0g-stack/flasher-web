/// Fixtures shared by the virtual-package tests: a minimal upstream snapshot,
/// a verified bloat store and a recording fastboot transport.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import 'ota_fixture.dart' show FixtureExtent, FixtureOp, FixturePartition, OtaFixture, buildZip, fixtureBlock, pattern;

/// The human device names the fixture tables list.
const Map<String, String> fixtureDevices = {
  'Oneplus 13': '13',
  'OPPO Find X9 Ultra': 'X9U',
};

/// One workflow row: `["<kind>", "<dev>", "<region>", "<builder>"]`.
typedef FixtureBuilder = (String kind, String dev, String region, String script);

/// The `tables.json` a fixture snapshot serves.
String tablesJson(List<FixtureBuilder> builders) => jsonEncode({
  'commit': 'fixture',
  'devices': fixtureDevices,
  'region_sizes': {
    for (final dev in fixtureDevices.values)
      dev: [1 << 34, 1 << 34],
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
}) async {
  await _writeFile(directory, 'tables.json', utf8.encode(tablesJson(builders)));
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
    this.bloatFiles,
  );

  /// Creates a deterministic OTA over [partitions] (one REPLACE block each),
  /// a bloat store holding [bloatFiles] and an upstream snapshot.
  static Future<VirtualFixture> create({
    required List<String> partitions,
    required Map<String, Uint8List> bloatFiles,
    Map<String, Map<String, Uint8List>> templates = const {},
    List<FixtureBuilder> builders = const [
      ('RegionalHybrid Flasher', '13', 'GLO', 'BUILD_REGIONAL.sh'),
    ],
  }) async {
    final root = await Directory.systemTemp.createTemp('virtual_fixture_');
    final otaWorkspace = IoWorkspace(Directory('${root.path}/ota'));
    final bloatWorkspace = IoWorkspace(Directory('${root.path}/bloat'));
    final upstream = Directory('${root.path}/upstream');

    final images = <String, Uint8List>{};
    final ops = <FixturePartition>[];
    for (var index = 0; index < partitions.length; index++) {
      final name = partitions[index];
      final data = pattern(fixtureBlock, seed: index + 1);
      images[name] = data;
      ops.add(
        FixturePartition(
          name: name,
          ops: [
            FixtureOp.replace([
              const FixtureExtent(0, 1),
            ], data),
          ],
        ),
      );
    }
    final ota = OtaFixture(ops);
    final sink = await otaWorkspace.create('ota.zip');
    await sink.write(ota.build(), 0);
    await sink.close();

    await writeBloatStore(bloatWorkspace, bloatFiles);
    final upstreamPath = await writeUpstream(
      upstream,
      builders: builders,
      templates: templates,
      platformTools: fixturePlatformTools(),
      bloatFiles: bloatFiles,
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
      bloatFiles,
    );
  }

  final Directory root;
  final IoWorkspace otaWorkspace;
  final IoWorkspace bloatWorkspace;
  final String upstreamPath;
  final BloatManifest bloatManifest;

  /// Partition name to the image its operations decode to.
  final Map<String, Uint8List> images;

  /// Bloat manifest path to the bytes the store holds.
  final Map<String, Uint8List> bloatFiles;

  UpstreamAssets get upstream => UpstreamAssets(upstreamPath);

  /// The OTA input identity `localOtaIdentity` would produce.
  Map<String, Object?> get identity => {
    'kind': 'file',
    'name': 'ota.zip',
    'size': 0,
    'lastModified': 0,
  };

  /// Opens a virtual package over this fixture.
  ///
  /// [bloat] overrides the workspace the package verifies and reads; a test
  /// passes a [CountingWorkspace] to observe how often bloat is read.
  Future<VirtualFlashPackage> open(
    Selection selection, {
    Map<String, Object?>? sourceIdentity,
    Workspace? bloat,
  }) async {
    final source = await otaWorkspace.open('ota.zip');
    final archive = await OtaArchive.open(source);
    try {
      return await VirtualFlashPackage.load(
        ota: archive,
        selection: selection,
        bloat: bloat ?? bloatWorkspace,
        bloatManifest: bloatManifest,
        sourceIdentity: sourceIdentity ?? identity,
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
  FixtureDevice({this.serial = 'SERIAL-A', this.product = 'sun'});

  final String serial;
  final String product;
  bool fastbootd = false;
  bool superFastboot = false;
  bool android = false;

  /// Reported `partition-size:<name>`, when a test sets one.
  int? partitionBytes;

  /// A partition whose `flash:` command fails.
  String? failFlash;

  final commands = <String>[];
  final flashCommands = <String>[];

  /// What each partition received through the download commands.
  final delivered = <String, Uint8List>{};

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
    if (command == 'getvar:max-download-size') return '0x4000';
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
      if (bytes != null) device.delivered[partition] = bytes;
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
