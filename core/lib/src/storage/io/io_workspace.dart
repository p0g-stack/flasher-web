import 'dart:io';

import '../contracts.dart';
import '../paths.dart';
import 'file_sink.dart';
import 'file_source.dart';

/// A [Workspace] on a local directory, for the CLI, desktop and tests.
///
/// Paths are validated by [normalizeWorkspacePath] and every existing entry is
/// checked against the root's resolved path, so `..` and a symlink pointing
/// outside cannot reach the host filesystem. [move] renames where it can: a
/// file moved onto an existing file is one atomic rename on POSIX. Across
/// filesystems it copies to a temporary file beside the destination and
/// renames that into place, so a reader never sees a partial destination.
final class IoWorkspace implements Workspace {
  IoWorkspace(Directory root) : _root = root;

  /// Creates a workspace rooted at [path].
  factory IoWorkspace.path(String path) => IoWorkspace(Directory(path));

  final Directory _root;
  String? _realRoot;
  int _tempCounter = 0;

  /// The workspace's root directory.
  Directory get root => _root;

  @override
  Future<ByteSink> create(String path) async {
    final normalized = normalizeWorkspacePath(path);
    await _root.create(recursive: true);
    final target = await _guard(normalized);
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      throw FileSystemException('Is a directory', target);
    }
    if (type == FileSystemEntityType.link) {
      throw FileSystemException('Is a symbolic link', target);
    }
    return FileSink.open(File(target));
  }

  @override
  Future<ByteSource> open(String path) async {
    final normalized = normalizeWorkspacePath(path);
    final target = await _guard(normalized);
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      throw FileSystemException('Is a directory', target);
    }
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException('File does not exist', target);
    }
    if (type == FileSystemEntityType.link) {
      throw FileSystemException('Is a symbolic link', target);
    }
    return FileSource.open(File(target));
  }

  @override
  Future<bool> exists(String path) async {
    final normalized = normalizeWorkspacePath(path, allowRoot: true);
    if (normalized.isEmpty) return _root.exists();
    final type = await FileSystemEntity.type(_target(normalized));
    return type != FileSystemEntityType.notFound;
  }

  @override
  Future<int> size(String path) async {
    final normalized = normalizeWorkspacePath(path);
    final target = await _guard(normalized);
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('Not a file', target);
    }
    return File(target).length();
  }

  @override
  Future<List<String>> list(String dir, {bool recursive = false}) async {
    final normalized = normalizeWorkspacePath(dir, allowRoot: true);
    final target = Directory(await _guard(normalized, allowRoot: true));
    if (!await target.exists()) {
      throw FileSystemException('Directory does not exist', target.path);
    }
    final absolute = target.absolute;
    final base = _root.absolute.path;
    final found = <String>[];
    await for (final entity in absolute.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      var relative = entity.path.substring(base.length);
      while (relative.startsWith(Platform.pathSeparator)) {
        relative = relative.substring(1);
      }
      found.add(relative.replaceAll(r'\', '/'));
    }
    found.sort();
    return found;
  }

  @override
  Future<void> move(String from, String to) async {
    final source = normalizeWorkspacePath(from);
    final destination = normalizeWorkspacePath(to);
    if (source == destination) return;
    if (source.startsWith('$destination/')) {
      throw ArgumentError.value(to, 'to', 'must not contain $from');
    }
    await _root.create(recursive: true);

    final sourcePath = await _guard(source);
    final destinationPath = await _guard(destination);
    final sourceType = await FileSystemEntity.type(
      sourcePath,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.notFound) {
      throw FileSystemException('File does not exist', sourcePath);
    }
    if (sourceType == FileSystemEntityType.directory &&
        destination.startsWith('$source/')) {
      throw ArgumentError.value(to, 'to', 'must not be inside $from');
    }

    await Directory(File(destinationPath).parent.path).create(recursive: true);
    final destinationType = await FileSystemEntity.type(
      destinationPath,
      followLinks: false,
    );

    if (sourceType == FileSystemEntityType.directory) {
      if (destinationType != FileSystemEntityType.notFound) {
        await _deleteAt(destinationPath, destinationType);
      }
      try {
        await Directory(sourcePath).rename(destinationPath);
      } on FileSystemException catch (error) {
        if (!_isCrossDevice(error)) rethrow;
        await _copyDirectory(sourcePath, destinationPath);
        await Directory(sourcePath).delete(recursive: true);
      }
      return;
    }

    if (destinationType == FileSystemEntityType.directory) {
      throw FileSystemException('Is a directory', destinationPath);
    }
    try {
      await File(sourcePath).rename(destinationPath);
    } on FileSystemException catch (error) {
      if (!_isCrossDevice(error) || sourceType == FileSystemEntityType.link) {
        rethrow;
      }
      await _copyFileAcross(sourcePath, destinationPath);
    }
  }

  @override
  Future<void> delete(String path) async {
    final normalized = normalizeWorkspacePath(path);
    final target = await _guard(normalized);
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    await _deleteAt(target, type);
  }

  String _target(String normalized) {
    if (normalized.isEmpty) return _root.path;
    final base = _root.path;
    if (base.endsWith(Platform.pathSeparator)) return '$base$normalized';
    return '$base${Platform.pathSeparator}$normalized';
  }

  Future<String> _guard(String normalized, {bool allowRoot = false}) async {
    final target = _target(normalized);
    if (normalized.isEmpty) {
      if (!allowRoot) throw ArgumentError.value(normalized, 'path');
      return target;
    }
    if (!await _root.exists()) return target;
    final realRoot = await _realRootPath();
    final existing = await _nearestExisting(target);
    final real = await existing.resolveSymbolicLinks();
    if (!_inside(realRoot, real)) {
      throw ArgumentError.value(
        normalized,
        'path',
        'escapes the workspace root',
      );
    }
    return target;
  }

  Future<String> _realRootPath() async {
    final cached = _realRoot;
    if (cached != null) return cached;
    try {
      return _realRoot = await _root.resolveSymbolicLinks();
    } on FileSystemException {
      return _root.absolute.path;
    }
  }

  static bool _inside(String realRoot, String candidate) {
    if (candidate == realRoot) return true;
    final prefix = realRoot.endsWith(Platform.pathSeparator)
        ? realRoot
        : '$realRoot${Platform.pathSeparator}';
    return candidate.startsWith(prefix);
  }

  static Future<FileSystemEntity> _nearestExisting(String target) async {
    var path = target;
    while (true) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        return _entity(path, type);
      }
      final parent = File(path).parent.path;
      if (parent == path) return Directory(path);
      path = parent;
    }
  }

  static FileSystemEntity _entity(String path, FileSystemEntityType type) {
    return switch (type) {
      FileSystemEntityType.directory => Directory(path),
      FileSystemEntityType.link => Link(path),
      _ => File(path),
    };
  }

  static Future<void> _deleteAt(String path, FileSystemEntityType type) async {
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      case FileSystemEntityType.link:
        await Link(path).delete();
      case FileSystemEntityType.notFound:
        return;
      case FileSystemEntityType.file:
        await File(path).delete();
      default:
        throw FileSystemException('Unsupported file type', path);
    }
  }

  static bool _isCrossDevice(FileSystemException error) {
    final code = error.osError?.errorCode;
    return code == 18 || code == 17;
  }

  Future<void> _copyFileAcross(String source, String destination) async {
    final parent = File(destination).parent;
    await parent.create(recursive: true);
    final temp = File(
      '$destination.move-${DateTime.now().microsecondsSinceEpoch}-'
      '${_tempCounter++}',
    );
    try {
      await File(source).copy(temp.path);
      await temp.rename(destination);
      await File(source).delete();
    } on Object {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  static Future<void> _copyDirectory(String source, String destination) async {
    await Directory(destination).create(recursive: true);
    final base = Directory(source).absolute.path;
    await for (final entity in Directory(
      source,
    ).absolute.list(recursive: true, followLinks: false)) {
      var relative = entity.path.substring(base.length);
      while (relative.startsWith(Platform.pathSeparator)) {
        relative = relative.substring(1);
      }
      final target = '$destination${Platform.pathSeparator}$relative';
      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is Link) {
        await Link(target).create(await entity.target());
      } else if (entity is File) {
        await Directory(File(target).parent.path).create(recursive: true);
        await entity.copy(target);
      }
    }
  }
}
