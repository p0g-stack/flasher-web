import 'model.dart';

/// These axes are independent: a ready connection cannot settle a lost write.
enum FlashConnection {
  unavailable,
  waiting,
  opening,
  probing,
  ready,
  active,
  transitioning,
  needsAccess,
  lost,
  closing,
  stopped,
}

enum FlashRunPhase {
  setup,
  connecting,
  preparing,
  confirming,
  writing,
  recovering,
  done,
  stopped,
}

enum WriteCertainty { notSubmitted, confirmed, refused, uncertain }

enum FlashRecovery {
  retryRead,
  reconnectDevice,
  recoverBootloader,
  recoverFastbootd,
  recoverPowerCycle,
  rewriteStep,
  wipeSuper,
  stopRun,
}

final class FlashFlowState {
  const FlashFlowState({
    this.connection = FlashConnection.waiting,
    this.phase = FlashRunPhase.setup,
    this.certainty = WriteCertainty.notSubmitted,
  });
  final FlashConnection connection;
  final FlashRunPhase phase;
  final WriteCertainty certainty;

  FlashFlowState onEvent(Map<String, Object?> event) {
    final receipt = event['receipt'];
    final uncertain = receipt is Map && receipt['uncertain'] == true;
    return switch (event['type']) {
      'connection' => FlashFlowState(
        connection: FlashConnection.values.byName(event['state']! as String),
        phase: phase,
        certainty: certainty,
      ),
      'run' => FlashFlowState(
        connection: connection,
        phase: FlashRunPhase.preparing,
        certainty: certainty,
      ),
      'step' => FlashFlowState(
        connection: connection,
        phase: FlashRunPhase.writing,
        certainty: certainty,
      ),
      'failure' => FlashFlowState(
        connection: connection,
        phase: FlashRunPhase.recovering,
        certainty: event['status'] == 'uncertain'
            ? WriteCertainty.uncertain
            : certainty,
      ),
      'result' => FlashFlowState(
        connection: connection,
        phase: switch (event['status']) {
          'succeeded' => FlashRunPhase.done,
          'stopped' || 'cancelled' => FlashRunPhase.stopped,
          _ => FlashRunPhase.recovering,
        },
        certainty: uncertain
            ? WriteCertainty.uncertain
            : event['status'] == 'succeeded'
            ? WriteCertainty.confirmed
            : WriteCertainty.refused,
      ),
      _ => this,
    };
  }

  /// Restored receipts are inspection only, never executable state.
  factory FlashFlowState.fromReceipt(Map<String, Object?> receipt) =>
      FlashFlowState(
        connection: FlashConnection.stopped,
        phase: receipt['status'] == 'succeeded'
            ? FlashRunPhase.done
            : FlashRunPhase.stopped,
        certainty: receipt['uncertain'] == true
            ? WriteCertainty.uncertain
            : receipt['status'] == 'succeeded'
            ? WriteCertainty.confirmed
            : WriteCertainty.refused,
      );

  Map<String, Object?> toMap() => {
    'connection': connection.name,
    'phase': phase.name,
    'certainty': certainty.name,
  };
}

String recoveryLabel(FlashRecovery action) => switch (action) {
  FlashRecovery.retryRead => 'Retry read-only check',
  FlashRecovery.reconnectDevice => 'Reconnect the same phone',
  FlashRecovery.recoverBootloader => 'Reboot to bootloader',
  FlashRecovery.recoverFastbootd => 'Reboot to fastbootd',
  FlashRecovery.recoverPowerCycle => 'I have power-cycled the phone',
  FlashRecovery.rewriteStep => 'Rewrite this step from byte zero',
  FlashRecovery.wipeSuper => 'Clear super and restart logical writes',
  FlashRecovery.stopRun => 'Stop further commands',
};

FlashMode requiredModeAt(List<FlashStep> steps, int index) {
  var mode = FlashMode.bootloader;
  for (var i = 0; i <= index; i++) {
    final step = steps[i];
    if (step is RequireMode) mode = step.mode;
    if (i < index && step is RebootTo) mode = step.mode;
  }
  return mode;
}

bool isMutatingStep(FlashStep step) =>
    step is Flash ||
    step is CreateLogical ||
    step is DeleteLogical ||
    step is SetActive ||
    step is RebootTo;

/// Only core classifies actions. Clients must not infer replay permission from
/// a connected USB device, a generic canRetry flag, or rendered failure text.
List<FlashRecovery> recoveryActions(
  List<FlashStep> steps,
  Map<String, Object?> receipt, {
  required bool canWipeSuper,
}) {
  final index = receipt['stepIndex'];
  if (index is! int || index < 0 || index >= steps.length) {
    return [FlashRecovery.stopRun];
  }
  final failure = receipt['failure'] is Map
      ? receipt['failure']! as Map
      : const {};
  final step = steps[index];
  final inconsistent = failure['name'] == 'InconsistentDeviceAnswers';
  final retired =
      failure['sessionRetired'] == true ||
      failure['disconnectObserved'] == true;
  final uncertain = receipt['uncertain'] == true;
  final mode = requiredModeAt(steps, index);
  final stage = '${failure['stage']}';
  // Changed inputs cannot be fixed by issuing another device command.
  if (stage == 'recovery-inputs') return [FlashRecovery.stopRun];
  if (inconsistent) {
    return [FlashRecovery.recoverPowerCycle, FlashRecovery.stopRun];
  }
  if (canWipeSuper &&
      (receipt['wipeSuperPending'] == true ||
          receipt['wipeSuperRequired'] == true ||
          (receipt['superPreflight'] is Map &&
              (receipt['superPreflight']! as Map)['needsWipe'] == true &&
              (receipt['superPreflight']! as Map)['cleared'] != true) ||
          failure['name'] == 'SuperSpaceRequired' ||
          ((step is CreateLogical ||
                  (step is Flash &&
                      steps.any(
                        (candidate) =>
                            candidate is CreateLogical &&
                            candidate.name == step.partition,
                      ))) &&
              '${failure['message']}'.toLowerCase().contains(
                'not enough space',
              )))) {
    return [FlashRecovery.wipeSuper, FlashRecovery.stopRun];
  }
  if (uncertain && isMutatingStep(step)) {
    return [
      FlashRecovery.rewriteStep,
      if (mode == FlashMode.bootloader) FlashRecovery.recoverBootloader,
      if (mode == FlashMode.fastbootd) FlashRecovery.recoverFastbootd,
      FlashRecovery.recoverPowerCycle,
      FlashRecovery.stopRun,
    ];
  }
  return [
    if (!isMutatingStep(step) &&
        !retired &&
        !uncertain &&
        failure['blame'] == 'device')
      FlashRecovery.retryRead,
    if (isMutatingStep(step)) FlashRecovery.rewriteStep,
    if (retired) FlashRecovery.reconnectDevice,
    if (mode == FlashMode.bootloader) FlashRecovery.recoverBootloader,
    if (mode == FlashMode.fastbootd) FlashRecovery.recoverFastbootd,
    if (retired) FlashRecovery.recoverPowerCycle,
    FlashRecovery.stopRun,
  ];
}
