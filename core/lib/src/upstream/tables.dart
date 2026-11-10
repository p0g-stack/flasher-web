/// The upstream workflow tables: devices, builders, super sizes and the
/// selection rule that follows from them.
///
/// Port of `backend.Catalog` in `flasher_builder/backend.py`.
library;

import 'dart:collection';
import 'dart:convert';

import 'device_layout.dart' as layout;

/// A failure in the upstream tables or in a requested selection.
final class UpstreamException implements Exception {
  const UpstreamException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One `BUILDER_MAP["<kind>|<dev>|<region>"]="<builder>"` row.
final class BuilderEntry {
  const BuilderEntry({
    required this.type,
    required this.dev,
    required this.region,
    required this.builder,
  });

  /// The flasher type, for example `SuperHybrid Flasher`.
  final String type;

  /// Upstream's short device ID, for example `13` or `X9U`.
  final String dev;

  final String region;

  /// The workflow script name, for example `BUILD_SUPER.sh`.
  final String builder;

  @override
  bool operator ==(Object other) =>
      other is BuilderEntry &&
      other.type == type &&
      other.dev == dev &&
      other.region == region &&
      other.builder == builder;

  @override
  int get hashCode => Object.hash(type, dev, region, builder);

  @override
  String toString() => '$type|$dev|$region -> $builder';
}

/// `["<dev>"]="<cn> <other>"` from `SUPER_SIZE_TABLE`.
final class RegionSizes {
  const RegionSizes(this.cn, this.other);

  final int cn;
  final int other;

  int forRegion(String region) => region == 'CN' ? cn : other;

  @override
  bool operator ==(Object other) =>
      other is RegionSizes && other.cn == cn && other.other == this.other;

  @override
  int get hashCode => Object.hash(cn, other);

  @override
  String toString() => '$cn $other';
}

/// One supported device, flasher type and region.
///
/// [dev], [kind] and [region] are the only fields a caller must provide, so a
/// bloat or pipeline test can build one without loading the tables. The
/// derived getters use upstream's `device_layout` rules.
final class Selection {
  const Selection({
    required this.dev,
    required this.kind,
    required this.region,
    this.device = '',
    this.builder = '',
  });

  /// Upstream short device ID, for example `X9U`.
  final String dev;

  /// Workflow flasher type, for example `Super Flasher`.
  final String kind;

  final String region;

  /// The human device name from `DEV_MAP`, when known.
  final String device;

  /// The workflow's builder script, when known.
  final String builder;

  /// `cos` or `oos`.
  String get subtree => layout.templateSubtree(dev, region);

  /// The template folder inside the device's template package:
  /// `<subtree>/super` or `<subtree>/regional`.
  String get template =>
      '$subtree/${kind.contains('Super') ? 'super' : 'regional'}';

  /// The folder the flasher expects the extracted images in.
  String get imageFolder => layout.imageFolder(dev, region);

  /// Whether this selection uses a ColorOS template.
  bool get coloros => layout.coloros(dev, region);

  @override
  bool operator ==(Object other) =>
      other is Selection &&
      other.dev == dev &&
      other.kind == kind &&
      other.region == region &&
      other.device == device &&
      other.builder == builder;

  @override
  int get hashCode => Object.hash(dev, kind, region, device, builder);

  @override
  String toString() =>
      'Selection($device/$dev, $kind, $region -> $builder, $template)';
}

/// The parsed upstream `tables.json`.
///
/// `{"commit": "...", "devices": {...}, "region_sizes": {...},
///  "builders": [[type, dev, region, builder], ...]}`.
final class UpstreamTables {
  UpstreamTables({
    this.commit = '',
    this.superParts = const [],
    required Map<String, String> devices,
    required Map<String, RegionSizes> regionSizes,
    required Iterable<BuilderEntry> builders,
  }) : devices = Map.unmodifiable(devices),
       regionSizes = Map.unmodifiable(regionSizes),
       _builders =
           LinkedHashMap<
             ({String type, String dev, String region}),
             BuilderEntry
           >() {
    for (final builder in builders) {
      _builders[(
            type: builder.type,
            dev: builder.dev,
            region: builder.region,
          )] =
          builder;
    }
  }

  /// Ordered names from native_pipeline.py SUPER_PARTS, never inferred from OTA contents.
  final List<String> superParts;

  factory UpstreamTables.fromJson(Object? json) {
    final root = _object(json, 'tables.json');
    final devices = <String, String>{};
    final rawDevices = _object(root['devices'], 'devices');
    for (final entry in rawDevices.entries) {
      devices[entry.key] = _string(entry.value, 'devices.${entry.key}');
    }

    final regionSizes = <String, RegionSizes>{};
    final rawSizes = _object(root['region_sizes'], 'region_sizes');
    for (final entry in rawSizes.entries) {
      final sizes = entry.value;
      if (sizes is! List || sizes.length != 2) {
        throw const UpstreamException('Invalid region_sizes in tables.json.');
      }
      regionSizes[entry.key] = RegionSizes(
        _integer(sizes[0], 'region_sizes.${entry.key}[0]'),
        _integer(sizes[1], 'region_sizes.${entry.key}[1]'),
      );
    }

    final builders = <BuilderEntry>[];
    final rawBuilders = root['builders'];
    if (rawBuilders is! List) {
      throw const UpstreamException('Invalid builders in tables.json.');
    }
    for (final row in rawBuilders) {
      if (row is! List || row.length != 4) {
        throw const UpstreamException('Invalid builders in tables.json.');
      }
      builders.add(
        BuilderEntry(
          type: _string(row[0], 'builders[][0]'),
          dev: _string(row[1], 'builders[][1]'),
          region: _string(row[2], 'builders[][2]'),
          builder: _string(row[3], 'builders[][3]'),
        ),
      );
    }

    if (devices.isEmpty || builders.isEmpty) {
      throw const UpstreamException(
        'The workflow device/builder tables could not be read.',
      );
    }
    final tables = UpstreamTables(
      commit: root['commit'] is String ? root['commit'] as String : '',
      devices: devices,
      regionSizes: regionSizes,
      builders: builders,
      superParts: root['super_parts'] == null ? const [] :
        List<String>.unmodifiable((root['super_parts']! as List).map((value) =>
          _string(value, 'super_parts'))),
    );
    return tables;
  }

  /// Parse the snapshot file contents.
  factory UpstreamTables.parse(String source) {
    try {
      return UpstreamTables.fromJson(jsonDecode(source));
    } on FormatException catch (error) {
      throw UpstreamException('tables.json is not valid JSON: $error');
    }
  }

  /// The upstream commit the snapshot was made from, when recorded.
  final String commit;

  /// `DEV_MAP`: human name to short device ID, in workflow order.
  final Map<String, String> devices;

  /// `SUPER_SIZE_TABLE`: short device ID to CN/other super size.
  final Map<String, RegionSizes> regionSizes;

  final LinkedHashMap<({String type, String dev, String region}), BuilderEntry>
  _builders;

  /// Builder rows in workflow order.
  List<BuilderEntry> get builders => List.unmodifiable(_builders.values);

  static const _standardRegions = ['GLO', 'EU', 'IN', 'NA', 'CN'];

  /// The short device ID for a human name, or an [UpstreamException].
  String devOf(String device) {
    final dev = devices[device];
    if (dev == null) {
      throw UpstreamException('Unknown device in the upstream tables: $device');
    }
    return dev;
  }

  /// Flasher types for [device], in workflow order. Port of `Catalog.types`.
  List<String> types(String device) {
    final dev = devOf(device);
    final seen = <String>{};
    return [
      for (final builder in _builders.values)
        if (builder.dev == dev && seen.add(builder.type)) builder.type,
    ];
  }

  /// Regions for [device] and [kind]. Standard regions keep their fixed order;
  /// a non-standard region set is sorted. Port of `Catalog.regions`.
  List<String> regions(String device, String kind) {
    final dev = devOf(device);
    final available = {
      for (final builder in _builders.values)
        if (builder.type == kind && builder.dev == dev) builder.region,
    };
    if (available.difference(_standardRegions.toSet()).isNotEmpty) {
      return available.toList()..sort();
    }
    return [
      for (final region in _standardRegions)
        if (available.contains(region)) region,
    ];
  }

  /// CN or other super size. Missing tables entries are `0`, as upstream's
  /// `region_sizes.get(device, (0, 0))`.
  int superSize(String dev, String region) =>
      (regionSizes[dev] ?? const RegionSizes(0, 0)).forRegion(region);

  /// The selected build, or an [UpstreamException] when the workflow does not
  /// list it.
  ///
  /// Template package contents are checked by the caller: `tables.json` has no
  /// directory tree. Upstream's checks are that `<template>` exists and, for a
  /// Hybrid kind, that `<template>/META-INF` exists.
  Selection selection(String device, String kind, String region) {
    final dev = devices[device];
    final builder = dev == null
        ? null
        : _builders[(type: kind, dev: dev, region: region)];
    if (builder == null) {
      throw const UpstreamException(
        'This device, flasher type and region combination is unsupported.',
      );
    }
    return Selection(
      dev: dev!,
      kind: kind,
      region: region,
      device: device,
      builder: builder.builder,
    );
  }

  /// A lookup that may return null instead of throwing.
  BuilderEntry? builderFor(String dev, String kind, String region) =>
      _builders[(type: kind, dev: dev, region: region)];
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map<String, Object?>) {
    throw UpstreamException('Invalid $field in tables.json.');
  }
  return value;
}

String _string(Object? value, String field) {
  if (value is! String) {
    throw UpstreamException('Invalid $field in tables.json.');
  }
  return value;
}

int _integer(Object? value, String field) {
  if (value is! num || value % 1 != 0) {
    throw UpstreamException('Invalid $field in tables.json.');
  }
  return value.toInt();
}
