import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import '../service_args.dart';

/// Prepares a virtual flash read-only, shows the plan, then writes only when
/// the user repeats the connected serial exactly.
class FlashCommand extends Command<int> {
  FlashCommand() {
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
        'ota',
        help: 'Full OTA ZIP path or HTTP(S) URL to read in place.',
      )
      ..addOption(
        'catalog',
        help: 'Catalog release id to read through ranges.',
      )
      ..addOption(
        'base',
        help: 'Ace 6 conversion BASE full OTA ZIP path or HTTP(S) URL.',
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
        help:
            'Directory or URL serving tables.json, bloat-manifest.json '
            'and templates.',
      )
      ..addOption(
        'serial',
        mandatory: true,
        help: 'The connected fastboot serial to prepare and flash.',
      )
      ..addMultiOption(
        'answer',
        help:
            'Prompt answer as id=value, repeatable. Use product=<getvar '
            'product> when the device table marks the product unknown.',
      )
      ..addOption(
        'confirm-serial',
        help:
            'Repeat --serial exactly to allow writes. Without it the command '
            'only prints the read-only plan.',
      )
      ..addFlag(
        'vulnerable-abl',
        negatable: true,
        help:
            'X9U only: pack ABL 16.0.6 as abl.img. Use --no-vulnerable-abl to '
            'keep the OTA ABL; X9U requires one of the two.',
      )
      ..addOption(
        'receipt',
        help:
            'Receipt JSON path. Defaults to ./receipt-<runId>.json next to the '
            'process working directory.',
      );
  }

  @override
  String get name => 'flash';

  @override
  String get description =>
      'Flash a full OTA directly after an explicit serial confirmation.';

  @override
  String get invocation =>
      '${runner!.executableName} flash --device D --kind K --region R '
      '(--ota ZIP | --catalog ID) --bloat-dir DIR --serial SERIAL '
      '[--confirm-serial SERIAL] [--answer id=value] [--receipt PATH]';

  @override
  Future<int> run() async {
    final results = argResults!;
    final otaPath = results.option('ota');
    final catalogId = results.option('catalog');
    if ((otaPath == null) == (catalogId == null)) {
      throw UsageException(
        'Choose exactly one of --ota or --catalog.',
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
    final apiBase = results.option('api-base')!;
    try {
      apiBaseUri(apiBase);
    } on FormatException catch (error) {
      throw UsageException(error.message, argParser.usage);
    }
    final device = results.option('device')!;
    final kind = results.option('kind')!;
    final region = results.option('region')!;
    final serial = results.option('serial')!;
    final confirm = results.option('confirm-serial');
    if (confirm != null && confirm != serial) {
      stderr.writeln(
        'ERROR: --confirm-serial "$confirm" does not match the connected '
        'serial "$serial". No write was sent.',
      );
      return 1;
    }
    final vulnerableAbl = results.wasParsed('vulnerable-abl')
        ? results.flag('vulnerable-abl')
        : null;
    try {
      final ota = otaPath != null
          ? otaInput(otaPath)
          : await resolveCatalogEntry(
              apiBase: apiBase,
              device: device,
              kind: kind,
              region: region,
              id: catalogId!,
              role: 'ota',
            );
      final basePath = results.option('base');
      final request = flashPrepareRequest(
        selection: selectionMap(device: device, kind: kind, region: region),
        virtual: virtualRequest(
          ota: ota,
          base: basePath == null ? null : otaInput(basePath),
          bloatDir: results.option('bloat-dir')!,
          vulnerableAbl: vulnerableAbl,
        ),
        serial: serial,
        answers: answers,
        apiBase: apiBase,
        upstream: results.option('upstream')!,
      );
      final service = FlasherService();
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
      if (confirm == null) {
        stderr.writeln(
          'Read-only plan complete. To allow writes, repeat the connected '
          'serial exactly:\n'
          '  --confirm-serial $serial',
        );
        return 2;
      }
      final token = prepared['token'];
      if (token is! String || token.isEmpty) {
        stderr.writeln('ERROR: The service returned no confirmation token.');
        return 1;
      }
      // The service binds the prepared plan to the job it derived and
      // refuses an execution request that omits it.
      final job = prepared['job'];
      if (job is String && job.isNotEmpty) request['job'] = job;
      return await _execute(
        service,
        request,
        token,
        receiptOption: results.option('receipt'),
      );
    } on UsageException {
      rethrow;
    } catch (error) {
      stderr.writeln('ERROR: $error');
      return 1;
    }
  }

  /// Runs the confirmed flash, then follows the explicit retry lifecycle.
  Future<int> _execute(
    FlasherService service,
    Map<String, Object?> request,
    String token, {
    required String? receiptOption,
  }) async {
    String? runId;
    Map<String, Object?>? result;
    Stream<Map<String, Object?>> stream = service.flash({
      ...request,
      'confirmationToken': token,
    });
    while (true) {
      result = null;
      await for (final event in stream) {
        final type = event['type'];
        if (type == 'run') {
          final id = event['runId'];
          runId = id is String ? id : null;
          print('RUN ${runId ?? '?'}');
        } else if (type == 'failure') {
          printFlashFailure(event);
        } else if (type == 'result') {
          result = event;
        } else {
          printEvent(event);
        }
      }
      if (result == null) {
        stderr.writeln('ERROR: The flash service returned no result.');
        return 1;
      }
      final status = '${result['status']}';
      if (status != 'failed' && status != 'uncertain') break;
      if (result['canRetry'] != true || runId == null) break;
      final choice = _askRetry();
      if (choice == 'stop') {
        final stopped = await service.stopRun({'runId': runId});
        final stoppedReceipt = stopped['receipt'];
        final receipt = stoppedReceipt is Map
            ? Map<String, Object?>.from(stoppedReceipt)
            : <String, Object?>{};
        printFlashResult({'status': 'stopped', 'receipt': receipt});
        await _writeReceipt(receipt, receiptOption: receiptOption, runId: runId);
        return 2;
      }
      stream = choice == 'reboot'
          ? service.rebootRetry({'runId': runId})
          : service.retryStep({'runId': runId});
    }
    printFlashResult(result);
    final receipt = result['receipt'];
    if (receipt is Map) {
      final map = Map<String, Object?>.from(receipt);
      final receiptRunId = map['runId'] is String
          ? map['runId'] as String
          : runId;
      await _writeReceipt(
        map,
        receiptOption: receiptOption,
        runId: receiptRunId,
      );
    }
    return switch ('${result['status']}') {
      'succeeded' => 0,
      'stopped' => 2,
      _ => 1,
    };
  }

  /// Asks through stdin while it is a terminal; anything else stops.
  String _askRetry() {
    if (!stdin.hasTerminal) {
      stderr.writeln('No terminal for a retry choice; stopping.');
      return 'stop';
    }
    while (true) {
      stdout.write(
        '[r]etry step / re[b]oot to fastboot and retry / [s]top [s]: ',
      );
      final line = stdin.readLineSync();
      if (line == null) return 'stop';
      switch (line.trim().toLowerCase()) {
        case '' || 's' || 'stop':
          return 'stop';
        case 'r' || 'retry':
          return 'retry';
        case 'b' || 'reboot':
          return 'reboot';
      }
    }
  }

  Future<void> _writeReceipt(
    Map<String, Object?> receipt, {
    required String? receiptOption,
    required String? runId,
  }) async {
    if (receipt.isEmpty) return;
    final path = receiptOption != null
        ? File(receiptOption).absolute.path
        : File('receipt-${runId ?? 'unknown'}.json').absolute.path;
    try {
      await writeReceipt(path, receipt);
    } catch (error) {
      stderr.writeln('ERROR: Cannot write the receipt: $error');
    }
  }
}
