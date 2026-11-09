/// A flash package backed by a full OTA and verified local bloat, not output files.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../bloat/manifest.dart';
import '../pipeline/ota.dart';
import '../rust/api/payload.dart';
import '../storage/storage.dart';
import '../upstream/bloat_selection.dart';
import '../upstream/tables.dart';
import 'model.dart';
import 'ota_source.dart';
import 'package_index.dart';
import 'package_source.dart';

/// Pure, deterministic job identity. [sourceIdentity] is JSON-like and stable
/// across opens (file metadata, URL, or the complete catalog release entry).
String virtualJobId(OtaArchive ota, Selection selection, Map<String, Object?> sourceIdentity) {
  final identity = {
    'source': sourceIdentity,
    'manifest': ota.manifestSha256,
    'bytes': ota.length,
    'device': selection.device,
    'kind': selection.kind,
    'region': selection.region,
  };
  return 'virtual-${sha256.convert(utf8.encode(jsonEncode(_canonical(identity)))).toString().substring(0, 16)}';
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is Iterable) return [for (final item in value) _canonical(item)];
  return value;
}

final class _BloatImage {
  const _BloatImage(this.sourcePath, this.asset);
  final String sourcePath;
  final BloatAsset asset;
}

/// Owns its OTA handle; callers must close it after preparation/execution.
final class VirtualFlashPackage implements FlashPackage {
  VirtualFlashPackage._(this.ota, this.selection, this.bloat, this.sourceIdentity,
      this._parts, this._bloatImages, this._selectedBloat, this.buildJson, this.job);

  static Future<VirtualFlashPackage> load({
    required OtaArchive ota,
    required Selection selection,
    required Workspace bloat,
    required BloatManifest bloatManifest,
    required Map<String, Object?> sourceIdentity,
  }) async {
    if (selection.kind.contains('Super') ||
        !(selection.kind == 'Regional Flasher' || selection.kind == 'RegionalHybrid Flasher')) {
      throw const FlashException('Virtual flashing supports only Regional and RegionalHybrid non-Super selections.');
    }
    try {
      ota.verifyVirtualReads();
    } on Object catch (error) {
      throw FlashException('This OTA cannot be flashed in place (a full OTA with hashed operations is required): $error');
    }
    final paths = selectedPaths(bloatManifest.source, selection);
    if (paths.isEmpty) {
      throw const FlashException('The bloat manifest has no images for this selection.');
    }
    final selectedBloat = <String, BloatAsset>{};
    for (final relative in paths) {
      final asset = bloatManifest.assets[bloatManifest.files[relative]];
      if (asset == null) throw FlashException('The bloat manifest has no asset for $relative.');
      await _verifyBloat(bloat, relative.substring('bloat/'.length), asset);
      selectedBloat[relative] = asset;
    }
    final main = bloatFolder(selection.dev, selection.kind, selection.region);
    final images = <String, _BloatImage>{};
    for (final relative in paths) {
      final path = relative.split('/');
      if (path.length != 4) throw FlashException('Invalid bloat image path: $relative');
      final folder = path[2];
      final file = path[3];
      if (selection.dev == 'X9U' && file == 'abl-16.0.6.img') continue;
      final destination = folder == main ? selection.imageFolder
          : folder == 'GLO_BLOAT' && selection.region == 'CN' ? 'OOS_FILES_HERE' : 'COS_FILES_HERE';
      images['$destination/$file'] = _BloatImage(relative.substring('bloat/'.length), selectedBloat[relative]!);
    }
    final parts = <String, PartitionInfo>{};
    for (final part in ota.manifest.partitions()) {
      if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(part.name)) {
        throw FlashException('Invalid OTA partition name: ${part.name}');
      }
      final path = '${selection.imageFolder}/${part.name}.img';
      if (selection.dev == 'X9U' && images.containsKey(path)) continue;
      images.remove(path); // Normal extraction overwrites staged bloat.
      parts[path] = part;
    }
    final hashes = <String, String>{
      for (final entry in images.entries) entry.key: entry.value.asset.rawSha256,
      for (final entry in parts.entries)
        if (entry.value.sha256 != null && entry.value.sha256!.isNotEmpty) entry.key: entry.value.sha256!,
    };
    final manifest = <String, Object?>{
      'device': selection.device,
      'dev': selection.dev,
      'flasher_type': selection.kind,
      'region': selection.region,
      'version': ota.version,
      'output_format': 'virtual',
      if (hashes.length == parts.length + images.length)
        'image_sha256': Map<String, String>.unmodifiable(hashes)
      else
        'available_image_sha256': Map<String, String>.unmodifiable(hashes),
    };
    final stableIdentity = Map<String, Object?>.unmodifiable(
      Map<String, Object?>.from(jsonDecode(jsonEncode(sourceIdentity)) as Map));
    final package = VirtualFlashPackage._(ota, selection, bloat, stableIdentity,
        Map.unmodifiable(parts), Map.unmodifiable(images), Map.unmodifiable(selectedBloat), Map.unmodifiable(manifest),
        virtualJobId(ota, selection, stableIdentity));
    // Validate every extent index before probing a device.
    for (final part in parts.values) {
      await OtaPartitionSource(ota: ota, partition: part, cache: package.cache).close();
    }
    return package;
  }

  final OtaArchive ota;
  final Selection selection;
  final Workspace bloat;
  final Map<String, Object?> sourceIdentity;
  final Map<String, PartitionInfo> _parts;
  final Map<String, _BloatImage> _bloatImages;
  final Map<String, BloatAsset> _selectedBloat;
  final OtaOperationCache cache = OtaOperationCache();
  final String job;
  @override
  final Map<String, Object?> buildJson;
  @override
  String get format => 'virtual';
  @override
  late final PackageIndex index = PackageIndex.fromEntries([
    ..._parts.keys, ..._bloatImages.keys,
  ], buildJson: buildJson);

  bool isOtaImage(String path) => _parts.containsKey(path);
  String? imageHash(String path) => _parts[path]?.sha256 ??
      _bloatImages[path]?.asset.rawSha256;

  @override
  Future<int> size(String path) async => _parts[path]?.size.toInt() ??
      _bloatImages[path]?.asset.rawBytes ?? (throw FlashException('The virtual package is missing $path.'));

  @override
  Future<FlashSource> open(String path) async {
    final part = _parts[path];
    if (part != null) return OtaPartitionSource(ota: ota, partition: part, cache: cache);
    final image = _bloatImages[path];
    if (image == null) throw FlashException('The virtual package is missing $path.');
    return _LocalImage(await bloat.open(image.sourcePath));
  }

  @override
  Future<Map<String, Object?>> snapshot() async => {
    'format': format,
    'job': job,
    'source': sourceIdentity,
    'otaBytes': ota.length,
    'manifestSha256': ota.manifestSha256,
    'payloadDataOffset': ota.payloadDataOffset,
    'dataStart': ota.dataStart,
    'partitions': {
      for (final part in ota.manifest.partitions()) part.name: {
        'bytes': part.size.toInt(), 'sha256': part.sha256,
      },
    },
    'selectedBloat': {
      for (final entry in _selectedBloat.entries) entry.key: {
        'bytes': entry.value.rawBytes, 'sha256': entry.value.rawSha256,
      },
    },
    'bloat': {
      for (final entry in _bloatImages.entries) entry.key: {
        'source': entry.value.sourcePath,
        'bytes': entry.value.asset.rawBytes,
        'sha256': entry.value.asset.rawSha256,
      },
    },
    'buildJson': buildJson,
  };

  Future<void> close() async {
    await cache.close();
    await closeByteSource(ota.source);
  }
}

Future<void> _verifyBloat(Workspace workspace, String path, BloatAsset asset) async {
  try {
    if (!await workspace.exists(path)) {
      throw FlashException('Missing local bloat image: $path');
    }
    final source = await workspace.open(path);
    try {
      if (source.length != asset.rawBytes) {
        throw FlashException('Bloat $path changed size (${source.length} != ${asset.rawBytes}).');
      }
      final hasher = Sha256Hasher();
      for (var offset = 0; offset < source.length; offset += 4 << 20) {
        final count = math.min(4 << 20, source.length - offset);
        final bytes = await source.read(offset, count);
        if (bytes.length != count) throw FlashException('Bloat $path ended early at $offset.');
        hasher.update(bytes: bytes);
      }
      final digest = hasher.finishHex();
      if (digest != asset.rawSha256) {
        throw FlashException('Bloat $path SHA-256 mismatch: $digest != ${asset.rawSha256}.');
      }
    } finally {
      await closeByteSource(source);
    }
  } on FlashException {
    rethrow;
  } on Object catch (error) {
    throw FlashException('Cannot read local bloat $path: $error');
  }
}

final class _LocalImage implements FlashSource {
  _LocalImage(this.source);
  final ByteSource source;
  @override
  int get length => source.length;
  @override
  Future<Uint8List> read(int offset, int length) => source.read(offset, length);
  @override
  Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    if (chunkSize <= 0) throw ArgumentError.value(chunkSize);
    for (var offset = 0; offset < length; offset += chunkSize) {
      yield await read(offset, math.min(chunkSize, length - offset));
    }
  }
  @override
  Future<FlashCursor> cursor() async => RandomFlashCursor(this);
  @override
  Future<void> close() => closeByteSource(source);
}
