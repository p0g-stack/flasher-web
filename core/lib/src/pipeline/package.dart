/// Packages the staged flasher tree: `super.img`, ZIP or folder.
///
/// Port of `native_pipeline.pack_super` and `backend.package`. The super is
/// built from the images `build_images` staged in `result/Super`: the exact
/// LP geometry comes from the Rust `super_layout`, sparse source images are
/// expanded, and gaps and partition padding read as zero. In a ZIP the super
/// is streamed directly into its entry (deflate level 3, ZIP64) and never
/// touches the workspace as `super.img`; a folder receives `super.img` as a
/// sparse image, exactly like `lpmake --sparse`.
///
/// Rust must be loaded before calling [packageFlasher] (`loadNative()`).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../rust/api/lp.dart';
import '../rust/api/payload.dart' show Sha256Hasher;
import '../rust/api/sparse.dart';
import '../rust/api/zip_write.dart';
import '../storage/paths.dart'
    show baseWorkspacePath, joinWorkspacePath, normalizeWorkspacePath;
import '../storage/storage.dart';
import 'errors.dart';
import 'extract.dart' show superParts;

/// What [packageFlasher] produced.
final class PackageResult {
  const PackageResult({
    required this.artifact,
    required this.format,
    required this.sha256,
    required this.imageSha256,
  });

  /// Workspace path of the finished artifact: the ZIP or the folder.
  final String artifact;

  /// `zip` or `folder`.
  final String format;

  /// Lowercase SHA-256 of the ZIP; null for a folder.
  final String? sha256;

  /// SHA-256 of final packaged image bytes, after patches and super assembly.
  final Map<String, String> imageSha256;
}

/// Builds a ZIP or a folder from the staged flasher tree.
///
/// [result] is the staged tree (`result/`, with `result/Super/*.img` as the
/// super inputs); [destination] is the artifact path. With [zip] the output is
/// a ZIP at [destination] plus its `<destination>.sha256`; without it the tree
/// is moved to the [destination] directory and `super.img` is written there.
///
/// [superSize] is the physical super partition size. When it is given, a new
/// `super.img` is generated from `result/Super`; when it is null the tree is
/// packaged as it is (`super.img` included if the caller staged one).
/// [superSizeFile] also writes X9U's
/// `META-INF/com/google/android/super-size` with the physical super size
/// [superSize], matching `native_pipeline.build_images` (the parity target):
/// after `pack_super` it writes the `--device super:<size>` value, not the
/// generated sparse image's expanded length.
///
/// [emit] receives `{"type": "progress", "label", "done", "total"}` at most
/// every 64 MiB; [check] throws to cancel.
Future<PackageResult> packageFlasher(
  Workspace workspace,
  String result, {
  required String destination,
  required bool zip,
  int? superSize,
  bool superSizeFile = false,
  void Function(Map<String, Object?> event)? emit,
  void Function()? check,
}) async {
  final checkNow = check ?? () {};
  final root = normalizeWorkspacePath(result);
  final artifact = normalizeWorkspacePath(destination);
  if (superSizeFile && superSize == null) {
    throw ArgumentError.value(
      superSizeFile,
      'superSizeFile',
      'needs superSize',
    );
  }
  checkNow();

  _SuperPlan? plan;
  try {
    if (superSize != null) {
      plan = await _planSuper(
        workspace,
        joinWorkspacePath(root, 'Super'),
        superSize,
        check: checkNow,
      );
    }
    final PackageResult packaged;
    if (zip) {
      packaged = await _packageZip(
        workspace,
        root,
        artifact,
        plan,
        superSizeFile: superSizeFile,
        emit: emit,
        check: checkNow,
      );
    } else {
      packaged = await _packageFolder(
        workspace,
        root,
        artifact,
        plan,
        superSizeFile: superSizeFile,
        emit: emit,
        check: checkNow,
      );
    }
    if (plan != null) {
      // Close the inputs first: Windows refuses to delete open files.
      await plan.close();
      // `build_images` removes the staging folder after `pack_super` moved
      // `super.img` into the result; the packaged artifact never contains it.
      await workspace.delete(joinWorkspacePath(root, 'Super'));
    }
    return packaged;
  } finally {
    await plan?.close();
  }
}

// ---------------------------------------------------------------------------
// ZIP

Future<PackageResult> _packageZip(
  Workspace workspace,
  String root,
  String destination,
  _SuperPlan? plan, {
  required bool superSizeFile,
  required void Function(Map<String, Object?> event)? emit,
  required void Function() check,
}) async {
  final entries = await _entries(
    workspace,
    root,
    generatedSuper: plan != null,
    generatedSuperSize: superSizeFile,
  );
  final partial = '$destination.part';
  final sink = await workspace.create(partial);
  final zip = ZipWriter();
  final hasher = Sha256Hasher();
  final output = _Output(sink, hasher);
  final imageHashes = <String, String>{};
  try {
    for (final name in entries) {
      check();
      if (plan != null && name == 'super.img') {
        await output.add(
          zip.startFile(name: name, unixMode: _modeFile, deflate: true),
        );
        await _writeSuper(
          plan,
          (bytes) async => output.add(zip.write(data: bytes)),
          emit: emit,
          check: check,
        );
        await output.add(zip.finishFile());
        imageHashes[name] = zip.finishedImageSha256()!;
      } else if (plan != null && superSizeFile && name == _superSizePath) {
        final content = Uint8List.fromList(
          ascii.encode('${plan.deviceSize}\n'),
        );
        await output.add(
          zip.startFile(name: name, unixMode: _modeFile, deflate: true),
        );
        await output.add(zip.write(data: content));
        await output.add(zip.finishFile());
      } else {
        await _zipFile(
          workspace,
          root,
          name,
          zip,
          output,
          imageHashes: imageHashes,
          emit: emit,
          check: check,
        );
      }
    }
    await output.add(zip.finish());
  } finally {
    await sink.close();
  }
  await workspace.move(partial, destination);
  final digest = hasher.finishHex();

  // `backend.package` writes the checksum beside the ZIP, never inside it.
  final checksumPath = '$destination.sha256';
  final checksum = await workspace.create(checksumPath);
  try {
    final line = '$digest  ${baseWorkspacePath(destination)}\n';
    await checksum.write(Uint8List.fromList(utf8.encode(line)), 0);
  } finally {
    await checksum.close();
  }
  return PackageResult(
    artifact: destination,
    format: 'zip',
    sha256: digest,
    imageSha256: Map.unmodifiable(imageHashes),
  );
}

/// Files to package, relative to [root], sorted like `backend.package`'s
/// `sorted(result.rglob('*'))`. The super staging folder is never packaged;
/// a generated `super.img` (and X9U's `super-size`) take the place of any
/// staged copy.
Future<List<String>> _entries(
  Workspace workspace,
  String root, {
  required bool generatedSuper,
  required bool generatedSuperSize,
}) async {
  final prefix = root.isEmpty ? '' : '$root/';
  final all = await workspace.list(root, recursive: true);
  final entries = <String>[
    for (final path in all)
      if (path.startsWith(prefix)) path.substring(prefix.length),
  ];
  entries.removeWhere((name) => name == 'Super' || name.startsWith('Super/'));
  if (generatedSuper) {
    entries.remove('super.img');
    entries.add('super.img');
  }
  if (generatedSuperSize) {
    entries.remove(_superSizePath);
    entries.add(_superSizePath);
  }
  entries.sort();
  return entries;
}

Future<void> _zipFile(
  Workspace workspace,
  String root,
  String name,
  ZipWriter zip,
  _Output output, {
  required Map<String, String> imageHashes,
  required void Function(Map<String, Object?> event)? emit,
  required void Function() check,
}) async {
  final path = joinWorkspacePath(root, name);
  final source = await workspace.open(path);
  try {
    final length = source.length;
    final mode = await _unixMode(source, baseWorkspacePath(name));
    await output.add(zip.startFile(name: name, unixMode: mode, deflate: true));
    var offset = 0;
    var reported = 0;
    while (offset < length) {
      check();
      final size = math.min(_ioChunk, length - offset);
      final data = await source.read(offset, size);
      offset += size;
      await output.add(zip.write(data: data));
      if (length >= _progressStep && offset - reported >= _progressStep) {
        reported = offset;
        _progress(emit, name, offset, length);
      }
    }
    await output.add(zip.finishFile());
    if (name.endsWith('.img')) imageHashes[name] = zip.finishedImageSha256()!;
    if (length >= _progressStep && reported < length) {
      _progress(emit, name, length, length);
    }
  } finally {
    await closeByteSource(source);
  }
}

/// `backend.package`'s executable heuristic. Unix modes go in the external
/// attributes; the Rust writer sets `create_system = 3`.
Future<int> _unixMode(ByteSource source, String name) async {
  final dot = name.lastIndexOf('.');
  final suffix = dot <= 0 ? '' : name.substring(dot);
  var executable = suffix == '.sh' || _executableNames.contains(name);
  if (!executable &&
      suffix != '.img' &&
      suffix != '.zip' &&
      source.length >= 4) {
    final head = await source.read(0, 4);
    executable =
        head[0] == 0x7f &&
        head[1] == 0x45 &&
        head[2] == 0x4c &&
        head[3] == 0x46;
  }
  return executable ? _modeExecutable : _modeFile;
}

const Set<String> _executableNames = {
  'update-binary',
  'aera-installer',
  'pack_super',
  'unpack_super',
  'pack_super_regional',
  'volprompt',
};

// ---------------------------------------------------------------------------
// Folder

Future<PackageResult> _packageFolder(
  Workspace workspace,
  String root,
  String destination,
  _SuperPlan? plan, {
  required bool superSizeFile,
  required void Function(Map<String, Object?> event)? emit,
  required void Function() check,
}) async {
  final entries = await _entries(
    workspace,
    root,
    generatedSuper: plan != null,
    generatedSuperSize: superSizeFile,
  );
  final imageHashes = <String, String>{};
  for (final name in entries) {
    check();
    if (plan != null && name == 'super.img') continue;
    if (plan != null && superSizeFile && name == _superSizePath) continue;
    await workspace.move(
      joinWorkspacePath(root, name),
      joinWorkspacePath(destination, name),
    );
    if (name.endsWith('.img')) {
      final source = await workspace.open(joinWorkspacePath(destination, name));
      final hash = Sha256Hasher();
      try {
        var offset = 0;
        while (offset < source.length) {
          check();
          final data = await source.read(
            offset,
            math.min(_ioChunk, source.length - offset),
          );
          hash.update(bytes: data);
          offset += data.length;
        }
        imageHashes[name] = hash.finishHex();
      } finally {
        await closeByteSource(source);
      }
    }
  }
  if (plan != null) {
    if (superSizeFile) {
      final sink = await workspace.create(
        joinWorkspacePath(destination, _superSizePath),
      );
      try {
        final line = '${plan.deviceSize}\n';
        await sink.write(Uint8List.fromList(ascii.encode(line)), 0);
      } finally {
        await sink.close();
      }
    }
    final sink = await workspace.create(
      joinWorkspacePath(destination, 'super.img'),
    );
    final imageHash = Sha256Hasher();
    final output = _Output(sink, imageHash);
    try {
      await _writeSuper(plan, output.add, emit: emit, check: check);
    } finally {
      await sink.close();
    }
    imageHashes['super.img'] = imageHash.finishHex();
  }
  return PackageResult(
    artifact: destination,
    format: 'folder',
    sha256: null,
    imageSha256: Map.unmodifiable(imageHashes),
  );
}

// ---------------------------------------------------------------------------
// super.img

/// The normal and virtual packers share this exact LP producer contract.
SuperLayout flasherSuperLayout(Map<String, int> images, int size) {
  if (size <= 4 * 1024 * 1024 || size % 4096 != 0) {
    throw const BuildException('Invalid physical super partition size.');
  }
  for (final name in const ['system', 'vendor', 'product']) {
    if ((images[name] ?? 0) <= 0) {
      throw BuildException('Required partition missing: $name.img');
    }
  }
  final included = [for (final name in superParts) if (images.containsKey(name)) name];
  try {
    return superLayout(spec: SuperSpec(
      deviceSize: BigInt.from(size), superName: 'super',
      metadataSize: 65536, metadataSlots: 3, virtualAb: true,
      logicalBlockSize: 4096, alignment: 1 << 20,
      groups: [
        for (final slot in const ['a', 'b'])
          SuperGroup(name: 'qti_dynamic_partitions_$slot', size: BigInt.from(size - 4 * 1024 * 1024)),
      ],
      partitions: [
        for (final name in included)
          SuperPartition(name: '${name}_a', size: BigInt.from(images[name]!),
            group: 'qti_dynamic_partitions_a', readonly: true, hasImage: true),
        for (final name in included)
          SuperPartition(name: '${name}_b', size: BigInt.zero,
            group: 'qti_dynamic_partitions_b', readonly: true, hasImage: false),
      ],
    ));
  } on Object catch (error) {
    throw BuildException('$error');
  }
}

final class _SuperPlan {
  _SuperPlan({
    required this.header,
    required this.head,
    required this.pieces,
    required this.length,
    required this.totalBlocks,
    required this.deviceSize,
    required this.images,
  });

  /// The 28-byte Android sparse header, computed before streaming.
  final Uint8List header;

  /// LP geometry and metadata from offset 0 to the first extent.
  final Uint8List head;

  final List<_Piece> pieces;

  /// Expanded image length: through the end of the last partition extent.
  final int length;

  final int totalBlocks;

  /// The physical super partition size `lpmake --device` was given; X9U's
  /// `super-size` file records this, as `native_pipeline.build_images` does.
  final int deviceSize;

  /// Images held open until the super has been streamed.
  final List<_Image> images;

  Future<void> close() async {
    for (final image in images) {
      await image.close();
    }
  }
}

sealed class _Piece {
  const _Piece(this.length);

  final int length;

  int get chunks;
}

/// Expanded partition bytes, padded with zeros to a sparse block.
final class _DataPiece extends _Piece {
  const _DataPiece(this.image, super.length);

  final _Image image;

  @override
  int get chunks => length ~/ _sparseBlockSize;
}

/// A hole; `lpmake --sparse` writes these as DONT_CARE chunks.
final class _ZeroPiece extends _Piece {
  const _ZeroPiece(super.length);

  @override
  int get chunks => length == 0 ? 0 : 1;
}

Future<_SuperPlan> _planSuper(
  Workspace workspace,
  String imagesDir,
  int size, {
  required void Function() check,
}) async {
  // `pack_super` requires these before it consults the super size.
  for (final name in const ['system', 'vendor', 'product']) {
    final path = joinWorkspacePath(imagesDir, '$name.img');
    if (!await workspace.exists(path) || await workspace.size(path) == 0) {
      throw BuildException('Required partition missing: $name.img');
    }
  }
  final groupSize = size - 4 * 1024 * 1024;
  if (groupSize <= 0) {
    throw const BuildException('Invalid physical super partition size.');
  }
  if (size % _sparseBlockSize != 0) {
    throw const BuildException('Invalid physical super partition size.');
  }

  final images = <String, _Image>{};
  try {
    for (final name in superParts) {
      check();
      final path = joinWorkspacePath(imagesDir, '$name.img');
      if (await workspace.exists(path)) {
        images[name] = await _Image.open(workspace, path, name);
      }
    }

    final layout = flasherSuperLayout(
      {for (final entry in images.entries) entry.key: entry.value.expanded},
      size,
    );

    if (layout.head.length % _sparseBlockSize != 0) {
      throw const BuildException('Invalid super layout.');
    }
    final extents = [...layout.extents]
      ..sort((a, b) => a.offset.compareTo(b.offset));
    final pieces = <_Piece>[];
    var position = layout.head.length;
    for (final extent in extents) {
      check();
      final offset = extent.offset.toInt();
      final length = extent.size.toInt();
      if (offset < position || length < 0) {
        throw const BuildException('Invalid super layout.');
      }
      if (offset > position) pieces.add(_ZeroPiece(offset - position));
      final partition = extent.name;
      final name = partition.endsWith('_a')
          ? partition.substring(0, partition.length - 2)
          : partition;
      final image = images[name];
      if (image == null) {
        throw const BuildException('Invalid super layout.');
      }
      final dataLength = _align(image.expanded, _sparseBlockSize);
      if (dataLength > length || dataLength <= 0) {
        throw const BuildException('Invalid super layout.');
      }
      pieces.add(_DataPiece(image, dataLength));
      if (length > dataLength) pieces.add(_ZeroPiece(length - dataLength));
      position = offset + length;
    }
    if (position > size) {
      throw const BuildException('Invalid super layout.');
    }
    if (position < size) {
      // `lpmake --sparse` fills the rest of the device with DONT_CARE blocks.
      pieces.add(_ZeroPiece(size - position));
      position = size;
    }
    if (position % _sparseBlockSize != 0) {
      throw const BuildException('Invalid super layout.');
    }

    var chunks = layout.head.length ~/ _sparseBlockSize;
    for (final piece in pieces) {
      chunks += piece.chunks;
    }
    if (chunks > 0xffffffff) {
      throw const BuildException('Invalid super layout.');
    }
    final header = _sparseHeaderBytes(
      totalBlocks: position ~/ _sparseBlockSize,
      totalChunks: chunks,
    );
    return _SuperPlan(
      header: header,
      head: layout.head,
      pieces: pieces,
      length: position,
      totalBlocks: position ~/ _sparseBlockSize,
      deviceSize: size,
      images: images.values.toList(),
    );
  } on Object {
    for (final image in images.values) {
      await image.close();
    }
    rethrow;
  }
}

Future<void> _writeSuper(
  _SuperPlan plan,
  Future<void> Function(Uint8List bytes) write, {
  required void Function(Map<String, Object?> event)? emit,
  required void Function() check,
}) async {
  final writer = SparseWriter(
    blockSize: _sparseBlockSize,
    totalBlocks: plan.totalBlocks,
  );
  final progress = _SuperProgress(emit, plan.length);
  final feeder = _Feeder(writer, write, check: check, onBytes: progress.add);

  await write(plan.header);
  for (var offset = 0; offset < plan.head.length; offset += _ioChunk) {
    check();
    final end = math.min(offset + _ioChunk, plan.head.length);
    await write(
      writer.push(bytes: Uint8List.sublistView(plan.head, offset, end)),
    );
  }
  progress.add(plan.head.length);

  for (final piece in plan.pieces) {
    check();
    if (piece is _ZeroPiece) {
      await write(writer.skip(len: BigInt.from(piece.length)));
      progress.add(piece.length);
    } else if (piece is _DataPiece) {
      // The feeder reports every flushed block, padding included.
      await feeder.addImage(piece.image, piece.length);
    }
  }

  final tail = writer.finish();
  if (tail.trailer.isNotEmpty) await write(tail.trailer);
  if (!_sameBytes(tail.header, plan.header)) {
    throw StateError('sparse super header does not match its stream');
  }
  progress.finish();
}

/// Buffers expanded image bytes into sparse-block multiples before pushing
/// them to the Rust writer, so every pushed block becomes exactly one chunk
/// (the count the precomputed sparse header declares).
final class _Feeder {
  _Feeder(
    this._writer,
    this._write, {
    required this.check,
    required this.onBytes,
  });

  final SparseWriter _writer;
  final Future<void> Function(Uint8List bytes) _write;
  final void Function() check;
  final void Function(int bytes) onBytes;
  final Uint8List _buffer = Uint8List(_ioChunk);
  int _used = 0;

  Future<void> addImage(_Image image, int paddedLength) async {
    var produced = 0;
    Future<void> add(Uint8List bytes) async {
      var position = 0;
      while (position < bytes.length) {
        final size = math.min(_buffer.length - _used, bytes.length - position);
        _buffer.setRange(_used, _used + size, bytes, position);
        _used += size;
        position += size;
        produced += size;
        if (_used == _buffer.length) await _flush();
      }
    }

    await image.stream(add, check);
    if (produced != image.expanded) {
      throw BuildException('Invalid Android sparse image: ${image.name}.img');
    }
    final remainder = produced % _sparseBlockSize;
    if (remainder != 0) {
      final padding = _sparseBlockSize - remainder;
      if (produced + padding > paddedLength) {
        throw const BuildException('Invalid super layout.');
      }
      await add(Uint8List(padding));
    }
    if (produced > paddedLength) {
      throw const BuildException('Invalid super layout.');
    }
    if (_used > 0) await _flush();
    if (produced < paddedLength) {
      await add(Uint8List(paddedLength - produced));
      if (_used > 0) await _flush();
    }
  }

  Future<void> _flush() async {
    check();
    final bytes = _writer.push(bytes: Uint8List.sublistView(_buffer, 0, _used));
    final flushed = _used;
    _used = 0;
    onBytes(flushed);
    await _write(bytes);
  }
}

/// Tracks logical super bytes and emits at most one progress event per 64 MiB.
final class _SuperProgress {
  _SuperProgress(this._emit, this._total);

  final void Function(Map<String, Object?> event)? _emit;
  final int _total;
  int _done = 0;
  int _reported = 0;

  void add(int bytes) {
    _done += bytes;
    if (_done - _reported >= _progressStep && _done < _total) {
      _reported = _done;
      _progress(_emit, 'super.img', _done, _total);
    }
  }

  void finish() {
    if (_reported != _total) {
      _reported = _total;
      _progress(_emit, 'super.img', _total, _total);
    }
  }
}

/// The 28-byte Android sparse v1.0 file header. Checksums are zero, as
/// `lpmake --sparse` writes them.
Uint8List _sparseHeaderBytes({
  required int totalBlocks,
  required int totalChunks,
}) {
  final bytes = Uint8List(28);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0xed26ff3a, Endian.little);
  data.setUint16(4, 1, Endian.little);
  data.setUint16(6, 0, Endian.little);
  data.setUint16(8, 28, Endian.little);
  data.setUint16(10, 12, Endian.little);
  data.setUint32(12, _sparseBlockSize, Endian.little);
  data.setUint32(16, totalBlocks, Endian.little);
  data.setUint32(20, totalChunks, Endian.little);
  data.setUint32(24, 0, Endian.little);
  return bytes;
}

// ---------------------------------------------------------------------------
// Source images

final class _Image {
  _Image({
    required this.name,
    required this.source,
    required this.expanded,
    required this.sparse,
  });

  final String name;
  final ByteSource source;

  /// Logical image size: the sparse header's size, or the file size.
  final int expanded;

  final _SparseFile? sparse;
  bool _closed = false;

  static Future<_Image> open(
    Workspace workspace,
    String path,
    String name,
  ) async {
    final source = await workspace.open(path);
    try {
      final length = source.length;
      if (length >= 28) {
        final head = await source.read(0, 28);
        if (_u32(head, 0) == _sparseMagic) {
          final SparseHeader? header;
          try {
            header = sparseHeader(bytes28: head);
          } on Object {
            throw BuildException('Invalid Android sparse image: $name.img');
          }
          if (header == null || header.blockSize % 512 != 0) {
            throw BuildException('Invalid Android sparse image: $name.img');
          }
          return _Image(
            name: name,
            source: source,
            expanded: header.blockSize * header.totalBlocks,
            sparse: _SparseFile(
              blockSize: header.blockSize,
              totalChunks: header.totalChunks,
              fileHeaderSize: header.fileHeaderSize,
              chunkHeaderSize: header.chunkHeaderSize,
            ),
          );
        }
      }
      return _Image(name: name, source: source, expanded: length, sparse: null);
    } on Object {
      await closeByteSource(source);
      rethrow;
    }
  }

  /// Streams exactly [expanded] bytes, expanding sparse chunks.
  Future<void> stream(
    Future<void> Function(Uint8List bytes) write,
    void Function() check,
  ) async {
    final sparse = this.sparse;
    if (sparse == null) {
      var offset = 0;
      while (offset < expanded) {
        check();
        final size = math.min(_ioChunk, expanded - offset);
        await write(await source.read(offset, size));
        offset += size;
      }
      return;
    }

    final chunks = sparse.totalChunks;
    var offset = sparse.fileHeaderSize;
    var produced = 0;
    for (var index = 0; index < chunks; index++) {
      check();
      if (offset + sparse.chunkHeaderSize > source.length) {
        throw BuildException('Invalid Android sparse image: $name.img');
      }
      final header = await source.read(offset, sparse.chunkHeaderSize);
      offset += sparse.chunkHeaderSize;
      final SparseChunk chunk;
      try {
        chunk = sparseChunk(bytes12: Uint8List.sublistView(header, 0, 12));
      } on Object {
        throw BuildException('Invalid Android sparse image: $name.img');
      }
      final dataLength = chunk.totalSize - sparse.chunkHeaderSize;
      final chunkLength = chunk.blocks * sparse.blockSize;
      if (dataLength < 0 ||
          offset + dataLength > source.length ||
          chunkLength < 0 ||
          produced + chunkLength > expanded) {
        throw BuildException('Invalid Android sparse image: $name.img');
      }
      switch (chunk.kind) {
        case 0xcac1: // RAW
          if (dataLength != chunkLength) {
            throw BuildException('Invalid Android sparse image: $name.img');
          }
          var position = offset;
          var remaining = dataLength;
          while (remaining > 0) {
            check();
            final size = math.min(_ioChunk, remaining);
            await write(await source.read(position, size));
            position += size;
            remaining -= size;
          }
          produced += chunkLength;
        case 0xcac2: // FILL
          if (dataLength != 4) {
            throw BuildException('Invalid Android sparse image: $name.img');
          }
          final value = await source.read(offset, 4);
          await _writeFill(write, check, value, chunkLength);
          produced += chunkLength;
        case 0xcac3: // DONT_CARE
          produced += chunkLength;
          var remaining = chunkLength;
          while (remaining > 0) {
            check();
            final size = math.min(_zeros.length, remaining);
            await write(Uint8List.sublistView(_zeros, 0, size));
            remaining -= size;
          }
        case 0xcac4: // CRC-32
          break;
        default:
          throw BuildException('Invalid Android sparse image: $name.img');
      }
      if (produced > expanded) {
        throw BuildException('Invalid Android sparse image: $name.img');
      }
      offset += dataLength;
    }
    if (produced != expanded) {
      throw BuildException('Invalid Android sparse image: $name.img');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await closeByteSource(source);
  }
}

final class _SparseFile {
  const _SparseFile({
    required this.blockSize,
    required this.totalChunks,
    required this.fileHeaderSize,
    required this.chunkHeaderSize,
  });

  final int blockSize;
  final int totalChunks;
  final int fileHeaderSize;
  final int chunkHeaderSize;
}

Future<void> _writeFill(
  Future<void> Function(Uint8List bytes) write,
  void Function() check,
  Uint8List value,
  int length,
) async {
  final pattern = Uint8List(_fillPattern);
  for (var offset = 0; offset < pattern.length; offset += 4) {
    pattern.setRange(offset, offset + 4, value);
  }
  var remaining = length;
  while (remaining > 0) {
    check();
    final size = math.min(pattern.length, remaining);
    await write(Uint8List.sublistView(pattern, 0, size));
    remaining -= size;
  }
}

// ---------------------------------------------------------------------------
// Output

/// Positional output with a running offset and the ZIP's SHA-256.
final class _Output {
  _Output(this._sink, this._hasher);

  final ByteSink _sink;
  final Sha256Hasher? _hasher;
  int _offset = 0;

  Future<void> add(Uint8List bytes) async {
    if (bytes.isEmpty) return;
    await _sink.write(bytes, _offset);
    _offset += bytes.length;
    _hasher?.update(bytes: bytes);
  }
}

// ---------------------------------------------------------------------------
// Small helpers

const int _sparseBlockSize = 4096;
const int _sparseMagic = 0xed26ff3a;
const String _superSizePath = 'META-INF/com/google/android/super-size';

/// `0o100644` / `0o100755`; Dart has no octal literals.
const int _modeFile = 0x81a4;
const int _modeExecutable = 0x81ed;
const int _ioChunk = 4 * 1024 * 1024;
const int _progressStep = 64 * 1024 * 1024;
const int _fillPattern = 64 * 1024;

final Uint8List _zeros = Uint8List(_ioChunk);

int _align(int value, int alignment) {
  final remainder = value % alignment;
  return remainder == 0 ? value : value + alignment - remainder;
}

int _u32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

void _progress(
  void Function(Map<String, Object?> event)? emit,
  String label,
  int done,
  int total,
) {
  emit?.call({
    'type': 'progress',
    'label': label,
    'done': done,
    'total': total,
  });
}
