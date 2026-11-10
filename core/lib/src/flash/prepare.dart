/// Read-only preparation: bind a job, a device and every answer before a
/// single write.
///
/// Preparation opens the device only for `getvar` reads, inspects every image
/// the plan will flash, and returns an immutable ticket. The service keeps the
/// ticket and refuses a flash whose request, device, package or images no
/// longer match it.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';

import '../upstream/tables.dart';
import 'model.dart';
import 'package.dart';
import 'plan.dart';
import 'sparse.dart';
import 'virtual.dart';

/// One image after inspection.
final class FlashImageInfo {
  const FlashImageInfo({
    required this.path,
    required this.bytes,
    required this.sparse,
    required this.digest,
    required this.parts,
    this.manifestSha256,
    this.scan,
  });

  final String path;
  final int bytes;
  final bool sparse;
  final String digest;
  final int parts;
  final String? manifestSha256;

  /// The chunk map from preparation, so execution does not scan the image
  /// again just to split it.
  final SparseScan? scan;

  Map<String, Object?> toMap() => {
    'path': path,
    'bytes': bytes,
    'sparse': sparse,
    'digest': digest,
    'parts': parts,
    if (manifestSha256 != null) 'manifestSha256': manifestSha256,
  };
}

final class FlashPromptInfo {
  const FlashPromptInfo({
    required this.id,
    required this.question,
    required this.choices,
    required this.selected,
  });

  final String id;
  final String question;
  final List<String> choices;
  final String? selected;

  Map<String, Object?> toMap() => {
    'id': id,
    'question': question,
    'choices': choices,
    'selected': selected,
  };
}

/// Everything a confirmed flash needs. Immutable except for the token.
final class PreparedFlash {
  PreparedFlash({
    required this.token,
    required this.serial,
    required this.mode,
    required this.maxDownloadSize,
    required this.selection,
    required this.answers,
    required this.job,
    required this.format,
    required this.version,
    required this.plan,
    required this.package,
    required this.images,
    required this.binding,
    required this.createdAt,
    required this.warnings,
  }) : logicalPartitions = Set.unmodifiable({
         if (plan.isResolved)
           for (final step in plan.executionSteps)
             if (step is CreateLogical) step.name,
       });

  final String token;
  final String serial;
  final FlashMode mode;
  final int maxDownloadSize;
  final Selection selection;
  final Map<String, String> answers;
  final String job;
  final String format;
  final String version;
  final FlashPlan plan;
  final FlashPackage package;
  final Map<String, FlashImageInfo> images;
  final FlashRequestBinding binding;
  final String createdAt;
  final List<String> warnings;
  final Set<String> logicalPartitions;

  bool get resolved => plan.isResolved;

  /// Returns the same confirmed ticket, but reads images through [package].
  ///
  /// Preparation releases its OTA handles when it returns, so execution
  /// reopens the same OTA identity and swaps the package in without changing
  /// the token or any confirmed input.
  PreparedFlash withPackage(FlashPackage package) => PreparedFlash(
    token: token,
    serial: serial,
    mode: mode,
    maxDownloadSize: maxDownloadSize,
    selection: selection,
    answers: answers,
    job: job,
    format: format,
    version: version,
    plan: plan,
    package: package,
    images: images,
    binding: binding,
    createdAt: createdAt,
    warnings: warnings,
  );

  bool get modeOk => mode == FlashMode.bootloader;

  List<FlashPromptInfo> get prompts => [
    for (final step in plan.steps)
      if (step is Prompt)
        FlashPromptInfo(
          id: step.id,
          question: step.question,
          choices: List.unmodifiable(step.choices.keys),
          selected: step.selectedChoice,
        ),
  ];

  Map<String, Object?> toMap() => {
    'token': resolved ? token : '',
    'serial': serial,
    'mode': mode.name,
    'modeOk': modeOk,
    'maxDownloadSize': maxDownloadSize,
    'resolved': resolved,
    'job': job,
    'format': format,
    'version': version,
    'device': selection.device,
    'dev': selection.dev,
    'kind': selection.kind,
    'region': selection.region,
    'steps': [for (final step in plan.steps) step.text],
    if (resolved)
      'executionSteps': [for (final step in plan.executionSteps) step.text],
    'prompts': [for (final prompt in prompts) prompt.toMap()],
    'images': {
      for (final entry in images.entries) entry.key: entry.value.toMap(),
    },
    'packageImages': [
      for (final image in package.index.imagesIn(selection.imageFolder))
        image.path,
    ],
    'manifest': package.buildJson,
    'confirmation': plan.confirmationText(serial),
    'warnings': warnings,
    'createdAt': createdAt,
  };
}

/// The exact confirmation input, minus the opaque token.
final class FlashRequestBinding {
  const FlashRequestBinding({
    required this.device,
    required this.kind,
    required this.region,
    required this.job,
    required this.serial,
    required this.answers,
    required this.upstreamBase,
    required this.storeKey,
    required this.packageDigest,
  });

  final String device;
  final String kind;
  final String region;
  final String job;
  final String serial;
  final Map<String, String> answers;
  final String upstreamBase;
  final String storeKey;
  final String packageDigest;

  /// Whether [req] still names this exact confirmation input.
  bool matches(Map<String, Object?> req, {required String storeKey}) {
    final selection = req['selection'];
    if (selection is! Map) return false;
    if (selection['device'] != device ||
        selection['kind'] != kind ||
        selection['region'] != region) {
      return false;
    }
    if (req['job'] != job || req['serial'] != serial) return false;
    if ((req['upstreamBase'] as String? ?? '') != upstreamBase) return false;
    if (storeKey != this.storeKey) return false;
    final supplied = _stringMap(req['answers']);
    if (supplied.length != answers.length) return false;
    for (final entry in answers.entries) {
      if (supplied[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// Prepares a flash and returns a ticket. [token] is generated when omitted.
Future<PreparedFlash> prepareFlash({
  required FlashPackage package,
  required Selection selection,
  required Map<String, String> answers,
  required String serial,
  required FastbootTransport transport,
  required String job,
  String upstreamBase = '',
  String storeKey = '',
  String? token,
}) async {
  if (serial.trim().isEmpty) {
    throw const FlashException('A device serial is required.');
  }
  final buildJson = package.buildJson;
  final warnings = <String>[];
  final device = buildJson['device'];
  final kind = buildJson['flasher_type'];
  final region = buildJson['region'];
  if (device != selection.device ||
      kind != selection.kind ||
      region != selection.region) {
    throw FlashException(
      'The job is a ${device ?? '?'} / ${kind ?? '?'} / '
      '${region ?? '?'} build, not ${selection.device} / '
      '${selection.kind} / ${selection.region}.',
    );
  }
  final format = buildJson['output_format'];
  if (format != package.format) {
    throw FlashException(
      'build.json says output_format $format but the job stores '
      '${package.format}.',
    );
  }
  if (buildJson['image_sha256'] == null) {
    warnings.add(
      package is VirtualFlashPackage
          ? 'Some OTA images have no whole-image SHA-256. Every operation is '
              'hash-verified and the fully decoded images are bound to this confirmation.'
          : 'This older build has no final-image SHA-256 manifest. Current bytes '
              'are validated and bound to this confirmation, but not to build-time digests.',
    );
  }
  if (buildJson['test_fixture'] == true) {
    warnings.add('This job is marked test_fixture; it is a synthetic package.');
  }
  final version = buildJson['version'];
  if (version is! String || version.isEmpty) {
    throw const FlashException('build.json has no version.');
  }

  final plan = planFlash(package.index, selection, answers);
  final digest = await packageDigest(package);
  final binding = FlashRequestBinding(
    device: selection.device,
    kind: selection.kind,
    region: selection.region,
    job: job,
    serial: serial,
    answers: Map.unmodifiable(Map<String, String>.from(answers)),
    upstreamBase: upstreamBase,
    storeKey: storeKey,
    packageDigest: digest,
  );

  final devices = await transport.devices();
  if (!devices.any((device) => device.serial == serial)) {
    final granted = devices.isEmpty
        ? 'none'
        : devices.map((device) => device.serial).join(', ');
    throw FlashException(
      'Fastboot device $serial is not connected or not granted. Granted: '
      '$granted.',
    );
  }
  FastbootSession? session;
  var mode = FlashMode.android;
  var maxDownloadSize = 0;
  final cleanup = <String>[];
  try {
    final opened = await transport.open(serial);
    session = opened;
    if (opened.serial != serial) {
      throw FlashException(
        'The transport opened ${opened.serial} instead of $serial.',
      );
    }
    mode = await probeFlashMode(opened);
    maxDownloadSize = parseDownloadSize(
      await opened.command('getvar:max-download-size'),
    );
  } finally {
    if (session != null) {
      try {
        await session.close();
      } on Object catch (error) {
        cleanup.add('$error');
      }
    }
  }
  if (cleanup.isNotEmpty) {
    warnings.addAll(cleanup.map((error) => 'Close after prepare: $error'));
  }
  if (maxDownloadSize <= 0) {
    throw const FlashException(
      'The device did not report a usable max-download-size.',
    );
  }
  if (mode != FlashMode.bootloader) {
    warnings.add(
      'The device is in ${mode.name}; this plan starts in the normal '
      'bootloader. Reboot there before flashing.',
    );
  }

  final images = <String, FlashImageInfo>{};
  if (plan.isResolved) {
    for (final step in plan.executionSteps) {
      if (step is! Flash || images.containsKey(step.image)) continue;
      images[step.image] = await _inspectImage(
        package,
        step.image,
        maxDownloadSize,
        buildJson,
      );
    }
  }

  final prepared = PreparedFlash(
    token: token ?? _newToken(),
    serial: serial,
    mode: mode,
    maxDownloadSize: maxDownloadSize,
    selection: selection,
    answers: binding.answers,
    job: job,
    format: package.format,
    version: version,
    plan: plan,
    package: package,
    images: Map.unmodifiable(images),
    binding: binding,
    createdAt: DateTime.now().toUtc().toIso8601String(),
    warnings: List.unmodifiable(warnings),
  );
  if (prepared.resolved) {
    final target = await transport.open(serial);
    try {
      if (target.serial != serial) {
        throw const FlashException('The device changed during preparation.');
      }
      for (final step in plan.executionSteps) {
        if (step is! Flash ||
            prepared.logicalPartitions.contains(step.partition)) {
          continue;
        }
        final info = images[step.image]!;
        await validateTargetPartition(
          target,
          step.partition,
          info.scan?.expandedBytes ?? info.bytes,
        );
      }
    } finally {
      await target.close();
    }
  }
  return prepared;
}

/// Re-inspects every image the ticket names. The service calls this
/// immediately before a write, so a package changed after preparation is
/// refused even when its file sizes stayed the same.
///
/// A [VirtualFlashPackage] is bound by its snapshot digest (OTA identity,
/// manifest, verified bloat) and its decoded images are hash-authenticated
/// per operation, so only their sizes are rechecked here; a folder or ZIP
/// package is rehashed.
Future<void> verifyPreparedImages(
  PreparedFlash prepared, {
  FlashPackage? package,
}) async {
  final current = package ?? prepared.package;
  if (current is VirtualFlashPackage &&
      await packageDigest(current) != prepared.binding.packageDigest) {
    throw const FlashException('The virtual OTA or bloat identity changed. Prepare again.');
  }
  for (final info in prepared.images.values) {
    // A virtual package is re-opened for the attempt: the manifest is
    // snapshot-bound, every operation is hash-verified before it yields
    // bytes, and `VirtualFlashPackage.load` re-verifies every bloat image
    // against the manifest before the package exists. Rehashing either kind
    // here would read the same bytes a second time without adding a check.
    if (current is VirtualFlashPackage) {
      if (await current.size(info.path) != info.bytes) {
        throw FlashException('${info.path} changed size after preparation.');
      }
      continue;
    }
    final source = await current.open(info.path);
    try {
      if (source.length != info.bytes) {
        throw FlashException(
          '${info.path} changed size after preparation '
          '(${source.length} != ${info.bytes}).',
        );
      }
      final digest = info.sparse
          ? (await scanSparse(source)).digest
          : await hashRawSource(source);
      if (digest != info.digest) {
        throw FlashException(
          '${info.path} changed after preparation. Prepare again.',
        );
      }
    } finally {
      await source.close();
    }
  }
}

/// Classifies the connected fastboot mode from `getvar:is-userspace`, the same
/// answer the fastboot CLI reads.
Future<FlashMode> probeFlashMode(FastbootSession session) async {
  final userspace = await _optionalGetvar(session, 'is-userspace');
  if (userspace != null && _truthy(userspace)) return FlashMode.fastbootd;
  return FlashMode.bootloader;
}

/// Parses a decimal or `0x` hexadecimal max-download-size payload.
int parseDownloadSize(String payload) {
  final value = cleanGetvar(payload, 'max-download-size').trim();
  if (value.isEmpty) {
    throw const FlashException('The device reported no max-download-size.');
  }
  final int? parsed;
  if (value.startsWith('0x') || value.startsWith('0X')) {
    parsed = int.tryParse(value.substring(2), radix: 16);
  } else {
    parsed = int.tryParse(value, radix: 10);
  }
  if (parsed == null || parsed <= 0) {
    throw FlashException('Invalid max-download-size: "$payload".');
  }
  // The wire command carries exactly eight hexadecimal length digits.
  return min(parsed, 0xffffffff);
}

/// Match the checks/resizing the fastboot CLI performs before `flash:`.
/// A reconstructed logical partition starts at one byte in upstream scripts;
/// fastbootd must resize it to the expanded image size before flashing.
Future<void> validateTargetPartition(
  FastbootSession session,
  String partition,
  int expandedBytes, {
  bool resizeLogical = false,
  bool createdLogical = false,
}) async {
  final logical =
      createdLogical ||
      await _optionalGetvar(session, 'is-logical:$partition') == 'yes';
  if (logical) {
    if (resizeLogical) {
      await session.command(
        'resize-logical-partition:$partition:$expandedBytes',
        write: true,
      );
    }
    return;
  }
  final reported = await _optionalGetvar(session, 'partition-size:$partition');
  if (reported == null || reported.isEmpty) return;
  final size = reported.startsWith('0x') || reported.startsWith('0X')
      ? int.tryParse(reported.substring(2), radix: 16)
      : int.tryParse(reported);
  if (size == null || size <= 0) {
    throw FlashException('Invalid partition-size for $partition: $reported.');
  }
  if (expandedBytes > size) {
    throw FlashException(
      '$partition is $size bytes; the expanded image is $expandedBytes bytes.',
    );
  }
}

/// A stable SHA-256 of a package's entries and metadata.
Future<String> packageDigest(FlashPackage package) async {
  final snapshot = await package.snapshot();
  final canonical = jsonEncode(_sorted(snapshot));
  return sha256.convert(utf8.encode(canonical)).toString();
}

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => '$key').toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is Iterable) return [for (final item in value) _sorted(item)];
  return value;
}

Future<FlashImageInfo> _inspectImage(
  FlashPackage package,
  String path,
  int maxDownloadSize,
  Map<String, Object?> buildJson,
) async {
  if (package is VirtualFlashPackage && (path == 'super.img' || package.isOtaImage(path))) {
    final bytes = await package.size(path);
    final scan = path == 'super.img' ? package.superScan : null;
    final parts = bytes > maxDownloadSize
      ? (scan == null ? splitRawImage(bytes, maxDownloadSize) : splitSparseScan(scan, maxDownloadSize)).length
      : 1;
    return FlashImageInfo(path: path, bytes: bytes, sparse: scan != null,
      digest: package.imageHash(path) ?? '', manifestSha256: package.imageHash(path),
      scan: scan, parts: parts);
  }
  final source = await package.open(path);
  try {
    if (source.length <= 0) {
      throw FlashException('The image $path is empty.');
    }
    final sparse = await isSparseSource(source);
    final int parts;
    final String digest;
    SparseScan? scan;
    if (sparse) {
      scan = await scanSparse(source);
      digest = scan.digest;
      parts = source.length > maxDownloadSize
          ? splitSparseScan(scan, maxDownloadSize).length
          : 1;
    } else {
      if (source.length > maxDownloadSize &&
          source.length % sparseBlockBytes != 0) {
        throw FlashException(
          '$path is ${source.length} bytes, larger than max-download-size '
          '$maxDownloadSize, and is not a multiple of 4096 bytes.',
        );
      }
      digest = await hashRawSource(source);
      parts = source.length > maxDownloadSize
          ? splitRawImage(source.length, maxDownloadSize).length
          : 1;
    }
    final expected = package is VirtualFlashPackage
        ? package.imageHash(path)
        : _manifestHash(buildJson, path);
    if (expected != null && expected != digest) {
      throw FlashException(
        '$path does not match the final-image SHA-256 recorded by the build.',
      );
    }
    return FlashImageInfo(
      path: path,
      bytes: source.length,
      sparse: sparse,
      digest: digest,
      parts: parts,
      manifestSha256: expected,
      scan: scan,
    );
  } finally {
    await source.close();
  }
}

String? _manifestHash(Map<String, Object?> buildJson, String path) {
  final images = buildJson['image_sha256'];
  if (images == null) return null;
  if (images is! Map) {
    throw const FlashException('Invalid final-image SHA-256 manifest.');
  }
  final digest = images[path];
  if (digest is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(digest)) {
    throw FlashException('No valid final-image SHA-256 recorded for $path.');
  }
  return digest.toLowerCase();
}

Future<String?> _optionalGetvar(FastbootSession session, String name) async {
  try {
    return cleanGetvar(await session.command('getvar:$name'), name);
  } on LinkFailure catch (failure) {
    if (failure.blame != 'device' ||
        failure.name != 'FastbootFail' ||
        failure.uncertain) {
      rethrow;
    }
    // Only a complete device FAIL proves this optional getvar is unavailable.
    return null;
  }
}

/// Strips a fastboot `name:` prefix and a `(bootloader)` tag from a payload.
String cleanGetvar(String payload, String name) {
  var value = payload.trim();
  if (value.startsWith('(')) {
    final close = value.indexOf(')');
    if (close > 0) value = value.substring(close + 1).trim();
  }
  final prefix = '$name:';
  if (value.toLowerCase().startsWith(prefix)) {
    value = value.substring(prefix.length).trim();
  }
  return value;
}

bool _truthy(String value) {
  final text = value.trim().toLowerCase();
  if (text.isEmpty) return false;
  if (const {'no', '0', 'false', 'n', 'off', 'unknown'}.contains(text)) {
    return false;
  }
  return true;
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
  };
}

String _newToken() {
  final random = Random.secure();
  final bytes = Uint8List(32);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
