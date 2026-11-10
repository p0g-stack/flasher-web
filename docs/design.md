# flasher_web design

A browser and CLI port of
[koaaN/Flasher_Builder](https://github.com/koaaN/Flasher_Builder). The user
picks a device, flasher type and region, verifies the bloat images the flasher
template needs, and points at one full OTA — a local ZIP read in place, or a
catalog version read through HTTP ranges. Two actions consume the same inputs
and produce the same images:

- **Flash directly**: the package is written to the phone over fastboot.
- **Export ZIP**: the package is streamed into one ZIP at a destination the
  user picks (a file handle, the service worker's download, or a path).

There is no staged build: nothing derived from the OTA is written to storage
before it is flashed or exported, and a flash leaves only a receipt.

## Pieces

| Piece | Where | Role |
|---|---|---|
| App Rust library | `rust/` (frb) | Thin surface over the reusable crates: synchronous, pure compute calls, plus asynchronous fastboot transport calls. No USB state machine or Dart policy here. |
| Reusable payload crate | `rust/crates/ota-payload/` | I/O-free parsing and operation decoding for Android update payloads, plus SHA-256. Port of otaripper and the upstream Python full-OTA check; builds for native and wasm. |
| Reusable fastboot crate | `rust/crates/fastboot-link/` | Discovery, exclusive serial selection, the fastboot state machine and streaming downloads over native nusb or browser WebUSB. No frb or Dart dependency. |
| Dart link package | `packages/device_link/` | Pure-Dart transport/session interfaces, device and failure records. No I/O, Flutter or frb dependency. |
| Core | `core/` (pure Dart) | Upstream tables and selection rules, storage interfaces, the virtual package, flash plans, preparation and execution, bloat and OTA cache stores, catalog client. Drives I/O and calls Rust. |
| CLI | `cli/` | `flasher_web flash`, `export`, `bloat`, `devices`, `facts` and `serve`, running the same service natively (dart:io + the native library). |
| App | `app/` (Flutter web) | The setup, flash, environment and documentation pages, and the app's service worker. The page owns permission choosers; the service runs in a Squadron Web Worker. |
| Edge worker | `worker/` (Cloudflare Workers) | Serves `app/build/web` and the same-origin `/api/*` routes the browser cannot do itself (CORS). Local: `wrangler dev`. |
| Upstream sync | `tool/sync_upstream.dart` | Fetches the pinned upstream commit and writes `app/web/upstream/` (gitignored). |
| Carried patches | `third_party/<name>/` + `tool/third_party.dart` | A `PIN` (repo, commit, package) plus a `git format-patch` series per carried package: bootstrap checks the commit out under `.dart_tool/` (gitignored), applies the series and overrides the package in `pubspec_overrides.yaml`. Carries the web picker's file system access dialog. |

## Upstream snapshot (`app/web/upstream/`, served as static files)

Pinned in `upstream.lock` (repository + commit `bdea12a`). Produced by
`dart run tool/sync_upstream.dart`, which bootstrap runs.

- `tables.json` — parsed from `.github/workflows/build_tools.yml` exactly like
  `backend.Catalog`:
  `{"commit": "...", "devices": {"Oneplus 13": "13", ...}, "region_sizes": {"13": [cn, other], ...}, "builders": [["SuperHybrid Flasher", "13", "GLO", "BUILD_SUPER.sh"], ...]}`
- `bloat-manifest.json` — copy of `bloat/assets-manifest.json`.
- `templates/<dev>.zip` — `flasher_scripts/<dev>/**` with paths relative to
  `flasher_scripts/<dev>/`, Unix modes kept in external attributes.
- `platform-tools.zip` — `Platform-Tools/**`, paths relative to
  `Platform-Tools/`.
- `README.md` — upstream README (Documentation page).

## Network routes (edge worker, same origin)

| Route | Behaviour |
|---|---|
| `GET /api/catalog?na=0\|1` | Proxy `https://roms.danielspringer.at/api/ota.php` (or `/api/na.php`), passing `If-None-Match`/`ETag`; cache 15 min. |
| `POST /api/resolve` body = catalog release entry JSON | Port of `ota_catalog.resolve_link`; returns `{"url": "..."}` (a fresh signed link). Never cached or logged. |
| `GET\|HEAD /api/ota?u=<url>` | Range proxy for a resolved OTA link. Allowlisted hosts only (`*.allawnofs.com`, `*.allawnos.com`, `roms.danielspringer.at/download.php`, `*.oneplus.com`, `*.oppo.com`, `*.coloros.com`); `Range` required; passes 206/Content-Range/Content-Length; adds upstream's OTA request headers. |
| `GET /api/bloat/<asset_name>` | Proxy `https://github.com/koaaN/Flasher_Builder/releases/download/bloat-assets-v1/<asset_name>` (following the redirect); `Range` passed through. Asset names validated against `[A-Za-z0-9._-]+`. |

The worker never sees OTA or bloat bytes at rest; it streams them. Everything
else on the origin is served by the static asset binding, and the app's own
service worker serves the page shell and the streamed export download
(`download/<id>`, described below).

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

Implementations: `dart:io` (CLI, desktop, tests); web
`FileSystemDirectoryHandle` for both OPFS (`navigator.storage.getDirectory()`)
and a picked folder (File System Access, Chromium); web `Blob`/`File` source;
HTTP range source (`fetch` on web, `HttpClient` on io). Paths are
`/`-separated and relative.

A service store is one of `{"kind": "directory", "handle": …}` (a folder the
user picked), `{"kind": "opfs"}` or `{"kind": "path", "path": …}` (VM). The
bloat store is the only workspace the app writes: verified bloat images at
their manifest paths (minus `bloat/`), plus `ota-cache/` when a catalog OTA is
kept offline.

Exports do not use a workspace at all. The destination is the save picker's
`FileSystemFileHandle`, `{"kind": "stream", "id", "channel"}` for the service
worker download, or `{"kind": "path", "path"}` on the VM; each is opened as a
`ByteSink` and the ZIP is written through it.

### App storage cap

`core/lib/src/storage/budget.dart` holds one self-imposed ceiling,
`appStorageCapBytes` = 10 GiB, because the browser keeps a bounded working set
in the origin's storage: verified bloat (at most about 1.72 GiB raw), the
optional catalog OTA cache, small metadata and the service-worker shell. Local
OTA files are read in place and cost nothing.

`StorageBudget.ensure(bytes)` compares the planned increase with
`min(cap - usage, quota - usage)` and, when short, asks an evictor to free the
shortfall (the OTA cache's least-recently-used entries) and re-reads the
estimate, with a bounded number of passes. A source that cannot measure
anything yields an unknown estimate, so the cap is the only limit and the
shortfall is reported rather than guessed. `BudgetException` names `needed`,
`available`, `cap`, `usage` and `quota`.

For a picked bloat folder the browser cannot measure free disk space, so the
store uses an unknown estimate: only the app cap applies, not the origin quota.

### Catalog OTA cache (`storage/ota_cache.dart`)

Optional and disposable. Per catalog entry: `ota-cache/<digest>.json` (the
inventory: label, catalog size, ETag, bytes written, complete flag, full-file
SHA-256, use timestamps), `<digest>.downloadx.part` while downloading, `<digest>.zip`
when complete, and `<digest>.downloadx.json`, the chunk layout of the
[`downloadx`](https://pub.dev/packages/downloadx) engine. `<digest>` is a
canonical digest of the catalog entry with signed-URL query strings and ranking
hints removed, so two releases never share a key.

A download fetches 8 ranges of 8 MiB at once through `/api/ota` and writes
them positionally; downloadx splits slow ranges so fast connections keep
working. Every response must carry exactly the requested `Content-Range` and
the same strong ETag, and the length is pinned to the catalog size, so a server
that changed the file is refused, not mixed in. An expired signed link is
resolved once for all connections. The chunk layout is written only after its
bytes are flushed (every 8 MiB in OPFS or a folder, every 512 MiB in a file
picked with the save picker, where each flush copies the file), so a cancel,
crash or reload resumes with only the missing ranges. Before resuming, every
recorded range must still be inside the file; a shorter file restarts from
zero. A server without a strong ETag gets one connection and no resume across
sessions. The full-file SHA-256 is read back once at the end. A complete cache
hit is transparent — same catalog identity, same archive — and payload
operation hashes are still checked while it is read, so a corrupt cache cannot
corrupt a flash. A cache that cannot be read is a miss and the OTA streams
instead.

**Download OTA → This computer** uses the same engine into the file the save
picker returned. The page remembers that file handle before the first byte, as
a `file_picker` token in `shared_preferences` (the patched `file_picker_web`
keeps the handle itself in IndexedDB); a save that stops offers **Resume save**
after a reload, which renews the handle's `readwrite` permission and fetches
only the missing ranges into the same file. Picking the file again cannot
resume: Chromium truncates an existing file chosen in the
save picker. On Android Chrome, which has no save picker, the OTA streams to the
browser's downloads in file order with 8 ranges in flight (at most 64 MiB
buffered); that download is faster but cannot resume.

Through the local proxy on one 5.3 GB OTA (256 MiB measured, including link
resolution and the final hash): one connection 9.3 MiB/s, eight 47.6 MiB/s.
A process killed after 64 MiB resumed by fetching exactly the 192 MiB missing.

## The virtual package (one pass)

`core/lib/src/flash/virtual.dart` implements `FlashPackage` over full OTAs and
the verified bloat store, so `planFlash`, `prepareFlash` and the executor run
unchanged and nothing is extracted to a file.

`VirtualFlashPackage.load` supports all four flasher kinds (Regional,
RegionalHybrid, Super, SuperHybrid) and refuses anything else. It:

1. Validates every OTA it was given with `verifyVirtualReads` (Rust
   `verify_virtual`): a full payload whose non-ZERO operations each carry a
   32-byte data SHA-256 and stay under the operation-size limit. A streamed
   OTA that cannot be read in place is refused with that reason.
2. Verifies every selected bloat image against `bloat-manifest.json` (size and
   raw SHA-256) before the package exists.
3. Builds the entry set `native_pipeline.stage` would produce: the bloat images
   in their folders, then the OTA's partitions as `<imageFolder>/<name>.img`.
   A decoded OTA image replaces a staged bloat copy at the same path; X9U keeps
   its bloat image and drops the OTA copy. For CN, `GLO_BLOAT` goes to
   `OOS_FILES_HERE` and every other non-main folder to `COS_FILES_HERE`. Every
   OTA partition must carry a whole-image manifest SHA-256, or the package is
   refused.
4. Applies the per-device rules: the Ace 6 OxygenOS conversion stages
   `targetParts` from the TARGET OTA and `baseParts` from BASE, regenerates the
   three `vbmeta` images from BASE with `make_vbmeta`, and requires
   `virtual.base`; the Ace 6T IN/GLO ODM donor is selected from the catalog by
   matching security patch (a caller donor is refused); X9U requires the
   `vulnerableAbl` choice, and `true` needs the verified bloat ABL 16.0.6
   (SHA-256 `4ad7f1db…`), recorded as `abl_source`; X9U also packages
   `META-INF/com/google/android/super-size`.

The `build.json`-shaped map (`output_format: "virtual"`) carries device, dev,
flasher_type, region, version, ARB, `vulnerableAbl`, `abl_source` and
`image_sha256` — every package image plus the `Super/<name>.img` inputs of a
super. A super's own digest is added to `receipt()` once it has streamed
completely. `virtualJobId` derives `virtual-<16 hex>` from the OTA source
identity, manifest digest, OTA length and selection; `snapshot()` exposes the
same data, so `packageDigest` binds a confirmation token to the exact OTA,
BASE, donor and bloat bytes.

### Reading an OTA

`core/lib/src/flash/ota_source.dart` implements `FlashSource` over a payload.
`OtaPartitionSource` maps a partition's destination extents — sorted, tiling
the image, independent of operation order and of how many extents one
operation owns — to the operations that fill them, and decodes an operation on
demand through Rust `decode_operation`, which checks its data SHA-256 before
returning bytes. `OtaOperationCache` is one package-wide LRU of decoded
operations capped at 64 MiB, counting operations still decoding ahead of the
reader; an operation that needs more, or that has no hash, is refused while the
source is built. `RandomFlashCursor` gives the executor the forward-only reads
and skips the sparse split needs.

Reads in destination order keep a window of operations in flight: adjacent
operations' payload data is fetched in one range of up to 8 MiB, and the
package's `OpDecoder` decodes them. Each virtual package owns a
`PoolOpDecoder`: `PayloadDecoder` workers (`service/decoder_service.dart`,
isolates on the VM, Web Workers nested in the service worker on the web), one
per core but one, at most 8, each with its own Rust library. They start on the
package's first decode, so a preparation that reads only metadata starts none,
and stop when the package closes. A place that cannot start them decodes
inline. The window holds two operations per worker,
so several range requests are in flight for a catalog OTA. Measured on the
real CPH2745 16.0.9.400 `my_stock` (2972 MiB, 1323 XZ operations), streaming
and hashing the image:

| Place | Inline | Pool (8 workers) |
|---|---|---|
| Chrome, local file | 66.5 s (45 MiB/s) | 13.1 s (227 MiB/s) |
| Dart VM, local file | 50.3 s (59 MiB/s) | 9.1 s (326 MiB/s) |

Through the local `/api/ota` proxy, one 2 MiB range at a time read 12 MiB/s;
four 8 MiB ranges at once read 118 MiB/s.

An OTA input is one of:

- `{"kind": "file", "file": <web File | io path>}` — read in place.
- `{"kind": "url", "url": …}` — HTTP ranges, direct on the VM and through
  `/api/ota` in the browser (a browser needs the proxy for CORS and CDN
  headers; the VM sends OnePlus's OTA headers itself).
- `{"kind": "catalog", "entry": <release>}` — a complete cache hit is used,
  otherwise `/api/resolve` supplies a signed link that is resolved again when
  it expires, and the catalog's declared size must equal the observed length.

Only ZIP metadata, `META-INF/com/android/metadata` and the payload manifest are
read before streaming; each image's bytes are verified against its partition
SHA-256 as they are consumed.

### `super.img`

`core/lib/src/flash/virtual_super.dart` produces one root `super.img` for a
Super kind. `flasherSuperLayout` is the LP geometry the normal packer writes
(`super_layout`: 64 KiB metadata, three slots, virtual AB, 1 MiB alignment,
`qti_dynamic_partitions_a/b` at `size - 4 MiB`), and the extents it returns
place every partition.

The sparse image is built from that layout alone: RAW chunks for image bytes
and DONT_CARE chunks for every gap — alignment padding, unused group space and
the tail after the last extent — with **no FILL detection**. Every sparse
piece's size therefore comes from the LP layout and is known before any image
byte is read; opening the super reads no OTA data. Inputs are bounded reads of
at most 8 MiB, and a sparse input bloat file is expanded lazily first. Raw
super inputs are checked against their manifest SHA-256 as they stream, and the
digest of the complete encoded super is computed in the same pass.

DONT_CARE costs a little more than the FILL form the desktop packer writes:
measured on the owner's real CPH2645 16.0.3.500 OTA, 29.5 MiB on an 8.75 GiB
super, about +0.33 %. The bootloader expands sparse chunks into raw partition data.

## Export ZIP

`core/lib/src/flash/virtual_export.dart` (`exportVirtualZip`) streams the tree
the desktop packer would produce into a ZIP64 through the same Rust `ZipWriter`
(deflate level 1, data descriptors, `create_system = 3`, Unix modes kept).
Level 1 rather than 3: on a real OnePlus `my_stock` image the wasm encoder runs
at 170 MiB/s instead of 42 MiB/s, for 0.873 instead of 0.860 of the input size.
`updater-script` and `*.sh` line endings are normalized, and Platform-Tools
files override same-named template files. The archive's SHA-256 and each
image's digest are computed while the bytes are written; the checksum and the
`build.json`-shaped receipt are returned rather than stored. No temporary file
and no workspace are used.

The destination decides where the bytes go (`storage/export_sink*.dart`):

- a `FileSystemFileHandle` from `showSaveFilePicker` — written positionally
  through `HandleSink`;
- `{"kind": "stream", "id", "channel"}` — the service worker's download.
  `ExportStreamSink` posts each chunk over a `BroadcastChannel` only after the
  download granted credit for it (1 MiB per pull), so the export never runs
  ahead of the file the browser is writing and no copy lands in origin
  storage. Writes must be sequential and `truncate` must equal the bytes
  written; `close` ends the download when the lengths agree and errors it
  otherwise. A `cancel` message from the download (the user stopped it) raises
  `CancelledException`.
- `{"kind": "path", "path"}` — a `dart:io` file for the CLI.

On the web the page registers a one-use download with the service worker
(`flasher-export-register` → id + channel + suggested name) and navigates a
hidden frame to `download/<id>`; the worker answers with
`Content-Disposition: attachment` and a `no-store` body. Registrations expire
after two minutes and are consumed by one download. If the export fails or the
page closes mid-stream, the page sends `flasher-export-abort` so the browser
drops the partial file instead of saving a broken ZIP.

## Flashing the virtual package

### Read-only preparation

`prepareFlash` binds the request, the device and every answer before a single
device write:

1. Rejects a selection that does not match `build.json`'s device, flasher type
   and region, or a package whose `output_format` disagrees with its format;
   warns when the package has no whole-image SHA-256 map or is marked
   `test_fixture`.
2. Requires the exact serial in the granted list, opens only that serial, and
   reads product, mode and `max-download-size` with `getvar`. Preparation sends
   no write command.
3. Resolves the template prompts. A prompt with a default is preselected; a
   prompt without one stays unanswered, and until an explicit answer arrives
   the result has `resolved: false` and an empty `token`.
4. When the device table has no confirmed product mapping, returns
   `productRequired` with the observed product instead of a token. The user
   must verify the selected model and pass that product explicitly.
5. Inspects every image a `Flash` step would send. For the virtual package this
   reads no OTA or super bytes: the size, sparse geometry, part count and
   digest come from the manifest and the LP layout, and bloat images are
   hashed when the package is opened. From those it also checks the target
   partitions' `getvar` sizes once the plan is resolved.

A resolved preparation returns a random 32-byte token. It is kept in the
service, never written to storage, is consumed by the first flash attempt, and
binds the selection, job, serial, answers, `upstreamBase`, bloat-store identity
and the package's canonical snapshot digest. The token is the only accepted
confirmation input (`confirmationToken`); a new preparation replaces every
earlier one, and a changed OTA, BASE, donor or bloat makes it stale.

### Execution

`flash` consumes the token, rechecks the request against its binding, reopens
the package, compares the snapshot digest, and takes the job lock. Execution
starts in the normal bootloader, rechecks product and `max-download-size`, then
follows the plan's expanded steps. It stops at the first failure.

Downloads are streamed in pieces of at most 1 MiB and split at the device's
`max-download-size`:

- a sparse image is split at chunk boundaries; every part repeats the original
  block geometry and starts with a DONT_CARE chunk for blocks already sent, so
  all parts write the same partition offsets;
- an oversized raw image is converted into sparse parts only when its length is
  a multiple of 4096 bytes;
- in fastbootd, a reconstructed logical partition is resized before flashing.

After a reboot it waits only for the confirmed serial, opens that exact device,
and requires both the expected product and fastboot mode before the next
command; the wait is bounded (180 s, polled every second). If the final reboot
is reached, it closes the fastboot session and reports Android mode as
`android (unverified)`.

The plan never sends a wipe or root command. Formatting data and rooting stay
manual on the phone; the plan only carries the instruction or the
prepare-root/flash-signal choice.

### Failure, retry and stop

A failure emits `{"type": "failure", "stepIndex", "status", "reason"}` with the
0-based index of the failed execution step and continues with a `result`
carrying `canRetry`. Nothing is resent automatically. The page shows the failed
step and offers three explicit actions, all addressed by `runId`:

- `retryStep({runId})` resends the failed step from byte zero and continues
  with the following steps;
- `rebootRetry({runId})` reboots to the mode the failed step requires
  (`reboot-bootloader` or `reboot-fastboot`), waits for that mode, then
  resends the failed step;
- `stopRun({runId})` stops future commands, waits for the in-flight one, and
  returns the receipt as `stopped`. It is not a rollback: commands already sent
  stay applied, and an in-flight write may leave the phone partially written.

A retry reopens the confirmed serial, rechecks product and mode (and the
package size), and keeps the earlier steps and writes in the receipt. A retry
that fails its own checks stays pausable and reports the reason instead of
closing the run. Serial, product and mode are checked again after a retried
step succeeds, before continuing. A write whose completion is unknown marks the receipt
`uncertain`; a complete device FAIL is a definite refusal. The session retires
on transport or protocol failure, independently of the public blame.

### Receipt

The result carries a receipt with status, `runId`, job, device, kind, region,
serial, OTA version, ARB index, the package map (`image_sha256` including
`super.img` and the super inputs, `vulnerableAbl`, `abl_source`), the step list
with per-step status, writes (image, partition, bytes, parts, part index),
start and end modes, expected and observed product, `max-download-size`,
failure evidence with its step, uncertainty, cleanup errors, timestamps and the
strategy that ran, plus the virtual snapshot. Verification is `unverified`:
fastboot `OKAY` is not a readback hash. The receipt is the only record; the
page downloads it as JSON and the CLI writes it as a file.

## Compute and transport (frb, `rust/src/api/`)

Compute functions are `#[frb(sync)]` and pure, so a call runs inside the
Squadron worker that makes it. Byte buffers are `Vec<u8>` in and out. The
fastboot functions in `api/fastboot.rs` are asynchronous because they await USB
I/O; they only hold session handles and convert typed failures for Dart.

The reusable crates own their concerns:

- `ota-payload` parses `CrAU` headers/manifests, decodes operations and hashes
  bytes. Callers pass the bytes they already read; it does no I/O and has no
  frb dependency. Gzip stream decoding stays app-local.
- `fastboot-link` owns discovery (`ff/42/03`), exact-serial open, alternate and
  bulk-endpoint selection, Web Locks (`flasher-web-fastboot:{serial}:{interface}`),
  bounded awaits, the fastboot state machine and the per-session mutex. Native
  and browser both use nusb's device/interface/endpoint surface; the browser
  selects from complete configuration descriptors after opening, not the
  potentially empty pre-open `DeviceInfo::interfaces()` list.
  `rust/Cargo.toml` pins nusb to revision `84890ce` of our
  `https://github.com/p0g-stack/nusb` fork, with owned browser error evidence,
  endpoint rejection evidence and shared open leases. That pin becomes a plain
  version bump to the released minimum once nusb ships those APIs. Published
  `fastboot-protocol` 0.4.0 supplies the response parser and command type. Owned
  chunks move into nusb buffers without a Rust-side copy; nusb owns WebUSB's
  required JS-buffer copy.
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
  `ZipDirectory { needs: Option<(u64,u64)>, entries: Vec<ZipEntry> }` — call it with the last
  `min(file_len, 65557 + 20 + 56)` bytes; when the central directory is not inside the tail,
  `needs` gives the absolute range to read and pass to `zip_parse_central(cd: Vec<u8>)`.
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
  and incomplete partitions); `verify_virtual(max_operation_bytes)` adds the in-place rules on top: every
  non-ZERO operation carries a 32-byte data SHA-256 and neither its encoded nor its decoded size exceeds the
  limit. Opaque `Sha256Hasher { new, update, update_zeros(n), finish_hex }`.
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
  `write(data) -> Vec<u8>`, `finish_file() -> Result<Vec<u8>>` (whose image digest is readable through
  `finished_image_sha256()`), `finish() -> Result<Vec<u8>>`; ZIP64 throughout, deflate level 1, data
  descriptors, `create_system = 3`.

The wasm build of `fastboot-link` needs `--cfg=web_sys_unstable_apis`; the root
`.cargo/config.toml` sets it for `wasm32-unknown-unknown` only, because
`rust/.cargo/config.toml` is rewritten by `tool/rust.sh`.

## Browser runtime

The page delegates WebUSB capability, grants and DOMException handling to the
pure-Dart `packages/web_usb_grant` package (`package:web` + `dart:js_interop`,
including Wasm; no Flutter dependency). The app invokes its chooser from the
user's click, keeps the fastboot interface `ff/42/03` filter, requires a serial,
and passes only that serial to the Squadron worker. The worker never opens a
chooser: it lists granted devices, reopens that exact serial, and asks the page
to regrant the same phone after a mode change. Native discovery matches the same
interface from USB descriptors. Tests inject a `UsbBackend`; the e2e build
selects the fake at bridge creation, not inside the production chooser.

The page holds a screen wake lock and a leave guard for the duration of a
flash, a bloat download or an export. The browser drops the wake lock while the
tab is hidden; the page takes it again when the tab is visible and the work
still runs. The app's service worker caches only the
shell and engine assets the page loads; `/api/*` and every request that carries
a `Range` header go to the network, and OTA, bloat and package bytes are never
cached.

## Tests and qualification

- `core/test/` covers the virtual package and super (sparse parity against an
  independent layout construction, DONT_CARE tail, streaming digests, mutation
  refusals), the OTA part source, preparation, the executor (splitting,
  reconnects, uncertain writes, explicit retries), the export stream, the OTA
  cache, the storage budget, upstream tables and the catalog.
- `app/test/` drives the pages with a fake bridge and a fake fastboot transport.
- `cli/test/` covers the request builders, exit codes and the retry lifecycle.
- `worker/test/` covers the range proxy and the other `/api/*` routes.
- `rust/` tests the crates and the frb surface.

Real OTA flashing on a real phone remains unqualified: the tests use a fake
fastboot transport and synthetic OTAs, and compare the written bytes with the
exported ZIP and the expected images rather than with a device.

