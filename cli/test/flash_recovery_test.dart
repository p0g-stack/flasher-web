import 'package:flasher_web_cli/src/commands/flash_command.dart';
import 'package:flasher_web_core/flasher_web_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'prompt numbers map only to displayed recovery actions; default is stop',
    () {
      const actions = [
        FlashRecovery.rewriteStep,
        FlashRecovery.recoverFastbootd,
      ];
      expect(recoveryChoice('1', actions), FlashRecovery.rewriteStep);
      expect(recoveryChoice('2', actions), FlashRecovery.recoverFastbootd);
      for (final input in ['', 'retry', '0', '-1', '3', 'reboot']) {
        expect(recoveryChoice(input, actions), FlashRecovery.stopRun);
      }
    },
  );
}
