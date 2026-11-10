// Writes app/web/upstream/ from the upstream commit pinned in upstream.lock.
//
// Usage, from the workspace root (tool/bootstrap.sh does the first):
//   dart run tool/sync_upstream.dart                    # fetch the pinned tarball
//   dart run tool/sync_upstream.dart --source ../Flasher_Builder
//
// --source reads the pinned commit's tree from a local git checkout, so a
// dirty or newer working tree never leaks into the snapshot. Both modes write
// the same bytes: sorted entries, fixed timestamps, raw file contents.
//
// Output:
//   tables.json             device/region/builder tables, parsed as backend.Catalog
//   bloat-manifest.json     bloat/assets-manifest.json
//   README.md               the upstream README
//   templates/<dev>.zip     flasher_scripts/<dev>/**, paths relative to it
//   platform-tools.zip      Platform-Tools/**, paths relative to it
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const _lockFile = 'upstream.lock';
const _defaultOutput = 'app/web/upstream';
const _tarballHost = 'https://codeload.github.com';
const _deflateLevel = 3;

/// Unix permission bits stored in a ZIP entry's external attributes, as
/// upstream's package() sets them.
const _modeFile = 0x81a4; // 100644
const _modeExecutable = 0x81ed; // 100755

const _executableNames = {
  'aera-installer',
  'pack_super',
  'pack_super_regional',
  'unpack_super',
  'update-binary',
  'volprompt',
};

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }

  final root = _workspaceRoot();
  final lock = _readLock(File(_join(root.path, _lockFile)));
  final output = Directory(options.output ?? _join(root.path, _defaultOutput));

  stdout.writeln(
    'Upstream ${lock.repository}@${lock.commit} '
    'from ${options.source ?? 'the pinned tarball'}',
  );
  final tarBytes = options.source == null
      ? await _fetchTarball(lock)
      : await _archiveLocalCheckout(options.source!, lock.commit);
  final upstream = _readUpstream(tarBytes, lock.commit);

  final staging = Directory('${output.path}.sync-tmp');
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);
  try {
    _writeSnapshot(staging, upstream, lock);
  } catch (_) {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    rethrow;
  }
  if (output.existsSync()) output.deleteSync(recursive: true);
  output.parent.createSync(recursive: true);
  staging.renameSync(output.path);
  stdout.writeln('Wrote ${output.path}');
}

const _usage =
    '''
Writes $_defaultOutput/ from the upstream commit pinned in $_lockFile.

  dart run tool/sync_upstream.dart [--source <checkout>] [--output <dir>]

  --source   Local git checkout; reads the pinned commit, not the working tree.
  --output   Output directory (default: $_defaultOutput).
  -h, --help Show this help.
''';

class _Options {
  _Options(this.source, this.output, this.help);

  final String? source;
  final String? output;
  final bool help;

  factory _Options.parse(List<String> args) {
    String? source;
    String? output;
    var help = false;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      switch (arg) {
        case '-h':
        case '--help':
          help = true;
        case '--source':
          if (++i == args.length) _fail('--source needs a path');
          source = _absolute(args[i]);
        case '--output':
          if (++i == args.length) _fail('--output needs a path');
          output = _absolute(args[i]);
        default:
          _fail('Unknown argument: $arg');
      }
    }
    return _Options(source, output, help);
  }
}

class _Lock {
  _Lock(this.repository, this.commit);

  final String repository;
  final String commit;
}

class _Upstream {
  _Upstream(this.files);

  /// Path relative to the upstream repository root, UTF-8 bytes verbatim.
  final Map<String, Uint8List> files;

  Uint8List require(String path) {
    final bytes = files[path];
    if (bytes == null) _fail('Upstream is missing $path');
    return bytes;
  }
}

Directory _workspaceRoot() {
  final cwd = Directory.current;
  if (File(_join(cwd.path, _lockFile)).existsSync()) return cwd;
  final script = File.fromUri(Platform.script);
  final candidate = script.parent.parent;
  if (File(_join(candidate.path, _lockFile)).existsSync()) return candidate;
  _fail('Run from the workspace root (no $_lockFile in ${cwd.path}).');
}

_Lock _readLock(File file) {
  if (!file.existsSync()) _fail('Missing ${file.path}');
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    _fail('${file.path} is not valid JSON: ${e.message}');
  }
  if (decoded is! Map<String, Object?>) {
    _fail('${file.path} must contain a JSON object');
  }
  final repository = decoded['repository'];
  final commit = decoded['commit'];
  if (repository is! String ||
      !RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
    _fail('${file.path}: repository must be "owner/name"');
  }
  if (commit is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
    _fail('${file.path}: commit must be a full lowercase SHA-1');
  }
  return _Lock(repository, commit);
}

Future<Uint8List> _fetchTarball(_Lock lock) async {
  final uri = Uri.parse(
    '$_tarballHost/${lock.repository}/tar.gz/${lock.commit}',
  );
  stdout.writeln('Fetching $uri');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 60);
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'flasher_web-sync/1.0');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      final body = await response.transform(utf8.decoder).join();
      _fail('GET $uri returned ${response.statusCode}: ${body.trim()}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } on SocketException catch (e) {
    _fail('Could not download $uri: ${e.message}');
  } on HttpException catch (e) {
    _fail('Could not download $uri: ${e.message}');
  } on TlsException catch (e) {
    _fail('Could not download $uri: ${e.message}');
  } finally {
    client.close(force: true);
  }
}

Future<Uint8List> _archiveLocalCheckout(String source, String commit) async {
  final directory = Directory(source);
  if (!directory.existsSync()) _fail('--source is not a directory: $source');
  stdout.writeln('Reading $commit with git archive from $source');
  final result = await Process.run(
    'git',
    ['-C', directory.path, 'archive', '--format=tar', commit],
    stdoutEncoding: null,
    stderrEncoding: utf8,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    final stderr = (result.stderr as String).trim();
    _fail(
      'git archive $commit in $source failed: '
      '${stderr.isEmpty ? 'exit ${result.exitCode}' : stderr}',
    );
  }
  final bytes = result.stdout as List<int>;
  return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}

_Upstream _readUpstream(Uint8List archiveBytes, String commit) {
  final tarBytes =
      archiveBytes.length >= 2 &&
          archiveBytes[0] == 0x1f &&
          archiveBytes[1] == 0x8b
      ? GZipDecoder().decodeBytes(archiveBytes, verify: true)
      : archiveBytes;
  final Archive archive;
  try {
    archive = TarDecoder().decodeBytes(tarBytes, verify: true);
  } on ArchiveException catch (e) {
    _fail('Upstream archive is not a readable tar: ${e.message}');
  }

  final prefix = 'Flasher_Builder-$commit/';
  final files = <String, Uint8List>{};
  for (final entry in archive.files) {
    if (entry.isDirectory) continue;
    if (entry.isSymbolicLink) {
      _fail(
        'Upstream archive has a symlink, which is unsupported: ${entry.name}',
      );
    }
    var name = entry.name.replaceAll('\\', '/');
    if (name.startsWith(prefix)) {
      name = name.substring(prefix.length);
    } else if (name.startsWith('./')) {
      name = name.substring(2);
    }
    if (name.isEmpty || name.endsWith('/')) continue;
    if (name.split('/').any((part) => part == '..' || part.isEmpty)) {
      _fail('Unsafe path in upstream archive: ${entry.name}');
    }
    final bytes = entry.readBytes();
    if (bytes == null) _fail('Upstream archive entry has no data: $name');
    files[name] = bytes;
  }
  return _Upstream(files);
}

void _writeSnapshot(Directory out, _Upstream upstream, _Lock lock) {
  out.createSync(recursive: true);

  final tables = _parseTables(
    upstream.require('.github/workflows/build_tools.yml'),
  );
  final nativePipeline = utf8.decode(upstream.require('flasher_builder/native_pipeline.py'));
  final superParts = RegExp(r"SUPER_PARTS\s*=\s*\(([\s\S]*?)\)").firstMatch(nativePipeline);
  if (superParts == null) _fail('native_pipeline.py has no SUPER_PARTS tuple');
  final names = RegExp(r"'([a-z0-9_]+)'").allMatches(superParts.group(1)!)
      .map((match) => match.group(1)!).toList();
  if (names.isEmpty || names.toSet().length != names.length) _fail('Invalid SUPER_PARTS');
  tables['super_parts'] = names;
  _writeBytes(
    File(_join(out.path, 'tables.json')),
    Uint8List.fromList(
      utf8.encode(
        '${const JsonEncoder.withIndent('  ').convert({'commit': lock.commit, ...tables})}\n',
      ),
    ),
  );
  _writeBytes(
    File(_join(out.path, 'bloat-manifest.json')),
    upstream.require('bloat/assets-manifest.json'),
  );
  _writeBytes(
    File(_join(out.path, 'README.md')),
    upstream.require('README.md'),
  );

  final templates = <String, List<_ZipEntry>>{};
  final platformTools = <_ZipEntry>[];
  for (final entry in upstream.files.entries) {
    final path = entry.key;
    if (path.startsWith('flasher_scripts/')) {
      final relative = path.substring('flasher_scripts/'.length);
      final slash = relative.indexOf('/');
      if (slash <= 0) continue;
      final device = relative.substring(0, slash);
      templates
          .putIfAbsent(device, () => [])
          .add(_ZipEntry(relative.substring(slash + 1), entry.value));
    } else if (path.startsWith('Platform-Tools/')) {
      final relative = path.substring('Platform-Tools/'.length);
      if (relative.isEmpty) continue;
      platformTools.add(_ZipEntry(relative, entry.value));
    }
  }
  if (templates.isEmpty) _fail('Upstream has no flasher_scripts templates');
  if (platformTools.isEmpty) _fail('Upstream has no Platform-Tools files');

  final templateDir = Directory(_join(out.path, 'templates'))..createSync();
  final devices = templates.keys.toList()..sort();
  for (final device in devices) {
    _writeZip(File(_join(templateDir.path, '$device.zip')), templates[device]!);
  }
  _writeZip(File(_join(out.path, 'platform-tools.zip')), platformTools);
}

Map<String, Object?> _parseTables(Uint8List workflowBytes) {
  final text = utf8.decode(workflowBytes);
  final marker = 'declare -A DEV_MAP=(';
  final start = text.indexOf(marker);
  if (start < 0) _fail('build_tools.yml has no DEV_MAP table');
  final devBody = text.substring(start + marker.length);
  final end = devBody.indexOf(')');
  if (end < 0) _fail('build_tools.yml has an unterminated DEV_MAP table');

  final devices = <String, String>{};
  for (final match in RegExp(
    r'\["([^"]+)"\]="([^"]+)"',
  ).allMatches(devBody.substring(0, end))) {
    devices[match.group(1)!] = match.group(2)!;
  }

  final regionSizes = <String, List<int>>{};
  for (final match in RegExp(r'\["([^"]+)"\]="(\d+) (\d+)"').allMatches(text)) {
    regionSizes[match.group(1)!] = [
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
  }

  final builders = <String, List<String>>{};
  for (final match in RegExp(
    r'BUILDER_MAP\["([^"]+)"\]="([^"]+)"',
  ).allMatches(text)) {
    final key = match.group(1)!.split('|');
    if (key.length != 3) {
      _fail('build_tools.yml has a builder key that is not type|device|region');
    }
    // Catalog stores builders in a dict, so a repeated key keeps its first
    // position and its last value.
    builders[key.join('|')] = [key[0], key[1], key[2], '${match.group(2)!}.sh'];
  }

  if (devices.isEmpty || builders.isEmpty) {
    _fail('The workflow device/builder tables could not be read.');
  }
  return {
    'devices': devices,
    'region_sizes': regionSizes,
    'builders': builders.values.toList(),
  };
}

class _ZipEntry {
  _ZipEntry(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

void _writeZip(File target, List<_ZipEntry> entries) {
  final sorted = [...entries]..sort((a, b) => a.name.compareTo(b.name));
  final archive = Archive();
  for (final entry in sorted) {
    final file = ArchiveFile.bytes(entry.name, entry.bytes)
      ..mode = _zipMode(entry.name, entry.bytes)
      ..compression = CompressionType.deflate
      ..compressionLevel = _deflateLevel;
    archive.add(file);
  }
  final encoded = ZipEncoder().encodeBytes(
    archive,
    level: _deflateLevel,
    modified: DateTime.fromMillisecondsSinceEpoch(0),
  );
  _writeBytes(target, _markUnixHost(encoded));
}

/// ZipEncoder writes MS-DOS as the creating host, which hides [ArchiveFile]
/// modes from tools that follow `version made by`. Upstream package() sets
/// `create_system = 3`, so mark each central directory entry as Unix.
Uint8List _markUnixHost(Uint8List zip) {
  final data = ByteData.sublistView(zip);
  var eocd = zip.length - 22;
  while (eocd >= 0 && data.getUint32(eocd, Endian.little) != 0x06054b50) {
    eocd--;
  }
  if (eocd < 0) _fail('Encoded ZIP has no end of central directory');
  final count = data.getUint16(eocd + 10, Endian.little);
  var offset = data.getUint32(eocd + 16, Endian.little);
  if (count == 0xffff || offset == 0xffffffff) {
    _fail('Encoded ZIP unexpectedly needs ZIP64');
  }
  for (var index = 0; index < count; index++) {
    if (data.getUint32(offset, Endian.little) != 0x02014b50) {
      _fail('Encoded ZIP has a damaged central directory');
    }
    final nameLength = data.getUint16(offset + 28, Endian.little);
    final extraLength = data.getUint16(offset + 30, Endian.little);
    final commentLength = data.getUint16(offset + 32, Endian.little);
    // version made by: Unix in the high byte, the ZIP spec version in the low.
    zip[offset + 5] = 3;
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return zip;
}

/// Upstream package()'s rule: scripts and known launchers, plus ELF images
/// (except .img/.zip, whose header is not executable code).
int _zipMode(String name, Uint8List bytes) {
  final base = name.substring(name.lastIndexOf('/') + 1);
  final dot = base.lastIndexOf('.');
  final suffix = dot > 0 ? base.substring(dot) : '';
  var executable = suffix == '.sh' || _executableNames.contains(base);
  if (suffix != '.img' &&
      suffix != '.zip' &&
      bytes.length >= 4 &&
      bytes[0] == 0x7f &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x4c &&
      bytes[3] == 0x46) {
    executable = true;
  }
  return executable ? _modeExecutable : _modeFile;
}

void _writeBytes(File file, Uint8List bytes) {
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes, flush: true);
}

String _join(String a, String b) => a.endsWith('/') ? '$a$b' : '$a/$b';

String _absolute(String path) {
  final file = File(path).absolute;
  return file.path;
}

Never _fail(String message) {
  stderr.writeln('sync_upstream: $message');
  exit(1);
}
