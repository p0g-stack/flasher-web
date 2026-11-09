/// A flash package backed by full OTAs and verified local bloat, not output files.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../bloat/manifest.dart';
import '../pipeline/ota.dart';
import '../rust/api/avb.dart';
import '../rust/api/payload.dart';
import '../storage/storage.dart';
import '../upstream/bloat_selection.dart';
import '../upstream/tables.dart';
import 'model.dart';
import 'ota_source.dart';
import 'package_index.dart';
import 'package.dart';
import 'sparse.dart';
import 'virtual_super.dart';

/// Partitions the Ace 6 conversion extracts from the target OTA.
const List<String> targetParts = [
  'my_bigball',
  'my_carrier',
  'my_engineering',
  'my_heytap',
  'my_manifest',
  'my_product',
  'my_region',
  'my_stock',
  'system',
  'system_ext',
  'product',
];

/// Partitions the Ace 6 conversion takes from the BASE OTA.
const List<String> baseParts = ['odm', 'system_dlkm', 'vendor', 'vendor_dlkm'];

String virtualJobId(OtaArchive ota, Selection selection, Map<String, Object?> sourceIdentity) {
  final identity = {
    'source': sourceIdentity, 'manifest': ota.manifestSha256, 'bytes': ota.length,
    'device': selection.device, 'kind': selection.kind, 'region': selection.region,
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
final class _OtaImage {
  const _OtaImage(this.archive, this.part);
  final OtaArchive archive;
  final PartitionInfo part;
}

/// Owns every OTA handle and the super input handles; close after the attempt.
final class VirtualFlashPackage implements FlashPackage {
  VirtualFlashPackage._(this.ota, this.selection, this.bloat, this.sourceIdentity,
    this._archives, this._selectedBloat, this.cache, this.job);

  static Future<VirtualFlashPackage> load({
    required OtaArchive ota,
    required Selection selection,
    required Workspace bloat,
    required BloatManifest bloatManifest,
    required Map<String, Object?> sourceIdentity,
    OtaArchive? base,
    Map<String, Object?>? baseIdentity,
    OtaArchive? donor,
    Map<String, Object?>? donorIdentity,
    bool? vulnerableAbl,
    int? superSize,
  }) async {
    const kinds = {'Regional Flasher', 'RegionalHybrid Flasher', 'Super Flasher', 'SuperHybrid Flasher'};
    if (!kinds.contains(selection.kind)) throw const FlashException('This flasher kind cannot be represented virtually.');
    if (selection.dev == 'X9U' && vulnerableAbl == null) {
      throw const FlashException('Choose vulnerableAbl true or false for X9U.');
    }
    if (selection.dev != 'X9U' && vulnerableAbl == true) {
      throw const FlashException('Vulnerable ABL is available only for X9U.');
    }
    final isSuper = selection.kind.contains('Super');
    final conversion = selection.builder == 'BUILD_ACE6_OOS.sh';
    final needsDonor = isSuper && selection.dev == 'Ace6T' && (selection.region == 'IN' || selection.region == 'GLO');
    if (conversion && (!isSuper || base == null || baseIdentity == null)) {
      throw const FlashException('Ace 6 OxygenOS needs virtual.base (Ace 6 ColorOS BASE full OTA).');
    }
    if (!conversion && base != null) throw const FlashException('This selection does not consume a BASE OTA.');
    if (needsDonor && (donor == null || donorIdentity == null)) {
      throw const FlashException('This selection requires a catalog patch-matched Ace 6T ODM donor.');
    }
    if (!needsDonor && donor != null) throw const FlashException('This selection does not consume an ODM donor.');
    if (isSuper && (superSize == null || superSize <= 0)) throw const FlashException('Missing physical super size.');
    final archives = <String, OtaArchive>{'ota': ota, 'base': ?base, 'donor': ?donor};
    try {
      for (final archive in archives.values) { archive.verifyVirtualReads(); }
    } on Object catch (error) {
      throw FlashException('This OTA cannot be flashed in place (a full OTA with hashed operations is required): $error');
    }
    final paths = selectedPaths(bloatManifest.source, selection);
    if (paths.isEmpty) throw const FlashException('The bloat manifest has no images for this selection.');
    final selectedBloat = <String, BloatAsset>{};
    for (final relative in paths) {
      final asset = bloatManifest.assets[bloatManifest.files[relative]];
      if (asset == null) throw FlashException('The bloat manifest has no asset for $relative.');
      await _verifyBloat(bloat, relative.substring('bloat/'.length), asset);
      selectedBloat[relative] = asset;
    }
    Map<String, Object?> archiveIdentity(OtaArchive archive, Map<String, Object?> identity) => {
      'source': identity, 'manifestSha256': archive.manifestSha256, 'bytes': archive.length,
    };
    final identities = <String, Object?>{
      ...sourceIdentity,
      if (base != null) 'base': archiveIdentity(base, baseIdentity!),
      if (donor != null) 'donor': archiveIdentity(donor, donorIdentity!),
    };
    final stableIdentity = Map<String, Object?>.unmodifiable(Map<String, Object?>.from(jsonDecode(jsonEncode(identities)) as Map));
    final result = VirtualFlashPackage._(ota, selection, bloat, stableIdentity,
      Map.unmodifiable(archives), Map.unmodifiable(selectedBloat), OtaOperationCache(), virtualJobId(ota, selection, stableIdentity));
    try {
      final main = bloatFolder(selection.dev, selection.kind, selection.region);
      for (final relative in paths) {
        final path = relative.split('/');
        if (path.length != 4) throw FlashException('Invalid bloat image path: $relative');
        final folder = path[2];
        final file = path[3];
        if (selection.dev == 'X9U' && file == 'abl-16.0.6.img') continue;
        final destination = folder == main ? (isSuper ? 'Super' : selection.imageFolder)
          : folder == 'GLO_BLOAT' && selection.region == 'CN' ? 'OOS_FILES_HERE' : 'COS_FILES_HERE';
        result._bloatImages['$destination/$file'] = _BloatImage(relative.substring('bloat/'.length), selectedBloat[relative]!);
      }
      if (vulnerableAbl == true) {
        const digest = '4ad7f1db0c92f0a358e28bf18170a20533011299827d8d9a25cffd2218f1415d';
        final source = 'X9U/${bloatFolder('X9U', 'Super Flasher', selection.region)}/abl-16.0.6.img';
        final asset = bloatManifest.assets[bloatManifest.files['bloat/$source']];
        if (asset == null || asset.rawSha256 != digest) {
          throw const FlashException('The verified X9U ABL 16.0.6 bloat image is missing.');
        }
        await _verifyBloat(bloat, source, asset);
        result._bloatImages['${selection.imageFolder}/abl.img'] = _BloatImage(source, asset);
        result._ablSource = {'version': '16.0.6', 'sha256': digest, 'bytes': asset.rawBytes};
      }
      void add(OtaArchive archive, PartitionInfo part, String folder, {bool keepBloat = false}) {
        if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(part.name)) throw FlashException('Invalid OTA partition name: ${part.name}');
        final path = '$folder/${part.name}.img';
        if (keepBloat && result._bloatImages.containsKey(path)) return;
        if (part.sha256 == null || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(part.sha256!)) {
          throw FlashException('${part.name}.img has no whole-image manifest SHA-256.');
        }
        result._bloatImages.remove(path);
        result._parts[path] = _OtaImage(archive, part);
      }
      if (conversion) {
        final target = {for (final p in ota.manifest.partitions()) p.name: p};
        for (final name in targetParts) {
          final part = target[name];
          if (part == null) throw FlashException('The TARGET OTA does not contain $name.');
          add(ota, part, 'Super');
        }
        final basePartsByName = {for (final p in base!.manifest.partitions()) p.name: p};
        for (final part in basePartsByName.values) {
          if (baseParts.contains(part.name)) { add(base, part, 'Super'); }
          else if (!targetParts.contains(part.name) && !const ['vbmeta', 'vbmeta_system', 'vbmeta_vendor'].contains(part.name)) {
            add(base, part, selection.imageFolder);
          }
        }
        for (final name in const ['vbmeta', 'vbmeta_system', 'vbmeta_vendor']) {
          final part = basePartsByName[name];
          if (part == null || part.size.toInt() > 1 << 20) throw FlashException('Missing or oversized BASE $name.img.');
          final source = OtaPartitionSource(ota: base, partition: part, cache: result.cache);
          try {
            final patched = makeVbmeta(includeDescriptorsFrom: [await source.read(0, source.length)], flags: 3, rollbackIndex: BigInt.zero);
            final path = '${selection.imageFolder}/$name.img';
            result._parts.remove(path);
            result._bloatImages.remove(path);
            result._bytes[path] = patched;
          } finally { await source.close(); }
        }
      } else {
        var extractedBoot = false;
        for (final part in ota.manifest.partitions()) {
          if (isSuper && (selection.dev == 'Ace5' || selection.dev == 'Ace6T') && selection.region != 'CN' && part.name == 'odm') continue;
          final packed = isSuper && (selection.dev == 'X9U' ? superParts : extractToSuper).contains(part.name);
          final folder = packed ? 'Super' : selection.imageFolder;
          final replaced = selection.dev == 'X9U' && result._bloatImages.containsKey('$folder/${part.name}.img');
          if (part.name == 'boot' && !replaced) extractedBoot = true;
          add(ota, part, folder, keepBloat: selection.dev == 'X9U');
        }
        if (isSuper && !extractedBoot) throw const FlashException('Full OTA boot.img missing after normal extraction rules.');
      }
      if (needsDonor) {
        final parts = donor!.manifest.partitions().where((p) => p.name == 'odm').toList();
        if (parts.length != 1 || parts.single.size <= BigInt.zero) throw const FlashException('The matched donor has no non-empty odm partition.');
        add(donor, parts.single, 'Super');
      }
      for (final image in result._parts.values) {
        await OtaPartitionSource(ota: image.archive, partition: image.part, cache: result.cache).close();
      }
      if (isSuper) {
        final sources = <String, FlashSource>{};
        var transferred = false;
        try {
          for (final name in superParts) {
            final path = 'Super/$name.img';
            if (result._parts.containsKey(path) || result._bloatImages.containsKey(path)) sources[name] = await result._open(path);
          }
          transferred = true;
          result._super = await VirtualSuperImage.create(sources, superSize!,
            expectedHashes: {
              for (final name in sources.keys)
                if (result.imageHash('Super/$name.img')?.isNotEmpty ?? false)
                  name: result.imageHash('Super/$name.img')!,
            });
        } on Object {
          if (!transferred) {
            for (final source in sources.values) { await source.close(); }
          }
          rethrow;
        }
        result._superInputHashes.addAll({
          for (final name in sources.keys) 'Super/$name.img': result.imageHash('Super/$name.img')!,
        });
        result._parts.removeWhere((path, _) => path.startsWith('Super/'));
        result._bloatImages.removeWhere((path, _) => path.startsWith('Super/'));
        if (selection.dev == 'X9U') result._bytes['META-INF/com/google/android/super-size'] = Uint8List.fromList(ascii.encode('$superSize\n'));
      }
      Map<String, int>? arb;
      try { arb = await (base ?? ota).arb(); } on Object { arb = null; }
      final hashes = <String, String>{
        for (final e in result._bloatImages.entries) e.key: e.value.asset.rawSha256,
        for (final e in result._parts.entries) if (e.value.part.sha256?.isNotEmpty ?? false) e.key: e.value.part.sha256!,
        for (final e in result._bytes.entries) if (e.key.endsWith('.img')) e.key: sha256.convert(e.value).toString(),
      };
      result.buildJson = Map.unmodifiable({
        'device': selection.device, 'dev': selection.dev, 'flasher_type': selection.kind,
        'region': selection.region, 'version': ota.version, 'output_format': 'virtual',
        'arb': arb, 'vulnerableAbl': vulnerableAbl ?? false,
        if (result._ablSource != null) 'abl_source': result._ablSource,
        'image_sha256': Map<String, String>.unmodifiable({...result._superInputHashes, ...hashes}),
      });
      return result;
    } on Object {
      await result._super?.close();
      await result.cache.close();
      rethrow;
    }
  }

  final OtaArchive ota;
  final Selection selection;
  final Workspace bloat;
  final Map<String, Object?> sourceIdentity;
  final Map<String, OtaArchive> _archives;
  final Map<String, BloatAsset> _selectedBloat;
  final Map<String, _OtaImage> _parts = {};
  final Map<String, _BloatImage> _bloatImages = {};
  final Map<String, Uint8List> _bytes = {};
  final OtaOperationCache cache;
  VirtualSuperImage? _super;
  final Map<String, String> _superInputHashes = {};
  final Map<String, String> _streamHashes = {};
  Map<String, Object?>? _ablSource;
  Map<String, Object?> receipt() => {
    ...buildJson, 'kind': selection.kind,
    'image_sha256': {
      ...Map<String, String>.from(buildJson['image_sha256']! as Map),
      ..._streamHashes,
      if (_super?.streamSha256 != null) 'super.img': _super!.streamSha256!,
    },
  };
  SparseScan? get superScan => _super?.scan;
  final String job;
  @override late final Map<String, Object?> buildJson;
  @override String get format => 'virtual';
  @override late final PackageIndex index = PackageIndex.fromEntries([
    ..._parts.keys, ..._bloatImages.keys, ..._bytes.keys, if (_super != null) 'super.img',
  ], buildJson: buildJson);
  bool isOtaImage(String path) => _parts.containsKey(path);
  String? imageHash(String path) => path == 'super.img' ? _super?.streamSha256 : _parts[path]?.part.sha256 ??
    _bloatImages[path]?.asset.rawSha256 ?? (_bytes.containsKey(path) ? sha256.convert(_bytes[path]!).toString() : null);
  @override Future<int> size(String path) async {
    if (path == 'super.img' && _super != null) {
      return _super!.length;
    }
    return _parts[path]?.part.size.toInt() ?? _bloatImages[path]?.asset.rawBytes ??
      _bytes[path]?.length ?? (throw FlashException('The virtual package is missing $path.'));
  }
  @override Future<FlashSource> open(String path) async {
    final source = await _open(path);
    return path == 'super.img' ? source : _verified(path, source);
  }
  Future<FlashSource> _open(String path) async {
    if (path == 'super.img' && _super != null) return _super!.open();
    final part = _parts[path];
    if (part != null) return OtaPartitionSource(ota: part.archive, partition: part.part, cache: cache);
    if (_bytes.containsKey(path)) return _BytesImage(_bytes[path]!);
    final image = _bloatImages[path];
    if (image == null) throw FlashException('The virtual package is missing $path.');
    return _LocalImage(await bloat.open(image.sourcePath));
  }
  FlashSource _verified(String path, FlashSource source) =>
    _VerifiedImage(source, imageHash(path), (digest) => _streamHashes[path] = digest, path);
  Future<FlashSource> openExpandedSuper() async => _super?.open(sparse: false) ?? (throw const FlashException('This package has no super image.'));
  @override Future<Map<String, Object?>> snapshot() async => {
    'format': format, 'job': job, 'source': sourceIdentity,
    if (_super != null) 'superSize': _super!.expandedLength,
    if (_super != null) 'superLayoutSha256': _super!.layoutHeadSha256,
    'otas': {for (final e in _archives.entries) e.key: {
      'otaBytes': e.value.length, 'manifestSha256': e.value.manifestSha256,
      'payloadDataOffset': e.value.payloadDataOffset, 'dataStart': e.value.dataStart,
      'partitions': {for (final part in e.value.manifest.partitions()) part.name: {'bytes': part.size.toInt(), 'sha256': part.sha256}},
    }},
    'selectedBloat': {for (final e in _selectedBloat.entries) e.key: {'bytes': e.value.rawBytes, 'sha256': e.value.rawSha256}},
    'bloat': {for (final e in _bloatImages.entries) e.key: {'source': e.value.sourcePath, 'bytes': e.value.asset.rawBytes, 'sha256': e.value.asset.rawSha256}},
    'buildJson': buildJson,
  };
  Future<void> close() async {
    await _super?.close();
    await cache.close();
    for (final archive in _archives.values) { await archive.close(); }
  }
}

final class _VerifiedImage implements FlashSource {
  _VerifiedImage(this.source, this.expected, this.record, this.path);
  final FlashSource source;
  final String? expected;
  final void Function(String) record;
  final String path;
  @override int get length => source.length;
  @override Future<Uint8List> read(int offset, int length) => source.read(offset, length);
  @override Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    final hash = Sha256Hasher();
    var count = 0;
    await for (final bytes in source.stream(chunkSize: chunkSize)) {
      hash.update(bytes: bytes);
      count += bytes.length;
      yield bytes;
    }
    if (count != length) throw FlashException('$path ended early.');
    final digest = hash.finishHex();
    if (expected != null && digest != expected!.toLowerCase()) throw FlashException('$path does not match its manifest SHA-256.');
    record(digest);
  }
  @override Future<FlashCursor> cursor() async => StreamingFlashCursor(stream(), length);
  @override Future<void> close() => source.close();
}

Future<void> _verifyBloat(Workspace workspace, String path, BloatAsset asset) async {
  try {
    if (!await workspace.exists(path)) throw FlashException('Missing local bloat image: $path');
    final source = await workspace.open(path);
    try {
      if (source.length != asset.rawBytes) throw FlashException('Bloat $path changed size (${source.length} != ${asset.rawBytes}).');
      final hasher = Sha256Hasher();
      for (var offset = 0; offset < source.length; offset += 4 << 20) {
        final count = math.min(4 << 20, source.length - offset);
        final bytes = await source.read(offset, count);
        if (bytes.length != count) throw FlashException('Bloat $path ended early at $offset.');
        hasher.update(bytes: bytes);
      }
      final digest = hasher.finishHex();
      if (digest != asset.rawSha256) throw FlashException('Bloat $path SHA-256 mismatch: $digest != ${asset.rawSha256}.');
    } finally { await closeByteSource(source); }
  } on FlashException { rethrow; } on Object catch (error) { throw FlashException('Cannot read local bloat $path: $error'); }
}

final class _LocalImage implements FlashSource {
  _LocalImage(this.source);
  final ByteSource source;
  @override int get length => source.length;
  @override Future<Uint8List> read(int offset, int length) => source.read(offset, length);
  @override Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    if (chunkSize <= 0) throw ArgumentError.value(chunkSize);
    for (var offset = 0; offset < length; offset += chunkSize) { yield await read(offset, math.min(chunkSize, length - offset)); }
  }
  @override Future<FlashCursor> cursor() async => RandomFlashCursor(this);
  @override Future<void> close() => closeByteSource(source);
}
final class _BytesImage implements FlashSource {
  _BytesImage(this.bytes);
  final Uint8List bytes;
  @override int get length => bytes.length;
  @override Future<Uint8List> read(int offset, int length) async => Uint8List.sublistView(bytes, offset, offset + length);
  @override Stream<Uint8List> stream({int chunkSize = 1 << 20}) async* {
    for (var p = 0; p < length; p += chunkSize) { yield await read(p, math.min(chunkSize, length - p)); }
  }
  @override Future<FlashCursor> cursor() async => RandomFlashCursor(this);
  @override Future<void> close() async {}
}
