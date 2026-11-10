/// Shared browser flow: choose the fixture inputs, then walk the guided
/// Connect → Check → Confirm → Flash → Done (or Recover) screens.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flasher_web_core/flasher_web_core.dart' show fakeFastbootSerial;

import 'browser.dart';

const _bloatReady = 'Already downloaded';

/// Loads the fixture's bloat store, picks its OTA and waits for inspection.
///
/// A reload restores the last checkpoint as an inspection-only receipt, so a
/// fresh page can open on Done; this returns to Setup first.
Future<void> selectInputs(HarnessBrowser browser) async {
  await browser.waitForEnabled();
  await browser.waitFor(
    "document.body.innerText.includes('Bloat files') || "
    "document.body.innerText.includes('Back to setup')",
    seconds: 120,
    describe: 'the setup page or a restored receipt',
  );
  if (!await browser.hasText('Bloat files')) {
    await browser.click('Back to setup');
    await browser.waitForText('Bloat files', seconds: 60);
  }
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

/// Setup → Connect: the single primary action of the setup screen.
Future<void> continueToConnect(HarnessBrowser browser) async {
  await browser.click('Continue');
  await browser.waitForText('Connect your phone', seconds: 60);
}

/// Connect → Check: the primary action lists the existing grant and selects
/// the only phone, then the read-only preparation runs.
Future<void> connectPhone(HarnessBrowser browser) async {
  await browser.waitForText('Check phone', seconds: 120);
  await browser.click('Check phone');
  await browser.waitForText('Check and prepare', seconds: 120);
  await browser.waitForText('Answers', seconds: 120);
}

/// Answers both plan prompts. The resolved plan enables Review plan, which
/// [reviewPlan] waits for; answered prompts stay listed on the Check screen.
Future<void> answerPrompts(HarnessBrowser browser) async {
  await browser.waitForText('flash-signal', seconds: 120);
  await browser.click('flash-signal');
  await browser.waitForText('reboot', seconds: 120);
  await browser.click('reboot');
}

/// Check → Confirm: the one primary action of the Check screen.
Future<void> reviewPlan(HarnessBrowser browser) async {
  await browser.waitForText('Review plan', seconds: 120);
  await browser.click('Review plan');
  await browser.waitForText('This writes to the phone', seconds: 120);
}

/// Confirm: acknowledges the exact serial and starts the write.
Future<void> startFlash(HarnessBrowser browser) async {
  await browser.click('I confirm serial', exact: false);
  await browser.click('Flash $fakeFastbootSerial');
  // The fake device can finish before a frame shows the Flash screen.
  await browser.waitFor(
    "['Flashing', 'Save receipt', 'Recover'].some(t => "
    "document.body.innerText.includes(t) || "
    "Array.from(document.querySelectorAll('flt-semantics')).some(e => "
    "(e.getAttribute('aria-label') || e.textContent || '').includes(t)))",
    seconds: 120,
    describe: 'the run to start',
  );
}

/// The whole successful path up to the first write.
Future<void> preparePlan(HarnessBrowser browser) async {
  await continueToConnect(browser);
  await connectPhone(browser);
  await answerPrompts(browser);
  await reviewPlan(browser);
}

/// Waits until the Done screen shows a receipt and returns its status word.
Future<String> waitForResult(HarnessBrowser browser) async {
  await browser.waitForText('Save receipt', seconds: 240);
  if (await browser.hasText('The phone accepted every write')) {
    return 'succeeded';
  }
  if (await browser.hasText('Finished with an uncertainty')) {
    return 'uncertain';
  }
  return 'failed';
}

/// Waits for the Recover screen and checks its explicit controls.
///
/// The failed step is a mutating one, so the service offers a whole-step
/// rewrite and Stop; there is no generic retry and no second write button.
Future<void> waitForRecovery(HarnessBrowser browser) async {
  await browser.waitForText('Recover the run', seconds: 240);
  await browser.waitForText('Rewrite this step from byte zero', seconds: 60);
  final rewrite = await browser.controlCount(
    'Rewrite this step from byte zero',
  );
  final stop = await browser.controlCount('Stop further commands');
  final retry = await browser.controlCount('Retry step');
  if (rewrite != 1 || stop != 1 || retry != 0) {
    throw StateError(
      'the recovery screen must show one rewrite, one stop and no generic '
      'retry, saw rewrite=$rewrite, stop=$stop, retry=$retry',
    );
  }
  for (final forbidden in ['Retry step', 'Reboot to fastboot and retry']) {
    if (await browser.hasControl(forbidden)) {
      throw StateError('the recovery screen still offers "$forbidden"');
    }
  }
}

/// Clicks the service's primary recovery action and confirms it explicitly.
Future<void> performRewrite(HarnessBrowser browser) async {
  await browser.click('Rewrite this step from byte zero');
  await browser.waitForText('Rewrite from byte zero', seconds: 60);
  await browser.click('I understand step', exact: false);
  await browser.click('Rewrite from byte zero', exact: true);
  // The fake device finishes the rewrite before a Flash frame is guaranteed.
  await browser.waitForText('Save receipt', seconds: 240);
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
  await browser.click('Save receipt');
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
