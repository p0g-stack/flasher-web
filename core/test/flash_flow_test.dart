import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

void main() {
  test('connection events cannot settle an uncertain write', () {
    final failed = const FlashFlowState().onEvent({
      'type': 'failure',
      'status': 'uncertain',
    });
    final connected = failed.onEvent({'type': 'connection', 'state': 'ready'});
    expect(connected.connection, FlashConnection.ready);
    expect(connected.phase, FlashRunPhase.recovering);
    expect(connected.certainty, WriteCertainty.uncertain);
    final restored = FlashFlowState.fromReceipt({
      'status': 'uncertain',
      'uncertain': true,
    });
    expect(restored.phase, FlashRunPhase.stopped);
    expect(restored.certainty, WriteCertainty.uncertain);
  });

  test('uncertain mutation never offers read retry or reconnect replay', () {
    final actions = recoveryActions(
      const [Flash('boot_a', 'boot.img')],
      {
        'stepIndex': 0,
        'uncertain': true,
        'failure': {'sessionRetired': true},
      },
      canWipeSuper: false,
    );
    expect(actions, contains(FlashRecovery.rewriteStep));
    expect(actions, isNot(contains(FlashRecovery.retryRead)));
    expect(actions, isNot(contains(FlashRecovery.reconnectDevice)));
  });

  test(
    'inconsistent replies require physical recovery, not a write action',
    () {
      expect(
        recoveryActions(
          const [Flash('boot_a', 'boot.img')],
          {
            'stepIndex': 0,
            'failure': {'name': 'InconsistentDeviceAnswers'},
          },
          canWipeSuper: true,
        ),
        [FlashRecovery.recoverPowerCycle, FlashRecovery.stopRun],
      );
    },
  );

  test('only regional capacity failures can offer clear super', () {
    final receipt = {
      'stepIndex': 1,
      'failure': {'message': 'Not enough space to resize partition'},
    };
    const steps = [
      CreateLogical('system_a', 1),
      Flash('system_a', 'system.img'),
    ];
    expect(
      recoveryActions(steps, receipt, canWipeSuper: true).first,
      FlashRecovery.wipeSuper,
    );
    expect(
      recoveryActions(steps, receipt, canWipeSuper: false),
      isNot(contains(FlashRecovery.wipeSuper)),
    );
    expect(
      recoveryActions(
        const [Flash('boot_a', 'boot.img')],
        {'stepIndex': 0, 'failure': receipt['failure']},
        canWipeSuper: true,
      ),
      isNot(contains(FlashRecovery.wipeSuper)),
    );
  });
}
