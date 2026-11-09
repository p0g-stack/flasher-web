/// The bloat image store: verify, fetch and stage the selected images.
///
/// Mirrors `scripts/materialize_bloat.py`: the same selected paths, the same
/// part concatenation and gzip decoding, and the same size + SHA-256 checks
/// before an image replaces its destination. The workspace is the bloat
/// destination root; destinations are the manifest paths minus `bloat/`.
library;

import 'dart:math';
import 'dart:typed_data';

import '../storage/budget.dart';
import '../storage/hashing.dart';
import '../storage/storage.dart';
import '../upstream/bloat_selection.dart';
import '../upstream/tables.dart';
import 'gunzip.dart';
import 'manifest.dart';

/// What a bloat inspection found.
final class BloatStatus {
  const BloatStatus({
    required this.total,
    required this.downloaded,
    required this.bytes,
    required this.ready,
  });

  /// Number of selected images.
  final int total;

  /// Number that exist and match their declared size and SHA-256.
  final int downloaded;

  /// Total decoded size of the selected images.
  final int bytes;

  /// Every selected image is present and verified.
  final bool ready;
}

/// Progress and results from [BloatStore.materialize].
sealed class BloatEvent {
  const BloatEvent();
}

/// The materialization started; [total] images, [bytes] decoded in all.
final class BloatStarted extends BloatEvent {
  const BloatStarted({required this.total, required this.bytes});

  final int total;
  final int bytes;
}

/// A step, such as reusing an image or downloading an asset.
final class BloatStep extends BloatEvent {
  const BloatStep({
    required this.message,
    this.path,
    required this.completed,
    required this.total,
    required this.bytesDone,
    required this.bytesTotal,
  });

  final String message;
  final String? path;
  final int completed;
  final int total;
  final int bytesDone;
  final int bytesTotal;
}

/// Transport bytes downloaded for one image.
final class BloatByteProgress extends BloatEvent {
  const BloatByteProgress({
    required this.path,
    required this.bytes,
    required this.total,
  });

  final String path;
  final int bytes;
  final int total;
}

/// Everything is in place.
final class BloatFinished extends BloatEvent {
  const BloatFinished(this.paths);

  /// Workspace-relative destinations, in manifest order.
  final List<String> paths;
}

/// Verifies and materializes the selected bloat images in a [Workspace].
final class BloatStore {
  BloatStore({
    required this.workspace,
    required this.manifest,
    Gunzip Function()? gunzip,
    this.budget,
  }) : _gunzip = gunzip ?? createGunzip;

  final Workspace workspace;
  final BloatManifest manifest;
  final Gunzip Function() _gunzip;

  /// The storage budget every download must fit, or null when the caller has
  /// none (the CLI does not need one). The check runs before an asset is
  /// fetched, so a full origin refuses the download instead of failing halfway.
  final StorageBudget? budget;

  static const int _chunk = 4 * 1024 * 1024;

  /// Inspects what the selected images need and what is already verified.
  ///
  /// Never downloads. A file is counted only when its size and SHA-256 match
  /// the manifest, as upstream's `inspect_downloads` does.
  Future<BloatStatus> inspect(
    Selection selection, {
    bool staticOdm = false,
  }) async {
    final paths = _selected(selection, staticOdm: staticOdm);
    var downloaded = 0;
    var bytes = 0;
    for (final item in paths) {
      bytes += item.asset.rawBytes;
      if (await _matches(item.target, item.asset)) downloaded++;
    }
    return BloatStatus(
      total: paths.length,
      downloaded: downloaded,
      bytes: bytes,
      ready: paths.isNotEmpty && downloaded == paths.length,
    );
  }

  /// Fetches missing images through [fetch] and stages all selected images.
  ///
  /// [fetch] receives a release asset name (a part name for multipart
  /// assets) and returns its bytes; the app serves them from `/api/bloat/`.
  /// Images already present and verified are kept. The final event carries
  /// the workspace-relative destinations. Cancelling the subscription stops
  /// the work at the next chunk boundary; an unfinished image is removed.
  Stream<BloatEvent> materialize(
    Selection selection,
    ByteSource Function(String assetName) fetch, {
    bool staticOdm = false,
  }) async* {
    final items = _selected(selection, staticOdm: staticOdm);
    final totalBytes = items.fold<int>(
      0,
      (sum, item) => sum + item.asset.rawBytes,
    );
    yield BloatStarted(total: items.length, bytes: totalBytes);

    var completed = 0;
    var bytesDone = 0;
    for (final item in items) {
      final asset = item.asset;
      if (await _matches(item.target, asset)) {
        completed++;
        bytesDone += asset.rawBytes;
        yield BloatStep(
          message: 'Using verified local image: ${item.relative}',
          path: item.target,
          completed: completed,
          total: items.length,
          bytesDone: bytesDone,
          bytesTotal: totalBytes,
        );
        continue;
      }

      yield BloatStep(
        message: asset.parts == null
            ? 'Downloading release asset: ${asset.assetName}'
            : 'Downloading ${asset.parts!.length} parts: ${asset.assetName}',
        path: item.target,
        completed: completed,
        total: items.length,
        bytesDone: bytesDone,
        bytesTotal: totalBytes,
      );

      await _ensureBudget(item);

      // 2^31 - 1 works on both the VM and dart2js, where `1 << 32` is 0.
      final suffix =
          '${DateTime.now().microsecondsSinceEpoch}-'
          '${_random.nextInt(0x7FFFFFFF)}';
      final partial = '${item.target}.part-$suffix';
      final transportPath = asset.gzip || asset.parts != null
          ? '${item.target}.transport-$suffix'
          : partial;
      var keep = false;
      try {
        await for (final fetched in _download(asset, fetch, transportPath)) {
          yield BloatByteProgress(
            path: item.target,
            bytes: fetched,
            total: asset.bytes,
          );
        }
        if (asset.gzip) {
          await for (final decoded in _decode(transportPath, partial, asset)) {
            yield BloatByteProgress(
              path: item.target,
              bytes: decoded,
              total: asset.rawBytes,
            );
          }
        } else if (transportPath != partial) {
          await workspace.move(transportPath, partial);
        }
        await _verifyFile(partial, asset.rawBytes, asset.rawSha256);
        await _replace(partial, item.target);
        keep = true;
        completed++;
        bytesDone += asset.rawBytes;
        yield BloatStep(
          message: 'Verified and staged: ${item.relative}',
          path: item.target,
          completed: completed,
          total: items.length,
          bytesDone: bytesDone,
          bytesTotal: totalBytes,
        );
      } finally {
        if (!keep) await _deleteIfExists(partial);
        if (transportPath != partial) await _deleteIfExists(transportPath);
      }
    }
    yield BloatFinished([for (final item in items) item.target]);
  }

  /// Downloads and verifies one transport asset, yielding bytes written.
  Stream<int> _download(
    BloatAsset asset,
    ByteSource Function(String) fetch,
    String path,
  ) async* {
    final sink = await workspace.create(path);
    var written = 0;
    final whole = StreamingSha256();
    var failed = true;
    try {
      for (final part in asset.transportParts) {
        final source = fetch(part.assetName);
        if (source.length != part.bytes) {
          throw BloatError('Release asset size mismatch: ${part.assetName}');
        }
        final one = StreamingSha256();
        var offset = 0;
        while (offset < part.bytes) {
          final want = min(_chunk, part.bytes - offset);
          final bytes = await source.read(offset, want);
          if (bytes.isEmpty || bytes.length > want) {
            throw BloatError('Release asset ended early: ${part.assetName}');
          }
          one.add(bytes);
          whole.add(bytes);
          await sink.write(bytes, written);
          written += bytes.length;
          offset += bytes.length;
          if (written > asset.bytes) {
            throw BloatError(
              'Release asset exceeds its declared size: ${asset.assetName}',
            );
          }
          yield written;
        }
        if (one.hex != part.sha256) {
          throw BloatError('Release asset SHA-256 mismatch: ${part.assetName}');
        }
      }
      if (written != asset.bytes || whole.hex != asset.sha256) {
        throw BloatError(
          'Release asset size/SHA-256 mismatch: ${asset.assetName}',
        );
      }
      failed = false;
    } finally {
      await sink.close();
      if (failed) await _deleteIfExists(path);
    }
  }

  /// Decodes a verified gzip transport asset into [output], yielding bytes
  /// decoded so far.
  Stream<int> _decode(
    String transport,
    String output,
    BloatAsset asset,
  ) async* {
    final source = await workspace.open(transport);
    final sink = await workspace.create(output);
    final decoder = _gunzip();
    final hasher = StreamingSha256();
    var written = 0;
    var failed = true;
    try {
      var offset = 0;
      while (offset < source.length) {
        final bytes = await source.read(
          offset,
          min(_chunk, source.length - offset),
        );
        if (bytes.isEmpty) {
          throw BloatError('Gzip asset ended early: ${asset.assetName}');
        }
        offset += bytes.length;
        written += await _writeDecoded(
          sink,
          decoder.push(bytes),
          hasher,
          written,
          asset,
        );
        if (written > asset.rawBytes) {
          throw BloatError(
            'Decompressed bloat image exceeds its declared size',
          );
        }
        yield written;
      }
      written += await _writeDecoded(
        sink,
        decoder.finish(),
        hasher,
        written,
        asset,
      );
      if (written != asset.rawBytes || hasher.hex != asset.rawSha256) {
        throw BloatError(
          'Original image size/SHA-256 mismatch: ${asset.assetName}',
        );
      }
      failed = false;
    } finally {
      await sink.close();
      await closeByteSource(source);
      if (failed) await _deleteIfExists(output);
    }
  }

  Future<int> _writeDecoded(
    ByteSink sink,
    List<int> bytes,
    StreamingSha256 hasher,
    int offset,
    BloatAsset asset,
  ) async {
    if (bytes.isEmpty) return 0;
    if (offset + bytes.length > asset.rawBytes) {
      throw const BloatError(
        'Decompressed bloat image exceeds its declared size',
      );
    }
    hasher.add(bytes);
    await sink.write(Uint8List.fromList(bytes), offset);
    return bytes.length;
  }

  List<_Item> _selected(Selection selection, {required bool staticOdm}) {
    final relativePaths = selectedPaths(
      manifest.source,
      selection,
      staticOdm: staticOdm,
    );
    final items = <_Item>[];
    for (final relative in relativePaths) {
      final key = manifest.files[relative];
      final asset = key == null ? null : manifest.assets[key];
      if (asset == null) {
        throw BloatError('Bloat path references a missing asset: $relative');
      }
      final target = _target(relative);
      items.add(_Item(relative: relative, target: target, asset: asset));
    }
    return items;
  }

  /// The manifest path without its `bloat/` root.
  static String _target(String relative) {
    const root = 'bloat/';
    if (!relative.startsWith(root)) {
      throw BloatError('Unsafe bloat destination in manifest: $relative');
    }
    final target = relative.substring(root.length);
    if (target.isEmpty ||
        target.split('/').any((part) => part.isEmpty || part == '..')) {
      throw BloatError('Unsafe bloat destination in manifest: $relative');
    }
    return target;
  }

  Future<bool> _matches(String target, BloatAsset asset) async {
    try {
      if (!await workspace.exists(target) ||
          await workspace.size(target) != asset.rawBytes) {
        return false;
      }
      final source = await workspace.open(target);
      try {
        final hasher = StreamingSha256();
        var offset = 0;
        while (offset < asset.rawBytes) {
          final bytes = await source.read(
            offset,
            min(_chunk, asset.rawBytes - offset),
          );
          if (bytes.isEmpty) return false;
          offset += bytes.length;
          hasher.add(bytes);
        }
        return hasher.hex == asset.rawSha256;
      } finally {
        await closeByteSource(source);
      }
    } on Object {
      return false;
    }
  }

  Future<void> _verifyFile(String path, int size, String sha256) async {
    if (!await workspace.exists(path) || await workspace.size(path) != size) {
      throw BloatError('Image size mismatch: $path');
    }
    final source = await workspace.open(path);
    try {
      final hasher = StreamingSha256();
      var offset = 0;
      while (offset < size) {
        final bytes = await source.read(offset, min(_chunk, size - offset));
        if (bytes.isEmpty) throw BloatError('Image ended early: $path');
        offset += bytes.length;
        hasher.add(bytes);
      }
      if (hasher.hex != sha256) {
        throw BloatError('Image SHA-256 mismatch: $path');
      }
    } finally {
      await closeByteSource(source);
    }
  }

  /// Checks that the transport file — plus the decoded image while gzip
  /// decoding keeps both — fits the budget before the download starts.
  ///
  /// An existing destination file is subtracted: staging replaces it with a
  /// move, so only the growth is new usage.
  Future<void> _ensureBudget(_Item item) async {
    final budget = this.budget;
    if (budget == null) return;
    final asset = item.asset;
    var needed = asset.gzip ? asset.bytes + asset.rawBytes : asset.bytes;
    try {
      if (await workspace.exists(item.target)) {
        needed -= await workspace.size(item.target);
      }
    } on Object {
      // An unreadable destination is replaced anyway; keep the full estimate.
    }
    if (needed > 0) await budget.ensure(needed);
  }

  Future<void> _replace(String from, String to) => workspace.move(from, to);

  Future<void> _deleteIfExists(String path) async {
    try {
      if (await workspace.exists(path)) await workspace.delete(path);
    } on Object {
      // Best effort: a stale temporary file must not hide the real error.
    }
  }

  static final Random _random = Random.secure();
}

final class _Item {
  const _Item({
    required this.relative,
    required this.target,
    required this.asset,
  });

  final String relative;
  final String target;
  final BloatAsset asset;
}
