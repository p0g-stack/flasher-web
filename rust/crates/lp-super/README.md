# lp-super

Pure Rust, native/wasm-compatible generation of a flashable Android sparse `super`
image that replaces logical-partition metadata with an empty virtual-A/B layout.
There is no FRB, filesystem, USB, or fastboot dependency. Nothing in this crate
sends commands. This resets allocation; it does **not** securely erase old data.

## Consumer and source contract

> AOSP `fastboot.cpp` `wipe_super`: reads LpMetadata from the image,
> `WriteToImageFile(path, metadata, block_size, {}, sparse=true)`, then
> `do_flash(super, ...)` for the single block device `super`.

Verified against AOSP `platform/system/core` revision
[`a3b721a32242006b59cb12bd62c9133632af3a2d`](https://github.com/aosp-mirror/platform_system_core/tree/a3b721a32242006b59cb12bd62c9133632af3a2d):

- [`fastboot/fastboot.cpp`](https://github.com/aosp-mirror/platform_system_core/blob/a3b721a32242006b59cb12bd62c9133632af3a2d/fastboot/fastboot.cpp#L2151-L2219):
  `do_wipe_super` reads the metadata-only image; `wipe_super` passes an empty image
  map and `true` for sparse, and flashes the metadata block device's name.
- [`fs_mgr/liblp/images.cpp`](https://github.com/aosp-mirror/platform_system_core/blob/a3b721a32242006b59cb12bd62c9133632af3a2d/fs_mgr/liblp/images.cpp#L300-L337):
  `ImageBuilder::Build` adds a reserved zero FILL block, then one contiguous RAW
  region containing two padded geometries and six padded metadata slots. No
  partition payload is added. The remainder is DONT_CARE.
- [`writer.cpp`](https://github.com/aosp-mirror/platform_system_core/blob/a3b721a32242006b59cb12bd62c9133632af3a2d/fs_mgr/liblp/writer.cpp#L37-L88):
  `SerializeGeometry` and `SerializeMetadata` compute SHA-256 with checksum fields
  zeroed. Tables are ordered partitions, extents, groups, block devices.
- [`builder.cpp`](https://github.com/aosp-mirror/platform_system_core/blob/a3b721a32242006b59cb12bd62c9133632af3a2d/fs_mgr/liblp/builder.cpp):
  a default unlimited group is inserted first; names retain insertion order;
  the first logical sector is the metadata end rounded to 1 MiB; virtual A/B
  requires version 10.2 and the expanded 256-byte header with flag 1.
- [`utility.cpp`](https://github.com/aosp-mirror/platform_system_core/blob/a3b721a32242006b59cb12bd62c9133632af3a2d/fs_mgr/liblp/utility.cpp#L79-L110)
  and [`include/liblp/metadata_format.h`](https://github.com/aosp-mirror/platform_system_core/blob/a3b721a32242006b59cb12bd62c9133632af3a2d/fs_mgr/liblp/include/liblp/metadata_format.h):
  little-endian packed wire fields and offsets, 4096-byte reserved block and
  geometries, 512-byte sectors, 52/24/48/64-byte table entries.

## Layout and API

`generate_wipe_super(super_size, partition_names)` returns ready-to-download
sparse bytes. Inputs are a physical super size in bytes and **unsuffixed** base
partition names in caller order. Device sizes and partition policy belong to the
caller, not this crate. Each base produces readonly, zero-extent `_a` and `_b`
entries in `qti_dynamic_partitions_a` and `qti_dynamic_partitions_b`, respectively.
Both groups have maximum size `super_size - 4 MiB`. There is one non-slot-suffixed
block device named `super`, with 1 MiB alignment and alignment offset zero.
Geometry uses 65536-byte metadata slots, three slots, and 4096-byte logical blocks.

These geometry/group arguments match `Flasher_Builder/flasher_builder/`'s
`native_pipeline.py:84-110` `pack_super`. Unlike packing real partition payloads,
the wipe recipe uses size zero for every partition and interleaves `_a`, `_b`
per base, as in the host reference vectors and the successful phone wipe.

Expanded byte offsets:

| Region | Offset | Size |
| --- | ---: | ---: |
| Reserved zero FILL | 0 | 4096 |
| Primary geometry | 4096 | 4096 |
| Backup geometry | 8192 | 4096 |
| Primary metadata slots 0, 1, 2 | 12288 + slot × 65536 | 65536 each |
| Backup metadata slots 0, 1, 2 | 208896 + slot × 65536 | 65536 each |
| DONT_CARE | 405504 | super_size − 405504 |

For 13R (`14266433536` bytes, 19 base partitions), the result is **401476 bytes**
(392.066 KiB) on the wire, with 401408 metadata RAW bytes. No layout deviation
from liblp is intended. The reserved zero FILL is necessary for exact AOSP
behavior; it is the one non-metadata region that is not DONT_CARE.

`build_empty_metadata`, `serialize_geometry`, and `serialize_metadata` expose the
semantic metadata and canonical liblp bytes. `parse_image` validates checksums,
versions, dimensions, table bounds/references, names and extent bounds. It accepts
lpmake metadata-only images, raw super images, or our sparse images without
expanding partition contents. Full-image copies must all agree: this intentionally
does not implement liblp's damaged-device backup recovery. Parsing supports
metadata 10.0–10.2, slots up to 64 KiB, and sparse RAW/FILL/DONT_CARE without CRC
chunks or a nonzero sparse checksum. It is not a general-purpose sparse reader.

Proposed app-local FRB entry point (signature only; integration is separate):

```rust
pub fn build_wipe_super_image(super_size: u64, partition_names: Vec<String>) -> anyhow::Result<Vec<u8>>;
```

Its implementation should call `lp_super::generate_wipe_super`. Confirmation,
exact-serial/device validation, download/flash execution, and receipts remain the
integrator's responsibility. Do not flash the small metadata-only fixture itself.

## Real contract checks

```sh
cargo test -p lp-super
cargo build -p lp-super --target wasm32-unknown-unknown
```

`tests/data/13r_super_empty.img` (6536 bytes) was generated on 2026-11-10 with
host `/usr/bin/lpmake` and the 19 `SUPER_PARTS` names:
`my_bigball my_carrier my_company my_engineering my_heytap my_manifest my_preload
my_product my_region my_stock odm product system system_dlkm system_dlkm_gki
system_dlkm_oki system_ext vendor vendor_dlkm`.
The 6432-byte `13r_super_empty_as_flashed_2026-11-10.img` is the exact metadata-only
input successfully used by host `fastboot wipe-super` that day; it omits
`system_dlkm_gki`. Both were copied unmodified from `.upstream/lp-vectors/`.

The command arguments were `--metadata-size 65536 --metadata-slots 3 --virtual-ab
--super-name super --device super:14266433536 --group
qti_dynamic_partitions_a:14262239232 --group
qti_dynamic_partitions_b:14262239232`, plus
`--partition <p>_a:readonly:0:qti_dynamic_partitions_a --partition
<p>_b:readonly:0:qti_dynamic_partitions_b` for each base name.

Tests compare every semantic field and exact geometry/header/table bytes against
both fixtures; check all sparse regions, copies, padding and expanded size; and
independently unsparse to a sparse host file for `lpdump` on all three slots.
When installed, `lpmake --force-full-image --sparse` must also produce identical
sparse bytes. Missing host tools produce explicit skip messages; golden and wire
contract checks always run. No tests communicate with a phone.
