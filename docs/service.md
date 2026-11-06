# FlasherService contract

The app's one Squadron service (`core/lib/src/service/flasher_service.dart`,
`@SquadronService(baseUrl: '~/workers', targetPlatform: vm | web)`). On the web
it runs in a Web Worker; natively in an isolate; the CLI calls the same class
directly. All arguments and results are JSON-like maps (`String`, `num`,
`bool`, `List`, `Map`, `null`) plus, on the web, these browser objects passed
by reference (structured clone): `File`, `FileSystemDirectoryHandle`.

## Locations

```text
OtaInput = {"kind": "file", "file": <web File | io path String>}
         | {"kind": "catalog", "entry": <catalog release map>}
Store    = {"kind": "directory", "handle": <FileSystemDirectoryHandle>}   // picked folder (Chromium)
         | {"kind": "opfs"}                                               // navigator.storage.getDirectory()
         | {"kind": "path", "path": <String>}                             // dart:io
```

`apiBase` is the origin serving `/api/*` (web: `Uri.base.origin`; CLI: flag).

## Methods

| Method | Arguments | Result |
|---|---|---|
| `Future<Map> environment()` | – | `{"facts": [...], "native": bool, "upstream": "<commit>", "storage": {"opfs": bool, "picker": bool, "persisted": bool, "quota": int, "usage": int}}` |
| `Future<Map> bloatStatus(Map req)` | `{"selection": Sel, "store": Store, "upstreamBase": String}` | `{"total": int, "downloaded": int, "bytes": int, "ready": bool}` |
| `Stream<Map> downloadBloat(Map req)` | same as `bloatStatus` + `"apiBase"` | events (below); last is `{"type": "result", "bloat": {...status}}` |
| `Future<Map> inspectOta(Map req)` | `{"ota": OtaInput, "apiBase": String}` | `{"version", "fields": {...metadata}, "partitions": {name: size}, "length": int, "stored": bool, "arb": {"major","minor","index"}?, "device": String?, "securityPatch": String?}` |
| `Stream<Map> build(Map req)` | `{"selection": Sel, "ota": OtaInput, "base": OtaInput?, "vulnerableAbl": bool?, "zip": bool, "bloat": Store, "output": Store, "apiBase": String, "upstreamBase": String}` | events; last is `{"type": "result", ...}` |
| `Future<List<Map>> history(Map req)` | `{"output": Store}` | `build.json` contents, newest first, each plus `"job": <relative dir>` |

`Sel = {"device": "Oneplus 13", "kind": "SuperHybrid Flasher", "region": "GLO"}` (upstream display names).
`upstreamBase` is where `tables.json`, `bloat-manifest.json`, `templates/<dev>.zip`, `platform-tools.zip` are served (web: `<origin>/upstream/`; CLI: a directory path or URL).

## Events

```text
{"type": "step",     "index": 1..5, "total": 5, "title": "Prepare OTA"}      // upstream's STEP n/5 titles
{"type": "log",      "text": "..."}                                          // one line, same wording as upstream where it exists
{"type": "progress", "label": "system.img", "done": int, "total": int}       // bytes
{"type": "result",   "job": "<dir>", "artifact": "<file or dir name>", "format": "zip"|"folder",
                     "sha256": String?, "manifest": {...build.json}}
```

Errors are thrown (Squadron carries them); messages match upstream's `BuildError` texts.
Cancelling the stream subscription cancels the job: the job directory is removed, like upstream.

## Output layout (in the output Store)

`<YYYYMMDD-HHMMSS>-<6 hex>/` containing the artifact (`<kind> <dev> <COS|region> <version>.zip` + `.zip.sha256`,
or the folder), `build.json`, `build.log` — identical names and fields to upstream, plus
`ota_access` (`"file"` | `"stream"`), `arb`, `extracted_sha256`.
