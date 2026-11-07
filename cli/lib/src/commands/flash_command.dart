import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import '../service_args.dart';

/// Prepares a job read-only, shows the plan, then flashes only when the user
/// repeats the connected serial exactly.
class FlashCommand extends Command<int> {
  FlashCommand() {
    argParser
      ..addOption(
        'output',
        mandatory: true,
        help: 'Directory that contains the finished job.',
      )
      ..addOption(
        'job',
        mandatory: true,
        help: 'Job directory name inside --output.',
      )
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
        'serial',
        mandatory: true,
        help: 'The connected fastboot serial to prepare.',
      )
      ..addOption(
        'confirm-serial',
        help:
            'Repeat --serial exactly to allow writes. Without it the command '
            'only prints the read-only plan.',
      )
      ..addMultiOption(
        'answer',
        help:
            'Prompt answer as id=value, repeatable. Use product=<getvar '
            'product> when the device table marks the product unknown.',
      )
      ..addOption(
        'upstream',
        defaultsTo: defaultUpstream,
        help: 'Directory or URL serving tables.json and the flasher templates.',
      );
  }

  @override
  String get name => 'flash';

  @override
  String get description =>
      'Flash a finished job after an explicit serial confirmation.';

  @override
  String get invocation =>
      '${runner!.executableName} flash --output DIR --job JOB --device D '
      '--kind K --region R --serial SERIAL [--confirm-serial SERIAL] '
      '[--answer id=value]';

  @override
  Future<int> run() async {
    final results = argResults!;
    const required = ['output', 'job', 'device', 'kind', 'region', 'serial'];
    final missing = [
      for (final key in required)
        if (!results.wasParsed(key) ||
            (results.option(key) ?? '').trim().isEmpty)
          key,
    ];
    if (missing.isNotEmpty) {
      throw UsageException(
        'Missing ${missing.map((key) => '--$key').join(', ')}.',
        argParser.usage,
      );
    }
    final answers = <String, String>{};
    for (final raw in results.multiOption('answer')) {
      final at = raw.indexOf('=');
      if (at <= 0 || at == raw.length - 1) {
        throw UsageException(
          'An answer must be id=value, not "$raw".',
          argParser.usage,
        );
      }
      answers[raw.substring(0, at)] = raw.substring(at + 1);
    }
    final request = flashPrepareRequest(
      selection: selectionMap(
        device: results.option('device')!,
        kind: results.option('kind')!,
        region: results.option('region')!,
      ),
      outputDir: results.option('output')!,
      job: results.option('job')!,
      serial: results.option('serial')!,
      answers: answers,
      upstream: results.option('upstream')!,
    );
    final service = FlasherService();
    try {
      final prepared = await service.prepareFlash(request);
      final failure = prepared['error'];
      if (failure is Map) {
        stderr.writeln('ERROR: ${failure['name']}: ${failure['message']}');
        return 1;
      }
      if (prepared['productRequired'] == true) {
        stderr.writeln(
          '${prepared['message']}\nUse --answer product=<verified product>.',
        );
        return 2;
      }
      printFlashPreparation(prepared);
      if (prepared['resolved'] != true) {
        stderr.writeln(
          'ERROR: Answer every prompt above with --answer id=value, then '
          'prepare again.',
        );
        return 2;
      }
      final serial = '${prepared['serial'] ?? ''}';
      final confirm = results.option('confirm-serial');
      if (confirm == null) {
        stderr.writeln(
          'Read-only plan complete. To allow writes, repeat the connected '
          'serial exactly:\n'
          '  --confirm-serial $serial',
        );
        return 2;
      }
      if (confirm != serial) {
        stderr.writeln(
          'ERROR: --confirm-serial "$confirm" does not match the connected '
          'serial "$serial". No write was sent.',
        );
        return 1;
      }
      final token = prepared['token'];
      if (token is! String || token.isEmpty) {
        stderr.writeln('ERROR: The service returned no confirmation token.');
        return 1;
      }
      Map<String, Object?>? result;
      await for (final event in service.flash({
        ...request,
        'confirmationToken': token,
      })) {
        if (event['type'] == 'result') {
          result = event;
        } else {
          printEvent(event);
        }
      }
      if (result == null) {
        stderr.writeln('ERROR: The flash service returned no result.');
        return 1;
      }
      printFlashResult(result);
      final status = result['status'];
      return switch (status) {
        'succeeded' => 0,
        'cancelled' => 2,
        _ => 1,
      };
    } on UsageException {
      rethrow;
    } catch (error) {
      stderr.writeln('ERROR: $error');
      return 1;
    }
  }
}
