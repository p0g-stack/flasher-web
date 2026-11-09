/// Where payload operations are decoded: inline, or on a pool of workers.
///
/// XZ decoding is the slowest step of reading a OnePlus OTA: one thread
/// decodes about 55 MiB/s in wasm and 64 MiB/s natively, while hashing runs
/// at 590 MiB/s and 2.5 GiB/s. Operations are independent, so a pool decodes
/// several at once and the reader takes them back in destination order.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:squadron/squadron.dart';

import '../rust/api/payload.dart';
import '../service/decoder_service.dart';
import 'cpu_count.dart';

/// Decodes one operation's payload data into the bytes it writes.
abstract interface class OpDecoder {
  /// How many operations this decoder works on at once.
  int get parallelism;

  /// The bytes [op] writes, from its payload [data]; empty for ZERO and
  /// DISCARD. [total] is what its extents hold and [what] names it in errors.
  Future<Uint8List> decode(
    OpInfo op,
    Uint8List data, {
    required int total,
    required int blockSize,
    required String what,
  });

  Future<void> close();
}

/// Decodes on the calling isolate or worker, one operation at a time.
final class InlineOpDecoder implements OpDecoder {
  const InlineOpDecoder();

  @override
  int get parallelism => 1;

  @override
  Future<Uint8List> decode(
    OpInfo op,
    Uint8List data, {
    required int total,
    required int blockSize,
    required String what,
  }) async => decodeOperation(
    kind: op.kind,
    data: data,
    dataSha256: op.dataSha256,
    total: BigInt.from(total),
    blockSize: BigInt.from(blockSize),
    what: what,
  );

  @override
  Future<void> close() async {}
}

/// Decodes on a pool of [PayloadDecoder] workers (isolates natively, Web
/// Workers in a browser), each with its own copy of the Rust library.
///
/// The workers start on the first decode, so a package that only reads
/// metadata (a flash preparation) starts none. A place that cannot start them
/// (a browser without nested workers, a missing library) decodes inline
/// instead, so reading an OTA never depends on the pool. [close] stops the
/// workers; an open pool keeps a VM process alive.
final class PoolOpDecoder implements OpDecoder {
  PoolOpDecoder({int? workers})
    : parallelism = workers ?? defaultDecodeWorkers();

  @override
  final int parallelism;

  Future<PayloadDecoderWorkerPool?>? _pool;
  bool _closed = false;

  static const _inline = InlineOpDecoder();

  Future<PayloadDecoderWorkerPool?> _start() async {
    if (parallelism <= 1) return null;
    final pool = PayloadDecoderWorkerPool(
      concurrencySettings: ConcurrencySettings(
        minWorkers: parallelism,
        maxWorkers: parallelism,
        maxParallel: 1,
      ),
    );
    try {
      // A worker script that never answers must not stall a flash.
      await pool.start().timeout(const Duration(seconds: 15));
      final ready = await pool.ready().timeout(const Duration(seconds: 15));
      if (!ready) throw StateError('no Rust library');
      return pool;
    } on Object {
      pool.stop();
      return null;
    }
  }

  @override
  Future<Uint8List> decode(
    OpInfo op,
    Uint8List data, {
    required int total,
    required int blockSize,
    required String what,
  }) async {
    if (_closed) throw StateError('The operation decoder is closed.');
    final pool = await (_pool ??= _start());
    if (pool == null) {
      return _inline.decode(
        op,
        data,
        total: total,
        blockSize: blockSize,
        what: what,
      );
    }
    return pool.decode(op.kind, data, op.dataSha256, total, blockSize, what);
  }

  @override
  Future<void> close() async {
    _closed = true;
    final pool = await _pool;
    pool?.stop();
  }
}

/// Decode workers for this machine: one per core but one, between 1 and 8.
int defaultDecodeWorkers() => (cpuCount() - 1).clamp(1, 8);
