use lp_super::{
    build_empty_metadata, generate_wipe_super, parse_image, serialize_geometry, serialize_metadata,
};
use std::io::{Seek, SeekFrom, Write};
use std::process::Command;

const SUPER_SIZE: u64 = 14_266_433_536;
const PARTS: &[&str] = &[
    "my_bigball",
    "my_carrier",
    "my_company",
    "my_engineering",
    "my_heytap",
    "my_manifest",
    "my_preload",
    "my_product",
    "my_region",
    "my_stock",
    "odm",
    "product",
    "system",
    "system_dlkm",
    "system_dlkm_gki",
    "system_dlkm_oki",
    "system_ext",
    "vendor",
    "vendor_dlkm",
];
const REFERENCE: &[u8] = include_bytes!("data/13r_super_empty.img");
const AS_FLASHED: &[u8] = include_bytes!("data/13r_super_empty_as_flashed_2026-11-10.img");

#[test]
fn metadata_matches_lpmake_and_as_flashed_reference() {
    for (names, reference) in [
        (PARTS.to_vec(), REFERENCE),
        (
            PARTS
                .iter()
                .copied()
                .filter(|n| *n != "system_dlkm_gki")
                .collect(),
            AS_FLASHED,
        ),
    ] {
        let generated = build_empty_metadata(SUPER_SIZE, &names).unwrap();
        assert_eq!(generated, parse_image(reference).unwrap());
        assert_eq!(
            serialize_geometry(&generated.geometry).unwrap(),
            reference[..4096]
        );
        assert_eq!(serialize_metadata(&generated).unwrap(), reference[4096..]);
        assert_eq!(
            generated,
            parse_image(&generate_wipe_super(SUPER_SIZE, &names).unwrap()).unwrap()
        );
        assert_eq!(generated.major_version, 10);
        assert_eq!(generated.minor_version, 2);
        assert_eq!(generated.flags, 1);
        assert_eq!(generated.partitions.len(), names.len() * 2);
        assert!(generated
            .partitions
            .iter()
            .all(|p| p.attributes == 1 && p.num_extents == 0 && p.first_extent_index == 0));
        assert!(generated.extents.is_empty());
        assert_eq!(generated.groups.len(), 3);
        assert_eq!(generated.groups[0].name, "default");
        assert_eq!(generated.groups[0].maximum_size, 0);
        for g in &generated.groups[1..] {
            assert_eq!(g.maximum_size, SUPER_SIZE - 4 * 1024 * 1024);
        }
        assert_eq!(generated.block_devices[0].size, SUPER_SIZE);
        assert_eq!(generated.block_devices[0].first_logical_sector, 2048);
    }
}

fn u16_at(bytes: &[u8], pos: usize) -> u16 {
    u16::from_le_bytes(bytes[pos..pos + 2].try_into().unwrap())
}
fn u32_at(bytes: &[u8], pos: usize) -> u32 {
    u32::from_le_bytes(bytes[pos..pos + 4].try_into().unwrap())
}

// Independent wire decoder: skip holes using seek/set_len, never allocate 13 GiB.
fn unsparse(bytes: &[u8], file: &mut std::fs::File) {
    assert_eq!(u32_at(bytes, 0), 0xed26ff3a);
    assert_eq!((u16_at(bytes, 4), u16_at(bytes, 6)), (1, 0));
    assert_eq!((u16_at(bytes, 8), u16_at(bytes, 10)), (28, 12));
    assert_eq!(u32_at(bytes, 24), 0);
    let block_size = u32_at(bytes, 12) as u64;
    let mut pos = 28;
    let mut expanded = 0;
    for _ in 0..u32_at(bytes, 20) {
        let kind = u16_at(bytes, pos);
        let len = u32_at(bytes, pos + 4) as u64 * block_size;
        let chunk_size = u32_at(bytes, pos + 8) as usize;
        let data = &bytes[pos + 12..pos + chunk_size];
        match kind {
            0xcac1 => {
                assert_eq!(len, data.len() as u64);
                file.write_all(data).unwrap();
            }
            0xcac2 => {
                assert_eq!(data, [0; 4]);
                assert_eq!(len, 4096);
                file.write_all(&[0; 4096]).unwrap();
            }
            0xcac3 => {
                assert!(data.is_empty());
                file.seek(SeekFrom::Current(len as i64)).unwrap();
            }
            _ => panic!("unexpected chunk {kind:x}"),
        }
        expanded += len;
        pos += chunk_size;
    }
    assert_eq!(expanded, SUPER_SIZE);
    assert_eq!(expanded, u32_at(bytes, 16) as u64 * block_size);
    assert_eq!(pos, bytes.len());
    file.set_len(expanded).unwrap();
    file.flush().unwrap();
}

#[test]
fn sparse_data_is_exactly_the_liblp_metadata_region() {
    let image = generate_wipe_super(SUPER_SIZE, PARTS).unwrap();
    assert_eq!(image.len(), 401_476);
    assert_eq!(u32_at(&image, 12), 4096);
    assert_eq!(u32_at(&image, 16) as u64 * 4096, SUPER_SIZE);
    assert_eq!(u32_at(&image, 20), 3);
    assert_eq!(u16_at(&image, 28), 0xcac2); // Required reserved boot-sector zero fill.
    assert_eq!(u32_at(&image, 32), 1);
    let raw = 44;
    assert_eq!(u16_at(&image, raw), 0xcac1);
    assert_eq!(u32_at(&image, raw + 4), 98); // 2 geometry + 6 * 16 metadata blocks.
    assert_eq!(u32_at(&image, raw + 8), 12 + 98 * 4096);
    let data = &image[raw + 12..raw + 12 + 98 * 4096];
    assert_eq!(&data[..4096], &REFERENCE[..4096]);
    assert_eq!(&data[4096..8192], &REFERENCE[..4096]);
    for slot in 0..6 {
        let metadata = &data[8192 + slot * 65536..8192 + (slot + 1) * 65536];
        assert_eq!(&metadata[..REFERENCE.len() - 4096], &REFERENCE[4096..]);
        assert!(metadata[REFERENCE.len() - 4096..].iter().all(|b| *b == 0));
    }
    let rest = raw + 12 + data.len();
    assert_eq!(u16_at(&image, rest), 0xcac3);
    assert_eq!(
        u32_at(&image, rest + 4) as u64 * 4096,
        SUPER_SIZE - 99 * 4096
    );
    assert_eq!(rest + 12, image.len());
}

#[test]
fn unsparsed_image_passes_lpdump_for_every_slot() {
    let probe = Command::new("lpdump").arg("--help").output();
    match probe {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            eprintln!("SKIP: lpdump is not installed; liblp host-tool compatibility check not run");
            return;
        }
        Err(error) => panic!("could not execute lpdump: {error}"),
        Ok(_) => (),
    }
    let mut raw = tempfile::NamedTempFile::new().unwrap();
    let mut reference = tempfile::NamedTempFile::new().unwrap();
    reference.write_all(REFERENCE).unwrap();
    unsparse(
        &generate_wipe_super(SUPER_SIZE, PARTS).unwrap(),
        raw.as_file_mut(),
    );
    let expected = Command::new("lpdump")
        .arg(reference.path())
        .output()
        .unwrap();
    assert!(
        expected.status.success(),
        "{}",
        String::from_utf8_lossy(&expected.stderr)
    );
    let text = String::from_utf8(expected.stdout.clone()).unwrap();
    assert!(text.contains("Metadata version: 10.2"));
    assert!(text.contains("Size: 14266433536 bytes"));
    assert!(text.contains("Maximum size: 14262239232 bytes"));
    for slot in 0..3 {
        let actual = Command::new("lpdump")
            .arg(format!("--slot={slot}"))
            .arg(raw.path())
            .output()
            .unwrap();
        assert!(
            actual.status.success(),
            "{}",
            String::from_utf8_lossy(&actual.stderr)
        );
        let actual = String::from_utf8(actual.stdout).unwrap();
        assert_eq!(
            actual.strip_prefix(&format!("Slot {slot}:\n")),
            Some(text.as_str())
        );
    }
}

#[test]
fn malformed_metadata_and_sparse_images_are_rejected() {
    for offset in [0, 8, 40, 4096, 4096 + 12, 4096 + 256] {
        let mut image = REFERENCE.to_vec();
        image[offset] ^= 1;
        assert!(
            parse_image(&image).is_err(),
            "accepted corruption at {offset}"
        );
    }
    let sparse = generate_wipe_super(SUPER_SIZE, PARTS).unwrap();
    for length in [0, 4, 27, 28, 43, 55, sparse.len() - 1] {
        assert!(parse_image(&sparse[..length]).is_err());
    }
    let mut image = sparse.clone();
    image[raw_metadata_offset(1)] ^= 1;
    assert!(
        parse_image(&image).is_err(),
        "accepted divergent backup geometry"
    );
    let mut image = sparse.clone();
    image[raw_metadata_offset(2) + 65536] ^= 1;
    assert!(
        parse_image(&image).is_err(),
        "accepted divergent metadata slot"
    );
    let mut image = sparse;
    image[16..20].copy_from_slice(&u32::MAX.to_le_bytes());
    assert!(
        parse_image(&image).is_err(),
        "accepted expanded size mismatch"
    );
}
fn raw_metadata_offset(block: usize) -> usize {
    44 + 12 + block * 4096
}

#[test]
fn unsafe_generator_dimensions_and_names_are_rejected() {
    for size in [
        0,
        4 * 1024 * 1024,
        SUPER_SIZE + 1,
        u32::MAX as u64 * 4096,
        u64::MAX,
    ] {
        assert!(generate_wipe_super(size, PARTS).is_err());
    }
    for names in [
        vec![],
        vec![""],
        vec!["system", "system"],
        vec!["../system"],
        vec!["systém"],
        vec!["abcdefghijklmnopqrstuvwxyz123456789"],
    ] {
        assert!(generate_wipe_super(SUPER_SIZE, &names).is_err());
    }
    let too_many = (0..700)
        .map(|i| format!("partition_{i}"))
        .collect::<Vec<_>>();
    assert!(generate_wipe_super(SUPER_SIZE, &too_many).is_err());
}

#[test]
fn sparse_bytes_match_host_lpmake_when_available() {
    let output = tempfile::NamedTempFile::new().unwrap();
    let mut command = Command::new("lpmake");
    command
        .args([
            "--metadata-size",
            "65536",
            "--metadata-slots",
            "3",
            "--virtual-ab",
            "--super-name",
            "super",
            "--device",
            &format!("super:{SUPER_SIZE}"),
            "--group",
            &format!("qti_dynamic_partitions_a:{}", SUPER_SIZE - 4 * 1024 * 1024),
            "--group",
            &format!("qti_dynamic_partitions_b:{}", SUPER_SIZE - 4 * 1024 * 1024),
            "--force-full-image",
            "--sparse",
            "--output",
        ])
        .arg(output.path());
    for name in PARTS {
        for slot in ["a", "b"] {
            command.arg("--partition").arg(format!(
                "{name}_{slot}:readonly:0:qti_dynamic_partitions_{slot}"
            ));
        }
    }
    let result = match command.output() {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            eprintln!("SKIP: lpmake is not installed; host sparse byte comparison not run");
            return;
        }
        result => result.unwrap(),
    };
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    // liblp atomically renames its output: reopen the path, not the old inode.
    let bytes = std::fs::read(output.path()).unwrap();
    let generated = generate_wipe_super(SUPER_SIZE, PARTS).unwrap();
    assert_eq!(generated.len(), bytes.len());
    assert_eq!(generated.iter().zip(&bytes).position(|(a, b)| a != b), None);
}
