import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import '../service_args.dart';

/// Downloads and verifies the bloat images a selection needs.
class BloatCommand extends Command<int> {
  BloatCommand() {
    argParser
      ..addOption(
        'device',
        mandatory: true,
        help: 'Upstream device name, for example "Oneplus 13".',
      )
      ..addOption(
        'kind',
        mandatory: true,
        help: 'Flasher type, for example "SuperHybrid Flasher".',
      )
      ..addOption(
        'region',
        mandatory: true,
        help: 'Region code, for example GLO.',
      )
      ..addOption(
        'bloat-dir',
        mandatory: true,
        help: 'Directory that holds the selected bloat images.',
      )
      ..addOption(
        'api-base',
        defaultsTo: defaultApiBase,
        help: 'Origin serving /api/*.',
      )
      ..addOption(
        'upstream',
        defaultsTo: defaultUpstream,
        help: 'Directory or URL serving bloat-manifest.json.',
      );
  }

  @override
  String get name => 'bloat';

  @override
  String get description =>
      'Download and verify the bloat images a selection needs.';

  @override
  String get invocation =>
      '${runner!.executableName} bloat --device D --kind K --region R '
      '--bloat-dir DIR';

  @override
  Future<int> run() async {
    final args = argResults!;
    String? option(String name) =>
        args.wasParsed(name) ? args.option(name) : null;
    final bloatDir = option('bloat-dir');
    final device = option('device');
    final kind = option('kind');
    final region = option('region');
    if (bloatDir == null || device == null || kind == null || region == null) {
      throw UsageException(
        'Missing --device, --kind, --region or --bloat-dir.',
        argParser.usage,
      );
    }
    final apiBase = args.option('api-base')!;
    try {
      apiBaseUri(apiBase);
    } on FormatException catch (error) {
      throw UsageException(error.message, argParser.usage);
    }
    final request = bloatRequest(
      selection: selectionMap(device: device, kind: kind, region: region),
      bloatDir: bloatDir,
      apiBase: apiBase,
      upstream: args.option('upstream')!,
    );
    print('STEP 1/5 • Check selected bloat files');
    print('Bloat folder: ${Directory(bloatDir).absolute.path}');
    try {
      final service = FlasherService();
      Map<String, Object?>? result;
      await for (final event in service.downloadBloat(request)) {
        if (event['type'] == 'result') {
          result = event;
        } else {
          printEvent(event);
        }
      }
      if (result == null) {
        stderr.writeln('ERROR: The bloat service returned no result.');
        return 1;
      }
      final bloat = result['bloat'];
      if (bloat is! Map || bloat['ready'] != true) {
        printBloatResult(result);
        stderr.writeln('ERROR: The selected bloat files are not ready.');
        return 1;
      }
      print('STEP 5/5 • Bloat files ready');
      printBloatResult(result);
      return 0;
    } on UsageException {
      rethrow;
    } catch (error) {
      stderr.writeln('ERROR: $error');
      return 1;
    }
  }
}
