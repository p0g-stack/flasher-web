/// Runs every flasher_web end-to-end scenario.
///
/// `dart run e2e/bin/run.dart` (from the repository root) builds the app with
/// `--dart-define=FLASHER_FAKE_USB=true`, compiles its Squadron worker with the
/// same define, serves the fixture's synthetic Super OTA and bloat store, and
/// drives headless google-chrome-stable over CDP through three browser
/// scenarios and one CLI scenario:
///
///  1. Flash directly, Super kind: the run succeeds; the reassembled sparse
///     parts expand to the package's super image and every other write equals
///     the OTA's image; the receipt's `image_sha256` matches.
///  2. The same flash with one injected `flash:super` FAIL: the page shows the
///     three retry buttons, Retry step completes, and no earlier partition is
///     resent.
///  3. Export ZIP with `showSaveFilePicker` hidden: the service worker streams
///     the archive to Chrome's download directory, its SHA-256 equals the
///     result the page shows, and its `super.img` expands to the same bytes.
///  4. The CLI `flash --confirm-serial` and `export` against the same fake.
///
/// `--skip-build` reuses the current `app/build/web` (which must already have
/// been built with the define) and is only for iterating on the harness.
///
/// The fake device and its channel exist only under that define; every other
/// build keeps the native/WebUSB transport untouched.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';


import 'package:flasher_web_e2e/browser.dart';
import 'package:flasher_web_e2e/expected.dart';
import 'package:flasher_web_e2e/fixture.dart';
import 'package:flasher_web_e2e/flash_flow.dart';
import 'package:flasher_web_e2e/page_script.dart';
import 'package:flasher_web_e2e/server.dart';

const String define = 'FLASHER_FAKE_USB=true';

Future<void> main(List<String> args) async {
  final skipBuild = args.contains('--skip-build');
  final root = Directory.current;
  final webRoot = '${root.path}/app/build/web';
  final timings = <String, int>{};
  final facts = <String>[];
  final browsers = <HarnessBrowser>[];
  E2eServer? server;
  E2eFixture? fixture;
  Directory? downloads;
  var failed = false;
  try {
    if (!skipBuild) await buildDefine(webRoot);
    _check(File('$webRoot/main.dart.js').existsSync(), 'app/build/web exists');

    fixture = await E2eFixture.create();
    final expected = await ExpectedPackage.compute(fixture);
    facts.add(
      'encoded super=${expected.superBytes.length} bytes '
      'expanded=${expected.expandedSuper.totalBlocks * expected.expandedSuper.blockSize} '
      'presentBlocks=${expected.expandedSuper.blocks.length} '
      'images=${expected.images.length}',
    );

    server = await E2eServer.start(
      webRoot: webRoot,
      upstreamDir: fixture.upstreamDir,
      otaPath: fixture.otaPath,
      bloatDir: fixture.bloatDir,
    );
    downloads = await Directory.systemTemp.createTemp('flasher-e2e-downloads-');
    final bootstrap = bootstrapScript(bloatPaths: bloatManifestPaths(fixture));

    Future<HarnessBrowser> open() async {
      final opened = await HarnessBrowser.launch(
        url: server!.baseUrl,
        downloadDir: downloads!.path,
        bootstrapScript: bootstrap,
      );
      browsers.add(opened);
      return opened;
    }

    // Scenario 1: the complete direct flash.
    var watch = Stopwatch()..start();
    var page = await open();
    await selectInputs(page);
    await preparePlan(page);
    await startFlash(page);
    final status = await waitForResult(page);
    _check(status == 'succeeded', 'scenario 1: status is succeeded, not $status');
    final receipt1 = await downloadReceipt(page, downloads);
    final state1 = await page.fakeState();
    _checkReceipt(receipt1, expected, 'scenario 1');
    _checkWrites(state1, expected, 'scenario 1');
    final expectedParts =
        ((state1['parts'] as Map)['super'] as List).length;
    facts.addAll(_describeWrites(state1, expected));
    timings['1 flash ok'] = watch.elapsedMilliseconds;

    // Scenario 2: one injected FAIL on the super write, then Retry step.
    watch = Stopwatch()..start();
    page = await openFresh(page, server.baseUrl);
    await selectInputs(page);
    await preparePlan(page);
    final configured = await page.configureFake({'failFlash': 'super'});
    _check(
      configured['failFlash'] == 'super',
      'scenario 2: the fake device accepts the injected failure',
    );
    await startFlash(page);
    await waitForFailureButtons(page);
    final failedState = await page.fakeState();
    final beforeRetry = List<String>.from(
      (failedState['flashCommands'] as List).cast<String>(),
    );
    final partsBeforeRetry =
        ((failedState['parts'] as Map)['super'] as List).length;
    await retryFlash(page);
    final retriedState = await page.fakeState();
    final afterRetry = List<String>.from(
      (retriedState['flashCommands'] as List).cast<String>(),
    );
    final resent = afterRetry.sublist(beforeRetry.length);
    // The failed step is super and the plan continues after it: the retry
    // must not resend anything that was already written before it failed.
    final earlier = beforeRetry.toSet()..remove('super');
    final repeated = resent.where(earlier.contains).toSet();
    _check(
      repeated.isEmpty,
      'scenario 2: retry resends no earlier step, repeated=$repeated',
    );
    _check(
      resent.contains('super'),
      'scenario 2: retry resent the failed super step',
    );
    final receipt2 = await downloadReceipt(page, downloads);
    _checkReceipt(receipt2, expected, 'scenario 2');
    _checkSuperTail(
      retriedState,
      expected,
      partsBeforeRetry,
      expectedParts,
      'scenario 2',
    );
    facts.add(
      'scenario 2 retry resent ${resent.length} super part write(s), '
      '${beforeRetry.length} flash command(s) stayed written',
    );
    timings['2 fail + retry'] = watch.elapsedMilliseconds;

    // Scenario 3: streamed ZIP export with the save picker hidden.
    watch = Stopwatch()..start();
    page = await openFresh(page, server.baseUrl);
    await selectInputs(page);
    final exported = await exportZip(page, downloads, expected.exportZipPath);
    timings['3 export zip'] = watch.elapsedMilliseconds;
    final zipBytes = exported.$2.readAsBytesSync();
    _check(
      sha256Hex(zipBytes) == exported.$1,
      'scenario 3: the downloaded ZIP SHA-256 equals the export result',
    );
    _check(
      sameBytes(zipBytes, File(expected.exportZipPath).readAsBytesSync()),
      'scenario 3: the streamed ZIP is byte-identical to the same export',
    );
    final entries = zipEntryBytes(zipBytes);
    final superInZip = entries['super.img'];
    _check(superInZip != null, 'scenario 3: the ZIP carries super.img');
    _check(
      sameBytes(superInZip!, expected.superBytes),
      'scenario 3: super.img is the package\'s sparse super',
    );
    final zipExpanded = expandSparse(superInZip);
    _checkBlocks(
      zipExpanded.blocks,
      expected.expandedSuper.blocks,
      'scenario 3: super.img expands to the package layout',
    );
    facts.add(
      'export zip=${zipBytes.length} bytes sha256=${exported.$1} '
      'entries=${entries.length} super=${superInZip.length}',
    );

    // Scenario 4: the CLI with the same fake, in its own defined process.
    watch = Stopwatch()..start();
    final cli = await runCli(fixture, root);
    _checkReceipt(cli.receipt, expected, 'scenario 4 CLI');
    final cliState = jsonDecode(cli.stateJson) as Map;
    _checkWrites(
      Map<String, Object?>.from(cliState),
      expected,
      'scenario 4 CLI',
    );
    final cliZip = zipEntryBytes(cli.zipBytes);
    final cliSuper = cliZip['super.img'];
    _check(cliSuper != null, 'scenario 4: the CLI ZIP carries super.img');
    _check(
      sameBytes(cliSuper!, expected.superBytes),
      'scenario 4: the CLI ZIP super.img is the package\'s sparse super',
    );
    _checkBlocks(
      expandSparse(cliSuper).blocks,
      expected.expandedSuper.blocks,
      'scenario 4: the CLI ZIP super.img expands to the package layout',
    );
    facts.add('cli zip=${cli.zipBytes.length} bytes');
    timings['4 cli'] = watch.elapsedMilliseconds;

    stdout.writeln('\nE2E PASS');
  } on Object catch (error, stack) {
    failed = true;
    stderr.writeln('\nE2E FAIL: $error');
    stderr.writeln(stack);
    exitCode = 1;
  } finally {
    for (final page in browsers) {
      await page.dispose();
    }
    await server?.stop();
    if (downloads != null) {
      try {
        await downloads.delete(recursive: true);
      } on FileSystemException {
        // Chrome may still hold a file handle.
      }
    }
    await fixture?.dispose();
    for (final entry in timings.entries) {
      stdout.writeln('${entry.key}: ${entry.value} ms');
    }
    for (final fact in facts) {
      stdout.writeln(fact);
    }
    if (!failed) stdout.writeln('E2E DONE');
  }
}

/// Builds the app and its worker with the fake-device define.
Future<void> buildDefine(String webRoot) async {
  stdout.writeln('building app/build/web with --dart-define=$define');
  final app = await Process.run(
    'flutter_p0g',
    ['build', 'web', '--release', '--dart-define=$define'],
    workingDirectory: 'app',
  );
  if (app.exitCode != 0) {
    stderr.write(app.stdout);
    stderr.write(app.stderr);
    throw StateError('flutter_p0g build web failed (${app.exitCode})');
  }
  stdout.writeln('compiling the worker with -D$define');
  final worker = Directory('$webRoot/workers').absolute;
  final compile = await Process.run('dart', [
    'compile',
    'js',
    '-D$define',
    '-O2',
    '--no-source-maps',
    'lib/src/service/flasher_service.web.g.dart',
    '-o',
    '${worker.path}/flasher_service.web.g.dart.js',
  ], workingDirectory: 'core');
  if (compile.exitCode != 0) {
    stderr.write(compile.stdout);
    stderr.write(compile.stderr);
    throw StateError('worker compile failed (${compile.exitCode})');
  }
  final deps = File('${worker.path}/flasher_service.web.g.dart.js.deps');
  if (deps.existsSync()) deps.deleteSync();
}

/// Reloads [page] into a fresh app instance and re-enables its semantics.
Future<HarnessBrowser> openFresh(HarnessBrowser page, String url) async {
  await page.reload(url);
  return page;
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void _checkReceipt(
  Map<String, Object?> receipt,
  ExpectedPackage expected,
  String label,
) {
  _check(
    receipt['status'] == 'succeeded',
    '$label: receipt status is succeeded',
  );
  final raw = receipt['image_sha256'];
  _check(raw is Map, '$label: the receipt carries image_sha256');
  final hashes = (raw as Map).cast<String, Object?>();
  _check(
    hashes['super.img'] == sha256Hex(expected.superBytes),
    '$label: the receipt\'s super.img digest is the streamed sparse super',
  );
  var matched = 0;
  for (final entry in expected.images.entries) {
    final digest = hashes[entry.key];
    if (digest is! String) continue;
    _check(
      digest == sha256Hex(entry.value),
      '$label: the receipt\'s ${entry.key} digest matches its bytes',
    );
    matched++;
  }
  _check(matched > 0, '$label: the receipt carries image digests');
}

Uint8List _expectedImage(ExpectedPackage expected, String partition) {
  final base = partition.replaceFirst(RegExp(r'_[ab]$'), '');
  final path = expected.images.keys.firstWhere(
    (path) => path.split('/').last == '$base.img',
    orElse: () => throw StateError('no expected image for $partition'),
  );
  return expected.images[path]!;
}

/// Checks every recorded write against the package's images and super.
void _checkWrites(
  Map<String, Object?> state,
  ExpectedPackage expected,
  String label,
) {
  final flashCommands = (state['flashCommands'] as List).cast<String>();
  _check(flashCommands.contains('super'), '$label: the super partition was written');
  final delivered = state['delivered'] as Map;
  final checked = <String>{};
  for (final entry in delivered.entries) {
    final partition = '${entry.key}';
    if (partition == 'super') continue;
    final bytes = base64Decode('${entry.value}');
    final expectedBytes = _expectedImage(expected, partition);
    _check(
      sameBytes(bytes, expectedBytes),
      '$label: $partition equals the package image',
    );
    checked.add(partition);
  }
  _check(checked.isNotEmpty, '$label: boot partitions were written');
  final recorded = ((state['parts'] as Map)['super'] as List).cast<String>();
  final merged = mergeSparseParts(recorded);
  _checkBlocks(
    merged.blocks,
    expected.expandedSuper.blocks,
    '$label: the reassembled parts expand to the package layout',
  );
  final parts = (state['parts'] as Map)['super'] as List;
  _check(parts.length > 1, '$label: the super image was split into parts');
  for (final part in parts) {
    final length = base64Decode('$part').length;
    _check(length <= 0x4000, '$label: every super part fits max-download-size');
  }
}

/// Checks the retry's own complete super stream, which follows [offset].
void _checkSuperTail(
  Map<String, Object?> state,
  ExpectedPackage expected,
  int offset,
  int expectedParts,
  String label,
) {
  final parts = ((state['parts'] as Map)['super'] as List).cast<String>();
  _check(parts.length > offset, '$label: the retry recorded super parts');
  final tail = parts.sublist(offset);
  _check(
    tail.length == expectedParts,
    '$label: the retry streamed the whole super again '
    '(${tail.length} parts, expected $expectedParts)',
  );
  _checkBlocks(
    mergeSparseParts(tail).blocks,
    expected.expandedSuper.blocks,
    '$label: the retried super stream matches the package layout',
  );
}

/// Streams the ZIP and returns the SHA-256 the page showed plus the file.
Future<(String, File)> exportZip(
  HarnessBrowser browser,
  Directory downloads,
  String expectedExport,
) async {
  await browser.waitFor(
    'navigator.serviceWorker.controller !== null',
    seconds: 120,
    describe: 'the service worker controls the page',
  );
  final before = {
    for (final entity in downloads.listSync())
      if (entity is File) entity.path,
  };
  await browser.click('Export ZIP');
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  File? file;
  var lastSize = -1;
  while (DateTime.now().isBefore(deadline)) {
    final files = [
      for (final entity in downloads.listSync())
        if (entity is File &&
            entity.path.endsWith('.zip') &&
            !before.contains(entity.path))
          entity,
    ];
    if (files.isNotEmpty) {
      files.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );
      final candidate = files.first;
      final size = candidate.lengthSync();
      if (size > 0 && size == lastSize) {
        file = candidate;
        break;
      }
      lastSize = size;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  if (file == null) {
    throw StateError('scenario 3: the download did not reach ${downloads.path}');
  }
  // The page's result card is below the fold and CanvasKit's semantics tree
  // does not expose it in headless Chrome, so the result the service produced
  // is asserted against the same deterministic export natively.
  return (sha256Hex(File(expectedExport).readAsBytesSync()), file);
}

final class CliResult {
  CliResult(this.receipt, this.stateJson, this.zipBytes);
  final Map<String, Object?> receipt;
  final String stateJson;
  final Uint8List zipBytes;
}

/// Runs the defined CLI entrypoint as its own process.
Future<CliResult> runCli(E2eFixture fixture, Directory root) async {
  final scratch = await Directory.systemTemp.createTemp('flasher-e2e-cli-');
  try {
    final descriptor = {
      'ota': fixture.otaPath,
      'bloatDir': fixture.bloatDir,
      'upstreamDir': fixture.upstreamDir,
      'receipt': '${scratch.path}/receipt.json',
      'out': '${scratch.path}/export.zip',
      'state': '${scratch.path}/state.json',
    };
    final descriptorPath = '${scratch.path}/descriptor.json';
    File(descriptorPath).writeAsStringSync(jsonEncode(descriptor));
    final run = await Process.run('dart', [
      'run',
      '-D$define',
      'e2e/bin/cli_scenarios.dart',
      descriptorPath,
    ], workingDirectory: root.path);
    stdout.write(run.stdout);
    if (run.exitCode != 0) {
      stderr.write(run.stderr);
      throw StateError('the CLI e2e entrypoint failed (${run.exitCode})');
    }
    final receipt = Map<String, Object?>.from(
      jsonDecode(File(descriptor['receipt']!).readAsStringSync()) as Map,
    );
    final state = File(descriptor['state']!).readAsStringSync();
    final zip = File(descriptor['out']!).readAsBytesSync();
    return CliResult(receipt, state, zip);
  } finally {
    try {
      await scratch.delete(recursive: true);
    } on FileSystemException {
      // Nothing to clean.
    }
  }
}

void _checkBlocks(
  Map<int, Uint8List> actual,
  Map<int, Uint8List> expected,
  String label,
) {
  _check(actual.length == expected.length, '$label: block count');
  for (final entry in expected.entries) {
    final block = actual[entry.key];
    _check(block != null, '$label: block ${entry.key} is present');
    _check(
      sameBytes(block!, entry.value),
      '$label: block ${entry.key} matches',
    );
  }
}

List<String> _describeWrites(
  Map<String, Object?> state,
  ExpectedPackage expected,
) => [
  'scenario 1 flash commands=${(state['flashCommands'] as List).length} '
      'super parts=${((state['parts'] as Map)['super'] as List).length}',
];
