# flasher-web

Flash a OnePlus full OTA straight to a phone over fastboot, or save the same
package as one ZIP: a port of
[koaaN/Flasher_Builder](https://github.com/koaaN/Flasher_Builder) that reads
the OTA where it is instead of building an intermediate package. Choose a
device, flasher type and region, verify the bloat images the flasher template
needs, then pick one full OTA (a local ZIP or a catalog version).

Both actions take the same inputs and produce the same images:

- **Flash directly** — images from the OTA and verified bloat are streamed to
  the phone over fastboot in the template's order. No OTA-derived file is stored.
- **Export ZIP** — the same package is streamed into one ZIP on the machine
  that runs the app. Nothing is staged in browser storage.

Upstream stays the source of truth for device tables, flasher templates,
Platform-Tools and the bloat manifest. `upstream.lock` pins its commit
(`bdea12a`) and `tool/sync_upstream.dart` writes the snapshot into
`app/web/upstream/`.

Clients: desktop Chrome and Edge, Android Chrome, and the Dart CLI (both
actions, native USB and a file destination). Firefox, Safari and browsers with
Brave's default shields are not targeted.

Design: [docs/design.md](docs/design.md). Service contract:
[docs/service.md](docs/service.md).

## Layout

| Package | What | Runs on |
|---|---|---|
| `core/` (`flasher_web_core`) | the virtual package, flash plans, preparation and execution, the bloat store and the block OTA reader, catalog client, upstream tables, facts and strategies | plain Dart; never imports `package:flutter` |
| `app/` (`flasher_web`) | the setup, flash, environment and documentation pages; the page owns permission choosers, a Squadron worker owns execution | Flutter web |
| `cli/` (`flasher_web_cli`) | `flash`, `export`, `bloat`, `devices`, `facts`, `serve` | `dart run` / `dart compile exe` |
| `packages/device_link/` | reusable pure-Dart transport/session interfaces and failure evidence | Dart, no Flutter or frb dependency |
| `rust/` | app frb library: synchronous compute and asynchronous fastboot transport adapters | native and single-threaded wasm |
| `rust/crates/ota-payload/` | reusable full-OTA parsing, operation decoding and SHA-256 compute; otaripper/AOSP provenance | native and wasm, no frb or I/O |
| `rust/crates/fastboot-link/` | reusable USB discovery, serial-bound sessions and streaming fastboot | native nusb / browser WebUSB, no frb |
| `worker/` | Cloudflare Worker: the static site plus `/api/catalog`, `/api/resolve`, `/api/manifest`, `/api/block`, `/api/bloat` | Cloudflare Workers (`wrangler dev` locally) |

This repository is Dart (with Flutter) and Rust. `worker/` is the one
exception: it is TypeScript, because Cloudflare Workers hosts the site and
`wrangler` (Node) builds, serves and deploys a Worker whatever language it is
written in. The Worker holds hosting code only: the static site, the catalog
proxy and the block cache. OTA decoding, verification, fastboot and ZIP
output stay in `core/` and `rust/`.

## Fastboot connection safety

Responsibility (`LinkBlame`: host, user, device, unknown) is independent of
the API in `source`. Access-denied and ownership evidence establish host
responsibility; a complete fastboot FAIL establishes a device refusal.
Timeouts, generic transfer errors, disconnects and malformed replies stay
unknown. Original errors, INFO/TEXT, cleanup errors and correlated disconnect
observations remain in logs/receipts. Discovery returns accessible devices
alongside per-grant `discoveryFailures`; one inaccessible grant cannot hide
the others.

The first read-only command on a new session has a **5-second absolute
deadline** (the research's 3–5-second candidate, allowing scheduling slack).
Later reads/download handshakes have **15 seconds without new INFO/TEXT**
and a **60-second absolute deadline**. Repeating an identical INFO/TEXT frame
does not renew progress. Each streamed data call is bounded to **15 seconds**.
Storage commands and the final download reply retain **180 seconds**, including
silent processing; INFO/TEXT cannot extend that absolute bound. Cleanup has
**2 seconds**. A failed transfer gets **100 ms** to correlate a matching USB
disconnect (Tango's race allowance); the original error is kept, never resent.

`probeFastbootConsistency` requires two identical complete OKAY answers each
for `max-download-size` and `is-userspace`. Preparation, the start of every
execution/retry (before even a recovery reboot), and each post-reboot reopen
run it before permitting writes. A complete refusal or disagreement retires
that connection with `InconsistentDeviceAnswers`; fully power-cycle the phone
and prepare again. Silence retains its transport failure instead of being
misreported as an inconsistent answer.

## Start

Needs Flutter 3.47.5, flutter_p0g with its patched frb
(`flutter_p0g precache --frb`), cargo with `wasm32-unknown-unknown`, and Node.

```sh
PLATFORMS=web bash tool/bootstrap.sh       # upstream snapshot, codegen, Rust + wasm, workers
dart analyze --fatal-infos
(cd core && dart test) && (cd cli && dart test) && (cd app && flutter test)
(cd rust && cargo test --workspace) && (cd worker && npm install && npx vitest run)
dart run e2e/bin/run.dart  # headless Chrome + CLI against a fake fastboot device; rebuilds app/build/web with FLASHER_FAKE_USB
(cd app && flutter_p0g build web --release)
(cd worker && npx wrangler dev --port 8787)  # open http://127.0.0.1:8787
```

Bootstrap also builds the native library, which the CLI and the Dart tests
load (`rust/target/release/libflasher_web_native.so` on Linux). The web build
needs `app/build/web`, which the `build web` step writes; the Worker serves it.

For UI work, run the page with hot reload against the same Worker:

```sh
(cd worker && npx wrangler dev --port 8787)   # /api/* for the page
(cd app && flutter run -d web-server --print-dtd)   # http://127.0.0.1:8780
```

`app/web_dev_config.yaml` fixes the port and forwards `/api/` to
`127.0.0.1:8787`. The dev server serves `app/web/` as it is: `r` reloads
widget code; after changing `core/` services run `bash tool/build_workers.sh`,
after changing `rust/src/api/` run `bash tool/rust.sh`, then `R` (hot
restart). The Rust wasm and the workers are never rebuilt by `flutter run`.
`--print-dtd` puts the app on Dart's tooling daemon, so the Dart MCP server
can reload and inspect it; without it, type `r` or `R` into `flutter run`.

## CLI

`cli/` runs the same service classes natively, so the CLI and the page share
one contract.

Download and verify the bloat images of a selection:

```sh
dart run cli/bin/flasher_web.dart bloat --device 'Oneplus 13' --kind 'SuperHybrid Flasher' \
  --region GLO --bloat-dir /path/to/bloat --api-base http://127.0.0.1:8787 \
  --upstream app/web/upstream
```

Flash a full OTA directly. Without `--confirm-serial` the command only prints
the read-only plan and exits with code 2:

```sh
dart run cli/bin/flasher_web.dart devices
dart run cli/bin/flasher_web.dart flash --device 'Oneplus 13' --kind 'SuperHybrid Flasher' \
  --region GLO --ota /path/to/FULL-OTA.zip --bloat-dir /path/to/bloat \
  --serial SERIAL --upstream app/web/upstream
```

Add `--catalog ID` instead of `--ota PATH` to resolve a catalog release and
read it through HTTP ranges (or give `--ota` an HTTP(S) URL).
`--base PATH_OR_URL` supplies the Ace 6
ColorOS BASE OTA for the Ace 6 OxygenOS conversion. X9U requires either
`--vulnerable-abl` (pack bloat ABL 16.0.6) or `--no-vulnerable-abl`.

Repeat the connected serial exactly to authorize writes; a mismatch exits 1
before any preparation. Answer template prompts with repeated
`--answer id=value`, and check the serial line before confirming.
Do not guess answers or confirm a different phone.

On failure the command offers only the explicit actions allowed by the shared
[recovery table](docs/flow.md), defaults to Stop, and stops without a terminal.
Destructive recovery requires typing the exact serial again. The receipt goes to
`--receipt PATH` or `./receipt-<runId>.json`. Exit codes: 0 succeeded, 2 policy
stop (plan only, unanswered prompt, stopped run), 1 failed,
uncertain or an error, 64 for a usage error.

Export the same package without a device:

```sh
dart run cli/bin/flasher_web.dart export --device 'Oneplus 13' --kind 'SuperHybrid Flasher' \
  --region GLO --ota /path/to/FULL-OTA.zip --bloat-dir /path/to/bloat \
  --out /path/to/flasher.zip --upstream app/web/upstream
```

It prints the ZIP's SHA-256, size and entry count and writes
`<zip>.receipt.json` next to it. Both actions accept `--api-base ORIGIN` and
`--upstream PATH_OR_URL`. `facts` prints what the place has checked it can do;
`devices` lists fastboot serials. Global flags are `-v`/`--verbose` and `--json`.
`serve` hosts the Squadron services for a process-place launcher, accepting
`--session-file FILE`, `--port N`, `--launch-id ID`, `--grace-ms N` and
`--first-link-grace-ms N`.

## In the browser

The setup page has four steps and one action card:

1. **Package configuration** — device, flasher type and region from the
   upstream tables, plus the local engine state.
2. **Bloat files** — the images the template needs, verified by size and
   SHA-256. They are downloaded through `/api/bloat/` once and then read from
   the store. A picked folder (File System Access) keeps them outside the
   browser's quota; otherwise they stay in origin-private storage (OPFS).
3. **OTA source** — a local ZIP (read in place, dropped or chosen through
   `file_picker`'s file system access dialog, which the page remembers so a
   reload can reconnect it) or a catalog version (read in 8 MiB blocks from the
   edge block cache; the Worker fills a missing block from the CDN). Full OTA
   packages only; incremental updates are rejected. **Download OTA** on a
   catalog version saves the ZIP where you choose (outside the app cap) and
   then reads it as the local OTA, or starts a browser download on Android
   Chrome. The copy reads ahead up to eight blocks and has no resume: start it
   again and the blocks already cached come straight back.
4. **Vulnerable ABL** — the X9U choice between the bloat ABL 16.0.6 and the
   OTA's ABL.

The action card then offers **Continue** and, as its secondary action,
**Export ZIP**. Continue opens the guided flash flow one screen at a time:

1. **Connect** — the phone in bootloader fastboot, one connection status and
   one primary **Check phone** for a grant the page already holds (or
   **Choose phone** to open the WebUSB chooser). “Not in the list?” explains
   mode, cable, port and OS causes.
2. **Check** — read-only input and device checks, the plan’s remaining prompt
   answers and the plan outline. **Review plan** once it resolves.
3. **Confirm** — the exact serial, the OTA identity, the ordered writes and
   the readback limits. **Flash serial …** only after the acknowledgement.
4. **Flash** — the current step, byte progress, the last reply and
   mode-change guidance. The only action is **Stop further commands**.
5. **Recover** — uncertainty first, a plain-language failure and the raw
   evidence one tap away. The primary action is the safest one the service
   offers (never a generic retry for an uncertain write, which is flagged
   before the error); the other explicit choices are secondary. Clear super
   has its own serial-naming confirmation and an unbootable warning, and the
   power-cycle action shows the physical steps.
6. **Done / Stopped** — OKAY is distinguished from a verified readback, any
   unresolved uncertainty stays visible, and **Save receipt** is the primary
   action. Diagnostics are always available.

Exporting opens the save-file picker where the browser has one, and otherwise
(Android Chrome) starts a streamed download. A failed streamed export aborts
the download. Discard a partial ZIP left at a picked file.

The flash holds a screen wake lock and a leave guard only while it writes,
including an in-flight command after Stop, and releases them when the run
pauses, finishes or is stopped; a page without wake-lock support says so. A
reload restores the last checkpoint as an inspection-only receipt: nothing is
resumed and no command is replayed, and a nonterminal checkpoint stays
uncertain. A new app deploy is announced while a run is busy, but the reload
it offers is enabled only when nothing is preparing, confirming or writing.
The Environment page shows the engine and the documented storage budget.

Flashing requires current Chrome or Edge on HTTPS or localhost, outside an
embedded webview. The page uses the pure-Dart `packages/web_usb_grant` chooser
from the click; its browser backend preserves cancellation versus permission
failure and DOMException diagnostics. The app keeps the fastboot `ff/42/03`
filter and requires a serial; only that serial crosses to the Squadron worker,
which reopens that exact granted device. Regrant the same phone when the app
asks after a mode change. The local path dependency bootstraps from a fresh
clone without an unpublished package or sibling checkout.

## One pass over the OTA

Every kind is produced in one pass over the OTA, with the images streamed from
their payload operations to whichever sink consumes them:

- Each image is verified against its payload-partition SHA-256 while it is
  streamed; a mismatch stops the run. Earlier sparse parts may already be written.
- `super.img` is emitted as a sparse image with RAW data blocks and DONT_CARE
  gaps only. LP extents come from the layout the flasher template writes, so
  every sparse piece's size is known without reading the images first; boot
  partitions stay raw, and the bootloader expands sparse chunks into raw data.
- The DONT_CARE form is slightly larger than FILL detection would be: measured
  on the owner's real CPH2645 16.0.3.500 OTA, 29.5 MiB on an 8.75 GiB super,
  about +0.33 %.
- The receipt carries the SHA-256 of every image the package contains,
  including the `super.img` digest computed while it streamed.

## Storage

The app keeps its own data under a 10 GiB cap: verified bloat images (at most
about 1.72 GiB raw) and the service worker shell. An OTA costs nothing: a
local file is read in place, a catalog release is read from the edge block
cache, and a downloaded copy lands outside the store.

- Bloat uses OPFS by default, or an optionally picked folder on desktop
  Chromium. Nothing else is written there.
- A write that would pass the cap is refused. The browser's origin quota may
  be lower than the cap. A picked folder's free disk space is not reported by
  the browser; only the app cap applies to that store, not the origin quota.
- Archives are never written to the store: the export streams straight into
  the chosen file or the download, so the output needs no OPFS space and no
  workspace.

## Failures, retries and the receipt

Execution stops at the first failing step (a USB drop, a hash mismatch, a
device FAIL reply) and reports the step, its status and the reason. Nothing is
resent automatically. Core supplies the allowed recovery actions: read-only
retry, same-serial reconnect, explicit bootloader/fastbootd reboot, physical
power-cycle check, deliberate whole-step rewrite, clear super, or Stop.
Connection readiness does not settle a write whose completion is unknown.
An uncertain write is never replayed by reconnecting or rebooting.

Regional plans check peak logical allocation in fastbootd before their logical
section. Old other-slot/custom-ROM/cow allocations can require **Clear super**.
It is never automatic: name the serial again, require snapshot status `none`,
then flash a metadata-only sparse super image and restart logical writes.
The phone cannot boot until flashing completes. No userdata format is sent.
See [docs/flow.md](docs/flow.md) for preconditions, commands, certainty and the
guided-screen/lifecycle contract.

The receipt is the only record: status, device, serial, OTA version, ARB index,
the per-image SHA-256 map (including `super.img` and, for X9U, the ABL source),
the step and write list, the start and end modes, the failure and its step,
uncertainty, cleanup errors and the strategy that ran. The page shows it and
downloads it as JSON; the CLI writes it as a file. FASTBOOT `OKAY` is not a
readback check, so verification stays `unverified`, and the Android mode after
the final reboot is reported as unverified because it is not probed.

Physical-device qualification is still pending: real OTA flashing on a real
phone has not been performed for this work. The tests drive a fake fastboot
transport and synthetic OTAs, and compare written bytes with the exported ZIP
and the expected images.

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
  service calls. `nusb` is pinned in `rust/Cargo.toml`'s `[patch.crates-io]` to
  revision `84890ce` of `https://github.com/p0g-stack/nusb`, a fork that carries
  three changes not yet released: owned WebUSB rejection evidence for
  operations and endpoints, chooser cancellation distinguished from refusal,
  and the `#221` shared-lease follow-up. The pin becomes a plain version bump to
  the released minimum once nusb ships them. `fastboot-protocol` remains
  published 0.4.0.
- **Patched Squadron.** squadron_process needs Squadron with its
  channel-factory patch; bootstrap runs `squadron_process:squadron_patch`,
  which puts it under `.dart_tool/` and writes `pubspec_overrides.yaml`.
- **Carried patches.** `third_party/<name>/` holds a `PIN` (upstream repo,
  commit and package directory) plus a `git format-patch` series; bootstrap
  runs `dart run tool/third_party.dart`, which checks the pinned commit out
  under `.dart_tool/third_party/`, applies the series and adds the
  `dependency_overrides` entry, idempotently. `file_picker_web` is carried
  this way for its file system access dialog; `third_party/README.md` has the
  convention and how to refresh a series.

Generated by the `p0g_app` brick (p0g-stack/bricks); the conventions above
come from it.

## License

flasher-web's own code is LGPL-3.0-or-later: `LICENSE` is the GNU Lesser
General Public License v3, and `COPYING` is the GNU GPL v3 it incorporates.
No linking exception applies here; the established stack repositories keep
their own `LICENSE.exception`.

Code taken from other projects keeps its original licence and notices:

- `rust/crates/ota-payload/` is Apache-2.0 (its `LICENSE`), derived from
  otaripper 3.5.0; its README has the provenance.
- `rust/src/api/arb.rs` (an otaripper port), `rust/src/api/avb.rs` (AOSP
  avbtool) and `rust/src/api/lp.rs` (AOSP liblp) are Apache-2.0 ports, as
  their file headers state.
- `third_party/*/patches/` are changes to their upstream packages and fall
  under those packages' licences.
- `packages/web_usb_grant/` carries its own copy of the same LGPL texts.
