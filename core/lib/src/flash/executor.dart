/// Executes one prepared flash plan.
///
/// Rules this file owns:
/// - stop at the first failure; resend only on explicit user retry;
/// - reconnect only by the confirmed serial, with bounded waits;
/// - split a download at the device's `max-download-size` while preserving
///   sparse block positions;
/// - send at most 1 MiB per transport write;
/// - keep the final Android mode unverified; the fastboot session is closed
///   after the reboot command.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:logging/logging.dart';

import 'model.dart';
import 'flow.dart';
import 'wipe_super.dart';
import 'prepare.dart';
import 'sparse.dart';
import 'virtual.dart';

final _log = Logger('link.fastboot');

typedef FlashEventSink = void Function(Map<String, Object?> event);

/// A cancellation request from the stream subscriber.
final class FlashCancellation {
  var _cancelled = false;
  String? reason;

  bool get isCancelled => _cancelled;

  void cancel([String? why]) {
    if (_cancelled) return;
    _cancelled = true;
    reason = why;
  }
}

/// Runs [prepared] against [transport].
///
/// Device and protocol failures are returned in the receipt, not thrown, so
/// the caller can persist and display them. Invalid internal state (a missing
/// preflight record) is still an exception.
Future<Map<String, Object?>> executePreparedFlash(
  PreparedFlash prepared,
  FastbootTransport transport, {
  required FlashEventSink emit,
  FlashCancellation? cancellation,
  Duration reconnectTimeout = const Duration(seconds: 180),
  Duration reconnectPoll = const Duration(seconds: 1),
  Map<String, Object?>? previousReceipt,
  FlashRecovery? recovery,
  WipeSuperSpec? wipeSuperSpec,
}) async {
  final cancel = cancellation ?? FlashCancellation();
  final startedAt = previousReceipt?['startedAt'] as String? ?? DateTime.now().toUtc().toIso8601String();
  var startStep = previousReceipt?['stepIndex'] as int? ?? 0;
  final execution = prepared.plan.executionSteps;
  if (startStep < 0 || startStep >= execution.length) throw const FlashException('Invalid failed step.');
  if (previousReceipt != null && (recovery == null ||
      !recoveryActions(execution, previousReceipt, canWipeSuper: wipeSuperSpec?.canWipe ?? false).contains(recovery))) {
    throw const FlashException('This recovery action is not allowed for the paused run.');
  }
  if (recovery == FlashRecovery.wipeSuper) startStep = logicalSectionStart(execution);
  if (startStep < 0) throw const FlashException('This plan has no logical section.');
  final requiredMode = requiredModeAt(execution, startStep);
  if (!prepared.resolved) {
    throw const FlashException(
      'The plan still has unanswered prompts; execution is refused.',
    );
  }
  final steps = <Map<String, Object?>>[
    if (previousReceipt != null)
      for (final raw in previousReceipt['steps']! as List)
        if ((raw as Map)['index'] as int <= startStep) Map<String, Object?>.from(raw),
  ];
  final writes = <Map<String, Object?>>[
    if (previousReceipt != null)
      for (final raw in previousReceipt['writes']! as List) Map<String, Object?>.from(raw as Map),
  ];
  final cleanupErrors = <String>[];
  var status = 'succeeded';
  var uncertain = previousReceipt?['uncertain'] == true;
  Map<String, Object?>? failure;
  var modeEnd = prepared.mode.name;
  var maxDownloadSize = prepared.maxDownloadSize;
  FastbootSession? session;
  var stepIndex = startStep;
  Map<String, Object?>? superPreflight = previousReceipt?['superPreflight'] is Map
      ? Map<String, Object?>.from(previousReceipt!['superPreflight']! as Map) : null;
  var wipePending = previousReceipt?['wipeSuperPending'] == true;
  var wipeRequired = previousReceipt?['wipeSuperRequired'] == true || recovery == FlashRecovery.wipeSuper;
  var connectionOnly = false;

  void connection(FlashConnection state, {FlashMode? mode}) => emit({
    'type': 'connection', 'state': state.name, 'serial': prepared.serial,
    if (mode != null) 'mode': mode.name,
  });

  void check() {
    if (cancel.isCancelled) throw const _Cancelled();
  }

  void markUncertain() => uncertain = true;

  try {
    check();
    connection(FlashConnection.opening);
    final reopened = recovery == FlashRecovery.reconnectDevice || recovery == FlashRecovery.recoverPowerCycle
        ? await _waitForSerial(transport, prepared,
            recovery == FlashRecovery.recoverPowerCycle ? null : requiredMode,
            check, reconnectTimeout, reconnectPoll) : null;
    final first = reopened?.session ?? await _openExact(transport, prepared.serial);
    session = first;
    connection(FlashConnection.probing);
    final readiness = reopened?.readiness ?? await probeFastbootConsistency(first);
    var mode = readiness.mode;
    maxDownloadSize = readiness.maxDownloadSize;
    _log.info('flash ${prepared.serial}: mode ${mode.name}');
    modeEnd = mode.name;
    final rebootMode = switch (recovery) {
      FlashRecovery.recoverBootloader => FlashMode.bootloader,
      FlashRecovery.recoverFastbootd => FlashMode.fastbootd,
      _ => null,
    };
    if (rebootMode != null) {
      connection(FlashConnection.transitioning, mode: rebootMode);
      await first.command(rebootMode == FlashMode.fastbootd ? 'reboot-fastboot' : 'reboot-bootloader', write: true);
      await first.close();
      final reopened = await _waitForSerial(transport, prepared, rebootMode, check, reconnectTimeout, reconnectPoll);
      session = reopened.session;
      mode = reopened.readiness.mode;
      maxDownloadSize = reopened.readiness.maxDownloadSize;
      modeEnd = mode.name;
    }
    connection(FlashConnection.ready, mode: mode);
    connectionOnly = previousReceipt != null && (
      recovery == FlashRecovery.recoverPowerCycle ||
      (uncertain && recovery != FlashRecovery.rewriteStep && recovery != FlashRecovery.wipeSuper));
    if (!connectionOnly && mode != requiredMode) {
      throw FlashException('The device is in ${mode.name}; step $startStep requires ${requiredMode.name}.');
    }
    if (connectionOnly) {
      status = uncertain ? 'uncertain' : 'failed';
      failure = {...Map<String, Object?>.from(previousReceipt['failure'] as Map),
        'name': 'RecoveryReady', 'sessionRetired': false, 'disconnectObserved': false,
        'message': 'The phone answers consistently in ${mode.name}. Choose the next recovery action; nothing was replayed.'};
    }
    if (recovery == FlashRecovery.wipeSuper) {
      final spec = wipeSuperSpec!;
      await requireNoSnapshots(session);
      final image = spec.buildImage();
      if (image.length > maxDownloadSize) throw const FlashException('Wipe-super image exceeds max-download-size.');
      check();
      connection(FlashConnection.active, mode: mode);
      wipePending = true;
      var submitted = false;
      try {
        await session.beginDownload(image.length);
        for (var offset = 0; offset < image.length; offset += _transportChunk) {
          await session.writeDownload(Uint8List.sublistView(image, offset, math.min(offset + _transportChunk, image.length)));
        }
        await session.endDownload();
        check();
        submitted = true;
        await session.command('flash:super', write: true);
        writes.add({'partition': 'super', 'image': 'wipe-super', 'bytes': image.length,
          'parts': 1, 'status': 'ok'});
        wipePending = false;
        wipeRequired = false;
        if (superPreflight != null) superPreflight['cleared'] = true;
        // All earlier logical attempts were replaced by this metadata rewrite.
        for (final write in writes) {
          if (prepared.logicalPartitions.contains(write['partition']) || write['image'] == 'wipe-super') {
            if (write['status'] == 'uncertain') write['resolvedBy'] = 'wipe-super';
          }
        }
        uncertain = false;
      } catch (error) {
        final lost = submitted && (error is! LinkFailure || error.uncertain);
        uncertain = uncertain || lost;
        writes.add({'partition': 'super', 'image': 'wipe-super', 'bytes': image.length,
          'parts': 1, 'status': lost ? 'uncertain' : 'failed'});
        rethrow;
      }
    }
    emit({
      'type': 'log',
      'text':
          'Flashing ${prepared.selection.device} '
          '(${prepared.serial}), '
          'max-download-size $maxDownloadSize.',
    });

    var logicalChecked = recovery == FlashRecovery.wipeSuper;
    for (var index = startStep; !connectionOnly && index < execution.length; index++) {
      stepIndex = index;
      check();
      final step = execution[index];
      if (!logicalChecked && wipeSuperSpec != null &&
          (step is DeleteLogical || step is CreateLogical ||
           (step is Flash && prepared.logicalPartitions.contains(step.partition)))) {
        if (modeEnd != FlashMode.fastbootd.name) throw const FlashException('Logical preflight requires fastbootd.');
        superPreflight = (await assessSuperSpace(session!, prepared, wipeSuperSpec, index)).toMap();
        emit({'type': 'superPreflight', ...superPreflight});
        logicalChecked = true;
        if (superPreflight['needsWipe'] == true) {
          throw const LinkFailure(blame: LinkBlame.user, source: 'flow',
            name: 'SuperSpaceRequired', stage: 'super-preflight',
            message: "This phone's super still holds another system (for example a custom ROM). Clear it?");
        }
      }
      connection(FlashConnection.active);
      emit({
        'type': 'step',
        'index': index + 1,
        'total': execution.length,
        'title': step.text,
      });
      try {
        final reconciled = previousReceipt != null && index == startStep &&
            recovery == FlashRecovery.rewriteStep &&
            await _reconcileStep(session!, step, emit);
        final next = reconciled ? session : await _runStep(
          session,
          step,
          prepared,
          maxDownloadSize,
          emit,
          writes,
          check,
          markUncertain,
          (mode, _) async {
            // Reconnect after a reboot: only the confirmed serial is opened,
            // and its mode is checked again before the next command.
            final reopened = await _waitForSerial(
              transport,
              prepared,
              mode,
              check,
              reconnectTimeout,
              reconnectPoll,
            );
            maxDownloadSize = reopened.readiness.maxDownloadSize;
            modeEnd = reopened.readiness.mode.name;
            connection(FlashConnection.ready, mode: reopened.readiness.mode);
            return reopened.session;
          },
          (isFinal) {
            if (isFinal) modeEnd = 'android (unverified)';
          },
          (seen) => modeEnd = seen.name,
        );
        session = next;
        if (previousReceipt != null && index == startStep && index + 1 < execution.length && next != null) {
          final expectedMode = step is RebootTo ? step.mode : requiredMode;
          if (next.serial != prepared.serial ||
              await probeFlashMode(next) != expectedMode) {
            throw const FlashException('Device identity or mode changed after the retried step.');
          }
        }
        steps.add({'index': index + 1, 'title': step.text, 'status': 'ok'});
        if (previousReceipt != null && index == startStep && recovery == FlashRecovery.rewriteStep) {
          for (final write in writes) {
            if (write['status'] == 'uncertain' &&
                step is Flash && write['partition'] == step.partition) {
              write['resolvedBy'] = 'rewrite';
            }
          }
          uncertain = writes.any((write) => write['status'] == 'uncertain' && write['resolvedBy'] == null);
        }
      } catch (error) {
        final stepStatus = _statusFor(error, uncertain);
        steps.add({
          'index': index + 1,
          'title': step.text,
          'status': stepStatus,
        });
        rethrow;
      }
    }
  } on _Cancelled {
    status = 'cancelled';
  } on LinkFailure catch (error) {
    uncertain = uncertain || error.uncertain;
    status = uncertain ? 'uncertain' : 'failed';
    failure = error.toMap();
    failure['stepIndex'] = stepIndex;
  } on FlashException catch (error) {
    uncertain = uncertain || error.uncertain;
    status = uncertain ? 'uncertain' : 'failed';
    failure = {
      'blame': 'user',
      'name': 'FlashException',
      'message': error.message,
      'stage': 'execute',
      'uncertain': uncertain,
      'stack': '',
      'causes': const <String>[],
      'cleanupErrors': const <String>[],
      'stepIndex': stepIndex,
    };
  } on Object catch (error, stack) {
    status = uncertain ? 'uncertain' : 'failed';
    failure = {
      'blame': 'unknown',
      'name': error.runtimeType.toString(),
      'message': '$error',
      'stage': 'execute',
      'uncertain': uncertain,
      'stack': '$stack',
      'causes': const <String>[],
      'cleanupErrors': const <String>[],
      'stepIndex': stepIndex,
    };
  } finally {
    connection(FlashConnection.closing);
    if (session != null) {
      await _close(session, cleanupErrors);
    }
  }
  connection(failure?['disconnectObserved'] == true || failure?['sessionRetired'] == true
      ? FlashConnection.lost : FlashConnection.stopped);

  if (status == 'cancelled') {
    _log.info('flash ${prepared.serial}: cancelled');
  } else {
    _log.info('flash ${prepared.serial}: $status');
  }
  final packageReceipt = prepared.package is VirtualFlashPackage
    ? (prepared.package as VirtualFlashPackage).receipt() : prepared.package.buildJson;
  final oldPackage = previousReceipt?['package'];
  final imageHashes = <String, Object?>{
    if (oldPackage is Map && oldPackage['image_sha256'] is Map)
      ...Map<String, Object?>.from(oldPackage['image_sha256'] as Map),
    if (packageReceipt['image_sha256'] is Map)
      ...Map<String, Object?>.from(packageReceipt['image_sha256'] as Map),
  };
  final receipt = <String, Object?>{
    'version': 1,
    'job': prepared.job,
    'status': status,
    'serial': prepared.serial,
    'stepIndex': status == 'failed' || status == 'uncertain' ? stepIndex : null,
    'reason': failure?['message'],
    'package': {...packageReceipt, 'image_sha256': imageHashes},
    'arb': packageReceipt['arb'],
    'image_sha256': imageHashes,
    if (packageReceipt['abl_source'] != null) 'abl_source': packageReceipt['abl_source'],
    'otaVersion': prepared.version,
    'device': prepared.selection.device,
    'dev': prepared.selection.dev,
    'kind': prepared.selection.kind,
    'region': prepared.selection.region,
    'modeStart': prepared.mode.name,
    'modeEnd': modeEnd,
    'maxDownloadSize': maxDownloadSize,
    'startedAt': startedAt,
    'finishedAt': DateTime.now().toUtc().toIso8601String(),
    'steps': steps,
    'writes': writes,
    'verification': {
      'status': 'unverified',
      'detail': modeEnd == 'android (unverified)'
          ? 'Readback is unverified. Android mode was not probed after the '
                'final reboot command.'
          : 'Readback is unverified; flash OKAY replies do not include a '
                'readback hash.',
    },
    'failure': failure,
    'uncertain': uncertain,
    'writeCertainty': uncertain ? WriteCertainty.uncertain.name :
      status == 'succeeded' ? WriteCertainty.confirmed.name : WriteCertainty.refused.name,
    'wipeSuperPending': wipePending,
    'wipeSuperRequired': wipePending || wipeRequired,
    'superPreflight': ?superPreflight,
    if (recovery != null) 'recovery': recovery.name,
    'cleanupErrors': cleanupErrors,
  };
  if (status == 'failed' || status == 'uncertain') {
    emit({'type': 'failure', 'stepIndex': stepIndex, 'status': status,
      'reason': failure?['message'] ?? 'Flash failed.'});
  }
  return receipt;
}

/// Reconcile uncertain logical mutations before deciding whether to resend.
Future<bool> _reconcileStep(FastbootSession session, FlashStep step, FlashEventSink emit) async {
  if (step is DeleteLogical || step is CreateLogical) {
    final name = step is DeleteLogical ? step.name : (step as CreateLogical).name;
    final flag = cleanGetvar(await session.command('getvar:is-logical:$name'), 'is-logical:$name');
    int? size;
    try {
      size = parsePartitionBytes(cleanGetvar(await session.command('getvar:partition-size:$name'), 'partition-size:$name'));
    } on LinkFailure catch (error) {
      final message = error.message.toLowerCase();
      if (error.blame != LinkBlame.device || error.sessionRetired || error.uncertain ||
          !(message.contains('not found') || message.contains("doesn't exist") || message.contains('does not exist'))) {
        rethrow;
      }
    }
    if (flag != 'yes' && flag != 'no') throw const FlashException('Logical state could not be reconciled.');
    if (flag == 'no' && size != null) throw FlashException('Refusing to mutate non-logical partition $name.');
    if (step is DeleteLogical) return size == null;
    final create = step as CreateLogical;
    if (flag == 'yes') {
      if (size == null) throw const FlashException('Logical size could not be reconciled.');
      if (size != create.size) await session.command('resize-logical-partition:$name:${create.size}', write: true);
      emit({'type': 'log', 'text': 'Reconciled existing logical partition $name.'});
      return true;
    }
    return false;
  }
  if (step is RebootTo && step.mode != FlashMode.android) return await probeFlashMode(session) == step.mode;
  if (step is SetActive) return cleanGetvar(await session.command('getvar:current-slot'), 'current-slot') == step.slot.name;
  return false;
}

Future<FastbootSession?> _runStep(
  FastbootSession? session,
  FlashStep step,
  PreparedFlash prepared,
  int maxDownloadSize,
  FlashEventSink emit,
  List<Map<String, Object?>> writes,
  void Function() check,
  void Function() markUncertain,
  Future<FastbootSession> Function(FlashMode, String) reconnect,
  void Function(bool isFinalReboot) finalReboot,
  void Function(FlashMode) observeMode,
) async {
  FastbootSession need() {
    final active = session;
    if (active == null) {
      throw const FlashException(
        'A device command followed the final reboot; its session is closed.',
      );
    }
    return active;
  }

  switch (step) {
    case RequireMode(:final mode):
      final seen = await probeFlashMode(need());
      observeMode(seen);
      if (mode == FlashMode.bootloader) {
        if (seen != FlashMode.bootloader) {
          throw FlashException(
            'Expected the normal bootloader, but the device is in '
            '${seen.name}.',
          );
        }
      } else if (seen != mode) {
        throw FlashException(
          'Expected ${mode.name}, but the device is in ${seen.name}.',
        );
      }
      return session;
    case Flash(:final partition, :final image):
      await _flashImage(
        need(),
        partition,
        image,
        prepared,
        maxDownloadSize,
        emit,
        writes,
        check,
        markUncertain,
      );
      return session;
    case DeleteLogical(:final name):
      await need().command('delete-logical-partition:$name', write: true);
      return session;
    case CreateLogical(:final name, :final size):
      await need().command('create-logical-partition:$name:$size', write: true);
      return session;
    case RebootTo(:final mode):
      final active = need();
      final command = switch (mode) {
        FlashMode.fastbootd => 'reboot-fastboot',
        FlashMode.bootloader => 'reboot-bootloader',
        FlashMode.android => 'reboot',
      };
      await active.command(command, write: true);
      await active.close();
      if (mode == FlashMode.android) {
        finalReboot(true);
        emit({
          'type': 'log',
          'text':
              'Android reboot acknowledged; the final Android mode '
              'was not probed.',
        });
        return null;
      }
      finalReboot(false);
      emit({
        'type': 'waiting',
        'serial': prepared.serial,
        'mode': mode.name,
        'text':
            'Waiting for ${prepared.serial} to return in ${mode.name}. '
            'If the browser lost the grant, choose the phone again.',
      });
      return reconnect(mode, 'device');
    case SetActive(:final slot):
      await need().command('set_active:${slot.name}', write: true);
      return session;
    case Instruct(:final text):
      emit({'type': 'log', 'text': text});
      return session;
    case Prompt():
      throw const FlashException('An unanswered prompt reached execution.');
  }
}

Future<void> _flashImage(
  FastbootSession session,
  String partition,
  String image,
  PreparedFlash prepared,
  int maxDownloadSize,
  FlashEventSink emit,
  List<Map<String, Object?>> writes,
  void Function() check,
  void Function() markUncertain,
) async {
  final info = prepared.images[image];
  if (info == null) {
    throw FlashException('No preflight record for $image.');
  }
  await validateTargetPartition(
    session,
    partition,
    info.scan?.expandedBytes ?? info.bytes,
    resizeLogical: true,
    createdLogical: prepared.logicalPartitions.contains(partition),
  );
  check();
  final source = await prepared.package.open(image);
  final cursor = await source.cursor();
  try {
    final split = source.length > maxDownloadSize;
    final List<SparsePart> parts;
    if (!split) {
      parts = const <SparsePart>[];
    } else if (info.sparse) {
      final scan = info.scan ?? await scanSparse(source);
      parts = splitSparseScan(scan, maxDownloadSize);
    } else {
      parts = splitRawImage(source.length, maxDownloadSize);
    }
    final total = source.length;
    var done = 0;
    emit({'type': 'progress', 'label': partition, 'done': 0, 'total': total});

    Future<void> progress(int bytes) async {
      done += bytes;
      emit({
        'type': 'progress',
        'label': partition,
        'done': done,
        'total': total,
      });
    }

    if (!split) {
      final guard = _WriteGuard();
      try {
        await session.beginDownload(source.length);
        guard.phase = 1;
        var left = source.length;
        while (left > 0) {
          final size = math.min(_transportChunk, left);
          final bytes = await cursor.readExact(size);
          guard.phase = 2;
          await session.writeDownload(bytes);
          left -= size;
          await progress(size);
        }
        await session.endDownload();
        check();
        guard.phase = 3;
        guard.phase = 4;
        await session.command('flash:$partition', write: true);
        guard.phase = 5;
      } catch (error) {
        if (_writeIsUncertain(guard, error)) markUncertain();
        writes.add({
          'partition': partition,
          'image': image,
          'bytes': source.length,
          'parts': 1,
          'status': _writeIsUncertain(guard, error) ? 'uncertain' : 'failed',
        });
        rethrow;
      }
      writes.add({
        'partition': partition,
        'image': image,
        'bytes': source.length,
        'parts': 1,
        'status': 'ok',
      });
      return;
    }

    for (var index = 0; index < parts.length; index++) {
      check();
      final part = parts[index];
      final guard = _WriteGuard();
      try {
        await session.beginDownload(part.length);
        guard.phase = 2;
        await session.writeDownload(
          sparseFileHeader(
            blockSize: part.blockSize,
            totalBlocks: part.totalBlocks,
            totalChunks: part.totalChunks,
          ),
        );
        for (final piece in part.pieces) {
          final totalSize = switch (piece.type) {
            sparseRaw => sparseChunkHeaderBytes + piece.dataSize,
            sparseFill => sparseChunkHeaderBytes + 4,
            _ => sparseChunkHeaderBytes,
          };
          await session.writeDownload(
            sparseChunkHeader(
              type: piece.type,
              blocks: piece.blocks,
              totalSize: totalSize,
            ),
          );
          guard.phase = 2;
          if (piece.type == sparseRaw) {
            await cursor.skipTo(piece.dataOffset);
            var left = piece.dataSize;
            while (left > 0) {
              final size = math.min(_transportChunk, left);
              await session.writeDownload(await cursor.readExact(size));
              left -= size;
              await progress(size);
            }
          } else if (piece.type == sparseFill) {
            await session.writeDownload(fillBytes(piece.fill));
          }
        }
        if (index == parts.length - 1) await cursor.skipTo(source.length);
        await session.endDownload();
        guard.phase = 3;
        check();
        guard.phase = 4;
        await session.command('flash:$partition', write: true);
        guard.phase = 5;
      } catch (error) {
        if (_writeIsUncertain(guard, error)) markUncertain();
        writes.add({
          'partition': partition,
          'image': image,
          'bytes': part.length,
          'parts': parts.length,
          'part': index + 1,
          'status': _writeIsUncertain(guard, error) ? 'uncertain' : 'failed',
        });
        rethrow;
      }
      writes.add({
        'partition': partition,
        'image': image,
        'bytes': part.length,
        'parts': parts.length,
        'part': index + 1,
        'status': 'ok',
      });
    }
  } finally {
    await cursor.close();
    await source.close();
  }
}

Future<({FastbootSession session, FastbootReadiness readiness})> _waitForSerial(
  FastbootTransport transport,
  PreparedFlash prepared,
  FlashMode? expectedMode,
  void Function() check,
  Duration timeout,
  Duration poll,
) async {
  final deadline = DateTime.now().add(timeout);
  LinkFailure? last;
  final maxAttempts = math.max(1, timeout.inSeconds + 1);
  for (var attempt = 0; attempt < maxAttempts && DateTime.now().isBefore(deadline); attempt++) {
    check();
    try {
      final discovery = await transport.devices();
      for (final item in discovery.failures) {
        if (item.serial == prepared.serial) throw item.failure;
      }
      if (discovery.devices.any((device) => device.serial == prepared.serial)) {
        final session = await transport.open(prepared.serial);
        if (session.serial != prepared.serial) {
          await session.close();
          throw FlashException(
            'The transport opened ${session.serial} instead of '
            '${prepared.serial}.',
          );
        }
        try {
          final readiness = await probeFastbootConsistency(session);
          if (expectedMode == null || readiness.mode == expectedMode) return (session: session, readiness: readiness);
          await session.close();
        } on Object {
          await session.close();
          rethrow;
        }
      }
    } on LinkFailure catch (error) {
      last = error;
      if (error.uncertain || error.name == 'InconsistentDeviceAnswers') rethrow;
    }
    await Future<void>.delayed(poll);
  }
  throw FlashException(
    'Timed out after ${timeout.inSeconds}s waiting for '
    '${prepared.serial} to return in ${expectedMode?.name ?? 'fastboot'}.'
    '${last == null ? '' : ' Last error: $last'}',
  );
}

Future<FastbootSession> _openExact(
  FastbootTransport transport,
  String serial,
) async {
  final session = await transport.open(serial);
  if (session.serial != serial) {
    await session.close();
    throw FlashException(
      'The transport opened ${session.serial} instead of $serial.',
    );
  }
  return session;
}

Future<void> _close(FastbootSession session, List<String> cleanupErrors) async {
  try {
    await session.close();
  } on Object catch (error) {
    cleanupErrors.add('$error');
  }
}

String _statusFor(Object error, bool uncertain) {
  if (error is _Cancelled) return 'cancelled';
  if (error is LinkFailure && error.uncertain) return 'uncertain';
  if (error is FlashException && error.uncertain) return 'uncertain';
  if (uncertain) return 'uncertain';
  return 'failed';
}

final class _WriteGuard {
  /// 0 none, 1 announced, 2 data sent, 3 staged, 4 flash in flight, 5 acknowledged.
  int phase = 0;
}

/// Staging changes RAM, not a partition. Only a flash command that may have
/// reached the device leaves a persistent write uncertain. A complete device
/// FAIL is a definite refusal, not an uncertain write.
bool _writeIsUncertain(_WriteGuard guard, Object error) {
  if (guard.phase != 4) return false;
  if (error is LinkFailure) return error.uncertain;
  return true;
}

final class _Cancelled implements Exception {
  const _Cancelled();
}

const int _transportChunk = 1 << 20;
