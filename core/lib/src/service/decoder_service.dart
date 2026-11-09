import 'dart:typed_data';

import 'package:squadron/squadron.dart';

import '../native/native.dart';
import '../rust/api/payload.dart';
import 'decoder_service.activator.g.dart';

part 'decoder_service.worker.g.dart';

/// Decodes single payload operations for `PoolOpDecoder`.
///
/// Stateless: every request carries the operation's kind, data, data SHA-256
/// and sizes, so any worker of the pool can take any operation. Each worker
/// loads its own copy of the Rust library on first use.
///
/// Only `FlasherService` starts these workers, and on the web it runs in a
/// Web Worker under `workers/`. Squadron's `~` names the page's root, which a
/// worker does not have, so the entry point is relative to the spawning
/// worker's script instead: `workers/decoder_service.web.g.dart.js`.
@SquadronService(
  baseUrl: '.',
  targetPlatform: TargetPlatform.vm | TargetPlatform.web,
)
base class PayloadDecoder {
  /// Loads the Rust library; false when this place has none.
  @squadronMethod
  Future<bool> ready() => loadNative();

  /// The bytes one operation writes; see `decodeOperation` in Rust.
  @squadronMethod
  Future<Uint8List> decode(
    int kind,
    Uint8List data,
    Uint8List? dataSha256,
    int total,
    int blockSize,
    String what,
  ) async {
    if (!await loadNative()) {
      throw StateError('The OTA decoder is unavailable in this worker.');
    }
    return decodeOperation(
      kind: kind,
      data: data,
      dataSha256: dataSha256,
      total: BigInt.from(total),
      blockSize: BigInt.from(blockSize),
      what: what,
    );
  }
}
