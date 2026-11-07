import 'dart:async';
import 'dart:io';

import 'package:flasher_web_core/flasher_web_core.dart';

import 'config.dart';
import 'errors.dart';
import 'remote_source.dart';
import 'strict_http.dart';
import 'util.dart';

/// A verified bloat workspace shared by every job that needs this manifest.
final class BloatWorkspace {
  const BloatWorkspace({
    required this.manifestSha256,
    required this.workspace,
    required this.directory,
    required this.selected,
  });

  final String manifestSha256;
  final IoWorkspace workspace;
  final Directory directory;

  /// Manifest path to verified raw SHA-256 for this selection.
  final Map<String, String> selected;
}

/// Materializes the manifest's selected images once and reuses them.
final class BloatCache {
  BloatCache({
    required this.config,
    required this.http,
    required this.root,
  });

  final HostedConfig config;
  final StrictHttp http;
  final Directory root;
  final Map<String, _Mutex> _locks = {};

  Future<BloatWorkspace> prepare({
    required BloatManifest manifest,
    required String manifestSha256,
    required Selection selection,
  }) async {
    if (!isSha256Hex(manifestSha256)) {
      throw const HostedInternalException(
        'bloat_manifest_hash_invalid',
        'The bloat manifest hash is invalid.',
      );
    }
    final selected = _selectedHashes(manifest, selection);
    final directory = Directory(joinPath(root.path, [manifestSha256]));
    await directory.create(recursive: true);
    final workspace = IoWorkspace(directory);
    final lock = _locks.putIfAbsent(manifestSha256, _Mutex.new);
    await lock.run(() async {
      final store = BloatStore(workspace: workspace, manifest: manifest);
      var status = await store.inspect(selection);
      if (status.total == 0) {
        await _touch(directory);
        return;
      }
      if (status.ready) {
        await _touch(directory);
        return;
      }
      final started = DateTime.now();
      await for (final event in store.materialize(
        selection,
        (assetName) => EdgeRangeSource(
          http: http,
          assetName: assetName,
          length: _assetLength(manifest, assetName),
          maxChunk: 4 * 1024 * 1024,
        ),
      )) {
        if (event is BloatStep && event.message.contains('mismatch')) {
          throw HostedException(
            'bloat_verify_failed',
            'Bloat verification failed: ${event.message}',
            status: 502,
          );
        }
      }
      status = await store.inspect(selection);
      if (!status.ready) {
        throw const HostedException(
          'bloat_incomplete',
          'The bloat images were not verified after download.',
          status: 502,
        );
      }
      if (DateTime.now().difference(started) > config.jobTimeout) {
        throw const HostedException(
          'bloat_timeout',
          'Bloat preparation took longer than this server allows.',
          status: 504,
        );
      }
      await _touch(directory);
    });
    return BloatWorkspace(
      manifestSha256: manifestSha256,
      workspace: workspace,
      directory: directory,
      selected: selected,
    );
  }

  Future<void> _touch(Directory directory) => atomicWriteJson(
    File(joinPath(directory.path, ['.hosted-bloat.json'])),
    {
      'schema': 1,
      'lastUsedAt': isoUtc(DateTime.now().toUtc()),
    },
  );

  Map<String, String> _selectedHashes(
    BloatManifest manifest,
    Selection selection,
  ) {
    final result = <String, String>{};
    for (final relative in selectedPaths(manifest.source, selection)) {
      final key = manifest.files[relative];
      final asset = key == null ? null : manifest.assets[key];
      if (asset == null) {
        throw const HostedInternalException(
          'bloat_selection_invalid',
          'The bloat manifest does not cover this selection.',
        );
      }
      result[relative] = asset.rawSha256;
    }
    final keys = result.keys.toList()..sort();
    return {for (final key in keys) key: result[key]!};
  }

  int _assetLength(BloatManifest manifest, String assetName) {
    for (final asset in manifest.assets.values) {
      for (final part in asset.transportParts) {
        if (part.assetName == assetName) return part.bytes;
      }
    }
    throw const HostedInternalException(
      'bloat_asset_missing',
      'The bloat manifest does not declare a requested asset.',
    );
  }
}

final class _Mutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }
}
