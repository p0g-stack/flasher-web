/// A headless Chrome page over the DevTools protocol.
///
/// The app is a Flutter CanvasKit page, so the harness never reads pixels for
/// control: it enables the semantics tree, finds labelled accessible nodes,
/// and clicks them exactly as a user's assistive technology would.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

/// One running headless Chrome with a page on the app's origin.
final class HarnessBrowser {
  HarnessBrowser._(this._chrome, this._connection, this._page, this.profile);

  final Process _chrome;
  final ChromeConnection _connection;
  final WipConnection _page;
  final Directory profile;

  WipConnection get page => _page;

  /// Launches Chrome with a throwaway profile and opens [url].
  static Future<HarnessBrowser> launch({
    required String url,
    required String downloadDir,
    required String bootstrapScript,
    List<String> extraArgs = const [],
  }) async {
    final profile = await Directory.systemTemp.createTemp('flasher-e2e-profile-');
    final port = await _freePort();
    final chrome = await Process.start('google-chrome-stable', [
      '--headless=new',
      '--remote-debugging-port=$port',
      '--user-data-dir=${profile.path}',
      '--window-size=1400,2600',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-features=Translate,MediaRouter',
      '--disable-background-networking',
      '--disable-sync',
      '--metrics-recording-only',
      ...extraArgs,
      'about:blank',
    ]);
    chrome.stderr.drain<void>();
    chrome.stdout.drain<void>();

    final connection = ChromeConnection('127.0.0.1', port);
    WipConnection? page;
    for (var attempt = 0; attempt < 120; attempt++) {
      try {
        final tabs = await connection.getTabs();
        final tab = tabs.firstWhere((tab) => tab.type == 'page');
        page = await tab.connect();
        break;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    if (page == null) {
      chrome.kill();
      throw StateError('Chrome did not expose a page over CDP.');
    }
    await page.sendCommand('Page.enable');
    await page.sendCommand('Runtime.enable');
    await page.sendCommand('Log.enable');
    await page.sendCommand('Browser.setDownloadBehavior', {
      'behavior': 'allow',
      'downloadPath': downloadDir,
      'eventsEnabled': true,
    });
    await page.sendCommand('Page.addScriptToEvaluateOnNewDocument', {
      'source': bootstrapScript,
    });
    await page.sendCommand('Page.navigate', {'url': url});
    return HarnessBrowser._(chrome, connection, page, profile);
  }

  Future<String> evaluate(String expression) async {
    final response = await _page.sendCommand('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });
    final body =
        (response.result?['result'] as Map?)?.cast<String, dynamic>() ??
        const {};
    if (body['subtype'] == 'error') {
      throw StateError('${body['description'] ?? expression}');
    }
    final value = body['value'];
    return value == null ? '${body['description'] ?? ''}' : '$value';
  }

  Future<void> navigate(String url) =>
      _page.sendCommand('Page.navigate', {'url': url}).then((_) {});

  /// Reloads the app and re-enables its semantics tree.
  Future<void> reload(String url) async {
    await navigate(url);
    await waitForEnabled();
  }

  /// Waits until the app is up and its semantics tree can be enabled.
  Future<void> waitForEnabled({int seconds = 60}) async {
    await waitFor(
      "!!document.querySelector('flt-semantics-placeholder') || "
      "document.querySelectorAll('flt-semantics').length > 5",
      seconds: seconds,
    );
    await evaluate(
      "document.querySelector('flt-semantics-placeholder')?.click()",
    );
  }

  /// Polls [expression] until it evaluates to `true`.
  Future<void> waitFor(
    String expression, {
    int seconds = 60,
    String? describe,
  }) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(deadline)) {
      if (await evaluate(expression) == 'true') return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw TimeoutException(
      describe == null ? 'timed out: $expression' : 'timed out: $describe',
    );
  }

  /// Waits for [text] to appear in the semantics tree.
  Future<void> waitForText(String text, {int seconds = 60}) =>
      waitFor(_hasTextExpression(text), seconds: seconds, describe: text);

  /// Waits for [text] to disappear.
  Future<void> waitForNoText(String text, {int seconds = 60}) =>
      waitFor('!(${_hasTextExpression(text)})', seconds: seconds);

  Future<bool> hasText(String text) async =>
      await evaluate(_hasTextExpression(text)) == 'true';

  /// Every text line of the semantics tree, in document order.
  Future<List<String>> semanticsText() async {
    final raw = await evaluate(
      "Array.from(document.querySelectorAll('flt-semantics'))"
      ".map(e => (e.getAttribute('aria-label') || e.textContent || '').trim())"
      ".filter(t => t.length > 0).join('\\n')",
    );
    return raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  /// Clicks the first actionable semantics node whose label is exactly
  /// [label] (or contains it, when [exact] is false).
  Future<void> click(String label, {bool exact = true}) async {
    final find = _clickableExpression(label, exact: exact);
    await waitFor('!!($find)', describe: 'clickable "$label"');
    await evaluate('($find).click()');
  }

  /// Whether an actionable node with [label] exists (enabled or not).
  Future<bool> hasControl(String label, {bool exact = true}) async =>
      await evaluate('!!(${_clickableExpression(label, exact: exact)})') ==
      'true';

  /// How many actionable nodes carry [label] exactly.
  Future<int> controlCount(String label) async {
    final value = await evaluate(
      'Array.from(document.querySelectorAll(\'flt-semantics\'))'
      '.filter(e => ${_labelOf('e')} === ${jsonEncode(label)} && '
      '${_actionable('e')}).length',
    );
    return int.tryParse(value) ?? 0;
  }

  /// Posts a JSON message on the fake device's channel and returns at once.
  Future<void> postFake(Map<String, Object?> message) async {
    await evaluate(
      '(() => { const c = new BroadcastChannel(${jsonEncode('flasher-e2e')}); '
      'c.postMessage(${jsonEncode(jsonEncode(message))}); '
      'setTimeout(() => c.close(), 100); return true; })()',
    );
  }

  /// Asks the fake device for its state and waits for the reply.
  Future<Map<String, Object?>> fakeState({int seconds = 60}) async {
    final before = await _fakeMessageCount();
    await postFake({'op': 'state'});
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(deadline)) {
      final messages = await fakeMessages();
      if (messages.length > before) {
        final last = messages.last;
        final state = last['state'];
        if (last['type'] == 'state' && state is Map) {
          return Map<String, Object?>.from(state);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('the fake device did not answer a state request');
  }

  /// Configures the fake device and returns the state the worker reported.
  Future<Map<String, Object?>> configureFake(
    Map<String, Object?> command, {
    int seconds = 60,
  }) async {
    final before = await _fakeMessageCount();
    await postFake({'op': 'configure', ...command});
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(deadline)) {
      final messages = await fakeMessages();
      if (messages.length > before) {
        final last = messages.last;
        final state = last['state'];
        if (last['type'] == 'state' && state is Map) {
          return Map<String, Object?>.from(state);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('the fake device did not answer a configure request');
  }

  /// Every message the fake device posted since the page loaded.
  Future<List<Map<String, Object?>>> fakeMessages() async {
    final raw = await evaluate('JSON.stringify(window.__e2eMessages || [])');
    if (raw.isEmpty || raw == 'null') return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final message in decoded)
        if (message is Map) Map<String, Object?>.from(message),
    ];
  }

  Future<int> _fakeMessageCount() async {
    final raw = await evaluate('(window.__e2eMessages || []).length');
    return int.tryParse(raw) ?? 0;
  }

  /// Sends a wheel event into the page, which Flutter's scroll view consumes.
  Future<void> wheel({int x = 400, int y = 400, int deltaY = 600}) async {
    await _page.sendCommand('Input.dispatchMouseEvent', {
      'type': 'mouseWheel',
      'x': x,
      'y': y,
      'deltaX': 0,
      'deltaY': deltaY,
    });
  }

  /// Evaluates a written-scenario assertion in the page and returns its text.
  Future<String> runPageFunction(String source) => evaluate(source);

  /// Captures the page as a PNG at [path] and returns that path.
  ///
  /// The screens of the guided flow are captured so a run leaves visual
  /// evidence beside its assertions.
  Future<String> screenshot(String path) async {
    final response = await _page.sendCommand(
      'Page.captureScreenshot',
      {'format': 'png'},
    );
    final data = (response.result?['data'] as String?) ?? '';
    if (data.isEmpty) {
      throw StateError('the page did not produce a screenshot');
    }
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(base64Decode(data));
    return file.path;
  }

  Future<void> dispose() async {
    try {
      await _page.close();
    } on Object {
      // The browser may already be gone.
    }
    _connection.close();
    _chrome.kill();
    await _chrome.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _chrome.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        await profile.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}

String _hasTextExpression(String text) =>
    '((document.body && document.body.innerText.includes(${jsonEncode(text)}))'
    ' || Array.from(document.querySelectorAll(\'flt-semantics\')).some(e => '
    '((e.getAttribute("aria-label") || "") + " " + (e.textContent || ""))'
    '.includes(${jsonEncode(text)})))';

String _labelOf(String element) =>
    '(($element.getAttribute("aria-label") || $element.textContent || "").trim())';

String _actionable(String element) =>
    '($element.getAttribute("role") === "button" || '
    '$element.hasAttribute("flt-tappable") || '
    '$element.getAttribute("role") === "checkbox" || '
    '$element.getAttribute("role") === "radio" || '
    '$element.getAttribute("role") === "menuitem" || '
    '$element.getAttribute("role") === "tab")';

String _clickableExpression(String label, {required bool exact}) {
  final match = exact
      ? '${_labelOf('e')} === ${jsonEncode(label)}'
      : '${_labelOf('e')}.includes(${jsonEncode(label)})';
  // Smallest first: a modal barrier or a scroll container can carry the whole
  // sheet's text, while the row or button the label names is the leaf.
  return '(() => { const found = Array.from('
      'document.querySelectorAll(\'flt-semantics\')).filter(e => '
      '$match && ${_actionable('e')}); found.sort((a, b) => '
      '(a.textContent || "").length - (b.textContent || "").length); '
      'return found[0]; })()';
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
