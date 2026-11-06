import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import '../service_args.dart';

/// Describes a full OTA ZIP or URL through [FlasherService.inspectOta].
class InspectCommand extends Command<int> {
  InspectCommand() {
    argParser.addOption(
      'api-base',
      defaultsTo: defaultApiBase,
      help: 'Origin serving /api/*.',
    );
  }

  @override
  String get name => 'inspect';

  @override
  String get description => 'Describe a full OTA ZIP or URL.';

  @override
  String get invocation => '${runner!.executableName} inspect <zip|url>';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length != 1) {
      throw UsageException(
        'Choose one OTA ZIP path or HTTP(S) URL.',
        argParser.usage,
      );
    }
    final source = args.rest.single;
    final apiBase = args.option('api-base')!;
    try {
      apiBaseUri(apiBase);
    } on FormatException catch (error) {
      throw UsageException(error.message, argParser.usage);
    }
    try {
      final info = await FlasherService().inspectOta(
        inspectRequest(ota: otaInput(source), apiBase: apiBase),
      );
      printInspection(info, source: source);
      return 0;
    } on UsageException {
      rethrow;
    } catch (error) {
      stderr.writeln('ERROR: $error');
      return 1;
    }
  }
}
