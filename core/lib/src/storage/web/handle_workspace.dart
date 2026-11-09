import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../contracts.dart';
import '../paths.dart';
import 'blob_source.dart';
import 'handle_sink.dart';
import 'interop.dart';

/// A [Workspace] over a browser `FileSystemDirectoryHandle`.
///
/// [directoryHandle] is either OPFS's root (`navigator.storage.getDirectory()`)
/// or a directory the user picked with the File System Access API. The same
/// object works in the page and in a Web Worker.
///
/// Files are written through [HandleSink], which prefers a worker's
/// `createSyncAccessHandle()` and falls back to a writable stream. `move` uses
/// the browser's own `FileSystemHandle.move()` where it exists (OPFS files in
/// Chromium) and falls back to a copy followed by a delete because File System
/// Access has no portable rename.
final class HandleWorkspace implements Workspace {
  HandleWorkspace(JSObject directoryHandle)
    : _root = directoryHandle as web.FileSystemDirectoryHandle;

  /// The workspace at the origin private file system's root.
  static Future<HandleWorkspace> opfs() async =>
      HandleWorkspace(await opfsRoot());

  final web.FileSystemDirectoryHandle _root;

  @override
  Future<ByteSink> create(String path) async {
    final normalized = normalizeWorkspacePath(path);
    final handle = await _file(normalized, create: true);
    return HandleSink.open(handle);
  }

  @override
  Future<ByteSink> update(String path) async {
    final normalized = normalizeWorkspacePath(path);
    final handle = await _file(normalized, create: true);
    return HandleSink.open(handle, keepExisting: true);
  }

  @override
  Future<ByteSource> open(String path) async {
    final normalized = normalizeWorkspacePath(path);
    final handle = await _file(normalized, create: false);
    return BlobSource(await handle.getFile().toDart);
  }

  @override
  Future<bool> exists(String path) async {
    final normalized = normalizeWorkspacePath(path, allowRoot: true);
    final type = await _type(normalized);
    return type != null;
  }

  @override
  Future<int> size(String path) async {
    final normalized = normalizeWorkspacePath(path);
    final handle = await _file(normalized, create: false);
    final file = await handle.getFile().toDart;
    return file.size;
  }

  @override
  Future<List<String>> list(String dir, {bool recursive = false}) async {
    final normalized = normalizeWorkspacePath(dir, allowRoot: true);
    final directory = await _directory(normalized, create: false);
    final found = <String>[];
    await _walk(directory, normalized, recursive, found);
    found.sort();
    return found;
  }

  @override
  Future<void> move(String from, String to) async {
    final source = normalizeWorkspacePath(from);
    final destination = normalizeWorkspacePath(to);
    if (source == destination) return;
    if (source.startsWith('$destination$workspaceSeparator')) {
      throw ArgumentError.value(to, 'to', 'must not contain $from');
    }

    final sourceType = await _type(source);
    if (sourceType == null) {
      throw StateError('no such entry: $from');
    }
    if (sourceType == 'directory' &&
        destination.startsWith('$source$workspaceSeparator')) {
      throw ArgumentError.value(to, 'to', 'must not be inside $from');
    }
    final destinationType = await _type(destination);
    if (sourceType == 'file' && destinationType == 'directory') {
      throw StateError('destination is a directory: $to');
    }

    await delete(destination);
    final parent = await _directory(
      parentWorkspacePath(destination),
      create: true,
    );
    final name = baseWorkspacePath(destination);

    if (sourceType == 'file') {
      final sourceHandle = await _file(source, create: false);
      if (await _nativeMove(sourceHandle, parent, name, source, destination)) {
        return;
      }
      final blob = await sourceHandle.getFile().toDart;
      final target = await parent
          .getFileHandle(name, web.FileSystemGetFileOptions(create: true))
          .toDart;
      final writable = await target.createWritable().toDart;
      try {
        await writable.write(blob).toDart;
      } finally {
        await writable.close().toDart;
      }
      await _removeEntry(source);
      return;
    }

    final sourceDirectory = await _directory(source, create: false);
    if (await _nativeMove(
      sourceDirectory,
      parent,
      name,
      source,
      destination,
    )) {
      return;
    }
    final targetDirectory = await parent
        .getDirectoryHandle(
          name,
          web.FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;
    await _copyDirectory(sourceDirectory, targetDirectory);
    await _removeEntry(source);
  }

  @override
  Future<void> delete(String path) async {
    final normalized = normalizeWorkspacePath(path);
    if (await _type(normalized) == null) return;
    await _removeEntry(normalized);
  }

  /// Renames [handle] into [parent] as [name] with the browser's own `move()`.
  ///
  /// Returns false when the browser has no `move` (package:web does not bind
  /// it) or refuses it, for example on the page or in a picked directory, so
  /// the caller copies instead. A refused call that did move the entry leaves
  /// no source behind; that is reported as success so it is not copied onto
  /// itself.
  Future<bool> _nativeMove(
    web.FileSystemHandle handle,
    web.FileSystemDirectoryHandle parent,
    String name,
    String source,
    String destination,
  ) async {
    if (!hasMethod(handle, 'move')) return false;
    try {
      await handle
          .callMethod<JSPromise<JSAny?>>('move'.toJS, parent, name.toJS)
          .toDart;
      return true;
    } on Object {
      return await _type(source) == null && await _type(destination) != null;
    }
  }

  Future<web.FileSystemDirectoryHandle> _directory(
    String normalized, {
    required bool create,
  }) async {
    var directory = _root;
    if (normalized.isEmpty) return directory;
    for (final part in normalized.split(workspaceSeparator)) {
      directory = await directory
          .getDirectoryHandle(
            part,
            web.FileSystemGetDirectoryOptions(create: create),
          )
          .toDart;
    }
    return directory;
  }

  Future<web.FileSystemFileHandle> _file(
    String normalized, {
    required bool create,
  }) async {
    final parent = await _directory(
      parentWorkspacePath(normalized),
      create: create,
    );
    return parent
        .getFileHandle(
          baseWorkspacePath(normalized),
          web.FileSystemGetFileOptions(create: create),
        )
        .toDart;
  }

  Future<String?> _type(String normalized) async {
    if (normalized.isEmpty) return 'directory';
    try {
      await _file(normalized, create: false);
      return 'file';
    } on Object {
      // Not a file; it may be a directory.
    }
    try {
      await _directory(normalized, create: false);
      return 'directory';
    } on Object {
      return null;
    }
  }

  Future<void> _walk(
    web.FileSystemDirectoryHandle directory,
    String prefix,
    bool recursive,
    List<String> found,
  ) async {
    for (final handle in await directoryEntries(directory)) {
      final path = joinWorkspacePath(prefix, handle.name);
      if (handle.kind == 'file') {
        found.add(path);
      } else if (recursive) {
        await _walk(handle as web.FileSystemDirectoryHandle, path, true, found);
      }
    }
  }

  Future<void> _copyDirectory(
    web.FileSystemDirectoryHandle source,
    web.FileSystemDirectoryHandle destination,
  ) async {
    for (final handle in await directoryEntries(source)) {
      if (handle.kind == 'file') {
        final file = await (handle as web.FileSystemFileHandle)
            .getFile()
            .toDart;
        final target = await destination
            .getFileHandle(
              handle.name,
              web.FileSystemGetFileOptions(create: true),
            )
            .toDart;
        final writable = await target.createWritable().toDart;
        try {
          await writable.write(file).toDart;
        } finally {
          await writable.close().toDart;
        }
      } else {
        final child = await destination
            .getDirectoryHandle(
              handle.name,
              web.FileSystemGetDirectoryOptions(create: true),
            )
            .toDart;
        await _copyDirectory(handle as web.FileSystemDirectoryHandle, child);
      }
    }
  }

  Future<void> _removeEntry(String normalized) async {
    final parent = await _directory(
      parentWorkspacePath(normalized),
      create: false,
    );
    final name = baseWorkspacePath(normalized);
    final type = await _type(normalized);
    if (type == 'directory') {
      await parent
          .removeEntry(name, web.FileSystemRemoveOptions(recursive: true))
          .toDart;
    } else {
      await parent.removeEntry(name).toDart;
    }
  }
}
