'use strict';

// The app's own service worker. Flutter's generated flutter_service_worker.js
// only unregisters itself, so index.html registers this file instead and
// flutter_bootstrap.js no longer asks the Flutter loader for a service worker.
//
// What it must never do:
//   - touch /api/… (catalog, resolve, OTA and bloat ranges): those
//     streams rely on range semantics and must hit the network directly;
//   - answer any request that carries a Range header;
//   - keep OTA, bloat or package bytes: only the app shell and the engine
//     assets the page itself loads are cached.
//
// It also serves the streamed export download, `download/<id>`: the page
// registers a one-use id, and the response body is the export worker's ZIP,
// pulled chunk by chunk over a broadcast channel. Those bytes are never cached
// and the route is answered before anything else.
//
// Bump CACHE_VERSION when the strategy changes. Same-origin assets are
// network-first so a deploy runs on the next load; the caches serve offline.

const CACHE_VERSION = 'v2';
const SHELL_CACHE = `flasher-shell-${CACHE_VERSION}`;
const ASSET_CACHE = `flasher-assets-${CACHE_VERSION}`;
const ENGINE_CACHE = `flasher-engine-${CACHE_VERSION}`;
const CACHE_PREFIXES = ['flasher-shell-', 'flasher-assets-', 'flasher-engine-'];

// The document, its manifest and the icons the browser and OS read.
const SHELL_URLS = [
  './',
  './index.html',
  './manifest.json',
  './favicon.png',
  './icons/Icon-192.png',
  './icons/Icon-512.png',
  './icons/Icon-maskable-192.png',
  './icons/Icon-maskable-512.png',
];

// What the page fetches before it paints. Cached during install so the first
// offline reload works even though this worker did not control the initial
// load. Best effort: an optional asset that is absent must not fail install.
const PRECACHE_URLS = [
  './flutter_bootstrap.js',
  './main.dart.js',
  './pkg/flasher_web_native.js',
  './pkg/flasher_web_native_bg.wasm',
  './workers/flasher_service.web.g.dart.js',
  './workers/decoder_service.web.g.dart.js',
  './upstream/tables.json',
  './upstream/bloat-manifest.json',
  './canvaskit/canvaskit.js',
  './canvaskit/canvaskit.wasm',
  './canvaskit/chromium/canvaskit.js',
  './canvaskit/chromium/canvaskit.wasm',
];

// Resolved against this script (the app's base href), not against the page.
const INDEX_URL = new URL('index.html', self.location.href).href;
const ROOT_URL = new URL('./', self.location.href).href;

// One streamed export: how much the download asks for at a time, and how long
// a registration waits for its download before it is dropped.
const EXPORT_CHUNK_BYTES = 1024 * 1024;
const EXPORT_REGISTRATION_TTL = 120000;

/// Registered exports by id, until their one download has finished.
const exportStreams = new Map();

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const shell = await caches.open(SHELL_CACHE);
      const assets = await caches.open(ASSET_CACHE);
      const targets = [
        ...SHELL_URLS.map((url) => [url, shell]),
        ...PRECACHE_URLS.map((url) => [url, assets]),
      ];
      await Promise.all(
        targets.map(async ([url, cache]) => {
          try {
            const request = new Request(url, { cache: 'reload' });
            const response = await fetch(request);
            if (isCacheable(response)) await cache.put(request, response);
          } catch (error) {
            // Optional asset (for example an engine variant this build does
            // not ship); the runtime handler will cache it if it is requested.
          }
        }),
      );
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keep = new Set([SHELL_CACHE, ASSET_CACHE, ENGINE_CACHE]);
      const names = await caches.keys();
      await Promise.all(
        names
          .filter((name) => !keep.has(name))
          .filter((name) =>
            CACHE_PREFIXES.some((prefix) => name.startsWith(prefix)),
          )
          .map((name) => caches.delete(name)),
      );
      await self.clients.claim();
    })(),
  );
});

self.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || typeof data !== 'object' || typeof data.type !== 'string') {
    return;
  }
  if (data.type === 'flasher-export-register') {
    registerExport(event, data);
  } else if (data.type === 'flasher-export-abort') {
    abortExport(data);
  }
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  let url;
  try {
    url = new URL(request.url);
  } catch (error) {
    return;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return;

  // A streamed export download outranks every other route: it is not an
  // asset, it is never cached, and its body comes from the export worker.
  const exportId = exportDownloadId(url);
  if (exportId != null) {
    event.respondWith(exportResponse(exportId));
    return;
  }

  // /api/ and every range read stay network-only. OTA and bloat bytes
  // use streamed ranges and a cached 200 can never replace them.
  if (url.origin === self.location.origin && isApiPath(url.pathname)) return;
  if (request.headers.has('range')) return;
  if (request.cache === 'only-if-cached' && request.mode !== 'same-origin') {
    return;
  }

  if (request.mode === 'navigate') {
    event.respondWith(networkFirst(event, request));
    return;
  }

  // Same-origin code (main.dart.js, workers, the Rust wasm) is network-first:
  // a stale-while-revalidate copy would run the previous build for one load
  // after every deploy, including its USB transport. The cache is the offline
  // fallback only.
  if (url.origin === self.location.origin) {
    event.respondWith(assetNetworkFirst(event, request));
    return;
  }
  event.respondWith(staleWhileRevalidate(event, request, ENGINE_CACHE));
});

/// `/api/catalog`, `/api/resolve`, `/api/manifest`, `/api/block`, `/api/bloat/…`.
function isApiPath(pathname) {
  return pathname === '/api' || pathname.startsWith('/api/');
}

/// The export id of a `…/download/<id>` request, or null for any other path.
function exportDownloadId(url) {
  if (url.origin !== self.location.origin) return null;
  const parts = url.pathname.split('/');
  if (parts.length < 3) return null;
  if (parts[parts.length - 2] !== 'download') return null;
  const id = parts[parts.length - 1];
  return id.length > 0 ? id : null;
}

/// `Content-Disposition` wants a plain ASCII name; anything else is dropped.
function exportFilename(value) {
  const name = typeof value === 'string' ? value : '';
  const safe = name.replace(/[^A-Za-z0-9._-]+/g, '_').replace(/^\.+/, '');
  return safe.length > 0 ? safe : 'flasher.zip';
}

/// Registers one download. The page waits for `flasher-export-accepted` before
/// it requests `download/<id>`, so the route below always finds the entry.
function registerExport(event, data) {
  const id = typeof data.id === 'string' ? data.id : '';
  const channelName = typeof data.channel === 'string' ? data.channel : '';
  const source = event.source;
  const reply = (message) => {
    if (source && typeof source.postMessage === 'function') {
      source.postMessage(message);
    }
  };
  if (id.length === 0 || channelName.length === 0) {
    reply({ type: 'flasher-export-rejected', id });
    return;
  }
  const previous = exportStreams.get(id);
  if (previous) disposeExport(previous);
  const entry = {
    id,
    filename: exportFilename(data.filename),
    channel: new BroadcastChannel(channelName),
    controller: null,
    resolvePull: null,
    ready: false,
    creditSent: false,
    used: false,
    closed: false,
    timer: null,
  };
  entry.channel.onmessage = (message) => onExportMessage(entry, message.data);
  entry.timer = setTimeout(() => {
    if (exportStreams.get(id) === entry && !entry.used) disposeExport(entry);
  }, EXPORT_REGISTRATION_TTL);
  exportStreams.set(id, entry);
  reply({ type: 'flasher-export-accepted', id });
}

/// The page gave up before the worker finished: fail the download so the
/// browser drops the partial file instead of saving a broken ZIP.
function abortExport(data) {
  const id = typeof data.id === 'string' ? data.id : '';
  const entry = exportStreams.get(id);
  if (!entry) return;
  const reason =
    typeof data.reason === 'string' && data.reason.length > 0
      ? data.reason
      : 'The export was cancelled.';
  if (!entry.used) {
    // The download has not been requested yet. Remember the failure so the
    // navigation that may still arrive fails the download instead of saving a
    // 404 page as the ZIP; the registration's timer drops it otherwise.
    entry.failure = reason;
    return;
  }
  failExport(entry, reason);
}

/// The response body: bytes arrive only after `pull` grants credit, so the
/// worker never runs ahead of the file the browser is writing.
function exportResponse(id) {
  const entry = exportStreams.get(id);
  if (!entry || entry.used) {
    return new Response('Unknown export download.', {
      status: 404,
      headers: {
        'Cache-Control': 'no-store',
        'Content-Type': 'text/plain;charset=utf-8',
      },
    });
  }
  entry.used = true;
  if (entry.timer != null) {
    clearTimeout(entry.timer);
    entry.timer = null;
  }

  if (entry.failure) {
    // The export failed before the download asked for bytes: error the body
    // so the browser drops the download instead of keeping a broken file.
    const failure = entry.failure;
    disposeExport(entry);
    return new Response(
      new ReadableStream({
        start(controller) {
          controller.error(new Error(failure));
        },
      }),
      {
        headers: {
          'Content-Type': 'application/zip',
          'Cache-Control': 'no-store',
        },
      },
    );
  }

  const stream = new ReadableStream({
    start(controller) {
      entry.controller = controller;
      grantExportCredit(entry);
    },
    pull() {
      if (entry.closed) return undefined;
      return new Promise((resolve) => {
        entry.resolvePull = resolve;
        grantExportCredit(entry);
      });
    },
    cancel() {
      if (entry.closed) return;
      entry.channel.postMessage({ type: 'cancel' });
      disposeExport(entry);
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'application/zip',
      'Content-Disposition': `attachment; filename="${entry.filename}"`,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    },
  });
}

function onExportMessage(entry, data) {
  if (entry.closed || !data || typeof data !== 'object') return;
  switch (data.type) {
    case 'ready':
      entry.ready = true;
      grantExportCredit(entry);
      return;
    case 'chunk':
      deliverExportChunk(entry, data.bytes);
      return;
    case 'end':
      finishExport(entry);
      return;
    case 'error':
      failExport(
        entry,
        typeof data.message === 'string' && data.message.length > 0
          ? data.message
          : 'The export failed.',
      );
      return;
    default:
      return;
  }
}

/// Grants one chunk of credit per pending pull, and none while the worker has
/// not opened its side of the channel yet.
function grantExportCredit(entry) {
  if (entry.closed || entry.creditSent) return;
  if (!entry.ready || !entry.resolvePull) return;
  entry.creditSent = true;
  entry.channel.postMessage({ type: 'credit', bytes: EXPORT_CHUNK_BYTES });
}

function deliverExportChunk(entry, bytes) {
  if (entry.closed || !entry.controller) return;
  if (!(bytes instanceof Uint8Array)) return;
  entry.creditSent = false;
  entry.controller.enqueue(bytes);
  resolveExportPull(entry);
}

function resolveExportPull(entry) {
  const resolve = entry.resolvePull;
  entry.resolvePull = null;
  if (resolve) resolve();
}

function finishExport(entry) {
  if (entry.closed) return;
  const controller = entry.controller;
  resolveExportPull(entry);
  if (controller) controller.close();
  disposeExport(entry);
}

function failExport(entry, message) {
  if (entry.closed) return;
  const controller = entry.controller;
  resolveExportPull(entry);
  if (controller) controller.error(new Error(message));
  disposeExport(entry);
}

function disposeExport(entry) {
  entry.closed = true;
  if (entry.timer != null) {
    clearTimeout(entry.timer);
    entry.timer = null;
  }
  if (exportStreams.get(entry.id) === entry) exportStreams.delete(entry.id);
  try {
    entry.channel.close();
  } catch (error) {
    // Already closed by the browser.
  }
}

/// 200/ok responses of a type that can be replayed for the same request.
/// Opaque cross-origin responses are skipped: they cannot satisfy a CORS read.
function isCacheable(response) {
  if (!response || !response.ok || response.status === 206) return false;
  return response.type === 'basic' || response.type === 'cors';
}

/// index.html: fresh when the network answers, cached when it does not.
async function networkFirst(event, request) {
  const cache = await caches.open(SHELL_CACHE);
  try {
    const response = await fetch(request);
    if (isCacheable(response)) {
      event.waitUntil(cache.put(request, response.clone()));
    }
    return response;
  } catch (error) {
    const cached =
      (await cache.match(request, { ignoreSearch: true })) ||
      (await cache.match(INDEX_URL)) ||
      (await cache.match(ROOT_URL));
    return cached || Response.error();
  }
}

/// Same-origin assets: fresh when the network answers, cached when it does not.
async function assetNetworkFirst(event, request) {
  const cache = await caches.open(ASSET_CACHE);
  try {
    const response = await fetch(request);
    if (isCacheable(response)) {
      event.waitUntil(cache.put(request, response.clone()));
    }
    return response;
  } catch (error) {
    return (await cache.match(request)) || Response.error();
  }
}

/// Cross-origin engine assets: cached immediately, refreshed in the background.
async function staleWhileRevalidate(event, request, cacheName) {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request);
  const network = fetch(request).then(async (response) => {
    if (isCacheable(response)) {
      await cache.put(request, response.clone());
    }
    return response;
  });
  if (cached) {
    event.waitUntil(network.catch(() => undefined));
    return cached;
  }
  const response = await network.catch(() => undefined);
  return response || Response.error();
}
