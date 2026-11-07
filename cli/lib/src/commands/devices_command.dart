import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

/// Lists granted fastboot devices. It never opens a browser chooser.
class DevicesCommand extends Command<int> {
  @override
  String get name => 'devices';

  @override
  String get description => 'List connected fastboot devices.';

  @override
  Future<int> run() async {
    try {
      final result = await FlasherService().fastbootDevices();
      final failure = result['error'];
      if (failure is Map) {
        stderr.writeln('ERROR: ${failure['name']}: ${failure['message']}');
        return 1;
      }
      final devices = (result['devices'] as List).cast<Map>();
      if (devices.isEmpty) {
        print('No granted fastboot devices.');
        return 0;
      }
      for (final device in devices) {
        final serial = device['serial'] ?? '?';
        final label = device['label'] ?? '';
        final transport = device['transport'] ?? '';
        print('$serial\t$label\t$transport');
      }
      return 0;
    } catch (error) {
      stderr.writeln('ERROR: $error');
      return 1;
    }
  }
}
