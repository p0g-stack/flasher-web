import 'dart:convert';
import 'dart:io';

import 'package:flasher_web_core/flasher_web_core.dart';

import 'config.dart';
import 'util.dart';

/// The operator-owned upstream snapshot, verified once at startup.
final class UpstreamSnapshot {
  const UpstreamSnapshot({
    required this.directory,
    required this.tables,
    required this.manifest,
    required this.manifestSha256,
    required this.snapshotSha256,
  });

  final Directory directory;
  final UpstreamTables tables;
  final BloatManifest manifest;
  final String manifestSha256;
  final String snapshotSha256;

  String get base => directory.absolute.path;
  String get commit => tables.commit;

  static Future<UpstreamSnapshot> load(Directory directory) async {
    final tablesFile = File(joinPath(directory.path, ['tables.json']));
    final manifestFile = File(joinPath(directory.path, ['bloat-manifest.json']));
    final tools = File(joinPath(directory.path, ['platform-tools.zip']));
    if (!await tablesFile.exists() ||
        !await manifestFile.exists() ||
        !await tools.exists()) {
      throw const HostedConfigException(
        'The upstream snapshot is missing tables.json, bloat-manifest.json or '
        'platform-tools.zip',
      );
    }
    final tables = UpstreamTables.parse(await tablesFile.readAsString());
    final manifestBytes = await manifestFile.readAsBytes();
    final manifest = BloatManifest.decode(utf8.decode(manifestBytes));

    final entries = <({String path, String sha256})>[];
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = entity.path
          .substring(directory.path.length)
          .replaceAll(Platform.pathSeparator, '/')
          .replaceFirst(RegExp(r'^/+'), '');
      if (!_relevant(relative)) continue;
      final sha = await sha256File(entity);
      entries.add((path: relative, sha256: sha));
    }
    entries.sort((left, right) => left.path.compareTo(right.path));
    if (entries.isEmpty) {
      throw const HostedConfigException('The upstream snapshot is empty');
    }
    final snapshotSha = canonicalSha256({
      'files': [
        for (final entry in entries)
          {'path': entry.path, 'sha256': entry.sha256},
      ],
    });
    return UpstreamSnapshot(
      directory: directory.absolute,
      tables: tables,
      manifest: manifest,
      manifestSha256: sha256Hex(manifestBytes),
      snapshotSha256: snapshotSha,
    );
  }

  static bool _relevant(String relative) {
    if (relative.startsWith('.') || relative.contains('/.')) return false;
    return relative == 'tables.json' ||
        relative == 'bloat-manifest.json' ||
        relative == 'platform-tools.zip' ||
        (relative.startsWith('templates/') && relative.endsWith('.zip'));
  }
}
