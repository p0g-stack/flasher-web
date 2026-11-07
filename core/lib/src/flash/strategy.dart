import 'package:device_link/device_link.dart';

import '../facts/facts.dart';
import '../strategy/objective.dart';
import '../strategy/strategy.dart';
import 'executor.dart';
import 'model.dart';
import 'prepare.dart';

/// The service calls this only after consuming the exact user confirmation
/// token and rechecking its package. Objective owns strategy accounting; the
/// executor owns the serial pin and the protocol's uncertainty semantics.
Future<Map<String, Object?>> applyConfirmedFlash(
  PreparedFlash input,
  FastbootTransport transport,
  PlaceInfo place, {
  required FlashEventSink emit,
  required FlashCancellation cancellation,
}) async {
  final objective = Objective<PreparedFlash, Map<String, Object?>>('flash', [
    _NativeFastboot(transport, emit, cancellation),
    _WebUsbFastboot(transport, emit, cancellation),
  ]);
  final plan = await objective.plan(input, place);
  final receipt = await objective.apply(plan, Confirmation.of(plan));
  return {
    ...receipt.result,
    'strategy': receipt.run.strategy,
    'place': receipt.run.place,
    'facts': receipt.run.facts,
  };
}

abstract base class _FastbootWrite
    extends WriteStrategy<PreparedFlash, Map<String, Object?>> {
  const _FastbootWrite(this.transport, this.emit, this.cancellation);
  final FastbootTransport transport;
  final FlashEventSink emit;
  final FlashCancellation cancellation;

  @override
  Future<List<String>> plan(PreparedFlash input, PlaceInfo place) async {
    if (!input.resolved) {
      throw const FlashException('Answer every flash prompt first.');
    }
    return input.plan.confirmationText(input.serial);
  }

  @override
  Future<Map<String, Object?>> write(PreparedFlash input, PlaceInfo place) =>
      executePreparedFlash(
        input,
        transport,
        emit: emit,
        cancellation: cancellation,
      );
}

final class _NativeFastboot extends _FastbootWrite {
  const _NativeFastboot(super.transport, super.emit, super.cancellation);
  @override
  String get name => 'native_fastboot';
  @override
  Set<String> get requires => const {Fact.usbNative, Fact.native};
}

final class _WebUsbFastboot extends _FastbootWrite {
  const _WebUsbFastboot(super.transport, super.emit, super.cancellation);
  @override
  String get name => 'webusb_fastboot';
  @override
  Set<String> get requires => const {Fact.usbWeb, Fact.native};
}
