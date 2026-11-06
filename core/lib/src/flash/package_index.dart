/// What a flasher package contains: its entry names and its `build.json`.
///
/// Built from a ZIP central directory (the Rust reader's entry names) or a
/// folder listing, so planning needs no I/O and runs before any write.
library;

import 'model.dart';

/// One image in the flasher's image folder.
final class PackageImage {
  const PackageImage({required this.stem, required this.path});

  /// The partition name the launcher derives: the file name without `.img`.
  final String stem;

  /// Package-relative path, for example `OOS_FILES_HERE/boot.img`.
  final String path;
}

final class PackageIndex {
  PackageIndex._(this.entries, this.buildJson, this._paths);

  /// Indexes [entries], the package's file names as the ZIP or folder lists
  /// them. Entries are package-relative (`OOS_FILES_HERE/boot.img`), use `/`
  /// separators, and must not climb out of the package.
  factory PackageIndex.fromEntries(
    Iterable<String> entries, {
    Map<String, Object?> buildJson = const {},
  }) {
    final normalized = <String>[];
    final paths = <String>{};
    for (final entry in entries) {
      final path = _normalizeEntry(entry);
      if (path == null) continue;
      if (!paths.add(path)) {
        throw FlashPlanException('Duplicate package entry: $path');
      }
      normalized.add(path);
    }
    return PackageIndex._(
      List.unmodifiable(normalized),
      Map.unmodifiable(buildJson),
      Set.unmodifiable(paths),
    );
  }

  /// File entries in package order (a ZIP central directory or folder order).
  final List<String> entries;

  /// The package's `build.json`, when it was included.
  final Map<String, Object?> buildJson;

  final Set<String> _paths;

  bool has(String path) => _paths.contains(path);

  /// Top-level `*.img` files in [folder], in package order. The launchers
  /// enumerate their image folder with a non-recursive glob and derive each
  /// partition by removing `.img`.
  List<PackageImage> imagesIn(String folder) {
    final prefix = folder.endsWith('/') ? folder : '$folder/';
    final images = <PackageImage>[];
    for (final path in entries) {
      if (!path.startsWith(prefix)) continue;
      final name = path.substring(prefix.length);
      if (name.contains('/')) continue;
      if (!name.endsWith('.img')) continue;
      final stem = name.substring(0, name.length - '.img'.length);
      if (stem.isEmpty) continue;
      images.add(PackageImage(stem: stem, path: path));
    }
    return List.unmodifiable(images);
  }

  /// Whether an entry exists; callers use it for the launchers' explicit
  /// existence checks (X9U's logical list, NEO8's boot list).
  bool imageExists(String folder, String stem) => has('$folder/$stem.img');

  static String? _normalizeEntry(String entry) {
    var path = entry.replaceAll('\\', '/');
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    if (path.isEmpty || path == '.') return null;
    if (path.endsWith('/')) {
      // Directory records carry no content.
      return null;
    }
    if (path.startsWith('/') || path.contains(':')) {
      throw FlashPlanException('Package entry is not relative: $entry');
    }
    final segments = path.split('/');
    for (final segment in segments) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        throw FlashPlanException('Unsafe package entry: $entry');
      }
    }
    return segments.join('/');
  }
}
