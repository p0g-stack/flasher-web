/// The CLI half of the e2e proof, run as its own process so `FLASHER_FAKE_USB`
/// is a compile-time define of this entrypoint only.
///
/// Usage: `dart run -DFLASHER_FAKE_USB=true e2e/bin/cli_scenarios.dart
/// descriptor.json`
///
/// The descriptor names the fixture paths and where to write the receipt,
/// exported ZIP and the fake device's recorded state.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flasher_web_cli/flasher_web_cli.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: cli_scenarios.dart <descriptor.json>');
    exitCode = 64;
    return;
  }
  final descriptor = jsonDecode(File(args.single).readAsStringSync()) as Map;
  String path(String key) => '${descriptor[key]}';

  final runner = AppRunner();
  final flashCode = await runner.run([
    'flash',
    '--device',
    'Oneplus 13',
    '--kind',
    'SuperHybrid Flasher',
    '--region',
    'GLO',
    '--ota',
    path('ota'),
    '--bloat-dir',
    path('bloatDir'),
    '--upstream',
    path('upstreamDir'),
    '--serial',
    fakeFastbootSerial,
    '--confirm-serial',
    fakeFastbootSerial,
    '--answer',
    'root=flash-signal',
    '--answer',
    'wipe=reboot',
    '--receipt',
    path('receipt'),
  ]);
  final exported = await runner.run([
    'export',
    '--device',
    'Oneplus 13',
    '--kind',
    'SuperHybrid Flasher',
    '--region',
    'GLO',
    '--ota',
    path('ota'),
    '--bloat-dir',
    path('bloatDir'),
    '--upstream',
    path('upstreamDir'),
    '--out',
    path('out'),
  ]);
  File(path('state')).writeAsStringSync(jsonEncode(fakeFastbootState()));
  stdout.writeln('cli flash exit=$flashCode export exit=$exported');
  if (flashCode != 0 || exported != 0) {
    exitCode = 1;
  }
}
