import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:flasher_web_core/flasher_web_core.dart';

import '../service_args.dart';

/// Runs a build through the same [FlasherService] the app calls.
class BuildCommand extends Command<int> {
  BuildCommand() {
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
        'catalog-id',
        help: 'Catalog release id to read through ranges.',
      )
      ..addOption(
        'base',
        help: 'Ace 6 conversion BASE full OTA ZIP path or HTTP(S) URL.',
      )
      ..addOption(
        'base-catalog-id',
        help: 'Ace 6 conversion BASE catalog release id.',
      )
      ..addOption(
        'bloat-dir',
        mandatory: true,
        help: 'Directory that holds the selected bloat images.',
      )
      ..addOption(
        'output',
        mandatory: true,
        help: 'Directory that receives the job folder.',
      )
      ..addFlag(
        'no-zip',
        negatable: false,
        help: 'Keep the flasher folder instead of creating a ZIP.',
      )
      ..addFlag(
        'vulnerable-abl',
        negatable: false,
        help: 'X9U only: pack ABL 16.0.6 as abl.img.',
      )
      ..addFlag(
        'stock-abl',
        negatable: false,
        help: 'X9U only: keep the OTA ABL.',
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
      );
  }

  @override
  String get name => 'build';

  @override
  String get description => 'Build a flasher package from a full OTA.';

  @override
  String get invocation =>
      '${runner!.executableName} build --device D --kind K --region R '
      '(--ota ZIP | --catalog-id ID) --bloat-dir DIR --output DIR';

  @override
  Future<int> run() async {
    final results = argResults!;
    final otaPath = results.option('ota');
    final catalogId = results.option('catalog-id');
    if ((otaPath == null) == (catalogId == null)) {
      throw UsageException(
        'Choose exactly one of --ota or --catalog-id.',
        argParser.usage,
      );
    }
    final vulnerableAbl = _ablChoice(results);
    final basePath = results.option('base');
    final baseCatalogId = results.option('base-catalog-id');
    if (basePath != null && baseCatalogId != null) {
      throw UsageException(
        'Choose at most one of --base or --base-catalog-id.',
        argParser.usage,
      );
    }
    final apiBase = results.option('api-base')!;
    try {
      apiBaseUri(apiBase);
    } on FormatException catch (error) {
      throw UsageException(error.message, argParser.usage);
    }

    try {
      final ota = otaPath != null
          ? otaInput(otaPath)
          : await resolveCatalogEntry(
              apiBase: apiBase,
              device: results.option('device')!,
              kind: results.option('kind')!,
              region: results.option('region')!,
              id: catalogId!,
              role: 'ota',
            );
      Map<String, Object?>? base;
      if (basePath != null) {
        base = otaInput(basePath);
      } else if (baseCatalogId != null) {
        base = await resolveCatalogEntry(
          apiBase: apiBase,
          device: results.option('device')!,
          kind: results.option('kind')!,
          region: results.option('region')!,
          id: baseCatalogId,
          role: 'base',
        );
      }
      final request = buildRequest(
        selection: selectionMap(
          device: results.option('device')!,
          kind: results.option('kind')!,
          region: results.option('region')!,
        ),
        ota: ota,
        base: base,
        vulnerableAbl: vulnerableAbl,
        zip: !results.flag('no-zip'),
        bloatDir: results.option('bloat-dir')!,
        outputDir: results.option('output')!,
        apiBase: apiBase,
        upstream: results.option('upstream')!,
      );
      final service = FlasherService();
      Map<String, Object?>? result;
      await for (final event in service.build(request)) {
        if (event['type'] == 'result') {
          result = event;
        } else {
          printEvent(event);
        }
      }
      if (result == null) {
        stderr.writeln('ERROR: The build service returned no result.');
        return 1;
      }
      printBuildResult(result, output: results.option('output')!);
      return 0;
    } on UsageException {
      rethrow;
    } catch (error) {
      stderr.writeln('ERROR: $error');
      return 1;
    }
  }

  bool? _ablChoice(ArgResults results) {
    final vulnerable = results.wasParsed('vulnerable-abl');
    final stock = results.wasParsed('stock-abl');
    if (vulnerable && stock) {
      throw UsageException(
        'Choose at most one of --vulnerable-abl or --stock-abl.',
        argParser.usage,
      );
    }
    if (vulnerable) return true;
    if (stock) return false;
    return null;
  }
}
