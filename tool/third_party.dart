// Materializes every carried third-party patch series and points the
// workspace at the patched package.
//
// Usage, from the workspace root (tool/bootstrap.sh runs it before the second
// `flutter pub get`):
//   dart run tool/third_party.dart                 # every third_party/<name>/PIN
//   dart run tool/third_party.dart . file_picker   # one series, from a root
//
// For each series it fetches the pinned commit into
// <root>/.dart_tool/third_party/<name>-<commit12>, applies
// third_party/<name>/patches/*.patch in name order, and adds a
// `dependency_overrides` entry for the package the PIN names, the way
// squadron_process's squadron_patch does for Squadron. Re-running it restores
// the pinned tree and re-applies the series, so it is safe to repeat; a tree
// whose stamp still matches the PIN and the patch bytes is reused as is.
// Needs git.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The directory the series live in, relative to the root.
const _thirdParty = 'third_party';

/// The marker a materialized tree carries once its series is applied.
const _stampName = '.third_party.stamp';

Future<void> main(List<String> args) async {
  final positional = args.where((arg) => !arg.startsWith('-')).toList();
  final root = positional.isEmpty
      ? Directory.current.absolute
      : Directory(positional.first).absolute;
  final wanted = positional.skip(1).toSet();
  final third = Directory('${root.path}/$_thirdParty');
  if (!await third.exists()) _fail('${third.path} does not exist');

  final series = <Directory>[];
  await for (final entry in third.list()) {
    if (entry is! Directory) continue;
    if (!File('${entry.path}/PIN').existsSync()) continue;
    if (wanted.isNotEmpty && !wanted.contains(_name(entry))) continue;
    series.add(entry);
  }
  if (series.isEmpty) {
    _fail(
      wanted.isEmpty
          ? '${third.path} holds no series (a directory needs a PIN)'
          : 'no series named ${wanted.join(', ')}',
    );
  }
  series.sort((a, b) => _name(a).compareTo(_name(b)));

  final overrides = File('${root.path}/pubspec_overrides.yaml');
  for (final dir in series) {
    final pin = await _readPin(File('${dir.path}/PIN'));
    final patches = _patches(dir);
    final src = await _materialize(root, dir, pin, patches);
    final pubspec = File('${src.path}/${pin['package']!}/pubspec.yaml');
    if (!await pubspec.exists()) {
      _fail('${pubspec.path} is not a package; check package= in the PIN');
    }
    final rel =
        '${src.path.substring(root.path.length + 1)}/${pin['package']!.trim()}';
    await _setOverride(overrides, await _packageName(pubspec), rel);
    stdout.writeln(
      '${_name(dir)} ${pin['commit']!.substring(0, 12)} + '
      '${patches.length} patch(es) at ${src.path}',
    );
  }
  stdout.writeln('updated ${overrides.path}; run flutter pub get');
}

String _name(FileSystemEntity entity) =>
    entity.uri.pathSegments.where((part) => part.isNotEmpty).last;

/// The PIN's `key=value` lines, ignoring comments and blank lines.
Future<Map<String, String>> _readPin(File file) async {
  final pin = <String, String>{};
  for (final line in await file.readAsLines()) {
    final at = line.indexOf('=');
    if (!line.startsWith('#') && at > 0) {
      pin[line.substring(0, at).trim()] = line.substring(at + 1).trim();
    }
  }
  for (final key in const ['repo', 'commit', 'package']) {
    if ((pin[key] ?? '').isEmpty) _fail('${file.path} has no $key=');
  }
  return pin;
}

/// The series' patches, in the order their names sort as.
List<File> _patches(Directory series) {
  final dir = Directory('${series.path}/patches');
  if (!dir.existsSync()) return const [];
  return dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// Checks out the PIN's commit at `<root>/.dart_tool/third_party/<name>-<c12>`
/// and applies [patches] to it, skipping both when the tree already carries
/// them.
Future<Directory> _materialize(
  Directory root,
  Directory series,
  Map<String, String> pin,
  List<File> patches,
) async {
  final commit = pin['commit']!;
  final src = Directory(
    '${root.path}/.dart_tool/third_party/${_name(series)}-'
    '${commit.substring(0, 12)}',
  );
  final stamp = File('${src.path}/$_stampName');
  final expected = '$commit\n${_fingerprint(patches)}\n';
  if (await stamp.exists() && await stamp.readAsString() == expected) {
    return src;
  }
  // A tree without a matching stamp is rebuilt from scratch, so an
  // interrupted run never leaves a half-applied series behind.
  if (await stamp.exists()) await stamp.delete();

  if (!await Directory('${src.path}/.git').exists()) {
    await src.create(recursive: true);
    await _git(['init', '-q'], src);
    await _git(['remote', 'add', 'origin', pin['repo']!], src);
  }
  await _git(['fetch', '-q', '--depth', '1', 'origin', commit], src);
  await _git(['checkout', '-q', '--force', '--detach', commit], src);
  await _git(['clean', '-q', '-fdx'], src);
  for (final patch in patches) {
    await _git(['apply', '--whitespace=nowarn', patch.path], src);
  }
  await stamp.writeAsString(expected);
  return src;
}

/// A 64-bit FNV-1a over the patch names and bytes, so a reused tree can be
/// shown to be the one these patches produce.
String _fingerprint(List<File> patches) {
  var hash = 0xcbf29ce484222325;
  for (final patch in patches) {
    final bytes = BytesBuilder()
      ..add(utf8.encode('${_name(patch)}:'))
      ..add(patch.readAsBytesSync());
    for (final byte in bytes.takeBytes()) {
      hash = (hash ^ byte) * 0x100000001b3;
    }
  }
  return hash.toUnsigned(64).toRadixString(16);
}

/// The `name:` of a package pubspec.
Future<String> _packageName(File pubspec) async {
  for (final line in await pubspec.readAsLines()) {
    if (line.startsWith('name:')) return line.substring(5).trim();
  }
  _fail('${pubspec.path} has no name');
}

/// Points [package] at [path] in [file]'s `dependency_overrides`, keeping the
/// entries already there and leaving the rest of the file untouched.
Future<void> _setOverride(File file, String package, String path) async {
  final text = await file.exists() ? await file.readAsString() : '';
  final lines = text.isEmpty ? <String>[] : text.split('\n').toList();
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();

  final header = lines.indexWhere(
    (line) => line.trimRight() == 'dependency_overrides:',
  );
  // The last line of the overrides mapping: every entry is indented, and the
  // block ends at the first line that is not.
  var end = header;
  if (header >= 0) {
    for (var i = header + 1; i < lines.length; i++) {
      if (!lines[i].startsWith('  ') || lines[i].trim().isEmpty) break;
      end = i;
    }
  }

  final key = RegExp('^  ${RegExp.escape(package)}:\\s*\$');
  var at = -1;
  for (var i = header + 1; i >= 0 && i <= end; i++) {
    if (key.hasMatch(lines[i])) {
      at = i;
      break;
    }
  }

  final pathLine = '    path: $path';
  if (at >= 0 && at < end && lines[at + 1].trimLeft().startsWith('path:')) {
    if (lines[at + 1].trimRight() != pathLine) lines[at + 1] = pathLine;
  } else if (at >= 0) {
    lines.insert(at + 1, pathLine);
  } else if (header >= 0) {
    lines.insertAll(end + 1, ['  $package:', pathLine]);
  } else {
    if (lines.isNotEmpty) lines.add('');
    lines.addAll(['dependency_overrides:', '  $package:', pathLine]);
  }
  await file.writeAsString('${lines.join('\n')}\n');
}

Future<void> _git(List<String> args, Directory dir) async {
  final result = await Process.run('git', ['-C', dir.path, ...args]);
  if (result.exitCode != 0) _fail('git ${args.join(' ')}: ${result.stderr}');
}

Never _fail(String message) {
  stderr.writeln('third_party: $message');
  exit(1);
}
