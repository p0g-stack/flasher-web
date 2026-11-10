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

import 'package:device_link/device_link.dart';
import 'package:logging/logging.dart';

import 'model.dart';
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
  bool rebootRetry = false,
}) async {
  final cancel = cancellation ?? FlashCancellation();
  final startedAt = previousReceipt?['startedAt'] as String? ?? DateTime.now().toUtc().toIso8601String();
  final startStep = previousReceipt?['stepIndex'] as int? ?? 0;
  final execution = prepared.plan.executionSteps;
  if (startStep < 0 || startStep >= execution.length) throw const FlashException('Invalid failed step.');
  var requiredMode = FlashMode.bootloader;
  for (var i = 0; i <= startStep; i++) {
    final step = execution[i];
    if (step is RequireMode) requiredMode = step.mode;
    if (i < startStep && step is RebootTo) requiredMode = step.mode;
  }
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
  var uncertain = false;
  Map<String, Object?>? failure;
  var modeEnd = prepared.mode.name;
  var maxDownloadSize = prepared.maxDownloadSize;
  FastbootSession? session;
  var stepIndex = startStep;

  void check() {
    if (cancel.isCancelled) throw const _Cancelled();
  }

  void markUncertain() => uncertain = true;

  try {
    check();
    final first = await _openExact(transport, prepared.serial);
    session = first;
    var mode = await probeFlashMode(first);
    _log.info('flash ${prepared.serial}: mode ${mode.name}');
    modeEnd = mode.name;
    if (!rebootRetry && mode != requiredMode) {
      throw FlashException('The device is in ${mode.name}; step $startStep requires ${requiredMode.name}.');
    }
    if (rebootRetry) {
      await first.command(requiredMode == FlashMode.fastbootd ? 'reboot-fastboot' : 'reboot-bootloader', write: true);
      await first.close();
      session = await _waitForSerial(transport, prepared, requiredMode, check, reconnectTimeout, reconnectPoll);
      mode = await probeFlashMode(session);
      modeEnd = mode.name;
    }
    maxDownloadSize = parseDownloadSize(
      await session.command('getvar:max-download-size'),
    );
    emit({
      'type': 'log',
      'text':
          'Flashing ${prepared.selection.device} '
          '(${prepared.serial}), '
          'max-download-size $maxDownloadSize.',
    });

    for (var index = startStep; index < execution.length; index++) {
      stepIndex = index;
      uncertain = false;
      check();
      final step = execution[index];
      emit({
        'type': 'step',
        'index': index + 1,
        'total': execution.length,
        'title': step.text,
      });
      try {
        final next = await _runStep(
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
            try {
              maxDownloadSize = parseDownloadSize(
                await reopened.command('getvar:max-download-size'),
              );
              return reopened;
            } on Object {
              await reopened.close();
              rethrow;
            }
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
    if (session != null) {
      await _close(session, cleanupErrors);
    }
  }

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
    'cleanupErrors': cleanupErrors,
  };
  if (status == 'failed' || status == 'uncertain') {
    emit({'type': 'failure', 'stepIndex': stepIndex, 'status': status,
      'reason': failure?['message'] ?? 'Flash failed.'});
  }
  return receipt;
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
          check();
          final size = math.min(_transportChunk, left);
          final bytes = await cursor.readExact(size);
          guard.phase = 2;
          await session.writeDownload(bytes);
          left -= size;
          await progress(size);
        }
        check();
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
          check();
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
              check();
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
        check();
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

Future<FastbootSession> _waitForSerial(
  FastbootTransport transport,
  PreparedFlash prepared,
  FlashMode expectedMode,
  void Function() check,
  Duration timeout,
  Duration poll,
) async {
  final deadline = DateTime.now().add(timeout);
  LinkFailure? last;
  while (DateTime.now().isBefore(deadline)) {
    check();
    try {
      final devices = await transport.devices();
      if (devices.any((device) => device.serial == prepared.serial)) {
        final session = await transport.open(prepared.serial);
        if (session.serial != prepared.serial) {
          await session.close();
          throw FlashException(
            'The transport opened ${session.serial} instead of '
            '${prepared.serial}.',
          );
        }
        try {
          final mode = await probeFlashMode(session);
          if (mode == expectedMode) return session;
          await session.close();
        } on Object {
          await session.close();
          rethrow;
        }
      }
    } on LinkFailure catch (error) {
      last = error;
      if (error.uncertain) rethrow;
    }
    await Future<void>.delayed(poll);
  }
  throw FlashException(
    'Timed out after ${timeout.inSeconds}s waiting for '
    '${prepared.serial} to return in ${expectedMode.name}.'
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
