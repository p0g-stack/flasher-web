/// Streams a virtual package as the flasher ZIP a folder build would produce.
///
/// The tree is the one `native_pipeline.stage` assembles: the selected
/// template subtree, `Platform-Tools/` and the images,
/// with `updater-script` and `*.sh` line endings normalized to LF. Images come
/// from [VirtualFlashPackage] (OTA operations decoded on demand, verified
/// bloat), so nothing is staged in a workspace and no temporary file is
/// written.
///
/// The output is a streaming ZIP64, written once from offset 0 with increasing
/// offsets, using the Rust `ZipWriter` (deflate level 1, data descriptors,
/// Unix modes). It contains no `build.json` and no checksum file: both are
/// returned to the caller instead.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../native/native.dart';
import '../pipeline/assets.dart';
import '../pipeline/errors.dart';
import '../rust/api/payload.dart' show Sha256Hasher;
import '../rust/api/zip.dart' as rust_zip;
import '../rust/api/zip_write.dart';
import '../storage/paths.dart' show baseWorkspacePath;
import '../storage/storage.dart';
import 'virtual.dart';
import 'virtual_super.dart' show superScrapFiles;

/// Writes [package]'s package tree into [sink] as a ZIP.
///
/// Events are `{"type": "progress", "label", "done", "total"}` while an image
/// streams and a final `{"type": "result", "job", "format", "sha256", "bytes",
/// "entries"}`. The sink receives the archive from offset 0, is truncated to
/// the archive's length and is left open: the caller owns and closes it.
///
/// [check] throws to cancel; cancelling the subscription also stops the
/// export. A stopped export leaves a partial, invalid archive in the sink,
/// which the caller discards.
Stream<Map<String, Object?>> exportVirtualZip({
  required VirtualFlashPackage package,
  required UpstreamAssets upstream,
  required ByteSink sink,
  void Function()? check,
}) {
  final controller = StreamController<Map<String, Object?>>();
  final run = _ExportRun(package, upstream, sink, check, controller);
  controller.onListen = () {
    unawaited(run._start());
  };
  controller.onCancel = run._cancel;
  return controller.stream;
}

/// Everything the package tree contains, before any bytes are written.
final class _TreeFile {
  const _TreeFile.bytes(this.name, Uint8List content)
    : bytes = content,
      image = null;
  const _TreeFile.image(this.name) : bytes = null, image = name;

  final String name;

  /// Buffered template or Platform-Tools content, already normalized.
  final Uint8List? bytes;

  /// A package image path, read from [VirtualFlashPackage] while writing.
  final String? image;
}

final class _ExportRun {
  _ExportRun(
    this._package,
    this._upstream,
    this._sink,
    this._check,
    this._controller,
  );

  final VirtualFlashPackage _package;
  final UpstreamAssets _upstream;
  final ByteSink _sink;
  final void Function()? _check;
  final StreamController<Map<String, Object?>> _controller;
  bool _cancelled = false;
  final _templateImageHashes = <String, String>{};

  void _verify() {
    if (_cancelled) throw const CancelledException('Export cancelled.');
    final check = _check;
    if (check != null) check();
  }

  void _emit(Map<String, Object?> event) {
    if (_cancelled || _controller.isClosed) return;
    _controller.add(event);
  }

  Future<void> _start() async {
    try {
      await _execute();
    } on CancelledException {
      _cancelled = true;
    } on Object catch (error, stack) {
      if (!_cancelled && !_controller.isClosed) {
        _controller.addError(error, stack);
      }
    } finally {
      if (!_controller.isClosed) {
        try {
          await _controller.close();
        } on Object {
          // A cancelled subscription needs no close acknowledgement.
        }
      }
    }
  }

  Future<void> _cancel() async {
    _cancelled = true;
  }

  Future<void> _execute() async {
    _verify();
    if (!await loadNative()) {
      throw const BuildException(
        "This place does not have flasher_web's native library.",
      );
    }
    final tree = await _tree();
    _verify();
    final names = tree.keys.toList()..sort();
    final zip = ZipWriter();
    final hasher = Sha256Hasher();
    final output = _ZipOutput(_sink, hasher);
    for (final name in names) {
      _verify();
      await _writeFile(name, tree[name]!, zip, output);
    }
    _verify();
    await output.add(zip.finish());
    await _sink.truncate(output.length);
    final digest = hasher.finishHex();
    final receipt = _package.receipt();
    receipt['output_format'] = 'zip';
    receipt['image_sha256'] = {
      ..._templateImageHashes,
      ...Map<String, String>.from(receipt['image_sha256']! as Map),
    };
    _emit({
      'type': 'result',
      'job': _package.job,
      'format': 'zip',
      'sha256': digest,
      'bytes': output.length,
      'entries': names.length,
      'receipt': {
        ...receipt,
        'job': _package.job,
        'zip': {'sha256': digest, 'bytes': output.length},
      },
    });
  }

  /// The package tree, in `native_pipeline.stage` order: template, then
  /// Platform-Tools (which the build copies over the template), then the bloat
  /// images and finally the OTA images the package exposes.
  Future<Map<String, _TreeFile>> _tree() async {
    final selection = _package.selection;
    final files = <String, _TreeFile>{};

    final dev = selection.dev;
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(dev)) {
      throw const BuildException('Invalid device ID.');
    }
    final templateZip = 'templates/$dev.zip';
    final template = await _archiveFiles(
      await _upstream.read(templateZip),
      templateZip,
    );
    final prefix = '${selection.template}/';
    // X9U's regional flashers ship no META-INF: the build deletes it after
    // staging the template, before Platform-Tools and images are added.
    final dropMeta = dev == 'X9U' && !selection.kind.contains('Super');
    for (final file in template) {
      _verify();
      if (!file.name.startsWith(prefix)) continue;
      final path = file.name.substring(prefix.length);
      if (path.isEmpty) continue;
      if (dropMeta && (path == 'META-INF' || path.startsWith('META-INF/'))) {
        continue;
      }
      files[path] = _TreeFile.bytes(path, _normalize(path, file.bytes));
    }

    final tools = await _archiveFiles(
      await _upstream.read('platform-tools.zip'),
      'platform-tools.zip',
    );
    for (final file in tools) {
      _verify();
      final path = 'Platform-Tools/${file.name}';
      files[path] = _TreeFile.bytes(path, _normalize(path, file.bytes));
    }

    for (final path in _package.index.entries) {
      if (selection.kind.contains('Super') &&
          (superScrapFiles.contains(path) || path.startsWith('Super/'))) {
        continue;
      }
      files[path] = _TreeFile.image(path);
    }
    if (selection.kind.contains('Super')) {
      files.removeWhere(
        (path, _) =>
            superScrapFiles.contains(path) || path.startsWith('Super/'),
      );
    }
    return files;
  }

  Future<void> _writeFile(
    String name,
    _TreeFile file,
    ZipWriter zip,
    _ZipOutput output,
  ) async {
    final bytes = file.bytes;
    if (bytes != null) {
      if (name.endsWith('.img')) {
        _templateImageHashes[name] = (Sha256Hasher()..update(bytes: bytes))
            .finishHex();
      }
      await output.add(
        zip.startFile(
          name: name,
          unixMode: _unixMode(name, bytes),
          deflate: true,
        ),
      );
      if (bytes.isNotEmpty) await output.add(zip.write(data: bytes));
      await output.add(zip.finishFile());
      return;
    }
    final source = await _package.open(file.image!);
    try {
      final length = source.length;
      if (length <= 0) {
        throw BuildException('$name is empty; it cannot be packaged.');
      }
      await output.add(
        zip.startFile(
          name: name,
          unixMode: _unixMode(name, Uint8List(0)),
          deflate: true,
        ),
      );
      var done = 0;
      var reported = 0;
      await for (final chunk in source.stream()) {
        _verify();
        if (chunk.isEmpty) continue;
        await output.add(zip.write(data: chunk));
        done += chunk.length;
        if (length >= _progressStep && done - reported >= _progressStep) {
          reported = done;
          _progress(name, done, length);
        }
      }
      if (done != length) {
        throw BuildException('$name ended early during export.');
      }
      await output.add(zip.finishFile());
    } finally {
      await source.close();
    }
  }

  void _progress(String label, int done, int total) {
    _emit({'type': 'progress', 'label': label, 'done': done, 'total': total});
  }
}

/// Positional output with a running offset and the ZIP's SHA-256.
final class _ZipOutput {
  _ZipOutput(this._sink, this._hasher);

  final ByteSink _sink;
  final Sha256Hasher _hasher;
  int length = 0;

  Future<void> add(Uint8List bytes) async {
    if (bytes.isEmpty) return;
    await _sink.write(bytes, length);
    length += bytes.length;
    _hasher.update(bytes: bytes);
  }
}

/// One file of an upstream asset ZIP.
final class _ArchiveFile {
  const _ArchiveFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

/// The files of a stored/deflated upstream ZIP, read without a workspace.
///
/// Same layout rules as `assets.dart`'s extraction: unsafe names are errors,
/// stored entries must match their declared size, deflated entries are
/// inflated to exactly it.
Future<List<_ArchiveFile>> _archiveFiles(
  Uint8List archive,
  String label,
) async {
  if (archive.isEmpty) {
    throw BuildException('The upstream asset $label is empty.');
  }
  const tailLimit = 65557 + 20 + 56;
  final tailLength = math.min(archive.length, tailLimit);
  final rust_zip.ZipDirectory directory;
  try {
    directory = rust_zip.zipEntries(
      tail: Uint8List.sublistView(archive, archive.length - tailLength),
      fileLen: BigInt.from(archive.length),
    );
  } on Object catch (error) {
    throw BuildException('The upstream asset ZIP is invalid: $error');
  }
  var entries = directory.entries;
  final needs = directory.needs;
  if (needs != null) {
    final offset = needs.$1.toInt();
    final size = needs.$2.toInt();
    if (offset < 0 || size < 0 || offset + size > archive.length) {
      throw const BuildException('The upstream asset ZIP is damaged.');
    }
    entries = rust_zip.zipParseCentral(
      cd: Uint8List.sublistView(archive, offset, offset + size),
    );
  }

  final files = <_ArchiveFile>[];
  for (final entry in entries) {
    final name = entry.name;
    if (name.endsWith('/')) continue;
    if (name.startsWith('/') ||
        name.contains('\\') ||
        name.split('/').any((part) => part.isEmpty || part == '..')) {
      throw BuildException('Unsafe path in the upstream asset ZIP: $name');
    }
    final localOffset = entry.localHeaderOffset.toInt();
    final compressedSize = entry.compressedSize.toInt();
    final size = entry.uncompressedSize.toInt();
    if (localOffset < 0 ||
        localOffset + 30 > archive.length ||
        compressedSize < 0 ||
        size < 0) {
      throw BuildException(
        'The upstream asset ZIP entry is out of range: $name',
      );
    }
    final int dataOffset;
    try {
      dataOffset = rust_zip
          .zipDataOffset(
            localHeader30Bytes: Uint8List.sublistView(
              archive,
              localOffset,
              localOffset + 30,
            ),
            localHeaderOffset: entry.localHeaderOffset,
          )
          .toInt();
    } on Object catch (error) {
      throw BuildException('The upstream asset ZIP entry is invalid: $error');
    }
    if (dataOffset < 0 || dataOffset + compressedSize > archive.length) {
      throw BuildException(
        'The upstream asset ZIP entry is out of range: $name',
      );
    }
    final compressed = Uint8List.sublistView(
      archive,
      dataOffset,
      dataOffset + compressedSize,
    );
    final Uint8List bytes;
    try {
      bytes = switch (entry.method) {
        0 when compressedSize == size => compressed,
        8 => rust_zip.inflateRaw(
          data: compressed,
          expectedLen: BigInt.from(size),
        ),
        _ => throw BuildException(
          'Unsupported compression in upstream asset $name.',
        ),
      };
    } on BuildException {
      rethrow;
    } on Object catch (error) {
      throw BuildException('Could not read upstream asset $name: $error');
    }
    if (bytes.length != size) {
      throw BuildException('The upstream asset ZIP entry is truncated: $name');
    }
    files.add(_ArchiveFile(name, bytes));
  }
  return files;
}

/// The staged tree's LF normalization: `updater-script` and every `*.sh` file
/// lose the CR of a CRLF pair, exactly as `build.dart` does before packaging.
Uint8List _normalize(String path, Uint8List bytes) {
  final base = baseWorkspacePath(path);
  if (base != 'updater-script' && !base.endsWith('.sh')) return bytes;
  var changed = false;
  for (var index = 0; index < bytes.length; index++) {
    if (bytes[index] == 0x0d &&
        index + 1 < bytes.length &&
        bytes[index + 1] == 0x0a) {
      changed = true;
      break;
    }
  }
  if (!changed) return bytes;
  final normalized = BytesBuilder(copy: false);
  for (var index = 0; index < bytes.length; index++) {
    final byte = bytes[index];
    if (byte == 0x0d && index + 1 < bytes.length && bytes[index + 1] == 0x0a) {
      continue;
    }
    normalized.addByte(byte);
  }
  return normalized.takeBytes();
}

/// `backend.package`'s mode rule, as `package.dart` applies it: `.sh` and the
/// known executable names are executable, an ELF header makes an entry
/// executable too, and images and ZIPs are never probed for one.
int _unixMode(String name, Uint8List head) {
  final base = baseWorkspacePath(name);
  final dot = base.lastIndexOf('.');
  final suffix = dot <= 0 ? '' : base.substring(dot);
  var executable = suffix == '.sh' || _executableNames.contains(base);
  if (!executable && suffix != '.img' && suffix != '.zip' && head.length >= 4) {
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

/// `0o100644` / `0o100755`; Dart has no octal literals.
const int _modeFile = 0x81a4;
const int _modeExecutable = 0x81ed;
const int _progressStep = 64 * 1024 * 1024;
