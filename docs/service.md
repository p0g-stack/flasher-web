# FlasherService contract

The app's one Squadron service (`core/lib/src/service/flasher_service.dart`,
`@SquadronService(baseUrl: '~/workers', targetPlatform: vm | web)`). It builds
flasher packages and flashes finished jobs. On the web it runs in a Web Worker;
natively in an isolate; the CLI calls the same class directly. All arguments
and results are JSON-like maps (`String`, `num`, `bool`, `List`, `Map`, `null`)
plus, on the web, these browser objects passed by reference (structured clone):
`File`, `FileSystemDirectoryHandle`.

## Locations

```text
OtaInput = {"kind": "file", "file": <web File | io path String>}
         | {"kind": "url", "url": String}                              // HTTP(S); web goes through /api/ota
         | {"kind": "catalog", "entry": <catalog release map>}
Store    = {"kind": "directory", "handle": <FileSystemDirectoryHandle>}   // picked folder (Chromium)
         | {"kind": "opfs"}                                               // navigator.storage.getDirectory()
         | {"kind": "path", "path": <String>}                             // dart:io
Destination = <web FileSystemFileHandle>                                  // one picked file (Chromium)
            | {"kind": "path", "path": <String>}                          // dart:io
```

`apiBase` is the origin serving `/api/*` (web: `Uri.base.origin`; CLI: flag).
`Sel = {"device": "Oneplus 13", "kind": "SuperHybrid Flasher", "region": "GLO"}`
(upstream display names). `upstreamBase` is where `tables.json`,
`bloat-manifest.json`, `templates/<dev>.zip` and `platform-tools.zip` are served
(web: `<origin>/upstream/`; CLI: a directory path or URL).

Build capacity checks follow the output Store: OPFS uses remaining origin
quota, a picked directory has unknown capacity because browsers expose no
free-disk-space API, and a native path queries its own volume (or its nearest
existing parent for a new directory). Unknown capacity is not zero and must
not inherit another store's quota. Filesystem write errors still stop the
build. `environment().storage` remains origin/working-volume information,
not the free space of a selected external folder.

`downloadBloat` applies the same cap to the bloat store: before each asset it
asks the budget for the transport bytes (plus the decoded image while gzip
decoding keeps both) and may evict the least recently used cached OTA to make
room. An in-progress download and everything outside `ota-cache/` are never
evicted.

## Methods

| Method | Arguments | Result |
|---|---|---|
| `Future<Map> environment()` | – | `{"facts": [...], "native": bool, "upstream": "<commit>", "storage": {"opfs": bool, "picker": bool, "handle": bool, "persisted": bool, "quota": int, "usage": int}}` |
| `Future<Map> bloatStatus(Map req)` | `{"selection": Sel, "store": Store, "upstreamBase": String}` | `{"total": int, "downloaded": int, "bytes": int, "ready": bool}` |
| `Stream<Map> downloadBloat(Map req)` | same as `bloatStatus` + `"apiBase"` | events (below); last is `{"type": "result", "bloat": {...status}}` |
| `Future<Map> storageBudget(Map req)` | `{"store": Store, "apiBase": String?}` | `{"cap": int, "usage": int, "quota": int, "available": int, "items": [{"key", "label", "bytes", "complete", "lastUsed"}]}` (see OTA cache and storage cap) |
| `Stream<Map> cacheOta(Map req)` | `{"store": Store, "ota": {"kind": "catalog", "entry": <release>}, "apiBase": String?}` | `started`/`progress` events; last is `{"type": "result", "key", "label", "bytes", "complete", "sha256", "etag", "lastUsed"}` |
| `Future<Map> evictCachedOta(Map req)` | `{"store": Store, "key": String}` | `{"key", "removed": bool, "freed": int, "storage": {"cap", "usage", "quota", "available"}}` |
| `Future<Map> inspectOta(Map req)` | `{"ota": OtaInput, "apiBase": String}` | `{"version", "fields": {...metadata}, "partitions": {name: size}, "length": int, "stored": bool, "arb": {"major","minor","index"}?, "device": String?, "securityPatch": String?}` |
| `Stream<Map> build(Map req)` | `{"selection": Sel, "ota": OtaInput, "base": OtaInput?, "vulnerableAbl": bool?, "zip": bool, "bloat": Store, "output": Store, "apiBase": String, "upstreamBase": String}` | events; last is `{"type": "result", ...}` |
| `Future<List<Map>> history(Map req)` | `{"output": Store}` | `build.json` contents, newest first, each plus `"job": <relative dir>` |
| `Future<Map> fastbootDevices()` | – | `{"devices": [{"serial", "label", "transport"}], "error"?: FailureMap}` |
| `Future<Map> prepareFlash(Map req)` | see below | prepared map, `productRequired` map, or `{"error": FailureMap}` |
| `Stream<Map> flash(Map req)` | prepared request + `{"confirmationToken": String}` | step/log/progress/waiting events; last is `{"type": "result", "status", "receipt"}` |
| `Stream<Map> exportVirtual(Map req)` | `{"virtual": {...}, "selection": Sel, "upstreamBase": String, "destination": Destination}` (see Virtual flashing) | step/progress events; last is `{"type": "result", "job", "format": "zip", "sha256", "bytes", "entries"}` |

`fastbootDevices()` never opens a browser chooser. On the web it returns only
the granted devices; a failure is returned as `error` with an empty `devices`
list.

## Build events

```text
{"type": "step",     "index": 1..5, "total": 5, "title": "Prepare OTA"}      // upstream's STEP n/5 titles
{"type": "log",      "text": "..."}                                          // one line, same wording as upstream where it exists
{"type": "progress", "label": "system.img", "done": int, "total": int}       // bytes
{"type": "result",   "job": "<dir>", "artifact": "<file or dir name>", "format": "zip"|"folder",
                     "sha256": String?, "manifest": {...build.json}}
```

Build errors are thrown (Squadron carries them); messages match upstream's
`BuildError` texts. Cancelling the build stream subscription cancels the job:
the job directory is removed, like upstream.

## Flash contract

### `prepareFlash`

Request:

```text
{"selection": Sel, "output": Store, "job": String, "serial": String,
 "answers": {promptId: choice}?, "upstreamBase": String}
```

For a hosted ZIP, omit `output` and supply
`"hosted": {"jobId": String, "sha256": String, "bytes": int}` with `job`
equal to `jobId`. The worker constructs same-origin URLs from the validated
capability ID; it never accepts a caller-supplied artifact URL. The hosted
manifest and ZIP are read through bounded ranges pinned to the artifact's
strong SHA-256 ETag. A renewable, bounded lease prevents cache eviction during
preparation and execution; expiry or failed renewal stops further device
commands and reads. Hosted receipts are returned to the page for download
rather than written into a local job store.

The call is read-only: it opens the granted device with the exact serial for
`getvar` reads, checks product, mode and `max-download-size`, and, once the
plan is resolved, inspects every image a `Flash` step would send. It sends no
write.

A resolved result has these keys:

```text
{"token": String, "serial", "product", "expectedProduct", "productMatches": bool,
 "mode": "bootloader"|"fastbootd"|"superFastboot"|"android", "modeOk": bool,
 "maxDownloadSize": int, "resolved": true, "job", "format": "zip"|"folder",
 "version", "device", "dev", "kind", "region",
 "steps": [String], "executionSteps": [String],
 "prompts": [{"id", "question", "choices": [String], "selected": String?}],
 "images": {path: {"path", "bytes": int, "sparse": bool, "digest": String,
                   "parts": int, "manifestSha256": String?}},
 "packageImages": [String], "manifest": {...build.json},
 "confirmation": [String], "warnings": [String], "createdAt": String}
```

`images` contains the full SHA-256 computed from the current bytes and, when
the build recorded it, `manifestSha256` from `image_sha256`. The build's
`extracted_sha256` map is extraction-time provenance, not a flash check.
Older builds without `image_sha256` still hash and bind current bytes but add a
warning. A `test_fixture` package also warns.

If a prompt has no default and no answer, its `selected` is null, the result
has `"resolved": false` and `"token": ""`, and `flash` cannot run. A prompt
with a default is preselected; the app still requires the user to answer every
displayed prompt before enabling Flash.

When the device table has no confirmed product mapping for the selected model
and no `product` answer was supplied, the result is not a prepared map:

```text
{"productRequired": true, "serial", "observedProduct": String, "message": String}
```

Pass the verified `product` answer and prepare again. A product mismatch is
refused before a token is returned. A link failure or a domain
`FlashException` returns `{"error": FailureMap}`; domain failures use
`blame: "user"`, `name: "FlashException"` and `stage: "prepare"`. Other errors
are thrown.

The token is random, held in service memory, and consumed by a flash attempt
before its binding checks; a refused attempt still needs a new preparation. It
binds the selection, job, serial, answers, `upstreamBase`, output-store
identity and a canonical digest of the package's entries and metadata.

### `flash`

The request is the `prepareFlash` request plus `"confirmationToken": <token>`.
A token from a resolved preparation is the only accepted confirmation input;
`token` is not an alias and is not accepted. Before the first command the
service:

1. Consumes the token (unknown, expired or already used is refused).
2. Rechecks the request against the bound selection, job, serial, answers,
   `upstreamBase` and store identity.
3. Reopens the package named by the job, rehashes its canonical snapshot and
   refuses a changed package.
4. Re-inspects every prepared image's size and content digest.
5. Takes the job lock.

Events:

```text
{"type": "log",     "text": String}
{"type": "step",    "index": int, "total": int, "title": String}
{"type": "progress","label": String, "done": int, "total": int}
{"type": "waiting", "serial": String, "mode": String, "text": String}   // reconnect after a reboot
{"type": "result",  "status": "succeeded"|"failed"|"uncertain"|"cancelled",
                    "receipt": {...}}
```

Token, binding and package failures are thrown on the stream. A `LinkFailure`
that escapes before execution produces a `failed` result with empty
`writes`/`steps`, `verification.status = "not-run"` and a failure map.

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
- Never retries an uncertain write. Staging is RAM-only; only a `flash:`
  command that may have reached the phone makes the write uncertain. A lost
  reboot acknowledgement is observed, not resent.
- Sends no wipe or root command. Formatting and rooting remain manual on the
  phone.
- If the final reboot is reached, it closes the session; Android mode is not
  probed and the receipt says `android (unverified)`.

Receipt:

```text
{"version": 1, "job", "status", "serial", "device", "dev", "kind", "region",
 "product", "expectedProduct", "modeStart", "modeEnd",
 "maxDownloadSize": int, "startedAt", "finishedAt",
 "steps": [{"index", "title", "status"}],
 "writes": [{"partition", "image", "bytes", "parts", "part"?, "status"}],
 "verification": {"status": "unverified", "detail": String},
 "failure": FailureMap | null, "uncertain": bool, "cleanupErrors": [String],
 "persistenceWarnings"?: [String], "strategy", "place", "facts"}
```

`verification.status` is `unverified`. Its detail reports that Android mode
was not probed after the final reboot command only when that final reboot was
attempted; otherwise it says flash OKAY replies carry no readback hash.
`persistenceWarnings` is present when the service attempted to save the
receipt. It writes `<job>/flash-receipt.json` and the same receipt under
`flash` in `build.json`; a failed save is reported there, not hidden.
`strategy`, `place` and `facts` are present after an execution attempt; the
early link-failure receipt described above is the smaller map.

`FailureMap` keeps the original evidence. Link failures add `source` (the
producing layer), `sessionRetired` and ordered INFO/TEXT `messages`; domain
failures share the remaining fields and use `blame: "user"`:

```text
{"blame": "host"|"user"|"device"|"unknown", "source"?: String,
 "sessionRetired"?: bool, "name", "message", "stage", "uncertain": bool,
 "stack", "causes": [String], "cleanupErrors": [String],
 "messages"?: [{"kind": "INFO"|"TEXT", "text": String}]}
```

`blame` is the public responsibility class, never a transport-layer name.
`source` carries the producing layer. Direct WebUSB failures keep the browser's
DOMException name/message/stack as evidence instead of re-describing it.
`sessionRetired` states whether the session is unusable; it is independent of
blame and is never inferred from an error name.

### Cancellation

Cancelling the `flash` subscription stops future commands and waits for the
in-flight command or write to return before the worker acknowledges. It is not
a rollback: commands already sent stay applied and the phone may be partially
written. The stream may close without a result; the service may still persist a
receipt. The app treats a failed cancellation acknowledgement as uncertain.
A used token is never offered again: a retry needs a new read-only preparation
and a new confirmation.

## Virtual flashing

A virtual flash applies a full OTA in place: no flasher package is built, no
image is extracted into a store, and the phone is written from operations
decoded in memory as the plan reaches them. It is offered for the `Regional
Flasher` and `RegionalHybrid Flasher` types only; a `Super` kind needs the
generated `super.img` and is refused.

Request, for both `prepareFlash` and `flash`:

```text
{"selection": Sel, "serial": String, "answers": {promptId: choice}?,
 "upstreamBase": String,
 "virtual": {"ota": OtaInput, "bloat": Store}}
```

`output` and `hosted` must be absent. `job` is optional: when supplied it must
equal the derived identity, otherwise preparation is refused. `flash` takes the
same fields plus `confirmationToken`, and must name the same `virtual` value it
prepared with: a changed OTA input or bloat store is refused, and the bloat
store's identity is compared with the one the token bound.

Job identity is derived, not chosen: `virtual-<16 hex>` over a canonical map of
the OTA source identity (`file` metadata, `url`, or the catalog release entry),
the manifest digest, the OTA length and the selection's device, kind and
region. A changed OTA file, URL or catalog entry therefore yields a different
job, and preparation no longer matches.

`prepareFlash` returns the usual resolved map with `format: "virtual"`, that
derived `job`, and `manifest` holding the virtual `build.json`-shaped map
(`device`, `dev`, `flasher_type`, `region`, `version`, `output_format:
"virtual"`, and `image_sha256` when every image has a whole-image digest). The
image list, confirmation text, prompts and token work as for a finished job.
`flash` returns the usual receipt; a virtual run adds `virtual` (the OTA,
manifest, partition, bloat and `build.json` snapshot it read) and leaves
`persistenceWarnings` empty, because there is no job directory to write.

### Integrity rule

- `prepareFlash` makes one full pass: every image a `Flash` step names is
  decoded completely and hashed, so a truncated operation, a wrong length or a
  tampered byte stops before any device command. The confirmation token binds
  that snapshot.
- `flash` authenticates every operation before its bytes are returned: the
  operation's data SHA-256 is checked first, the decoded length must match its
  destination extents, and ZERO operations write zeros. Packaged operations are
  never trusted for their length alone. No whole-image rehash and no second
  image pass happens during execution — the token already bound the decoded
  images.
- Bloat images are verified against `bloat-manifest.json` (size and raw
  SHA-256) when the package is opened, which is also what `flash` does before
  its first command; the snapshot digest covers those hashes. The pre-write
  ticket check therefore rechecks image sizes and the snapshot digest only, and
  rehashes neither OTA-derived nor bloat images.
- Rust `verify_virtual` (reached through `verifyVirtualReads`) refuses, before
  any device command, an incremental payload, an operation that reads the
  source partition, an operation without a data SHA-256, or an operation larger
  than the cache limit.

### Limits and storage model

- The OTA must be a full AB OTA with a stored `payload.bin`: ranges address its
  bytes, so a compressed `payload.bin` is refused ("Only OTAs with a stored
  payload.bin can be read in place").
- Each operation is bounded: at most 64 MiB of encoded data and, for a
  compressed kind, at most 64 MiB decoded. One package-wide
  least-recently-used cache holds at most 64 MiB of decoded operations, so a
  multi-GiB image is decoded piecewise from its operations rather than kept in
  memory.
- One image read is at most 8 MiB, so no caller can materialize a whole image
  by accident.
- Nothing OTA-derived is written by the flash itself: the OTA stays where it is
  read from (local file, HTTP ranges, or the catalog link), the bloat store is
  opened read-only, and a virtual flash writes only to the phone. A catalog OTA
  the user chose to cache is read from `<store>/ota-cache/` instead (see OTA
  cache and storage cap); that ZIP was written once by `cacheOta`, counts
  against the 10 GiB cap, and carries the same catalog identity, so the derived
  job id is unchanged.

### Virtual export

`exportVirtual` writes the package tree a build would contain for the same
inputs — the selected template subtree, `Platform-Tools/` and the images — as a
streaming ZIP64, without staging it first.

```text
request  {"virtual": {"ota": OtaInput, "bloat": Store}, "selection": Sel,
          "upstreamBase": String, "destination": Destination}
events   {"type": "step", "index": 1, "total": 2, "title": "Write flasher ZIP"}
         {"type": "progress", "label": String, "done": int, "total": int}
result   {"type": "result", "job": String, "format": "zip", "sha256": String,
          "bytes": int, "entries": int}
```

The archive applies the same rules as a build: the template subtree named by
the selection (X9U regional flashers drop `META-INF`), `Platform-Tools/`
overwriting template files of the same name, bloat images staged into the
image folders with the CN `GLO_BLOAT` preload placed in `OOS_FILES_HERE`, and a
decoded OTA image winning over a staged bloat copy (X9U keeps its bloat image).
`updater-script` and every `*.sh` are normalized to LF; other files keep their
bytes. Like a build ZIP it stores no `build.json` and no checksum file: both are
returned to the caller instead. Entries are written once in ascending order
with the same Rust `ZipWriter` a build uses, so no temporary file and no
second copy of an image exists; progress events are `{"type": "progress",
"label", "done", "total"}`.

The destination is the user's file outside every store, so an export never
counts against the browser storage cap. A cancelled or failed export leaves a
partial, invalid ZIP at that path.

## OTA cache and storage cap

The app's browser storage is capped at 10 GiB. Every planned write is checked
against `min(cap - usage, quota - usage)`, clamped at zero, from
`navigator.storage.estimate()` on the web, the volume's free space on the VM,
and the cap alone for a picked folder (the platform exposes no reading for it).
A shortfall throws a `BudgetException` naming `needed`, `available`, `cap`,
`usage` and `quota`, after asking the OTA cache to evict least recently used
entries.

Browser storage holds only verified bloat images, an optional cache of catalog
OTA ZIPs, small metadata and the service-worker shell. A local OTA file is read
in place, and an export goes to the user's destination, so neither counts.

The cache lives in the store that also holds bloat:

```text
<store>/ota-cache/<digest>.zip    the OTA bytes
<store>/ota-cache/<digest>.json   the sidecar
```

`<digest>` is a canonical digest of the catalog release entry (signed URL query
strings and `is_latest` excluded), so a changed entry is a different key and is
never served in place of another. The sidecar records the digest, a
device/region/version label, the catalog size, the observed length, the strong
ETag when the server sent one, bytes written, a complete flag, the full-file
SHA-256, `createdAt`, `completedAt` and `lastUsedAt`.

`cacheOta` probes the release first: a catalog size, a length or an ETag that
does not match an interrupted download is refused rather than mixed in. It then
writes with ranged reads and positional writes and persists progress after each
chunk, so a cancelled or failed download resumes at its recorded offset. A
resumed download rehashes the bytes already on disk and continues, so the
recorded SHA-256 always covers the whole file. Payload op hashes are still
checked when the virtual core reads the OTA, so a corrupt cache cannot feed a
flash.

A complete cached entry is used transparently for a catalog `OtaInput` on the
virtual path: the job identity stays the catalog entry (never a cache path), so
the derived job id does not change, and a cache that cannot be read falls back
to streaming the same bytes. `evictCachedOta` deletes one entry by key; eviction
never touches bloat images, the job workspace or an in-progress download.

```text
request  {"store": Store, "ota": {"kind": "catalog", "entry": <release>},
          "apiBase": String?}
events   {"type": "started", "key": String, "label": String, "total": int,
          "resumedFrom": int}
         {"type": "progress", "key": String, "label": String, "done": int,
          "total": int}
result   {"type": "result", "key": String, "label": String, "bytes": int,
          "complete": true, "sha256": String, "etag": String?,
          "lastUsed": String}
```

`storageBudget` reports the cap and the cache list for the UI. `items` is most
recently used first; `bytes` is the whole OTA once complete and the bytes
written so far before that; `lastUsed` is an ISO-8601 UTC string.

## Output layout (in the output Store)

`<YYYYMMDD-HHMMSS>-<6 hex>/` containing the artifact (`<kind> <dev> <COS|region> <version>.zip` + `.zip.sha256`,
or the folder), `build.json`, `build.log` — identical names and fields to upstream, plus
`ota_access` (`"file"` | `"stream"`), `arb`, `extracted_sha256`, `image_sha256`.
After a flash attempt the job also contains `flash-receipt.json`, and `build.json.flash` carries the receipt.
