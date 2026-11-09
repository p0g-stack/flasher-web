/// Shared browser flow: choose the fixture inputs, prepare, flash and retry.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'browser.dart';

const _bloatReady = 'Already downloaded';

/// Loads the fixture's bloat store, picks its OTA and waits for inspection.
Future<void> selectInputs(HarnessBrowser browser) async {
  await browser.waitForEnabled();
  await browser.waitForText('Bloat files');
  await browser.waitFor(
    '!!(window.__e2e && (window.__e2e.ready || window.__e2e.error))',
    seconds: 120,
    describe: 'the page bootstrap',
  );
  final error = await browser.evaluate('String(window.__e2e.error || "")');
  if (error.isNotEmpty) throw StateError('page bootstrap failed: $error');
  if (!await browser.hasText(_bloatReady)) {
    await browser.click('Recheck bloat files');
  }
  await browser.waitForText(_bloatReady, seconds: 120);
  await browser.click('Choose ZIP');
  await browser.waitForText('ota.zip', seconds: 60);
  // The inspection card appears once the service has read the payload.
  await browser.waitForText('Partitions', seconds: 120);
}

/// Opens the flash page, chooses the fake phone and answers every prompt.
Future<void> preparePlan(HarnessBrowser browser) async {
  await browser.click('Flash directly');
  await browser.waitForText('Fastboot device');
  await browser.click('Choose device');
  await browser.waitForText('Choose USB device', seconds: 120);
  await browser.click('Choose USB device');
  await browser.waitForText('flash-signal', seconds: 120);
  await browser.click('flash-signal');
  await browser.click('reboot');
  await browser.waitForText('I confirm serial', seconds: 120);
}

/// Confirms the serial checkbox and starts the write.
///
/// Answering a prompt schedules a debounced re-prepare that clears the
/// confirmation. If it lands between the checkbox tap and the final button,
/// the button is disabled for that tap; retry until the execution section
/// replaces the plan.
Future<void> startFlash(HarnessBrowser browser) async {
  await browser.click('I confirm serial', exact: false);
  for (var attempt = 0; attempt < 8; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!await browser.hasText('Flash device')) continue;
    await browser.click('Flash device');
    if (await _flashStarted(browser, const Duration(seconds: 8))) return;
    if (attempt == 7) {
      throw StateError('the Flash device button never started the run');
    }
    if (await browser.hasText('Flash device')) {
      await browser.click('I confirm serial', exact: false);
    }
  }
}

Future<bool> _flashStarted(HarnessBrowser browser, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await browser.hasText('Cancel') ||
        await browser.hasText('Download receipt')) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  return false;
}

/// Waits until a result receipt is on the page and returns its status text.
Future<String> waitForResult(HarnessBrowser browser) async {
  await browser.waitForText('Download receipt', seconds: 240);
  if (await browser.hasText('Failed step')) {
    return 'failed';
  }
  return 'succeeded';
}

/// Waits until the failure card offers exactly the three retry controls.
Future<void> waitForFailureButtons(HarnessBrowser browser) async {
  await browser.waitForText('Retry step', seconds: 240);
  final retry = await browser.controlCount('Retry step');
  final reboot = await browser.controlCount('Reboot to fastboot and retry');
  final stop = await browser.controlCount('Stop');
  if (retry != 1 || reboot != 1 || stop != 1) {
    throw StateError(
      'the failure card must show three buttons, saw '
      'Retry step=$retry, reboot=$reboot, stop=$stop',
    );
  }
}

/// Clicks the real Retry step button and waits for the run to finish.
Future<void> retryFlash(HarnessBrowser browser) async {
  await browser.click('Retry step');
  await browser.waitForNoText('Retry step', seconds: 240);
  await browser.waitForText('Download receipt', seconds: 240);
}

/// Downloads the receipt through its page button and parses it.
Future<Map<String, Object?>> downloadReceipt(
  HarnessBrowser browser,
  Directory downloads,
) async {
  final before = {
    for (final entity in downloads.listSync())
      if (entity is File) entity.path,
  };
  await browser.click('Download receipt');
  final deadline = DateTime.now().add(const Duration(seconds: 120));
  File? file;
  var lastSize = -1;
  while (DateTime.now().isBefore(deadline)) {
    final files = [
      for (final entity in downloads.listSync())
        if (entity is File &&
            entity.path.endsWith('.json') &&
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
    throw StateError('the receipt download did not reach ${downloads.path}');
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map) throw StateError('the receipt is not a JSON object');
  return Map<String, Object?>.from(decoded);
}
