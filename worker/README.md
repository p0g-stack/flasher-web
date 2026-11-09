# flasher_web worker

Cloudflare Worker for `flasher_web`. It serves the Flutter web build
(`../app/build/web`) and the same-origin `/api/*` routes that the browser
cannot call directly:

- `GET /api/catalog?na=0|1` — OTA catalog proxy, cached for 15 minutes.
- `POST /api/resolve` — resolves a catalog release entry to a fresh link.
- `GET|HEAD /api/ota?u=…` — streaming Range proxy for allowlisted OTA hosts.
- `GET /api/bloat/<asset>` — streaming proxy for the upstream bloat assets.

The site has two actions: **Flash directly** and **Export ZIP**. OTA decoding,
image verification, fastboot and ZIP generation run on the client, not in this
Worker. Local OTA files are read in place; catalog OTA bytes use `/api/ota`.
Verified bloat and optional catalog OTA copies share the browser's 10 GiB app
storage cap.

ZIP output goes directly to a save-picker file or a service-worker streamed
download, with no OPFS output copy. That download's `download/<id>` response is
provided by the browser's `app_sw.js`, not an edge API route.

## Local development

```sh
npm install
npx wrangler dev --port 8787
```

Open <http://127.0.0.1:8787>. `app/build/web` must exist (`flutter_p0g build web`).

## Checks

```sh
npx tsc --noEmit
npx vitest run
```

## Deploy

```sh
npx wrangler deploy
```
