/// Extracts payload partitions straight to their image files, in one pass.
///
/// Port of `native_pipeline.extract`, `extraction_plan` and the otaripper
/// extraction loop: coalesced ranges, bounded concurrency for remote sources,
/// and the manifest's SHA-256 checked on every image.
library;

import 'dart:typed_data';

import '../rust/api/payload.dart';
import '../storage/storage.dart';
import '../upstream/tables.dart';
import 'errors.dart';
import 'ota.dart';

/// Partitions `pack_super` may put in `super.img`, in `lpmake` order.
const List<String> superParts = [
  'my_bigball',
  'my_carrier',
  'my_company',
  'my_engineering',
  'my_heytap',
  'my_manifest',
  'my_preload',
  'my_product',
  'my_region',
  'my_stock',
  'odm',
  'product',
  'system',
  'system_dlkm',
  'system_dlkm_gki',
  'system_dlkm_oki',
  'system_ext',
  'vendor',
  'vendor_dlkm',
];

/// Partitions `build_images` moves into `Super/` for every device except X9U.
final List<String> extractToSuper = [
  for (final name in superParts)
    if (name != 'my_company' &&
        name != 'my_preload' &&
        name != 'system_dlkm_gki' &&
        name != 'system_dlkm_oki')
      name,
];

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

/// Images `build_images` skips, or null to extract every partition.
///
/// Port of `native_pipeline.extraction_plan`.
Future<List<String>?> extractionPlan({
  required Selection selection,
  required Workspace workspace,
  required String result,
  required Iterable<String> available,
}) async {
  final names = available.toList();
  if (names.isEmpty) return null;
  final bootDir = '$result/${selection.imageFolder}';
  final superDir = '$result/Super';

  Future<bool> discarded(String name) async {
    if (selection.kind.contains('Super') &&
        (selection.dev == 'Ace5' || selection.dev == 'Ace6T') &&
        selection.region != 'CN' &&
        name == 'odm') {
      return true;
    }
    if (selection.dev != 'X9U') return false;
    // Staged X9U bloat takes precedence over the OTA's copy of the same image.
    final folder = selection.kind.contains('Super') && superParts.contains(name)
        ? superDir
        : bootDir;
    return workspace.exists('$folder/$name.img');
  }

  final wanted = <String>[];
  for (final name in names) {
    if (!await discarded(name)) wanted.add(name);
  }
  if (wanted.isEmpty) {
    throw const BuildException(
      'The OTA contains no partitions this flasher uses.',
    );
  }
  return wanted.length == names.length ? null : wanted;
}

/// Extracts [names] (or every partition when null) into [directory].
///
/// Writes `<directory>/<name>.img`, truncated to the manifest size first.
/// Returns the SHA-256 of every image written, keyed by partition name.
/// [emit] receives `{"type": "progress", "label", "done", "total"}` events at
/// least every 64 MiB; [check] throws to cancel.
Future<Map<String, String>> extractPartitions(
  OtaArchive ota,
  Workspace workspace,
  String directory, {
  Iterable<String>? names,
  void Function(Map<String, Object?> event)? emit,
  void Function()? check,
}) async {
  final checkNow = check ?? () {};
  final selected = names?.toSet();
  final parts = [
    for (final part in ota.manifest.partitions())
      if (selected == null || selected.contains(part.name)) part,
  ];
  if (selected != null) {
    final found = {for (final part in parts) part.name};
    final missing = selected.difference(found);
    if (missing.isNotEmpty) {
      throw BuildException(
        'The OTA payload does not contain: ${missing.join(', ')}.',
      );
    }
  }
  if (parts.isEmpty) {
    throw const BuildException(
      'The OTA contains no partitions this flasher uses.',
    );
  }

  final hashes = <String, String>{};
  for (final part in parts) {
    checkNow();
    hashes[part.name] = await _extractOne(
      ota,
      workspace,
      '$directory/${part.name}.img',
      part,
      emit: emit,
      check: checkNow,
    );
  }
  return hashes;
}

Future<String> _extractOne(
  OtaArchive ota,
  Workspace workspace,
  String path,
  PartitionInfo part, {
  required void Function(Map<String, Object?> event)? emit,
  required void Function() check,
}) async {
  final size = part.size.toInt();
  final ops = ota.manifest.operations(name: part.name);
  final sink = await workspace.create(path);
  try {
    await sink.truncate(size);

    // Data ranges in operation order, coalesced up to 16 MiB.
    const maxRequest = 16 * 1024 * 1024;
    final jobs = <_ReadJob>[];
    for (final op in ops) {
      final offset = op.dataOffset.toInt();
      final length = op.dataLength.toInt();
      if (length <= 0) continue;
      final last = jobs.isEmpty ? null : jobs.last;
      if (last != null &&
          offset == last.offset + last.length &&
          last.length + length <= maxRequest) {
        last.ops.add(op);
        last.length += length;
      } else {
        jobs.add(_ReadJob(offset, length)..ops.add(op));
      }
    }

    var sequential = true;
    var expected = 0;
    for (final op in ops) {
      for (final extent in op.dst) {
        if (extent.offset.toInt() != expected) sequential = false;
        expected = extent.offset.toInt() + extent.length.toInt();
      }
    }
    if (expected != size) sequential = false;

    final hasher = Sha256Hasher();
    final window = ota.remote ? 4 : 1;
    final pending = <Future<Uint8List>>[];
    var nextJob = 0;
    var done = 0;
    var reported = 0;
    const reportEvery = 64 * 1024 * 1024;

    for (var index = 0; index < jobs.length; index++) {
      while (pending.length < window && nextJob < jobs.length) {
        final job = jobs[nextJob++];
        pending.add(ota.readPayloadData(job.offset, job.length));
      }
      check();
      final data = await pending.removeAt(0);
      final job = jobs[index];
      var position = 0;
      for (final op in job.ops) {
        check();
        final length = op.dataLength.toInt();
        final encoded = Uint8List.sublistView(
          data,
          position,
          position + length,
        );
        position += length;
        final decoded = ota.manifest.decodeOp(
          name: part.name,
          index: op.index,
          data: encoded,
        );
        final total = op.dst.fold<int>(
          0,
          (sum, extent) => sum + extent.length.toInt(),
        );
        if (decoded.isNotEmpty && decoded.length != total) {
          throw BuildException(
            '${part.name}.img operation ${op.index} has the wrong length.',
          );
        }
        if (decoded.isEmpty) {
          if (sequential) hasher.updateZeros(n: BigInt.from(total));
          done += total;
        } else {
          var decodedOffset = 0;
          for (final extent in op.dst) {
            final extentLength = extent.length.toInt();
            await sink.write(
              Uint8List.sublistView(
                decoded,
                decodedOffset,
                decodedOffset + extentLength,
              ),
              extent.offset.toInt(),
            );
            decodedOffset += extentLength;
            done += extentLength;
          }
          if (sequential) hasher.update(bytes: decoded);
        }
        if (done - reported >= reportEvery) {
          reported = done;
          emit?.call({
            'type': 'progress',
            'label': '${part.name}.img',
            'done': done,
            'total': size,
          });
        }
      }
    }
    if (done != size) {
      throw BuildException('${part.name}.img is incomplete.');
    }
    emit?.call({
      'type': 'progress',
      'label': '${part.name}.img',
      'done': size,
      'total': size,
    });

    String digest;
    if (sequential) {
      digest = hasher.finishHex();
    } else {
      // Operations do not run from 0 to size in order: hash the file.
      digest = await _hashFile(workspace, path, check);
    }
    final expectedHash = part.sha256?.toLowerCase();
    if (expectedHash != null &&
        expectedHash.isNotEmpty &&
        expectedHash != digest) {
      throw BuildException('${part.name}.img failed its SHA-256 check.');
    }
    return digest;
  } finally {
    await sink.close();
  }
}

Future<String> _hashFile(
  Workspace workspace,
  String path,
  void Function() check,
) async {
  final source = await workspace.open(path);
  try {
    final hasher = Sha256Hasher();
    const chunk = 8 * 1024 * 1024;
    var offset = 0;
    while (offset < source.length) {
      check();
      final length = source.length - offset < chunk
          ? source.length - offset
          : chunk;
      hasher.update(bytes: await source.read(offset, length));
      offset += length;
    }
    return hasher.finishHex();
  } finally {
    await closeByteSource(source);
  }
}

final class _ReadJob {
  _ReadJob(this.offset, this.length);

  final int offset;
  int length;
  final List<OpInfo> ops = [];
}
