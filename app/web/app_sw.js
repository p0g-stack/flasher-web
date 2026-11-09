'use strict';

// The app's own service worker. Flutter's generated flutter_service_worker.js
// only unregisters itself, so index.html registers this file instead and
// flutter_bootstrap.js no longer asks the Flutter loader for a service worker.
//
// What it must never do:
//   - touch /api/… (catalog, resolve, OTA and bloat ranges, hosted jobs): those
//     streams rely on range semantics and must hit the network directly;
//   - answer any request that carries a Range header;
//   - keep OTA, bloat or package bytes: only the app shell and the engine
//     assets the page itself loads are cached.
//
// Bump CACHE_VERSION when the strategy changes. Asset URLs are stable across
// builds, so cached responses are revalidated in the background; a deploy is
// picked up on the next navigation without wiping the cache up front.

const CACHE_VERSION = 'v1';
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
  './workers/hello_service.web.g.dart.js',
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

  // /api/ and every range read stay network-only. OTA, bloat and hosted
  // artifacts are streamed ranges and a cached 200 can never replace them.
  if (url.origin === self.location.origin && isApiPath(url.pathname)) return;
  if (request.headers.has('range')) return;
  if (request.cache === 'only-if-cached' && request.mode !== 'same-origin') {
    return;
  }

  if (request.mode === 'navigate') {
    event.respondWith(networkFirst(event, request));
    return;
  }

  const sameOrigin = url.origin === self.location.origin;
  const cacheName = sameOrigin ? ASSET_CACHE : ENGINE_CACHE;
  event.respondWith(staleWhileRevalidate(event, request, cacheName));
});

/// `/api/catalog`, `/api/resolve`, `/api/ota`, `/api/bloat/…`, `/api/hosted/…`.
function isApiPath(pathname) {
  return pathname === '/api' || pathname.startsWith('/api/');
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

/// Same-origin assets: cached immediately, refreshed in the background.
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
