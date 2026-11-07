import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import 'commands/bloat_command.dart';
import 'commands/build_command.dart';
import 'commands/devices_command.dart';
import 'commands/facts_command.dart';
import 'commands/flash_command.dart';
import 'commands/inspect_command.dart';
import 'commands/serve_command.dart';

// p0g:imports (bricks insert imports above this line)

/// The `flasher_web` command runner.
class AppRunner extends CommandRunner<int> {
  AppRunner()
    : super(
        'flasher_web',
        r'''Build OnePlus flasher packages from full OTAs in the browser.''',
      ) {
    argParser
      ..addFlag('verbose', abbr: 'v', help: 'Log everything.')
      ..addFlag('json', help: 'Log records as JSON lines.');
    addCommand(BloatCommand());
    addCommand(BuildCommand());
    addCommand(DevicesCommand());
    addCommand(FactsCommand());
    addCommand(FlashCommand());
    addCommand(InspectCommand());
    addCommand(ServeCommand());
    // p0g:commands (bricks insert commands above this line)
  }

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      return await super.run(args) ?? 0;
    } on UsageException catch (e) {
      stderr.writeln(e);
      return 64;
    }
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    final stop = logTo(
      stderr.writeln,
      level: topLevelResults.flag('verbose') ? Level.ALL : Level.INFO,
      json: topLevelResults.flag('json'),
    );
    try {
      return await super.runCommand(topLevelResults);
    } finally {
      stop();
    }
  }
}

/// The CLI running a command itself, with facts checked here.
Future<PlaceInfo> cliPlace() async =>
    PlaceInfo('cli', Facts(await checkFacts()));
