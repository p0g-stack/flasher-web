# flasher_web

Build OnePlus flasher packages from full OTAs, then flash finished jobs from
the browser or CLI: a port of
[koaaN/Flasher_Builder](https://github.com/koaaN/Flasher_Builder). Choose a
device, flasher type and region, provide a full OTA (a local ZIP or catalog
version), and build the same ZIP or folder the desktop app builds. Nothing is
uploaded; catalog OTAs are read in place by HTTP ranges, not downloaded in full.

Upstream stays the source of truth for device tables, flasher templates,
Platform-Tools and the bloat manifest; `upstream.lock` pins its commit and
`tool/sync_upstream.dart` writes the snapshot into `app/web/upstream/`.
Design: [docs/design.md](docs/design.md); service contract:
[docs/service.md](docs/service.md).

## Layout

| Package | What | Runs on |
|---|---|---|
| `core/` (`flasher_web_core`) | build and flash service, plans, storage, catalog, upstream tables, facts and strategies | plain Dart; never imports `package:flutter` |
| `app/` (`flasher_web`) | build + flash UI; page owns permission choosers, Squadron worker owns execution | Flutter web |
| `cli/` (`flasher_web_cli`) | `build`, `inspect`, `bloat`, `devices`, `flash`, `facts`, `serve` | `dart run` / `dart compile exe` |
| `packages/device_link/` | reusable pure-Dart transport/session interfaces and failure evidence | Dart, no Flutter or frb dependency |
| `rust/` | app frb library: synchronous compute and asynchronous fastboot transport adapters | native and single-threaded wasm |
| `rust/crates/ota-payload/` | reusable full-OTA parsing, operation decoding and SHA-256 compute; otaripper/AOSP provenance | native and wasm, no frb or I/O |
| `rust/crates/fastboot-link/` | reusable USB discovery, serial-bound sessions and streaming fastboot | native nusb / browser WebUSB, no frb |
| `worker/` | Cloudflare Worker: static site plus `/api/catalog`, `/api/resolve`, `/api/ota`, `/api/bloat` | Cloudflare Workers (`wrangler dev` locally) |

## Start

Needs Flutter 3.47.5, flutter_p0g with its patched frb
(`flutter_p0g precache --frb`), cargo with `wasm32-unknown-unknown`, and Node.

```sh
PLATFORMS=web bash tool/bootstrap.sh       # upstream snapshot, codegen, Rust + wasm, workers
dart analyze --fatal-infos
(cd core && dart test) && (cd cli && dart test) && (cd app && flutter test)
(cd rust && cargo test --workspace) && (cd worker && npm install && npx vitest run)
(cd app && flutter_p0g build web --release)
(cd worker && npx wrangler dev --port 8787)  # open http://127.0.0.1:8787
```

The CLI builds natively with the same pipeline:

```sh
dart run cli/bin/flasher_web.dart bloat --device 'Oneplus 13' --kind 'SuperHybrid Flasher' \
  --region GLO --bloat-dir /path/to/bloat --api-base http://127.0.0.1:8787 --upstream app/web/upstream
dart run cli/bin/flasher_web.dart build --device 'Oneplus 13' --kind 'SuperHybrid Flasher' \
  --region GLO --ota /path/to/FULL-OTA.zip --bloat-dir /path/to/bloat --output /path/to/builds \
  --upstream app/web/upstream
```

List native fastboot devices, then prepare a finished job without writing:

```sh
dart run cli/bin/flasher_web.dart devices
dart run cli/bin/flasher_web.dart flash --output /path/to/builds --job JOB \
  --device 'Oneplus 13' --kind 'SuperHybrid Flasher' --region GLO \
  --serial SERIAL --upstream app/web/upstream
```

The read-only invocation prints the plan and exits with code 2. Supply each
required choice using repeated `--answer id=value` flags, then rerun with
`--confirm-serial SERIAL` matching the connected serial exactly to authorize
writes. Unknown product mappings require `--answer product=VERIFIED_PRODUCT`;
verify the selected model and the reported product yourself. Do not guess
answers or confirm a different phone.

## In the browser

- Chromium can keep bloat and packages in a folder you pick (File System
  Access). Other browsers use origin-private storage (OPFS) and download the
  finished ZIP; ask for persistent storage on the Environment page.
- Allow working space for extracted images and the finished package; capacity
  preflight uses a conservative estimate from decoded partition sizes.
  `super.img` is streamed into ZIP output rather than stored separately.
  The Environment page shows the browser's quota, not a picked drive's space.
- Browser quota applies only to OPFS. Picking an output folder does not use
  that quota; browsers cannot report that folder's free disk space, so it is
  shown as unknown and filesystem writes can still fail if its drive fills.
  Choose a bloat folder too if its cache will not fit in browser storage.
  Persistence or PWA installation is not a quota increase in Chromium.
- Catalog versions are streamed through `/api/ota`, a range proxy limited to
  the OTA CDNs; signed links are resolved again when they expire.
- Keep the tab open during a build; the app holds a wake lock and warns before
  leaving.
- Open Flash from a finished build or history entry. In the browser, flashing
  requires current Chrome, Edge or Chromium on HTTPS or localhost, outside an
  embedded webview. The page opens the WebUSB chooser from your click, filtered
  to fastboot interface `ff/42/03`; only its serial crosses to the service,
  which reopens the exact granted device in its own worker.
- Read-only preparation checks product, mode, package and image hashes. Review
  every prompt and acknowledge the exact serial before writing; the CLI
  repeats it with `--confirm-serial`. Changes to the job, device, product or
  answers invalidate confirmation.
- Downloads respect `max-download-size` and split oversized images into sparse
  parts preserving partition offsets. Reconnects pin the serial and recheck
  product/mode; regrant the same phone when the app asks after a mode change.
- Failure stops the plan; uncertain writes are never retried automatically.
  Cancel stops future commands and waits for the worker to stop in-flight work,
  not a rollback. Manual data formatting and actual rooting remain your tasks.
- Receipts can be downloaded and are saved in the job when storage permits.
  Fastboot OKAY is not readback verification; Android mode after the final
  reboot is unverified. Browser hardware qualification is still pending.
  Synthetic responder evidence covers streaming, sparse splitting, reconnects
  and failure/uncertainty handling, not real USB or partition readback.

Generated by the `p0g_app` brick (p0g-stack/bricks); the conventions below
come from it.

## Conventions

- **One CLI.** `cli/` is this app's only command line, compiled per OS and
  ABI. Rust crates are used through frb inside it (and the app), never
  shipped as a separate binary with its own CLI.

- **Places.** A service is a Squadron service in `core/lib/src/service/`. It
  runs in Squadron's own place (an isolate, a Web Worker) or in the process
  place: this app's CLI in `serve` mode (hosting every service), through
  squadron_process, started by a launcher (`P0G_CLI` on a desktop,
  flutter-webui's root channel on WebUI, see
  `core/lib/src/places/webui_launcher.dart`). The app binds each worker to
  the place the user picked.
- **Facts.** `core/lib/src/facts/` owns the fact keys and the checks that
  decide them (`check_io.dart`, `check_web.dart`). Each place runs the check
  where it is, so the page and the root process report different facts.
- **Strategies.** An `Objective` holds strategies in preference order; the
  first whose `available(facts)` holds runs. Never decide with `kIsWeb` or
  `Platform`: WebUI says web, AERA says Linux, neither says root.
  `dart analyze` warns (p0g_lints `strategy_reads_platform`), as it does for
  Flutter imports in core (`core_imports_flutter`).
  Host-versus-device choices are strategies of one objective.
- **Device writes.** A `WriteStrategy` plans first (no side effects); the UI or
  CLI shows the steps and makes a `Confirmation`; `Objective.apply` writes
  and returns a `Receipt`.
- **Logging.** `package:logging`. Every objective run logs a `StrategyRun`
  (objective, strategy, place, facts, why, outcome, time) on
  `objective.<name>`. The CLI prints records to stderr (`-v`, `--json`); the
  app shows them. Records logged inside a worker stay in that worker (or the
  host's stderr), so the app also logs at the call site.
- **Adding code.** `mason make service` and `mason make strategy` from this
  folder; they insert themselves at the `// p0g:` markers.
- **Rust.** `rust/` is a library used through frb, never a binary.
  Bootstrap runs `flutter_rust_bridge_codegen generate` (bindings in
  `core/lib/src/rust/`) and `cargo build`. Compute bindings are synchronous
  (`default_dart_async: false`) inside the calling Squadron service worker;
  fastboot bindings are asynchronous so USB awaits do not block that worker.
  Each place loads the library itself (`loadNative()`); this is the `native`
  fact. `FlasherService` loads it before Rust work. USB belongs to
  `fastboot-link`, not `squadron_process`; the process package only carries
  service calls. Published `nusb` 0.2.9 and `fastboot-protocol` 0.4.0 are used;
  no fork rebase was performed for this work.
- **Patched Squadron.** squadron_process needs Squadron with its
  channel-factory patch; bootstrap runs `squadron_process:squadron_patch`,
  which puts it under `.dart_tool/` and writes `pubspec_overrides.yaml`.
