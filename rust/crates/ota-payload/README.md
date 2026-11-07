# ota-payload

Android full-OTA (`CrAU`) update payload decoding: the payload header, the
protobuf manifest, install operations, and the bytes each operation writes.

This crate is the reusable implementation behind the app's
`flutter_rust_bridge` payload API. It has no frb dependency, does no I/O, and
uses no application identifiers: callers pass the header, manifest and
operation bytes they already hold. The operation codecs (bzip2, xz, zstd) are
pure Rust, so the crate builds for native and single-threaded wasm.

## Scope

- `payload_header` validates the fixed header against the payload size.
- `Manifest::parse` reads the bounded protobuf manifest.
- `Manifest::{block_size, minor_version, partitions, operations}` exposes the
  manifest for planning.
- `Manifest::decode_op` checks the operation's data hash and decodes REPLACE,
  REPLACE_BZ, REPLACE_XZ, REPLACE_ZSTD, ZERO and DISCARD.
- `Manifest::verify_full` is the upstream full-OTA check: every partition is
  described by a complete image, so no source image is needed.
- `Sha256Hasher` is the streaming image hash, including zero runs for sparse
  holes.

Incremental (source-based) operations are deliberately rejected, matching the
full-OTA scope.

## Provenance and license

Derived from **otaripper 3.5.0** by syedinsaf and contributors, Apache-2.0:
`src/payload.rs`, `src/cmd/extractor.rs` and `src/proto/`.

- https://github.com/syedinsaf/otaripper
- https://github.com/syedinsaf/otaripper/releases/tag/v3.5.0

The full-OTA check follows the upstream Python `flasher_builder/payload.py`
and field numbers follow AOSP `system/update_engine/update_metadata.proto`.

This crate is distributed under the Apache License, Version 2.0; see
`LICENSE`. It is a derived work, not the upstream project, and the upstream
authors do not endorse it.
