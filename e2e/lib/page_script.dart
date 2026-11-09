/// The page bootstrap: OPFS fixture files, pickers and the fake device's
/// message log.
library;

import 'dart:convert';

/// The script installed before the app's first line runs.
///
/// It writes the fixture's bloat store into the origin's OPFS, stores the OTA
/// ZIP as an OPFS file, makes the OTA picker return that file's real handle,
/// hides the save picker so exports use the service worker's streamed
/// download, and mirrors the fake device's channel into an array the harness
/// reads over CDP.
String bootstrapScript({
  required List<String> bloatPaths,
}) =>
    '''
(() => {
  // The app's streamed export opens a hidden same-origin iframe for
  // download/<id>. Running the fixture bootstrap there would rewrite the OTA
  // and bloat files while the export worker reads them.
  if (window.top !== window) return;
  const e2e = window.__e2e = {
    messages: [],
    ready: false,
    error: null,
    otaHandle: null,
  };
  window.__e2eMessages = e2e.messages;
  const channel = new BroadcastChannel('flasher-e2e');
  channel.onmessage = (event) => {
    try { e2e.messages.push(JSON.parse(event.data)); } catch (_) {}
  };

  async function ensureDir(root, parts) {
    let dir = root;
    for (const part of parts) {
      dir = await dir.getDirectoryHandle(part, {create: true});
    }
    return dir;
  }

  async function writePath(root, path, blob) {
    const parts = path.split('/');
    const dir = await ensureDir(root, parts.slice(0, -1));
    const handle = await dir.getFileHandle(parts[parts.length - 1], {create: true});
    const writable = await handle.createWritable();
    await writable.write(blob);
    await writable.close();
    return handle;
  }

  async function fetchBlob(url) {
    const response = await fetch(url, {cache: 'no-store'});
    if (!response.ok) throw new Error(url + ': HTTP ' + response.status);
    return await response.blob();
  }

  e2e.readyPromise = (async () => {
    const root = await navigator.storage.getDirectory();
    for (const path of ${jsonEncode(bloatPaths)}) {
      await writePath(root, path, await fetchBlob('/e2e/bloat/' + path));
    }
    const ota = await writePath(root, 'e2e/ota.zip', await fetchBlob('/e2e/ota.zip'));
    e2e.otaHandle = ota;
    e2e.ready = true;
  })().catch((error) => {
    e2e.error = String(error && error.stack || error);
  });

  // Headless Chrome exposes WebUSB, but a fresh profile has no grant; the
  // define-gated page chooser answers with the fake serial anyway. The object
  // is only there so the page's capability check passes.
  if (!navigator.usb) {
    Object.defineProperty(navigator, 'usb', {
      value: {
        requestDevice: async () => null,
        getDevices: async () => [],
      },
      configurable: true,
    });
  }

  window.showOpenFilePicker = async () => {
    await e2e.readyPromise;
    if (!e2e.otaHandle) throw new Error('e2e OTA file missing: ' + e2e.error);
    return [e2e.otaHandle];
  };

  // The export scenario needs the save picker to be absent, so the page takes
  // the service worker's streamed download instead.
  Object.defineProperty(window, 'showSaveFilePicker', {
    value: undefined,
    configurable: true,
  });
})();
''';
