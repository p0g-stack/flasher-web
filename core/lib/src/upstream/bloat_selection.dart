/// Which bloat manifest images a build uses.
///
/// Port of `bloat_folder` and `selected_paths` from
/// `scripts/materialize_bloat.py`.
library;

import 'tables.dart';

/// The bloat folder this build reads, before conversion exceptions.
String bloatFolder(String dev, String kind, String region) {
  if (dev == 'X9U' && region == 'CN') return 'EU_BLOAT';
  if (dev == 'Ace6' && kind == 'SuperHybrid Flasher' && region == 'IN') {
    return 'OOS_BLOAT';
  }
  return '${region}_BLOAT';
}

/// Manifest destination paths (`bloat/<dev>/...`) this build needs, sorted.
///
/// [manifest] is the parsed `bloat-manifest.json`: only its `files` keys are
/// read. [staticOdm] includes Ace 6T's static ODM image; the build normally
/// excludes it and patches in a release with the matching security patch.
List<String> selectedPaths(
  Map<String, dynamic> manifest,
  Selection selection, {
  bool staticOdm = false,
}) {
  final dev = selection.dev;
  final kind = selection.kind;
  final region = selection.region;
  if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(dev)) {
    throw const UpstreamException('Invalid device ID');
  }
  if (!RegExp(r'^[A-Z]{2,3}$').hasMatch(region)) {
    throw const UpstreamException('Invalid region code');
  }
  final files = manifest['files'];
  if (files is! Map) {
    throw const UpstreamException('Invalid bloat manifest');
  }
  final main = bloatFolder(dev, kind, region);
  final prefix = 'bloat/$dev/';
  final extra = <String>{};
  if (region == 'CN' && dev != 'X9U') {
    extra.add('${prefix}GLO_BLOAT/my_preload.img');
  }
  if (dev == '13' && kind == 'SuperHybrid Flasher' && region != 'CN') {
    for (final name in ['my_region', 'oplusstanvbk']) {
      extra.add('${prefix}COS_FILES_HERE/$name.img');
    }
  }
  if (dev == '13T' && kind == 'Super Flasher' && region == 'IN') {
    for (final name in ['my_region', 'oplusstanvbk', 'odm']) {
      extra.add('${prefix}FIXES/$name.img');
    }
  }
  if (dev == 'GT7Pro' && kind == 'Super Flasher' && region == 'EU') {
    for (final name in ['my_region', 'oplusstanvbk']) {
      extra.add('${prefix}FIXES/$name.img');
    }
  }
  final paths = [
    for (final path in files.keys)
      if (path is String) path,
  ]..sort();
  final dynamicOdm =
      dev == 'Ace6T' &&
      kind == 'Super Flasher' &&
      (region == 'IN' || region == 'GLO');
  return [
    for (final path in paths)
      if ((path.startsWith('$prefix$main/') || extra.contains(path)) &&
          (staticOdm || !(dynamicOdm && path.endsWith('/odm.img'))))
        path,
  ];
}
