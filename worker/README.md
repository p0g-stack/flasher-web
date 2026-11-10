# flasher_web worker

Cloudflare Worker for `flasher_web`. It serves the Flutter web build
(`../app/build/web`) and the same-origin `/api/*` routes that the browser
cannot call directly:

- `GET /api/catalog?na=0|1` — OTA catalog proxy, cached for 15 minutes.
- `POST /api/resolve` — resolves a catalog release entry to a fresh link.
- `GET /api/block-config` — discover the public bucket read base.
- `GET /api/manifest?id=…` — discover an ETag/length-pinned OTA generation.
- `GET /api/block?id=…&v=…&n=…` — fill/read one aligned 8 MiB block.
- `GET|HEAD /api/ota?u=…` — legacy Range proxy for explicit URL inputs.
- `GET /api/bloat/<asset>` — streaming proxy for the upstream bloat assets.

The site has two actions: **Flash directly** and **Export ZIP**. OTA decoding,
image verification, fastboot and ZIP generation run on the client. Local OTA
files are read in place. Catalog OTAs use the public Garage website endpoint
directly; only misses go through the Worker's authenticated S3 fill path.
The same Worker runs every minute to warm latest supported releases (catalog
polling remains at most once per 15 minutes) and
retire superseded generations. See `../docs/design.md` for the authoritative
identity, object-key, validation and lifecycle contract.

ZIP output goes directly to a save-picker file or a service-worker streamed
download, with no OPFS output copy. That download's `download/<id>` response is
provided by the browser's `app_sw.js`, not an edge API route.

## Local development

From the repository root, install the Worker dependencies and start a
throwaway Garage (Linux x86_64/aarch64, requires curl, openssl and Node):

```sh
(cd worker && npm ci)
./tool/dev_garage.sh
```

Keep that terminal open. The helper downloads pinned Garage 2.5.0 under
`.dart_tool/garage`, creates a single-node temporary bucket, enables its
website and CORS, and writes mode-600 `worker/.dev.vars` (gitignored).
It refuses to overwrite existing vars. Ctrl-C stops only its Garage and
removes its temporary data and unchanged vars. Set `GARAGE_PORT=15900` to use
a different base port; RPC and website use base+1 and base+2.

In another terminal:

```sh
cd worker
npx wrangler dev --port 8787
```

Open <http://127.0.0.1:8787>. `app/build/web` must exist (`flutter_p0g build web`).
Catalog reads require the S3 backend even when `OTA_PUBLIC_BASE` is unset:
null public base means Worker-only reads, not an uncached CDN fallback.
For a persistent Garage, configure `OTA_S3_ENDPOINT`, `OTA_S3_BUCKET`,
`OTA_S3_REGION` and optionally `OTA_PUBLIC_BASE`; production endpoints must
use HTTPS. Store `OTA_S3_ACCESS_KEY_ID` and `OTA_S3_SECRET_ACCESS_KEY` as Worker
secrets, not Wrangler vars. Never expose a write key to the browser.

To exercise the configured cron locally (the SPA asset fallback intercepts
`/__scheduled`), use Wrangler's direct scheduled dispatcher:

```sh
curl --get http://127.0.0.1:8787/cdn-cgi/local/scheduled \
  --data-urlencode 'cron=* * * * *' --data-urlencode 'format=json'
```

The handler logs warmed/deleted counts and its actual subrequest count.

## Checks

```sh
npx tsc --noEmit
npx vitest run
```

## Deploy

```sh
npx wrangler deploy
```

### Qualify the Free CPU limit after deployment

Run one real block miss and one scheduled warm invocation. Read their
`cpuTime` in Workers Logs, or `npx wrangler tail --format json`. Both must fit
Free's 10 ms CPU limit; local Miniflare reports zero CPU and cannot qualify
it. Local `perf stat` includes native I/O/TLS and is an upper bound, not the
billed CPU time. If either real invocation exceeds 10 ms, select Workers
Paid ($5/month); no cache-code change is needed. The code hard-limits each
invocation to 48 subrequests even on Paid.
