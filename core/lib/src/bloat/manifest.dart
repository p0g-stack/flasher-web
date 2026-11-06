/// The bloat asset manifest (`bloat/assets-manifest.json` upstream).
///
/// Port of `scripts/materialize_bloat.py`'s `load_manifest` validation and
/// of the field names `materialize`, `download_asset` and `inspect_downloads`
/// use. Paths are validated here once, so the store never has to trust them.
library;

import 'dart:convert';

/// A bloat manifest is malformed, or the selected images cannot be produced.
class BloatError implements Exception {
  const BloatError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One release asset, or one part of a multipart asset.
final class BloatAsset {
  const BloatAsset({
    required this.assetId,
    required this.assetName,
    required this.bytes,
    required this.sha256,
    required this.rawBytes,
    required this.rawSha256,
    required this.encoding,
    this.parts,
  });

  /// GitHub release asset id.
  final int assetId;

  /// GitHub release asset name.
  final String assetName;

  /// Transport size (the file on the release).
  final int bytes;

  /// Transport SHA-256, lowercase hex.
  final String sha256;

  /// Size of the image after decoding.
  final int rawBytes;

  /// SHA-256 of the image after decoding, lowercase hex.
  final String rawSha256;

  /// `identity` or `gzip`.
  final String encoding;

  /// Parts to concatenate before decoding; null for a single asset.
  final List<BloatPart>? parts;

  bool get gzip => encoding == 'gzip';

  /// The transport units to fetch, in order.
  List<BloatPart> get transportParts =>
      parts ?? [BloatPart(assetId: assetId, assetName: assetName, bytes: bytes, sha256: sha256)];
}

/// One part of a multipart release asset.
final class BloatPart {
  const BloatPart({
    required this.assetId,
    required this.assetName,
    required this.bytes,
    required this.sha256,
  });

  final int assetId;
  final String assetName;
  final int bytes;
  final String sha256;
}

/// The parsed manifest: assets by raw SHA-256 and destination paths to assets.
final class BloatManifest {
  const BloatManifest({
    required this.repository,
    required this.tag,
    required this.assets,
    required this.files,
    required this.source,
  });

  /// `owner/repository` the assets are released under.
  final String repository;

  /// Release tag holding the assets.
  final String tag;

  /// Assets keyed by their raw SHA-256 (the manifest's own key).
  final Map<String, BloatAsset> assets;

  /// Manifest paths (`bloat/<device>/<folder>/<name>.img`) to asset keys.
  final Map<String, String> files;

  /// The decoded JSON, for callers that also compute upstream paths.
  final Map<String, dynamic> source;

  /// Decodes and validates a manifest. Throws [BloatError] on any defect,
  /// with the same checks (and order) as upstream's `load_manifest`.
  factory BloatManifest.decode(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw BloatError('The bloat manifest is not valid JSON: ${error.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BloatError('The bloat manifest is not an object');
    }
    return BloatManifest.fromJson(decoded);
  }

  /// Validates a decoded manifest.
  factory BloatManifest.fromJson(Map<String, dynamic> json) {
    if (json['schema_version'] != 1) {
      throw const BloatError('Unsupported bloat manifest version');
    }
    final repository = json['repository'];
    if (repository is! String ||
        !RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
      throw const BloatError('Invalid release repository in bloat manifest');
    }
    final tag = json['tag'];
    if (tag is! String || tag.isEmpty) {
      throw const BloatError('Invalid release tag in bloat manifest');
    }
    final rawAssets = json['assets'];
    if (rawAssets is! Map<String, dynamic>) {
      throw const BloatError('Invalid bloat asset table');
    }
    final assets = <String, BloatAsset>{};
    for (final MapEntry(:key, :value) in rawAssets.entries) {
      if (!_sha256.hasMatch(key)) {
        throw const BloatError('Invalid raw asset checksum in manifest');
      }
      if (value is! Map<String, dynamic> || value['raw_sha256'] != key) {
        throw const BloatError('Invalid raw asset checksum in manifest');
      }
      final asset = _asset(value, key: key);
      assets[key] = asset;
    }

    final rawFiles = json['files'];
    if (rawFiles is! Map<String, dynamic>) {
      throw const BloatError('Invalid bloat file table');
    }
    final files = <String, String>{};
    for (final MapEntry(:key, :value) in rawFiles.entries) {
      if (!_safeDestination(key)) {
        throw BloatError('Unsafe bloat destination in manifest: $key');
      }
      if (value is! String || !assets.containsKey(value)) {
        throw const BloatError('Bloat path references a missing asset');
      }
      files[key] = value;
    }
    return BloatManifest(
      repository: repository,
      tag: tag,
      assets: Map.unmodifiable(assets),
      files: Map.unmodifiable(files),
      source: json,
    );
  }

  static BloatAsset _asset(Map<String, dynamic> json, {required String key}) {
    final sha256 = json['sha256'];
    if (sha256 is! String || !_sha256.hasMatch(sha256)) {
      throw const BloatError('Invalid transport checksum in manifest');
    }
    final encoding = json['encoding'];
    if (encoding != 'identity' && encoding != 'gzip') {
      throw const BloatError('Unsupported bloat asset encoding');
    }
    final bytes = json['bytes'];
    final rawBytes = json['raw_bytes'];
    if (bytes is! int || bytes <= 0 || rawBytes is! int || rawBytes <= 0) {
      throw const BloatError('Invalid asset size or ID in manifest');
    }
    final assetId = json['asset_id'];
    final assetName = json['asset_name'];
    if (assetId is! int || assetId <= 0 || assetName is! String || !_assetName.hasMatch(assetName)) {
      throw const BloatError('Invalid release asset ID');
    }

    final rawParts = json['parts'];
    List<BloatPart>? parts;
    if (rawParts != null) {
      if (rawParts is! List || rawParts.length < 2 || rawParts.length > 100) {
        throw const BloatError('Invalid multipart asset');
      }
      parts = [for (final part in rawParts) _part(part)];
      var sum = 0;
      for (final part in parts) {
        sum += part.bytes;
      }
      if (sum != bytes) {
        throw const BloatError('Multipart asset size mismatch');
      }
    } else {
      parts = null;
    }
    return BloatAsset(
      assetId: assetId,
      assetName: assetName,
      bytes: bytes,
      sha256: sha256,
      rawBytes: rawBytes,
      rawSha256: key,
      encoding: encoding,
      parts: parts,
    );
  }

  static BloatPart _part(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const BloatError('Invalid multipart asset');
    }
    final assetId = raw['asset_id'];
    if (assetId is! int || assetId <= 0) {
      throw const BloatError('Invalid release asset ID');
    }
    final bytes = raw['bytes'];
    if (bytes is! int || bytes <= 0 || bytes >= 2 * 1024 * 1024 * 1024) {
      throw const BloatError('Invalid release asset size');
    }
    final sha256 = raw['sha256'];
    if (sha256 is! String || !_sha256.hasMatch(sha256)) {
      throw const BloatError('Invalid release asset checksum');
    }
    final assetName = raw['asset_name'];
    if (assetName is! String || !_assetName.hasMatch(assetName)) {
      throw const BloatError('Invalid release asset name');
    }
    return BloatPart(assetId: assetId, assetName: assetName, bytes: bytes, sha256: sha256);
  }

  /// A destination must stay under `bloat/`, use `/`, and name an `.img`.
  static bool _safeDestination(String path) {
    if (!path.endsWith('.img') || path.contains(r'\') || path.startsWith('/')) {
      return false;
    }
    final parts = path.split('/');
    if (parts.length < 4 ||
        parts.first != 'bloat' ||
        parts.contains('..') ||
        parts.contains('.') ||
        parts.any((part) => part.isEmpty)) {
      return false;
    }
    return parts.join('/') == path;
  }

  static final RegExp _sha256 = RegExp(r'^[a-f0-9]{64}$');
  static final RegExp _assetName = RegExp(r'^[A-Za-z0-9_.-]+$');
}
