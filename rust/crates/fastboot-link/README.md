# fastboot-link

Reusable fastboot transport. It owns discovery, exclusive serial selection,
the command/download state machine, bounded bulk I/O, and typed failures. It has
no flutter_rust_bridge or Dart dependency; the app's `rust/src/api/fastboot.rs`
is a thin handle/lifetime shim.

## Dependencies and provenance

- **fastboot-protocol 0.4.1** (released, `boardswarm/fastboot-rs`): the
  `FastBootResponse` / `FastBootCommand` parsing and formatting. Upstream does
  not check the DATA length against the requested download, and its
  `DataDownload` borrows the client for the whole transfer, so it cannot back
  begin/write/end calls that arrive through separate FFI calls. The
  `1vivy/fastboot-rs@ff063ae` fork adds bounded custom commands, `fetch`, and
  checked transfer lengths, but this crate already implements those checks in
  `session.rs` and needs only the parser. Using released upstream keeps the
  dependency on crates.io; no fork or `/tmp` path is in the manifest.
  The published 0.4.0 → 0.4.1 delta changes no library source: it updates
  package metadata, development dependencies and the example's sparse-image
  API (64-bit sizes). The existing transport/session suite passes with 0.4.1;
  no device policy or protocol semantics were changed.
- **nusb 0.2** (released upstream): native USB, endpoint descriptors, claimed
  interface, and bulk transfers. `1vivy/nusb@2d58dbc` has one unique fix that
  preserves WebUSB rejection name/message in its owned error. The browser path
  here talks to WebUSB directly, so it captures `DOMException.name`,
  `message`, and `stack` without parsing a formatted string and does not need
  the fork. Native nusb errors keep their `source()` chain. No fork or `/tmp`
  path is in the manifest.
- **web-sys / wasm-bindgen**: WebUSB is gated behind
  `--cfg=web_sys_unstable_apis`, set only for `wasm32-unknown-unknown` in the
  committed project-root `.cargo/config.toml` (the generated
  `rust/.cargo/config.toml` is rewritten by `tool/rust.sh`). No thread pool, no
  COOP/COEP requirement.

## Streaming contract

`Session::begin_download` sends `download:%08x`, requires the device's DATA
length to equal the requested length exactly, and enters a download state.
`write_download` accepts at most 1 MiB per call, rejects overruns before any
I/O, and sends exactly the given bytes. It takes ownership of the chunk so the
native backend hands that same allocation to nusb instead of copying it. `end_download` refuses a short transfer,
then requires the final OKAY and returns its payload. INFO and TEXT frames are
kept separately and travel with both successful replies and failures
(`LinkError.messages`); a FAIL is `FastbootFail` (`blame=device`,
`uncertain=false`) and leaves the session usable for mode probes. Public blame
is closed to `host`, `user`, `device` and `unknown`; the producing layer
(`caller`, `protocol`, `usb`, `browser`, `tcp`) travels as `LinkError.source`,
and every original name, message, stack and cause chain is kept. An invalid
device reply is also `blame=device` but named `Protocol`. Retirement is explicit
(`LinkError::session_retired`): transport, timeout, protocol and missing-handle
failures retire and close the device, while caller mistakes and a complete FAIL
do not. Probes
use a 15 s response bound; commands flagged as writes (flash/erase/reboot) use
180 s so a slow storage write is not aborted as uncertain. The WebUSB transfer
backup bound is longer than both. No write is retried.

One live session per serial/interface: nusb's claim is exclusive natively, an
in-process guard gives a clear Busy, and the browser holds a Web Lock per
serial/interface across tabs plus an in-worker guard.

## Optional real-protocol smoke

No network transport is compiled into the app. The `tcp-smoke` feature adds a
length-framed TCP `BulkTransport` and a small responder; every frame is
`u32 big-endian length` followed by the payload. Command frames carry raw
fastboot command bytes; download frames carry raw image bytes; responses are
raw `INFO` / `TEXT` / `OKAY` / `FAIL` / `DATA` frames.

```
cd rust
cargo run -p fastboot-link --features tcp-smoke --example tcp_smoke -- smoke
cargo run -p fastboot-link --features tcp-smoke --example tcp_smoke -- \
  client 127.0.0.1:8897 smoke-1 --expect-product synthetic-device
```

The client drives the same `Session` parser and download accounting as USB.
