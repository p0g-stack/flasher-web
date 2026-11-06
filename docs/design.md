# flasher_web design

A browser port of [koaaN/Flasher_Builder](https://github.com/koaaN/Flasher_Builder):
choose a device, flasher type and region, provide a full OTA, and build the
same flasher package the desktop app builds — in the tab, with no server-side
build. Upstream stays the source of truth for the device tables, flasher
templates, Platform-Tools and the bloat manifest; this app pins a commit of it.

## Pieces

| Piece | Where | Role |
|---|---|---|
| Rust library | `rust/` (frb, single-threaded wasm + native) | Pure, synchronous compute: ZIP reading, payload manifest and operation decoding (an otaripper port), ARB scan, SHA-256, gzip, sparse images, LP super metadata, vbmeta, streaming ZIP writing. No I/O. |
| Core | `core/` (pure Dart) | Upstream tables and selection rules, storage interfaces, the build pipeline as a service stream, catalog client, bloat materializer. Drives I/O and calls Rust. |
| CLI | `cli/` | `flasher_web build …` runs the same pipeline natively (dart:io + the native library). Parity tests compare it with upstream's Python pipeline. |
| App | `app/` (Flutter web) | The UI. Runs the service in a Squadron Web Worker. |
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

## Rust API (frb, `rust/src/api/`)

All functions are `#[frb(sync)]` and pure. Byte buffers are `Vec<u8>` in and out.

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
8. Package: ZIP (+ `.sha256`) or folder; `build.json` with upstream's fields plus `ota_access`, `arb`, `extracted_sha256`.

Progress is a `Stream<BuildEvent>` (step 1–5 like upstream's `STEP n/5`, log lines, byte progress, result).
Cancelling the subscription stops the job and removes the job folder, as upstream does.
