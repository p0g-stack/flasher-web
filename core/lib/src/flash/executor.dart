/// Executes one prepared flash plan.
///
/// Rules this file owns:
/// - stop at the first failure and never resend an uncertain write;
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
}) async {
  final cancel = cancellation ?? FlashCancellation();
  final startedAt = DateTime.now().toUtc().toIso8601String();
  if (!prepared.resolved) {
    throw const FlashException(
      'The plan still has unanswered prompts; execution is refused.',
    );
  }
  final steps = <Map<String, Object?>>[];
  final writes = <Map<String, Object?>>[];
  final cleanupErrors = <String>[];
  var status = 'succeeded';
  var uncertain = false;
  Map<String, Object?>? failure;
  var modeEnd = prepared.mode.name;
  var maxDownloadSize = prepared.maxDownloadSize;
  FastbootSession? session;

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
    if (mode != FlashMode.bootloader) {
      throw FlashException(
        'The device is in ${mode.name}, but this plan starts in the normal '
        'bootloader. Reboot there and prepare again.',
      );
    }
    var product = await readProduct(first);
    if (product != prepared.expectedProduct) {
      throw FlashException(
        'The device reports product "$product" after opening, not '
        '"${prepared.expectedProduct}".',
      );
    }
    maxDownloadSize = parseDownloadSize(
      await first.command('getvar:max-download-size'),
    );
    emit({
      'type': 'log',
      'text':
          'Flashing ${prepared.selection.device} '
          '(${prepared.serial}), product $product, '
          'max-download-size $maxDownloadSize.',
    });

    final execution = prepared.plan.executionSteps;
    for (var index = 0; index < execution.length; index++) {
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
            // and its product and mode are checked again before the next
            // command.
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
  final receipt = <String, Object?>{
    'version': 1,
    'job': prepared.job,
    'status': status,
    'serial': prepared.serial,
    'device': prepared.selection.device,
    'dev': prepared.selection.dev,
    'kind': prepared.selection.kind,
    'region': prepared.selection.region,
    'product': prepared.product,
    'expectedProduct': prepared.expectedProduct,
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
    case GetvarCheck(:final name, :final expected):
      final value = cleanGetvar(await need().command('getvar:$name'), name);
      if (value != expected) {
        throw FlashException(
          'getvar $name returned "$value"; the package requires "$expected".',
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
        FlashMode.superFastboot => 'reboot-bootloader',
      };
      LinkFailure? rebootFailure;
      try {
        await active.command(command, write: true);
      } on LinkFailure catch (error) {
        if (!error.uncertain) rethrow;
        // A reboot may disconnect before OKAY. Observe its result; never resend.
        rebootFailure = error;
        _log.warning('Reboot acknowledgement lost: ${error.toMap()}');
      }
      await active.close();
      if (mode == FlashMode.android) {
        finalReboot(true);
        if (rebootFailure != null) throw rebootFailure;
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
          final product = await readProduct(session);
          if (product != prepared.expectedProduct) {
            throw FlashException(
              'After reconnecting, ${prepared.serial} reports product '
              '"$product" instead of "${prepared.expectedProduct}".',
            );
          }
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
