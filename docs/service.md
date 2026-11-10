# FlasherService contract

The app's one Squadron service (`core/lib/src/service/flasher_service.dart`,
`@SquadronService(baseUrl: '~/workers', targetPlatform: vm | web)`). It turns a
full OTA plus verified bloat into a flashable virtual package, flashes it, or
streams it out as a ZIP. On the web it runs in a Web Worker; natively in an
isolate; the CLI calls the same class directly. All arguments and results are
JSON-like maps (`String`, `num`, `bool`, `List`, `Map`, `null`) plus, on the
web, these browser objects passed by reference (structured clone): `File`,
`FileSystemDirectoryHandle`, `FileSystemFileHandle`.

## Locations

```text
OtaInput = {"kind": "file", "file": <web File | io path String>}
         | {"kind": "url", "url": String}                    // HTTP(S); the browser goes through /api/ota
         | {"kind": "catalog", "entry": <catalog release map>}
Virtual  = {"ota": OtaInput, "base"?: OtaInput, "bloat": Store, "vulnerableAbl"?: bool}
Store    = {"kind": "directory", "handle": <FileSystemDirectoryHandle>}   // a folder the user picked (Chromium)
         | {"kind": "opfs"}                                               // navigator.storage.getDirectory()
         | {"kind": "path", "path": <String>}                             // dart:io
Destination = <web FileSystemFileHandle>                                  // one picked file (Chromium)
            | {"kind": "stream", "id": String, "channel": String}         // the service worker download (Android)
            | {"kind": "path", "path": <String>}                          // dart:io
```

`apiBase` is the origin serving `/api/*` (web: `Uri.base.origin`; CLI: flag).
`Sel = {"device": "Oneplus 13", "kind": "SuperHybrid Flasher", "region": "GLO"}`
(upstream display names). `upstreamBase` is where `tables.json`,
`bloat-manifest.json`, `templates/<dev>.zip` and `platform-tools.zip` are served
(web: `<origin>/upstream/`; CLI: a directory path or URL).

`Virtual` is the request's whole input: the OTA, the optional Ace 6 ColorOS
BASE OTA (`base`, required by and only accepted for the Ace 6 OxygenOS
conversion), the bloat store and the X9U `vulnerableAbl` choice (required for
X9U, refused elsewhere). A request that names an output store is refused; an
Ace 6T IN/GLO ODM donor is chosen from the catalog, never supplied by the
caller.

## Storage cap and cached OTAs

The app bounds what it stores at 10 GiB (`appStorageCapBytes`). The same store
holds the verified bloat images and, when the user keeps one catalog release
offline, `ota-cache/`. `downloadBloat` and `cacheOta` check the planned bytes
against `min(cap - usage, quota - usage)` before writing and may evict the
least recently used cached OTA to make room; a write that still does not fit is
refused with a `BudgetException` naming `needed`, `available`, `cap`, `usage`
and `quota`. Usage and quota come from `navigator.storage.estimate()` in the
browser and from the volume on the VM; a source that cannot measure anything
leaves the cap as the only limit. Local OTA files are read in place and never
counted.

Each `storageBudget.items` entry reports `bytes` (durable downloaded data) and
`allocated` (the current logical file extent, zero if missing). A sparse
`<key>.downloadx.part` can have an allocation much larger than `bytes`; that
extent is already included in `usage`. Resuming the same catalog entry needs
only `max(0, catalog size - allocated)` additional space. Allocation belonging
to a different entry is not credited, and the service rechecks the file before
resuming.

For a picked directory, an unknown estimate deliberately avoids applying the
origin's quota to that folder. Only the app cap applies, and filesystem writes
can still fail when the destination drive fills.

## Methods

| Method | Arguments | Result |
|---|---|---|
| `Future<Map> environment()` | – | `{"facts": [...], "native": bool, "upstream": "<commit>", "storage": {"opfs": bool, "picker": bool, "handle": bool, "persisted": bool, "quota": int, "usage": int}}` |
| `Future<Map> bloatStatus(Map req)` | `{"selection": Sel, "store": Store, "upstreamBase": String}` | `{"total": int, "downloaded": int, "bytes": int, "ready": bool}` |
| `Stream<Map> downloadBloat(Map req)` | same as `bloatStatus` + `"apiBase": String` | events (below); last is `{"type": "result", "bloat": {...status}}` |
| `Future<Map> storageBudget(Map req)` | `{"store": Store, "apiBase": String?}` | `{"cap": int, "usage": int, "quota": int, "available": int, "items": [{"key", "label", "bytes", "allocated", "complete", "lastUsed"}]}` |
| `Stream<Map> cacheOta(Map req)` | `{"store": Store, "ota": {"kind": "catalog", "entry": <release>}, "apiBase": String?}` | `started`/`progress` events; last is `{"type": "result", "key", "label", "bytes", "complete", "sha256", "etag", "lastUsed"}` |
| `Stream<Map> saveOta(Map req)` | `{"ota": {"kind": "catalog", "entry": <release>}, "apiBase": String?, "destination": FileSystemFileHandle \| {"kind": "stream", "id", "channel"} \| {"kind": "path", "path"}}` | `started`/`progress` events (as for `cacheOta`, without `key`); last is `{"type": "result", "label", "bytes", "sha256"}`. Copies the OTA byte for byte outside the stores; no budget check. A file or path destination resumes from its recorded ranges when the same destination is passed again; a stream destination cannot resume |
| `Future<Map> evictCachedOta(Map req)` | `{"store": Store, "key": String}` | `{"key", "removed": bool, "freed": int, "storage": {"cap", "usage", "quota", "available"}}` |
| `Future<Map> inspectOta(Map req)` | `{"ota": OtaInput, "apiBase": String}` | `{"version", "fields": {...metadata}, "partitions": {name: size}, "length": int, "stored": bool, "arb": {"major","minor","index"}?, "device": String?, "securityPatch": String?}` |
| `Future<Map> fastbootDevices()` | – | `{"devices": [{"serial", "label", "transport"}], "error"?: FailureMap}` |
| `Future<Map> prepareFlash(Map req)` | see below | prepared map, `productRequired` map, or `{"error": FailureMap}` |
| `Stream<Map> flash(Map req)` | prepared request + `{"confirmationToken": String}` | `run`/`step`/`log`/`progress`/`waiting`/`failure` events; last is `{"type": "result", "runId", "status", "canRetry", "receipt"}` |
| `Stream<Map> retryStep(Map req)` | `{"runId": String}` | same events as `flash` |
| `Stream<Map> rebootRetry(Map req)` | `{"runId": String}` | same events as `flash` |
| `Future<Map> stopRun(Map req)` | `{"runId": String}` | `{"receipt": {...}}` with `status: "stopped"` |
| `Stream<Map> exportVirtual(Map req)` | `{"selection": Sel, "virtual": Virtual, "apiBase": String, "upstreamBase": String, "destination": Destination}` | step/progress events; last is `{"type": "result", "job", "format": "zip", "sha256", "bytes", "entries", "receipt"}` |

`fastbootDevices()` never opens a browser chooser. On the web it returns only
the granted devices; a failure is returned as `error` with an empty `devices`
list.

`inspectOta` validates a full AB OTA and reports what the package would use; it
reads ZIP metadata, the OTA metadata file and the payload manifest, not the
images.

## Bloat events

```text
{"type": "step",     "index": int, "total": int, "title": String}
{"type": "log",      "text": String}
{"type": "progress", "label": String, "done": int, "total": int}
{"type": "result",   "bloat": {"total", "downloaded", "bytes", "ready"}}
```

Every selected image is verified by size and raw SHA-256; a present image is
kept, a missing one is fetched through `/api/bloat/`, gunzipped and joined.

## Cache events

```text
{"type": "started",  "key": String, "label": String, "total": int, "resumedFrom": int}
{"type": "progress", "key": String, "label": String, "done": int, "total": int}
{"type": "result",   "key", "label", "bytes", "complete", "sha256", "etag", "lastUsed"}
```

`key` is the catalog entry digest. Only a catalog OTA can be cached; other
inputs throw. `resumedFrom` counts the bytes already on disk, which may be
scattered ranges rather than a prefix. Cancelling the stream leaves the partial
file and its chunk layout in place for the next download of the same entry.

## Flash contract

### `prepareFlash`

Request:

```text
{"selection": Sel, "virtual": Virtual, "serial": String,
 "answers": {promptId: choice}?, "apiBase": String, "upstreamBase": String,
 "job": String?, "vulnerableAbl": bool?}
```

`vulnerableAbl` may sit here or in `virtual`. `job` is optional: when supplied
it must equal the derived `virtual-<16 hex>` identity, otherwise preparation is
refused.

The call is read-only. It opens the granted device with the exact serial for
`getvar` reads (product, mode, `max-download-size`), and, once the plan is
resolved, checks the target partitions' sizes. It sends no write.

When the device table has no confirmed product mapping for the selected model
and no `product` answer was supplied, the result is not a prepared map:

```text
{"productRequired": true, "serial", "observedProduct": String, "message": String}
```

Pass the verified `product` answer and prepare again. A product mismatch is
refused before a token is returned. A link failure or a domain
`FlashException` returns `{"error": FailureMap}`; domain failures use
`blame: "user"`, `name: "FlashException"` and `stage: "prepare"`. Other errors
are thrown. Invalid OTA inputs, unsupported kinds, missing conversion inputs,
missing X9U choices and failed bloat checks are refused before any device write.

A resolved result has these keys:

```text
{"token": String, "serial", "product", "expectedProduct", "productMatches": bool,
 "mode": "bootloader"|"fastbootd"|"superFastboot"|"android", "modeOk": bool,
 "maxDownloadSize": int, "resolved": true, "job", "format": "virtual",
 "version", "device", "dev", "kind", "region",
 "steps": [String], "executionSteps": [String],
 "prompts": [{"id", "question", "choices": [String], "selected": String?}],
 "images": {path: {"path", "bytes": int, "sparse": bool, "digest": String,
                   "parts": int, "manifestSha256": String?}},
 "packageImages": [String], "manifest": {...build.json},
 "confirmation": [String], "warnings": [String], "createdAt": String}
```

`images` covers every image a `Flash` step would send. `digest` is the payload
partition digest or bloat asset digest. For `super.img` it is initially empty:
the encoded digest exists only after a complete stream. `parts` is the number
of downloads forced by `max-download-size`. Sparse geometry comes from the LP
layout, so preparation does not decode the super's OTA image data.

If a prompt has no default and no answer, its `selected` is null, the result has
`"resolved": false` and `"token": ""`, and `flash` cannot run. A prompt with a
default is preselected; the app still requires the user to answer every
displayed prompt before enabling Flash.

The token is random, held in service memory, and consumed by a flash attempt
before its binding checks. A new resolved preparation replaces every earlier
token. It binds the selection, job, serial, answers, `upstreamBase`, bloat-store
identity and the canonical snapshot digest of the OTA, BASE, donor and bloat.

### `flash`

The request is the `prepareFlash` request plus `"confirmationToken": <token>`,
naming the same `virtual`. Before the first command the service:

1. Consumes the token (unknown, expired or already used is refused).
2. Rechecks the request against the bound selection, job, serial, answers,
   `upstreamBase` and store identity.
3. Reopens the package from the request's OTA and bloat store, compares the
   snapshot digest and verifies the bloat images again.
4. Rechecks every prepared image's size.
5. Takes the job lock; a second attempt on the same job is refused.

A binding failure is thrown on the stream. Events:

```text
{"type": "run",     "runId": String}                                     // first; the run identity for retries
{"type": "log",     "text": String}
{"type": "step",    "index": int, "total": int, "title": String}
{"type": "progress","label": String, "done": int, "total": int}
{"type": "waiting", "serial": String, "mode": String, "text": String}    // reconnect after a reboot
{"type": "failure", "stepIndex": int, "status": "failed"|"uncertain", "reason": String}
{"type": "result",  "runId": String,
                    "status": "succeeded"|"failed"|"uncertain"|"stopped",
                    "canRetry": bool, "receipt": {...}}
```

`stepIndex` is 0-based; UIs show `index + 1`. `canRetry` is true only when the
run failed or became uncertain and was left paused, and is never inferred by a
client.

Execution guarantees:

- Starts in the normal bootloader after a product check, then follows the
  expanded plan and stops at the first failure.
- After a reboot, waits only for the confirmed serial, then requires the
  expected product and fastboot mode before the next command (180 s, polled
  every second).
- Splits downloads at `max-download-size`; sparse parts preserve the original
  block geometry and offsets; a raw image is split only when its size is a
  multiple of 4096; a logical partition is resized before flashing.
- Sends at most 1 MiB per transport write. A failed or uncertain operation
  retires the session and reports `sessionRetired`; a complete device FAIL
  does not.
- Sends no wipe or root command. Formatting and rooting remain manual on the
  phone.
- If the final reboot is reached, it closes the session; Android mode is not
  probed and the receipt says `android (unverified)`.
- Cancelling the stream subscription stops future commands and waits for the
  in-flight command to return. It is not a rollback, and the caller gets no
  receipt; `stopRun` is the call that returns one.

### `retryStep`, `rebootRetry`, `stopRun`

A paused run is identified by the `runId` the stream reported. `retryStep`
resends the failed step from byte zero and then continues with the remaining
steps; `rebootRetry` first reboots to the mode that step requires
(`reboot-bootloader`, or `reboot-fastboot` for fastbootd) and waits for that
mode. Both reopen the confirmed serial, recheck product and mode, keep the
earlier `steps` and `writes` in the receipt, and stream the same events as
`flash`. A retry whose input or device checks fail emits `failure` and stays
pausable; the receipt's failure has `stage: "retry-preflight"`.
After the retried step succeeds, the executor checks serial, product and mode
again before proceeding to the next step.

`stopRun` accepts an active or paused run, stops future commands, and returns
the receipt with `status: "stopped"`; an unknown or already finished run
throws. The page's Stop button calls `stopRun` and then cancels its
subscription.

Receipt:

```text
{"version": 1, "runId", "job", "serial", "device", "kind", "region",
 "otaVersion", "status", "stepIndex": int?, "reason": String?,
 "package": {...build.json, "image_sha256": {path: sha256}}, "arb",
 "image_sha256": {path: sha256},
 "expectedProduct", "modeStart", "modeEnd", "maxDownloadSize",
 "startedAt", "finishedAt", "steps": [{"index", "title", "status"}],
 "writes": [{"image", "partition", "bytes", "part"?, "parts", "status"}],
 "verification": {"status": "unverified", "detail": String},
 "failure": FailureMap?, "uncertain": bool, "cleanupErrors": [String],
 "strategy", "virtual": {...snapshot}, "persistenceWarnings": []}
```

`verification.status` is always `unverified`: fastboot `OKAY` is not a readback
hash. `modeEnd` is `android (unverified)` only when the final reboot command was
reached; an earlier failure leaves it at the last observed mode. A flash command
that may have reached the device without a definite completion leaves its write
marked `uncertain` and sets `uncertain: true`.

### Failure evidence and browser qualification

Public `blame` is `host`, `user`, `device` or `unknown`; transport-layer
provenance stays in `source`, and the original evidence is retained (`name`,
`stage`, `causes`, browser stack, cleanup errors, ordered INFO/TEXT). Direct
WebUSB failures keep the DOMException name/message/stack rather than
re-describing it. `sessionRetired` is a lifecycle bit, independent of blame and
never inferred from an error name.

In the browser, the page calls `web_usb_grant` from the user gesture before any
await, only in a secure context. The app keeps its fastboot interface `ff/42/03`
filter and mandatory-serial policy. Package failures distinguish cancellation
from permission refusal and keep DOMException name/message/stack; the app
maps only cancellation to no chosen device. Only the chosen serial passes to
the worker. The worker never opens a chooser: it lists granted devices, reopens
that exact serial, and asks the page to regrant the same phone after a mode
change. Native discovery matches the same interface from USB descriptors.

On the pinned nusb revision, nusb also owns browser transport I/O.
`Error::webusb_error()` and `Endpoint::take_webusb_error()` preserve owned
name/message/stack fields without changing the copyable transfer-error category.
Only Web Locks errors are decoded locally. nusb's shared JS-device lease
closes failed/cancelled opens and the last independent handle; explicit
`Device::force_close()` is used only while fastboot's exclusive lock is held.
Open/configure/claim/alternate, bulk I/O and cleanup all have bounded awaits.
`rust/Cargo.toml` pins that revision in `[patch.crates-io]` until nusb releases
those APIs. No phone has qualified discovery, configuration/alternate
selection, USB I/O, re-enumeration, real browser lock contention or cleanup.

Real OTA flashing on a real phone remains unqualified. The synthetic fixture
packages exercise streaming, sparse splitting, retries and uncertainty against
a recording fake transport, not real USB or partition readback.

## `exportVirtual`

Request: `{"selection": Sel, "virtual": Virtual, "apiBase": String,
"upstreamBase": String, "destination": Destination}`.

The service opens the same virtual package a flash would (same OTA input, same
BASE/donor rules, same bloat checks), then writes the tree into the
destination: a save-picker `FileSystemFileHandle`, a service-worker stream
channel, or a `dart:io` path. Nothing is staged in a store. Events:

```text
{"type": "step",     "index": 1, "total": 2, "title": "Write flasher ZIP"}
{"type": "progress", "label": String, "done": int, "total": int}
{"type": "result",   "job": String, "format": "zip", "sha256": String,
                     "bytes": int, "entries": int,
                     "receipt": {...package receipt, "output_format": "zip",
                                "image_sha256": {...}, "job": String,
                                "zip": {"sha256": String, "bytes": int}}}
```

`sha256` is the digest of the archive as written, computed in the same pass;
the receipt also carries the per-image digests, the ARB index and, for X9U, the
ABL source. Template files come from `upstreamBase`; Platform-Tools override
same-named template files and `updater-script`/`*.sh` line endings are
normalized.

A cancelled or failed export leaves a partial, invalid archive at a file or
path destination; the caller must discard it. With the streamed destination the
page aborts the download instead, so no partial file is saved. Cancelling the
subscription stops the export; an `ExportStreamSink` that was mid-chunk errors
its download rather than ending it cleanly.

