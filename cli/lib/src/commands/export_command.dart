import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import '../service_args.dart';

/// Exports the same virtual package as one ZIP to a local file.
class ExportCommand extends Command<int> {
  ExportCommand() {
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
      ..addFlag(
        'vulnerable-abl',
        negatable: true,
        help:
            'X9U only: pack ABL 16.0.6 as abl.img. Use --no-vulnerable-abl to '
            'keep the OTA ABL; X9U requires one of the two.',
      )
      ..addOption(
        'out',
        mandatory: true,
        help: 'The ZIP file to write.',
      );
  }

  @override
  String get name => 'export';

  @override
  String get description =>
      'Stream the virtual flasher package as one ZIP file.';

  @override
  String get invocation =>
      '${runner!.executableName} export --device D --kind K --region R '
      '(--ota ZIP | --catalog ID) --bloat-dir DIR --out PATH.zip';

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
    final apiBase = results.option('api-base')!;
    try {
      apiBaseUri(apiBase);
    } on FormatException catch (error) {
      throw UsageException(error.message, argParser.usage);
    }
    final device = results.option('device')!;
    final kind = results.option('kind')!;
    final region = results.option('region')!;
    final out = results.option('out')!;
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
      final request = exportVirtualRequest(
        selection: selectionMap(device: device, kind: kind, region: region),
        virtual: virtualRequest(
          ota: ota,
          base: basePath == null ? null : otaInput(basePath),
          bloatDir: results.option('bloat-dir')!,
          vulnerableAbl: vulnerableAbl,
        ),
        apiBase: apiBase,
        upstream: results.option('upstream')!,
        destination: out,
      );
      final service = FlasherService();
      Map<String, Object?>? result;
      await for (final event in service.exportVirtual(request)) {
        if (event['type'] == 'result') {
          result = event;
        } else {
          printEvent(event);
        }
      }
      if (result == null) {
        stderr.writeln('ERROR: The export service returned no result.');
        return 1;
      }
      printExportResult(result);
      print('File: ${File(out).absolute.path}');
      final receipt = result['receipt'];
      if (receipt is Map) {
        await writeReceipt(
          '${File(out).absolute.path}.receipt.json',
          Map<String, Object?>.from(receipt),
        );
      }
      return 0;
    } on UsageException {
      rethrow;
    } catch (error) {
      stderr.writeln('ERROR: $error');
      return 1;
    }
  }
}
