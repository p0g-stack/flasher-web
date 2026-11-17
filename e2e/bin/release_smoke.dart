// Read-only release qualification: fixture OTA selection and cancellation.
// Never enters Connect or opens a USB chooser. Uses the e2e fixture server,
// a fresh browser profile, and the real compiled Rust/worker artifacts.
import 'dart:io';

import 'package:flasher_web_e2e/browser.dart';
import 'package:flasher_web_e2e/fixture.dart';
import 'package:flasher_web_e2e/flash_flow.dart';
import 'package:flasher_web_e2e/page_script.dart';
import 'package:flasher_web_e2e/server.dart';

Future<void> main() async {
  final webRoot = Directory('app/build/web').absolute;
  for (final path in [
    'main.dart.js',
    'workers/flasher_service.web.g.dart.js',
  ]) {
    final source = await File('${webRoot.path}/$path').readAsString();
    if (source.contains('FAKE-FASTBOOT-E2E-MARKER-8f3a2c') ||
        source.contains('FAKE-E2E-0001')) {
      throw StateError('Fake fastboot code in release artifact $path');
    }
  }
  final fixture = await E2eFixture.create();
  E2eServer? server;
  HarnessBrowser? browser;
  final evidence = await Directory.systemTemp.createTemp('flasher-release-');
  try {
    server = await E2eServer.start(
      webRoot: webRoot.path,
      upstreamDir: fixture.upstreamDir,
      otaPath: fixture.otaPath,
      bloatDir: fixture.bloatDir,
    );
    browser = await HarnessBrowser.launch(
      url: server.baseUrl,
      downloadDir: evidence.path,
      bootstrapScript:
          '${bootstrapScript(bloatPaths: bloatManifestPaths(fixture))}\n'
          '''
window.__usbCalls = 0;
if (navigator.usb) {
  navigator.usb.requestDevice = async () => {
    window.__usbCalls++;
    throw new Error('Physical USB selection is forbidden in qualification');
  };
}
window.__fixturePicker = window.showOpenFilePicker;
window.__cancelledPicks = 0;
''',
    );
    // The inspection card's Partitions result requires OtaArchive's real
    // Rust ZIP and payload parsers. The engine's SelectableText is painted
    // but not exposed as text in Flutter's semantics DOM; it is not proof.
    await selectInputs(browser);
    await browser.screenshot('${evidence.path}/selected.png');
    await browser.click('Remove file');
    await browser.waitForNoText('Partitions');
    await browser.evaluate('''
window.showOpenFilePicker = async () => {
  window.__cancelledPicks++;
  throw new DOMException('Qualification cancellation', 'AbortError');
};
true
''');
    await browser.click('Choose ZIP');
    await browser.waitFor('window.__cancelledPicks === 1');
    await browser.waitForText('Drop a full OTA .zip here or choose one');
    if (await browser.hasText('Partitions')) {
      throw StateError('Cancelled picker restored an OTA inspection');
    }
    await browser.screenshot('${evidence.path}/cancelled.png');
    await browser.evaluate(
      'window.showOpenFilePicker = window.__fixturePicker; true',
    );
    await selectInputs(browser);
    if (await browser.evaluate('window.__usbCalls') != '0') {
      throw StateError('Release smoke attempted a USB chooser');
    }
    if (await browser.evaluate('crossOriginIsolated') != 'false') {
      throw StateError('Release smoke unexpectedly requires COOP/COEP');
    }
    await File('${evidence.path}/semantics.txt')
        .writeAsString((await browser.semanticsText()).join('\n'));
    stdout.writeln(
      'PASS release: fake code absent; Rust OTA parsing; picker selection, '
      'cancellation and reselection; no USB selection; no COOP/COEP. '
      'Evidence: ${evidence.path}',
    );
  } finally {
    await browser?.dispose();
    await server?.stop();
    await fixture.dispose();
  }
}
