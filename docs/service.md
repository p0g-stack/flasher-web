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
```

`apiBase` is the origin serving `/api/*` (web: `Uri.base.origin`; CLI: flag).
`Sel = {"device": "Oneplus 13", "kind": "SuperHybrid Flasher", "region": "GLO"}`
(upstream display names). `upstreamBase` is where `tables.json`,
`bloat-manifest.json`, `templates/<dev>.zip` and `platform-tools.zip` are served
(web: `<origin>/upstream/`; CLI: a directory path or URL).

## Methods

| Method | Arguments | Result |
|---|---|---|
| `Future<Map> environment()` | – | `{"facts": [...], "native": bool, "upstream": "<commit>", "storage": {"opfs": bool, "picker": bool, "handle": bool, "persisted": bool, "quota": int, "usage": int}}` |
| `Future<Map> bloatStatus(Map req)` | `{"selection": Sel, "store": Store, "upstreamBase": String}` | `{"total": int, "downloaded": int, "bytes": int, "ready": bool}` |
| `Stream<Map> downloadBloat(Map req)` | same as `bloatStatus` + `"apiBase"` | events (below); last is `{"type": "result", "bloat": {...status}}` |
| `Future<Map> inspectOta(Map req)` | `{"ota": OtaInput, "apiBase": String}` | `{"version", "fields": {...metadata}, "partitions": {name: size}, "length": int, "stored": bool, "arb": {"major","minor","index"}?, "device": String?, "securityPatch": String?}` |
| `Stream<Map> build(Map req)` | `{"selection": Sel, "ota": OtaInput, "base": OtaInput?, "vulnerableAbl": bool?, "zip": bool, "bloat": Store, "output": Store, "apiBase": String, "upstreamBase": String}` | events; last is `{"type": "result", ...}` |
| `Future<List<Map>> history(Map req)` | `{"output": Store}` | `build.json` contents, newest first, each plus `"job": <relative dir>` |
| `Future<Map> fastbootDevices()` | – | `{"devices": [{"serial", "label", "transport"}], "error"?: FailureMap}` |
| `Future<Map> prepareFlash(Map req)` | see below | prepared map, `productRequired` map, or `{"error": FailureMap}` |
| `Stream<Map> flash(Map req)` | prepared request + `{"confirmationToken": String}` | step/log/progress/waiting events; last is `{"type": "result", "status", "receipt"}` |

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

## Output layout (in the output Store)

`<YYYYMMDD-HHMMSS>-<6 hex>/` containing the artifact (`<kind> <dev> <COS|region> <version>.zip` + `.zip.sha256`,
or the folder), `build.json`, `build.log` — identical names and fields to upstream, plus
`ota_access` (`"file"` | `"stream"`), `arb`, `extracted_sha256`, `image_sha256`.
After a flash attempt the job also contains `flash-receipt.json`, and `build.json.flash` carries the receipt.
