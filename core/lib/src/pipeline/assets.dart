/// Upstream snapshot assets and store opening for the build pipeline.
///
/// The snapshot (`tables.json`, `bloat-manifest.json`, `templates/<dev>.zip`
/// and `platform-tools.zip`) is served from the app's origin or read from the
/// CLI's checkout; both are addressed by [UpstreamAssets.base]. Store maps are
/// the service contract's `Store` values.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../bloat/manifest.dart';
import '../facts/facts.dart';
import '../native/native.dart';
import '../rust/api/zip.dart';
import '../storage/storage.dart';
import '../strategy/store.dart';
import '../strategy/store_open.dart';
import '../upstream/tables.dart';
import 'errors.dart';

/// A validated `Store` map, opened in the place this code runs.
///
/// `{"kind": "path", "path": "..."}`, `{"kind": "opfs"}` and
/// `{"kind": "directory", "handle": <FileSystemDirectoryHandle>}` are the
/// service's forms; a place that cannot provide one throws [BuildException].
Future<Workspace> openStore(Map<String, Object?> store) async {
  final spec = StoreSpec.fromMap(store);
  return openStoreWithFacts(spec, await PlaceInfo.current());
}

/// The upstream snapshot: tables, bloat manifest, templates and tools.
final class UpstreamAssets {
  UpstreamAssets(String base) : base = _normalizeBase(base);

  /// A URL ending in `/`, or a directory path (with or without a trailing
  /// separator).
  final String base;

  Uri? get _uri {
    final uri = Uri.tryParse(base);
    final scheme = uri?.scheme.toLowerCase();
    return uri != null && (scheme == 'http' || scheme == 'https') ? uri : null;
  }

  bool get remote => _uri != null;

  /// Reads one snapshot file completely.
  Future<Uint8List> read(String relative) async {
    final path = normalizeWorkspacePath(relative);
    final uri = _uri;
    if (uri != null) {
      final response = await http.get(uri.resolve(path));
      if (response.statusCode != 200) {
        throw BuildException(
          'Could not read upstream asset $relative: HTTP ${response.statusCode}.',
        );
      }
      return response.bodyBytes;
    }
    final workspace = openPathStore(base);
    final source = await workspace.open(path);
    try {
      final builder = BytesBuilder(copy: false);
      var offset = 0;
      const chunk = 4 * 1024 * 1024;
      while (offset < source.length) {
        final length = source.length - offset < chunk
            ? source.length - offset
            : chunk;
        builder.add(await source.read(offset, length));
        offset += length;
      }
      return builder.takeBytes();
    } finally {
      await closeByteSource(source);
    }
  }

  /// Parses `tables.json`.
  Future<UpstreamTables> tables() async =>
      UpstreamTables.parse(utf8.decode(await read('tables.json')));

  /// Parses `bloat-manifest.json`.
  Future<BloatManifest> bloatManifest() async =>
      BloatManifest.decode(utf8.decode(await read('bloat-manifest.json')));

  /// Extracts `templates/<dev>.zip` into [destination].
  Future<void> extractTemplates(
    String dev,
    Workspace workspace,
    String destination, {
    void Function()? check,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(dev)) {
      throw const BuildException('Invalid device ID.');
    }
    await _extractZip(
      _BytesSource(await read('templates/$dev.zip')),
      workspace,
      destination,
      check: check,
    );
  }

  /// Extracts `platform-tools.zip` into [destination].
  Future<void> extractPlatformTools(
    Workspace workspace,
    String destination, {
    void Function()? check,
  }) async {
    await _extractZip(
      _BytesSource(await read('platform-tools.zip')),
      workspace,
      destination,
      check: check,
    );
  }

  static String _normalizeBase(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const BuildException('Choose an upstream snapshot location.');
    }
    final uri = Uri.tryParse(trimmed);
    final scheme = uri?.scheme.toLowerCase();
    if (uri != null && (scheme == 'http' || scheme == 'https')) {
      return trimmed.endsWith('/') ? trimmed : '$trimmed/';
    }
    if (trimmed.contains('\\')) {
      throw const BuildException('Invalid upstream snapshot location.');
    }
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
}

/// A ZIP already in memory, such as a fetched snapshot asset.
final class _BytesSource implements ByteSource {
  _BytesSource(this._bytes);

  final Uint8List _bytes;

  @override
  int get length => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) {
    checkReadRange(offset, length, _bytes.length);
    return Future.value(Uint8List.sublistView(_bytes, offset, offset + length));
  }
}

/// Extracts a stored/deflated ZIP into [workspace] below [destination].
Future<void> _extractZip(
  ByteSource source,
  Workspace workspace,
  String destination, {
  void Function()? check,
}) async {
  final checkNow = check ?? () {};
  if (!await loadNative()) {
    throw const BuildException(
      "This place does not have flasher_web's native library.",
    );
  }
  try {
    final length = source.length;
    const tailLimit = 65557 + 20 + 56;
    final tailLength = length < tailLimit ? length : tailLimit;
    final ZipDirectory directory;
    try {
      directory = zipEntries(
        tail: await source.read(length - tailLength, tailLength),
        fileLen: BigInt.from(length),
      );
    } on Object catch (error) {
      throw BuildException('The upstream asset ZIP is invalid: $error');
    }
    var entries = directory.entries;
    final needs = directory.needs;
    if (needs != null) {
      final offset = needs.$1.toInt();
      final size = needs.$2.toInt();
      if (offset < 0 || size < 0 || offset + size > length) {
        throw const BuildException('The upstream asset ZIP is damaged.');
      }
      entries = zipParseCentral(cd: await source.read(offset, size));
    }

    for (final entry in entries) {
      checkNow();
      final name = entry.name;
      if (name.endsWith('/')) continue;
      if (name.startsWith('/') ||
          name.contains('\\') ||
          name.split('/').any((part) => part.isEmpty || part == '..')) {
        throw BuildException('Unsafe path in the upstream asset ZIP: $name');
      }
      final header = await source.read(entry.localHeaderOffset.toInt(), 30);
      final int dataOffset;
      try {
        dataOffset = zipDataOffset(
          localHeader30Bytes: header,
          localHeaderOffset: entry.localHeaderOffset,
        ).toInt();
      } on Object catch (error) {
        throw BuildException('The upstream asset ZIP entry is invalid: $error');
      }
      final compressedSize = entry.compressedSize.toInt();
      final size = entry.uncompressedSize.toInt();
      if (compressedSize < 0 ||
          size < 0 ||
          dataOffset + compressedSize > length) {
        throw BuildException(
          'The upstream asset ZIP entry is out of range: $name',
        );
      }
      final compressed = await source.read(dataOffset, compressedSize);
      final Uint8List bytes;
      try {
        bytes = switch (entry.method) {
          0 when compressedSize == size => compressed,
          8 => inflateRaw(data: compressed, expectedLen: BigInt.from(size)),
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
        throw BuildException(
          'The upstream asset ZIP entry is truncated: $name',
        );
      }
      final sink = await workspace.create('$destination/$name');
      try {
        await sink.write(bytes, 0);
      } finally {
        await sink.close();
      }
    }
  } finally {
    await closeByteSource(source);
  }
}
