/// Bounded, read-only access to a finished flasher package.
///
/// A job stores either a folder (the build's `--no-zip` output) or a ZIP.
/// A ZIP is read through its central directory and a streaming inflater, so
/// preparing and flashing never buffer a whole image or decompress the whole
/// archive to list it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../native/native.dart';
import '../rust/api/zip.dart' as rust_zip;
import '../storage/storage.dart';
import 'model.dart';
import 'package_index.dart';

/// A random-access image source. [read] is for small headers; images are
/// streamed through [cursor].
abstract interface class FlashSource {
  int get length;

  Future<Uint8List> read(int offset, int length);

  /// Sequential bytes, each chunk at most [chunkSize].
  Stream<Uint8List> stream({int chunkSize = 1 << 20});

  /// A forward-only cursor over the whole image. Offsets must not decrease.
  Future<FlashCursor> cursor();

  Future<void> close();
}

/// Forward-only bounded reads. A sparse plan revisits data in file order.
abstract interface class FlashCursor {
  Future<Uint8List> readExact(int length);

  /// Advances to [offset]; [offset] must be at or after the current position.
  Future<void> skipTo(int offset);

  Future<void> close();
}

/// A package whose `build.json` and entries are known without opening every
/// image. Implementations exist for a folder and a ZIP; tests provide their
/// own.
abstract interface class FlashPackage {
  PackageIndex get index;

  Map<String, Object?> get buildJson;

  String get format;

  Future<int> size(String path);

  Future<FlashSource> open(String path);

  /// A stable description of the package's entries and metadata. A
  /// confirmation token binds this snapshot so a changed job is refused.
  Future<Map<String, Object?>> snapshot();
}

/// Opens the package named by [buildJson] in [job].
Future<FlashPackage> openFlashPackage(
  Workspace workspace,
  String job,
  Map<String, Object?> buildJson,
) async {
  final format = buildJson['output_format'];
  final artifact = buildJson['artifact'];
  if (artifact is! String || artifact.isEmpty) {
    throw const FlashException('build.json has no artifact name.');
  }
  final path = joinWorkspacePath(job, artifact);
  if (!await workspace.exists(path)) {
    throw FlashException('The job artifact is missing: $path');
  }
  if (format == 'zip') {
    return ZipFlashPackage.load(workspace, path, buildJson);
  }
  if (format == 'folder') {
    return FolderFlashPackage.load(workspace, path, buildJson);
  }
  throw FlashException('build.json has an unknown output_format: $format');
}

/// Reads `job/build.json` with a small bound.
Future<Map<String, Object?>> readJobManifest(
  Workspace workspace,
  String job,
) async {
  final path = joinWorkspacePath(job, 'build.json');
  if (!await workspace.exists(path)) {
    throw FlashException('The job has no build.json: $path');
  }
  final source = await workspace.open(path);
  try {
    if (source.length > 1 << 20) {
      throw const FlashException('build.json is too large to be a manifest.');
    }
    final bytes = await source.read(0, source.length);
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FlashException('build.json is not a JSON object.');
    }
    return Map<String, Object?>.from(decoded);
  } finally {
    await closeByteSource(source);
  }
}

/// A folder package: `<job>/<artifact>/...`.
final class FolderFlashPackage implements FlashPackage {
  FolderFlashPackage._(this._workspace, this._root, this.buildJson, this.index);

  static Future<FolderFlashPackage> load(
    Workspace workspace,
    String root,
    Map<String, Object?> buildJson,
  ) async {
    final paths = await workspace.list(root, recursive: true);
    final prefix = '$root/';
    final entries = <String>[
      for (final path in paths)
        if (path.startsWith(prefix)) path.substring(prefix.length),
    ];
    return FolderFlashPackage._(
      workspace,
      root,
      Map.unmodifiable(buildJson),
      PackageIndex.fromEntries(entries, buildJson: buildJson),
    );
  }

  final Workspace _workspace;
  final String _root;

  @override
  final Map<String, Object?> buildJson;

  @override
  final PackageIndex index;

  @override
  String get format => 'folder';

  String _path(String path) => joinWorkspacePath(_root, path);

  @override
  Future<int> size(String path) async {
    if (!index.has(path)) {
      throw FlashException('The package is missing $path.');
    }
    return _workspace.size(_path(path));
  }

  @override
  Future<FlashSource> open(String path) async {
    if (!index.has(path)) {
      throw FlashException('The package is missing $path.');
    }
    final source = await _workspace.open(_path(path));
    return _FolderSource(source);
  }

  @override
  Future<Map<String, Object?>> snapshot() async {
    final sizes = <String, int>{};
    for (final path in index.entries) {
      sizes[path] = await _workspace.size(_path(path));
    }
    return {
      'format': format,
      'root': _root,
      'entries': sizes,
      'buildJson': buildJson,
    };
  }
}

final class _FolderSource implements FlashSource {
  _FolderSource(this._source);

  final ByteSource _source;

  @override
  int get length => _source.length;

  @override
  Future<Uint8List> read(int offset, int length) =>
      _source.read(offset, length);

  @override
  Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    var offset = 0;
    while (offset < length) {
      final size = math.min(chunkSize, length - offset);
      yield await _source.read(offset, size);
      offset += size;
    }
  }

  @override
  Future<FlashCursor> cursor() async => _FolderCursor(_source);

  @override
  Future<void> close() async {
    await closeByteSource(_source);
  }
}

final class _FolderCursor implements FlashCursor {
  _FolderCursor(this._source);

  final ByteSource _source;
  var _position = 0;

  @override
  Future<Uint8List> readExact(int length) async {
    if (length < 0 || _position + length > _source.length) {
      throw RangeError.range(
        _position + length,
        _position,
        _source.length,
        'offset + length',
      );
    }
    final bytes = await _source.read(_position, length);
    _position += length;
    return bytes;
  }

  @override
  Future<void> skipTo(int offset) async {
    if (offset < _position) {
      throw StateError('A flash cursor cannot move backwards.');
    }
    if (offset > _source.length) {
      throw RangeError.range(offset, _position, _source.length, 'offset');
    }
    _position = offset;
  }

  @override
  Future<void> close() async {}
}

/// A ZIP package. The central directory is read once; each entry is
/// decompressed only while it is being inspected or flashed.
final class ZipFlashPackage implements FlashPackage {
  ZipFlashPackage._(
    this._workspace,
    this._archivePath,
    this.buildJson,
    this.index,
    this._entries,
  );

  static Future<ZipFlashPackage> load(
    Workspace workspace,
    String archivePath,
    Map<String, Object?> buildJson,
  ) async {
    if (!await loadNative()) {
      throw const FlashException(
        "This place does not have flasher_web's native library.",
      );
    }
    final source = await workspace.open(archivePath);
    var entries = <String, rust_zip.ZipEntry>{};
    try {
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
      entries = {
        for (final entry in parsed)
          if (!entry.name.endsWith('/')) entry.name: entry,
      };
    } finally {
      await closeByteSource(source);
    }
    final index = PackageIndex.fromEntries(entries.keys, buildJson: buildJson);
    return ZipFlashPackage._(
      workspace,
      archivePath,
      Map.unmodifiable(buildJson),
      index,
      Map.unmodifiable(entries),
    );
  }

  final Workspace _workspace;
  final String _archivePath;
  final Map<String, rust_zip.ZipEntry> _entries;

  @override
  final Map<String, Object?> buildJson;

  @override
  final PackageIndex index;

  @override
  String get format => 'zip';

  rust_zip.ZipEntry _entry(String path) {
    final entry = _entries[path];
    if (entry == null) {
      throw FlashException('The package is missing $path.');
    }
    return entry;
  }

  @override
  Future<int> size(String path) async => _entry(path).uncompressedSize.toInt();

  @override
  Future<FlashSource> open(String path) async {
    final entry = _entry(path);
    final source = await _workspace.open(_archivePath);
    try {
      final header = await source.read(entry.localHeaderOffset.toInt(), 30);
      final dataOffset = rust_zip
          .zipDataOffset(
            localHeader30Bytes: header,
            localHeaderOffset: entry.localHeaderOffset,
          )
          .toInt();
      return _ZipEntrySource(
        workspace: _workspace,
        archivePath: _archivePath,
        dataOffset: dataOffset,
        compressedSize: entry.compressedSize.toInt(),
        length: entry.uncompressedSize.toInt(),
        crc32: entry.crc32,
        method: entry.method,
      );
    } finally {
      await closeByteSource(source);
    }
  }

  @override
  Future<Map<String, Object?>> snapshot() async {
    return {
      'format': format,
      'archive': _archivePath,
      'entries': {
        for (final entry in _entries.values)
          entry.name: {
            'bytes': entry.uncompressedSize.toString(),
            'compressed': entry.compressedSize.toString(),
            'crc32': entry.crc32,
            'method': entry.method,
          },
      },
      'buildJson': buildJson,
    };
  }
}

final class _ZipEntrySource implements FlashSource {
  _ZipEntrySource({
    required this.workspace,
    required this.archivePath,
    required this.dataOffset,
    required this.compressedSize,
    required this.length,
    required this.crc32,
    required this.method,
  });

  final Workspace workspace;
  final String archivePath;
  final int dataOffset;
  final int compressedSize;
  final int crc32;
  final int method;

  @override
  final int length;

  Future<ByteSource> _openArchive() => workspace.open(archivePath);

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || length < 0 || offset + length > this.length) {
      throw RangeError.range(
        offset + length,
        offset,
        this.length,
        'offset + length',
      );
    }
    if (method == 0) {
      final archive = await _openArchive();
      try {
        return await archive.read(dataOffset + offset, length);
      } finally {
        await closeByteSource(archive);
      }
    }
    // A small header read. The stream is still bounded; callers that need
    // image data use cursor() instead.
    final wanted = offset + length;
    final builder = BytesBuilder(copy: false);
    var got = 0;
    await for (final chunk in stream(
      chunkSize: math.min(1 << 20, math.max(1, wanted)),
    )) {
      final end = got + chunk.length;
      if (end <= offset) {
        got = end;
        continue;
      }
      final from = math.max(0, offset - got);
      final to = math.min(chunk.length, wanted - got);
      if (to > from) builder.add(Uint8List.sublistView(chunk, from, to));
      got = end;
      if (got >= wanted) break;
    }
    final bytes = builder.takeBytes();
    if (bytes.length != length) {
      throw FlashException(
        'ZIP entry ended after ${offset + bytes.length} bytes; '
        'expected $length.',
      );
    }
    return bytes;
  }

  @override
  Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    final archive = await _openArchive();
    try {
      if (method == 0) {
        if (compressedSize != length) {
          throw const FlashException(
            'Stored ZIP entry has inconsistent sizes.',
          );
        }
        final checksum = rust_zip.ZipCrc32();
        var cursor = dataOffset;
        var left = length;
        while (left > 0) {
          final size = math.min(chunkSize, left);
          final bytes = await archive.read(cursor, size);
          checksum.update(bytes: bytes);
          if (left == size && checksum.finish() != crc32) {
            throw const FlashException('Stored ZIP entry CRC does not match.');
          }
          yield bytes;
          cursor += size;
          left -= size;
        }
        return;
      }
      if (method != 8) {
        throw FlashException('Unsupported ZIP compression method $method.');
      }
      final inflater = rust_zip.RawZipInflater(
        expectedSize: BigInt.from(length),
        expectedCrc: crc32,
      );
      var compressed = 0;
      var loaded = 0;
      var input = Uint8List(0);
      var inputOffset = 0;
      while (true) {
        if (inputOffset == input.length && loaded < compressedSize) {
          final take = math.min(64 * 1024, compressedSize - loaded);
          input = await archive.read(dataOffset + loaded, take);
          loaded += take;
          inputOffset = 0;
        }
        final chunk = inflater.decode(
          data: Uint8List.sublistView(input, inputOffset),
          maxOutput: math.min(1 << 20, math.max(1, chunkSize)),
        );
        compressed += chunk.consumed;
        inputOffset += chunk.consumed;
        if (chunk.finished && compressed != compressedSize) {
          throw FlashException('ZIP entry has trailing compressed bytes.');
        }
        if (chunk.bytes.isNotEmpty) yield chunk.bytes;
        if (chunk.finished) return;
        if (chunk.consumed == 0 && chunk.bytes.isEmpty) {
          throw const FlashException(
            'ZIP entry is truncated or made no progress.',
          );
        }
      }
    } finally {
      await closeByteSource(archive);
    }
  }

  @override
  Future<FlashCursor> cursor() async => _ZipCursor(this);

  @override
  Future<void> close() async {}
}

final class _ZipCursor implements FlashCursor {
  _ZipCursor(this._source);

  final _ZipEntrySource _source;
  StreamIterator<Uint8List>? _iterator;
  Uint8List _current = Uint8List(0);
  var _currentOffset = 0;
  var _position = 0;

  Future<void> _ensure() async {
    _iterator ??= StreamIterator<Uint8List>(_source.stream());
  }

  Future<bool> _advance() async {
    await _ensure();
    if (!await _iterator!.moveNext()) {
      _current = Uint8List(0);
      _currentOffset = 0;
      return false;
    }
    _current = _iterator!.current;
    _currentOffset = 0;
    return true;
  }

  @override
  Future<Uint8List> readExact(int length) async {
    if (length >= 0 && _current.length - _currentOffset >= length) {
      final bytes = Uint8List.sublistView(
        _current,
        _currentOffset,
        _currentOffset + length,
      );
      _currentOffset += length;
      _position += length;
      return bytes;
    }
    final out = BytesBuilder(copy: false);
    var left = length;
    while (left > 0) {
      if (_currentOffset >= _current.length) {
        if (!await _advance()) {
          throw FlashException('ZIP entry ended before $length bytes.');
        }
        if (_current.isEmpty) continue;
      }
      final take = math.min(left, _current.length - _currentOffset);
      out.add(
        Uint8List.sublistView(_current, _currentOffset, _currentOffset + take),
      );
      _currentOffset += take;
      _position += take;
      left -= take;
    }
    return out.takeBytes();
  }

  @override
  Future<void> skipTo(int offset) async {
    if (offset < _position) {
      throw StateError('A flash cursor cannot move backwards.');
    }
    var left = offset - _position;
    while (left > 0) {
      if (_currentOffset >= _current.length) {
        if (!await _advance()) {
          throw FlashException('ZIP entry ended before offset $offset.');
        }
        if (_current.isEmpty) continue;
      }
      final take = math.min(left, _current.length - _currentOffset);
      _currentOffset += take;
      _position += take;
      left -= take;
    }
  }

  @override
  Future<void> close() async {
    await _iterator?.cancel();
    _iterator = null;
  }
}
