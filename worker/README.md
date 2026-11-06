# flasher_web worker

Cloudflare Worker for `flasher_web`. It serves the Flutter web build
(`../app/build/web`) and the same-origin `/api/*` routes that the browser
cannot call directly:

- `GET /api/catalog?na=0|1` — OTA catalog proxy, cached for 15 minutes.
- `POST /api/resolve` — resolves a catalog release entry to a fresh link.
- `GET|HEAD /api/ota?u=…` — streaming Range proxy for allowlisted OTA hosts.
- `GET /api/bloat/<asset>` — streaming proxy for the upstream bloat assets.

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
