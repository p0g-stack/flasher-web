import 'dart:typed_data';

import 'package:device_link/device_link.dart';

import '../rust/api/lp.dart' as rust;
import 'model.dart';
import 'prepare.dart';

final class WipeSuperSpec {
  WipeSuperSpec(this.superSize, List<String> partitionNames)
    : partitionNames = List.unmodifiable(partitionNames);
  final int superSize;
  final List<String> partitionNames;
  bool get canWipe => superSize > superReserve && partitionNames.isNotEmpty;
  Uint8List buildImage() => rust.buildWipeSuperImage(
    superSize: BigInt.from(superSize),
    partitionNames: partitionNames,
  );
}

const superReserve = 4 * 1024 * 1024;
int _aligned(int size) => ((size + 4095) ~/ 4096) * 4096;

final class SuperSpaceAssessment {
  const SuperSpaceAssessment({
    required this.capacity,
    required this.allocated,
    required this.peak,
    required this.snapshotStatus,
  });
  final int capacity;
  final int allocated;
  final int peak;
  final String snapshotStatus;
  bool get needsWipe => peak > capacity;
  Map<String, Object?> toMap() => {
    'capacity': capacity,
    'allocated': allocated,
    'free': capacity - allocated,
    'peak': peak,
    'shortfall': peak > capacity ? peak - capacity : 0,
    'snapshotStatus': snapshotStatus,
    'needsWipe': needsWipe,
  };
}

int logicalSectionStart(List<FlashStep> steps) =>
    steps.indexWhere((step) => step is DeleteLogical || step is CreateLogical);

/// Inventory comes from getvar all INFO/TEXT, not from an assumed set of names:
/// stale other-slot/custom-ROM/cow allocations must count too.
Future<SuperSpaceAssessment> assessSuperSpace(
  FastbootSession session,
  PreparedFlash prepared,
  WipeSuperSpec spec,
  int start,
) async {
  final reply = await session.commandWithMessages('getvar:all');
  final lines = [
    for (final message in reply.messages) ...message['text']!.split('\n'),
    ...reply.value.split('\n'),
  ];
  final sizes = <String, int>{};
  final logical = <String, bool>{};
  var snapshot = '';
  for (final raw in lines) {
    final line = raw.trim().replaceFirst(RegExp(r'^\(bootloader\)\s*'), '');
    if (line.startsWith('snapshot-update-status:')) {
      snapshot = line.substring(23).trim();
    }
    final size = RegExp(
      r'^partition-size:([^:]+):\s*(0[xX][0-9a-fA-F]+|[0-9]+)$',
    ).firstMatch(line);
    if (size != null) {
      final value = parsePartitionBytes(size.group(2)!);
      final previous = sizes[size.group(1)!];
      if (previous != null && previous != value) {
        throw const FlashException('Conflicting super inventory.');
      }
      sizes[size.group(1)!] = value;
    } else if (line.startsWith('partition-size:')) {
      throw const FlashException(
        'Malformed partition-size in super inventory.',
      );
    }
    final flag = RegExp(r'^is-logical:([^:]+):\s*(yes|no)$').firstMatch(line);
    if (flag != null) logical[flag.group(1)!] = flag.group(2) == 'yes';
  }
  if (!sizes.containsKey('super') || sizes['super'] != spec.superSize) {
    throw const FlashException(
      'Super inventory is missing or differs from the upstream device size.',
    );
  }
  final allocations = <String, int>{};
  for (final name in {...sizes.keys, ...logical.keys}) {
    var isLogical = logical[name];
    if (isLogical == null) {
      final value = cleanGetvar(
        await session.command('getvar:is-logical:$name'),
        'is-logical:$name',
      );
      if (value != 'yes' && value != 'no') {
        throw FlashException('Cannot identify logical allocation $name.');
      }
      isLogical = value == 'yes';
    }
    if (!isLogical) continue;
    allocations[name] =
        sizes[name] ??
        parsePartitionBytes(
          cleanGetvar(
            await session.command('getvar:partition-size:$name'),
            'partition-size:$name',
          ),
        );
  }
  final allocated = allocations.values.fold<int>(
    0,
    (sum, size) => sum + _aligned(size),
  );
  var current = allocated;
  var peak = current;
  for (final step in prepared.plan.executionSteps.skip(start)) {
    String? name;
    int? size;
    switch (step) {
      case DeleteLogical():
        name = step.name;
        size = 0;
      case CreateLogical():
        name = step.name;
        size = _aligned(step.size);
      case Flash()
          when prepared.logicalPartitions.contains(step.partition) ||
              allocations.containsKey(step.partition):
        name = step.partition;
        final image = prepared.images[step.image]!;
        size = _aligned(image.scan?.expandedBytes ?? image.bytes);
      default:
        break;
    }
    if (name == null || size == null) continue;
    current += size - (allocations[name] ?? 0);
    allocations[name] = size;
    if (current > peak) peak = current;
  }
  return SuperSpaceAssessment(
    capacity: spec.superSize - superReserve,
    allocated: allocated,
    peak: peak,
    snapshotStatus: snapshot,
  );
}

int parsePartitionBytes(String value) {
  final text = value.trim();
  final parsed = text.startsWith('0x') || text.startsWith('0X')
      ? int.tryParse(text.substring(2), radix: 16)
      : int.tryParse(text);
  if (parsed == null || parsed < 0) {
    throw FlashException('Invalid partition size: $value.');
  }
  return parsed;
}

Future<void> requireNoSnapshots(FastbootSession session) async {
  final status = cleanGetvar(
    await session.command('getvar:snapshot-update-status'),
    'snapshot-update-status',
  );
  if (status != 'none') {
    throw FlashException(
      'Clear super refused: snapshot-update-status is "$status", not "none". Finish the phone update first.',
    );
  }
}
