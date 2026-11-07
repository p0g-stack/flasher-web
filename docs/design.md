# flasher_web design

A browser port of [koaaN/Flasher_Builder](https://github.com/koaaN/Flasher_Builder):
choose a device, flasher type and region, provide a full OTA, and build the
same flasher package the desktop app builds — in the tab, with no server-side
build. Upstream stays the source of truth for the device tables, flasher
templates, Platform-Tools and the bloat manifest; this app pins a commit of it.
Finished jobs can then be flashed from the browser or CLI under the same
read-only preparation, confirmation and receipt rules.

## Pieces

| Piece | Where | Role |
|---|---|---|
| App Rust library | `rust/` (frb) | Thin surface over the reusable crates: synchronous, pure compute calls, plus asynchronous fastboot transport calls. No USB state machine or Dart policy here. |
| Reusable payload crate | `rust/crates/ota-payload/` | I/O-free parsing and operation decoding for Android update payloads, plus SHA-256. Port of otaripper and the upstream Python full-OTA check; builds for native and wasm. |
| Reusable fastboot crate | `rust/crates/fastboot-link/` | Discovery, exclusive serial selection, the fastboot state machine and streaming downloads over native nusb or browser WebUSB. No frb or Dart dependency. |
| Dart link package | `packages/device_link/` | Pure-Dart transport/session interfaces, device and failure records. No I/O, Flutter or frb dependency. |
| Core | `core/` (pure Dart) | Upstream tables and selection rules, storage interfaces, the build pipeline, flash plans, read-only preparation and execution as services/streams, catalog client, bloat materializer. Drives I/O and calls Rust. |
| CLI | `cli/` | `flasher_web build …`, `inspect`, `bloat`, `devices`, `flash`, `facts` and `serve`, running the same service natively (dart:io + the native library). |
| App | `app/` (Flutter web) | The build and flash UI. The page owns permission choosers; the service runs in a Squadron Web Worker. |
| Edge worker | `worker/` (Cloudflare Workers) | Serves `app/build/web` and the same-origin `/api/*` routes the browser cannot do itself (CORS). Local: `wrangler dev`. |
| Upstream sync | `tool/sync_upstream.dart` | Fetches the pinned upstream commit and writes `app/web/upstream/` (gitignored). |

## Upstream snapshot (`app/web/upstream/`, served as static files)

Pinned in `upstream.lock` (repository + commit). Produced by `dart run tool/sync_upstream.dart`, which bootstrap runs.

- `tables.json` — parsed from `.github/workflows/build_tools.yml` exactly like `backend.Catalog`:
  `{"commit": "...", "devices": {"Oneplus 13": "13", ...}, "region_sizes": {"13": [cn, other], ...}, "builders": [["SuperHybrid Flasher", "13", "GLO", "BUILD_SUPER.sh"], ...]}`
- `bloat-manifest.json` — copy of `bloat/assets-manifest.json`.
- `templates/<dev>.zip` — `flasher_scripts/<dev>/**` with paths relative to `flasher_scripts/<dev>/`, Unix modes kept in external attributes.
- `platform-tools.zip` — `Platform-Tools/**`, paths relative to `Platform-Tools/`.
- `README.md` — upstream README (Documentation page).

## Network routes (edge worker, same origin)

| Route | Behaviour |
|---|---|
| `GET /api/catalog?na=0|1` | Proxy `https://roms.danielspringer.at/api/ota.php` (or `/api/na.php`), passing `If-None-Match`/`ETag`; cache 15 min. |
| `POST /api/resolve` body = catalog release entry JSON | Port of `ota_catalog.resolve_link`; returns `{"url": "..."}` (a fresh signed link). Never cached or logged. |
| `GET /api/ota?u=<url>` | Range proxy for a resolved OTA link. Allowlisted hosts only (`*.allawnofs.com`, `*.allawnos.com`, `roms.danielspringer.at/download.php`, `*.oneplus.com`, `*.oppo.com`, `*.coloros.com`); `Range` required; passes 206/Content-Range/Content-Length; adds upstream's OTA request headers. |
| `GET /api/bloat/<asset_name>` | Proxy `https://github.com/koaaN/Flasher_Builder/releases/download/bloat-assets-v1/<asset_name>` (following the redirect); `Range` passed through. Asset names validated against `[A-Za-z0-9._-]+`. |

The worker never sees OTA or bloat bytes at rest; it streams them.

## Storage (core `lib/src/storage/`)

```dart
abstract interface class ByteSource {          // read-only random access
  int get length;
  Future<Uint8List> read(int offset, int length);
}
abstract interface class ByteSink {            // positional writes
  Future<void> write(Uint8List bytes, int offset);
  Future<void> truncate(int length);           // new bytes read as zero
  Future<void> close();
}
abstract interface class Workspace {           // a directory tree
  Future<ByteSink> create(String path);        // creates parents, replaces existing
  Future<ByteSource> open(String path);
  Future<bool> exists(String path);
  Future<int> size(String path);
  Future<List<String>> list(String dir, {bool recursive = false}); // relative paths, files only
  Future<void> move(String from, String to);
  Future<void> delete(String path);            // file or directory, recursive
}
```

Implementations: `dart:io` (CLI, desktop, tests); web `FileSystemDirectoryHandle`
for both OPFS (`navigator.storage.getDirectory()`) and a user-picked directory
(File System Access, Chromium); web `Blob`/`File` source; HTTP range source
(`fetch` on web, `HttpClient` on io). Paths are `/`-separated and relative.

Where output goes: Chromium — a directory the user picks holds the workspace,
the bloat cache and the finished package, like the desktop app. Elsewhere —
OPFS holds all of it and the finished ZIP is saved with a normal browser
download from the OPFS file (`navigator.storage.persist()` requested first).

## Compute and transport (frb, `rust/src/api/`)

Compute functions are `#[frb(sync)]` and pure, so a call runs inside the
Squadron worker that makes it. Byte buffers are `Vec<u8>` in and out. The
fastboot functions in `api/fastboot.rs` are asynchronous because they await USB
I/O; they only hold session handles and convert typed failures for Dart.

The reusable crates own their concerns:

- `ota-payload` parses `CrAU` headers/manifests, decodes operations and hashes
  bytes. Callers pass the bytes they already read; it does no I/O and has no
  frb dependency. Gzip stream decoding stays app-local.
- `fastboot-link` owns discovery (`ff/42/03`), exact-serial open, the command
  and download state machine, and the per-session mutex. Native uses nusb 0.2.9;
  browser uses WebUSB. Published `fastboot-protocol` 0.4.0 supplies the response
  parser and command type. No fork rebase was performed for this work. Each
  download chunk is owned by the session; native nusb moves that buffer into its
  transfer without another copy.
- `device_link` defines the interfaces the core uses. Failure records keep the
  original name, message, stack, causes, cleanup errors and ordered INFO/TEXT
  records; classification is additional. Public `blame` is `host`, `user`,
  `device` or `unknown`; the producing layer stays in the evidence, never in the
  public blame. A session retires on transport/protocol failure independently
  of that classification; a complete device FAIL does not retire it.

A failed native library load is cached as `nativeLoadFailure` with the
library's own name, message and stack.

`surfaces` is not part of this stack. `squadron_process` carries service calls
only; USB stays in `fastboot-link`, including in the CLI's `serve` process
place and in the browser worker.

Compute surface (`rust/src/api/`):

- `zip.rs` (reading): `zip_entries(tail: Vec<u8>, file_len: u64) -> Result<ZipDirectory>` where
  `ZipDirectory { needs: Option<(u64,u64)>, entries: Vec<ZipEntry> }` — call with the last
  `min(file_len, 65557 + 20 + 56)` bytes; when the central directory is not inside the tail,
  `needs` gives the absolute range to read and pass to `zip_parse_central(cd: Vec<u8>, ...)`.
  `ZipEntry { name, method, compressed_size, uncompressed_size, crc32, local_header_offset, unix_mode }`;
  `zip_data_offset(local_header_30_bytes: Vec<u8>, local_header_offset: u64) -> Result<u64>`;
  `inflate_raw(data: Vec<u8>, expected_len: u64) -> Result<Vec<u8>>`.
- `payload.rs`: `payload_header(head24: Vec<u8>, payload_size: u64) -> Result<PayloadHeader { manifest_len, signature_len, data_start }>`;
  opaque `Manifest::parse(manifest: Vec<u8>) -> Result<Manifest>`; `block_size()`;
  `partitions() -> Vec<PartitionInfo { name, size, op_count, sha256: Option<String> }>`;
  `operations(name) -> Vec<OpInfo { index, kind, data_offset, data_length, dst: Vec<Extent { offset, length }> }>`
  (offsets in bytes; `data_offset` relative to `data_start`);
  `decode_op(name, index, data: Vec<u8>) -> Result<Vec<u8>>` (verifies the op's data SHA-256, decompresses
  REPLACE / REPLACE_BZ / REPLACE_XZ / REPLACE_ZSTD; returns the bytes for `dst` in order; ZERO/DISCARD return empty);
  `verify_full() -> Result<u32>` (port of upstream `verify_full_payload`: rejects source-dependent operations
  and incomplete partitions). Opaque `Sha256Hasher { new, update, update_zeros(n), finish_hex }`.
  `GzipDecoder { new, push(bytes) -> Vec<u8>, finish() -> Result<Vec<u8>> }`.
- `arb.rs`: `arb_scan(image: Vec<u8>) -> Result<ArbInfo { major, minor, index }>` (port of otaripper `arbscan`).
- `sparse.rs`: `sparse_header(bytes28: Vec<u8>) -> Option<SparseHeader>`; `sparse_chunk(bytes12: Vec<u8>) -> Result<SparseChunk>`;
  opaque `SparseWriter::new(block_size, total_blocks)`, `push(bytes) -> Vec<u8>`, `push_fill(value: u32, len)`,
  `skip(len)`, `finish() -> SparseTail { header: Vec<u8> /* for offset 0 */, trailer: Vec<u8> }`.
- `lp.rs`: `super_layout(spec: SuperSpec) -> Result<SuperLayout>` — the exact LP geometry and metadata lpmake writes for
  `--metadata-size --metadata-slots --virtual-ab --super-name --device --group … --partition name:readonly:size:group`;
  `SuperLayout { head: Vec<u8> /* bytes from offset 0 */, extents: Vec<PartitionExtent { name, offset, size }> }`.
- `avb.rs`: `make_vbmeta(include_descriptors_from: Vec<Vec<u8>>, flags: u32, rollback_index: u64) -> Result<Vec<u8>>`
  equal to `avbtool make_vbmeta_image --include_descriptors_from_image … --flags … --rollback_index …`.
- `zip_write.rs`: opaque `ZipWriter::new()`, `start_file(name, unix_mode, deflate: bool) -> Vec<u8>`,
  `write(data) -> Vec<u8>`, `finish_file() -> Result<Vec<u8>>`, `finish() -> Result<Vec<u8>>`; ZIP64 throughout,
  deflate level 3, data descriptors, `create_system = 3`.

## Pipeline (core service, ports `backend.build` and `native_pipeline`)

1. Selection: `Catalog.selection(device, kind, region)` → dev, builder, template.
2. Bloat: verify the selected images in the bloat store (size + SHA-256); download missing ones through
   `/api/bloat/`, gunzip and join parts as `materialize_bloat` does. Never during a build.
3. OTA: a local `File`, or a catalog entry resolved through `/api/resolve` and read through `/api/ota`.
   Read only ZIP metadata, `META-INF/com/android/metadata` and the payload manifest; validate full AB OTA.
   ARB index from `xbl_config`. Catalog size must equal the remote length.
4. Stage templates and bloat exactly like `native_pipeline.stage`.
5. Extract each needed partition straight to its final path: truncate to size, decode ops in order, write at
   extents, verify the image SHA-256 against the manifest. Partitions the flasher discards are not extracted.
6. Super: `super_layout` + `SparseWriter` stream the staged images into `super.img`.
7. Ace 6 conversion: vbmeta via `make_vbmeta`; X9U super-size and ABL choice as upstream.
8. Package: ZIP (+ `.sha256`) or folder; `build.json` with upstream's fields plus `ota_access`, `arb`,
   `extracted_sha256` (decoded partition images at extraction) and `image_sha256` (final files in the package,
   including the generated `super.img` and converted vbmeta). Flashing checks `image_sha256`, not the
   extraction-time map.

Progress is a `Stream<BuildEvent>` (step 1–5 like upstream's `STEP n/5`, log lines, byte progress, result).
Cancelling the subscription stops the job and removes the job folder, as upstream does.

## Flashing a finished job

Flashing starts from a finished job in the output Store. `build.json` names the
artifact (ZIP or folder), and the package is opened in place: a ZIP is read
through its central directory and a streaming inflater, so preparation and
execution never buffer a whole image.

### Read-only preparation

`prepareFlash` binds the job, the device and every answer before a single
device write. It:

1. Rejects a selection that does not match `build.json`'s device, kind and
   region, or an artifact whose format disagrees with `output_format`.
2. Requires the exact serial in the granted list, opens only that serial, then
   reads product, mode and `max-download-size` with `getvar`. Preparation sends
   no write command; non-logical target sizes come from `getvar` too.
3. Resolves the template prompts. A prompt with a default is preselected; a
   prompt without one stays unanswered, and until an explicit answer arrives
   the result has `resolved: false` and an empty `token`.
4. When the device table has no confirmed product mapping, returns
   `productRequired` with the observed product instead of a token. The user
   must verify the selected model and pass that product explicitly.
5. Inspects every image a `Flash` step would send: size, sparse scan, full
   SHA-256, and the build's final-image digest. A build without
   `image_sha256` produces a warning: current bytes are still hashed and bound,
   but not to build-time digests.

A resolved preparation returns a random 32-byte token. It is kept in the
service, never written to the job, is consumed by the first flash attempt, and
binds the selection, job, serial, answers, `upstreamBase`, output-store
identity and a canonical digest of the package's entries and metadata. The
token is the only accepted confirmation input (`confirmationToken`); an
unresolved plan has no usable token.

### Execution

Execution starts in the normal bootloader, rechecks product and
`max-download-size`, then follows the plan's expanded steps. It stops at the
first failure. After a reboot it waits only for the confirmed serial, opens
that exact device, and requires both the expected product and fastboot mode
before the next command; the wait is bounded (180 s, polled every second).

Downloads are streamed in pieces of at most 1 MiB and split at the device's
`max-download-size`:

- a sparse image is split at chunk boundaries; every part repeats the original
  block geometry and starts with a DONT_CARE chunk for blocks already sent, so
  all parts write the same partition offsets;
- an oversized raw image is converted into sparse parts only when its length is
  a multiple of 4096 bytes;
- in fastbootd, a reconstructed logical partition is resized to the expanded
  image size before flashing.

The plan never sends a wipe or root command. Formatting data and rooting stay
manual on the phone; the plan only carries the instruction or the
prepare-root/flash-signal choice.

Staging a download changes RAM, not a partition. For an image write, only a
`flash:` command that may have reached the device makes the write uncertain. A
lost reboot acknowledgement is observed and never resent. Uncertain writes are
not retried automatically; a retry requires a new preparation and
confirmation. If the final reboot is reached, it closes the fastboot session
and Android mode is reported as `android (unverified)`; an earlier failure
leaves `modeEnd` at the last observed mode.

### Cancellation and receipts

Cancelling the `flash` subscription stops future commands and waits for the
in-flight command or write to return before acknowledging. It is not a
rollback: commands already sent stay applied, and an in-flight write may leave
the phone partially written. If the cancellation acknowledgement fails, the app
marks the run uncertain rather than assuming it stopped.

The result carries a receipt with status, plan steps, writes (including part
counts), start/end modes, failure evidence, uncertainty and cleanup errors.
Verification is `unverified`: fastboot OKAY is not a readback hash. The service
writes `<job>/flash-receipt.json` and records the same receipt under
`flash` in `build.json`; failures to persist appear in
`persistenceWarnings`.

### Failure evidence and browser qualification

Public `blame` is `host`, `user`, `device` or `unknown`; transport-layer
provenance stays in `source`, and the original evidence is retained (`name`,
`stage`, `causes`, browser stack, cleanup errors, ordered INFO/TEXT). Direct
WebUSB failures keep the DOMException name/message/stack rather than
re-describing it. `sessionRetired` is a lifecycle bit, independent of blame and
never inferred from an error name.

In the browser, the page opens the Chromium WebUSB chooser from a user gesture
only in a secure context; it filters on the fastboot interface `ff/42/03` and
passes only the chosen serial to the worker. The worker never opens a chooser:
it lists granted devices, reopens that exact serial, and asks the page to
regrant the same phone after a mode change. Native discovery matches the same
interface from USB descriptors.

Browser hardware qualification is still pending. The synthetic responder
exercises NEO8 streaming, sparse splitting, reconnects and uncertain stops, but
it is not real USB or partition-readback qualification. Physical writes were
not authorized for this work.
