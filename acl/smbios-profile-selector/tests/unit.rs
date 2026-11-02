// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use alloc::{vec, vec::Vec};
use uefi::{Status, boot};

use crate::{
    MAX_SMBIOS_TABLE_BYTES, Profile, SmbiosDetectionError, SmbiosTableLocation, active_addon_matches, detect_profile,
    firmware_read_length, parse_smbios_entry_point,
};

fn processor(manufacturer: &[u8], populated: bool) -> Vec<u8> {
    let mut record = vec![0; 26];
    record[0] = 4;
    record[1] = 26;
    record[7] = 1;
    record[24] = if populated { 0x41 } else { 0 };
    record.extend_from_slice(manufacturer);
    record.extend_from_slice(&[0, 0]);
    record
}

fn table(records: &[(&[u8], bool)]) -> Vec<u8> {
    let mut result = Vec::new();
    for (manufacturer, populated) in records {
        result.extend(processor(manufacturer, *populated));
    }
    result.extend_from_slice(&[127, 4, 0, 0, 0, 0]);
    result
}

fn checksum(bytes: &mut [u8], offset: usize) {
    bytes[offset] = 0;
    bytes[offset] = 0u8.wrapping_sub(bytes.iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)));
}

fn smbios3_entry(address: u64, length: u32) -> Vec<u8> {
    let mut bytes = vec![0; 24];
    bytes[..5].copy_from_slice(b"_SM3_");
    bytes[6] = 24;
    bytes[7] = 3;
    bytes[12..16].copy_from_slice(&length.to_le_bytes());
    bytes[16..24].copy_from_slice(&address.to_le_bytes());
    checksum(&mut bytes, 5);
    bytes
}

fn smbios2_entry() -> Vec<u8> {
    let mut bytes = vec![0; 31];
    bytes[..4].copy_from_slice(b"_SM_");
    bytes[5] = 31;
    bytes[6] = 2;
    bytes[16..21].copy_from_slice(b"_DMI_");
    bytes[22..24].copy_from_slice(&4096u16.to_le_bytes());
    bytes[24..28].copy_from_slice(&0x12340000u32.to_le_bytes());
    checksum(&mut bytes[16..31], 5);
    checksum(&mut bytes, 4);
    bytes
}

#[test]
fn valid_entry_points() {
    for (bytes, smbios3, address, length) in [
        (smbios2_entry(), false, 0x12340000, 4096),
        (smbios3_entry(1, 1), true, 1, 1),
        (smbios3_entry(0x1_0000_0000, MAX_SMBIOS_TABLE_BYTES as u32), true, 0x1_0000_0000, MAX_SMBIOS_TABLE_BYTES),
    ] {
        assert_eq!(
            parse_smbios_entry_point(&bytes, smbios3),
            Ok(SmbiosTableLocation { address, length }),
            "smbios3={smbios3}, address={address:#x}, length={length}"
        );
    }
}

#[test]
fn invalid_table_ranges_are_rejected() {
    for (address, length) in [
        (0, 4096),
        (4096, 0),
        (4096, MAX_SMBIOS_TABLE_BYTES as u32 + 1),
        (u64::MAX, 1),
    ] {
        assert_eq!(
            parse_smbios_entry_point(&smbios3_entry(address, length), true),
            Err(SmbiosDetectionError::InvalidSmbios),
            "address={address:#x}, length={length}"
        );
    }
}

#[test]
fn smbios3_maximum_is_capped_to_mapped_data() {
    let address = 0x1040;
    let region_end = 0x2000;
    let maximum = 2 * boot::PAGE_SIZE;
    let location = parse_smbios_entry_point(&smbios3_entry(address as u64, maximum as u32), true).unwrap();
    let length = firmware_read_length(location.address as usize, location.length, true, region_end).unwrap();
    assert_eq!(length, boot::PAGE_SIZE - 0x40);
    let mut bytes = table(&[(b"NVIDIA", true)]);
    let truncated = bytes.len() - 1;
    bytes.resize(length, 0xff);
    assert_eq!(detect_profile(&bytes[..length]).unwrap().profile, Profile::NvidiaGrace);
    assert_eq!(firmware_read_length(address, maximum, false, region_end), None);
    assert_eq!(firmware_read_length(address, 7, false, region_end), Some(7));
    assert_eq!(firmware_read_length(region_end as usize, 7, true, region_end), None);
    let length = firmware_read_length(address, truncated, true, region_end).unwrap();
    assert_eq!(length, truncated);
    assert_eq!(detect_profile(&bytes[..length]), Err(SmbiosDetectionError::InvalidSmbios));
}

#[test]
fn entry_point_truncation_is_rejected() {
    for (bytes, smbios3) in [(smbios2_entry(), false), (smbios3_entry(0x12340000, 4096), true)] {
        for length in 0..bytes.len() {
            assert_eq!(
                parse_smbios_entry_point(&bytes[..length], smbios3),
                Err(SmbiosDetectionError::InvalidSmbios),
                "smbios3={smbios3}, truncated length {length}"
            );
        }
    }
}

#[test]
fn entry_point_identity_and_declared_lengths_are_checked() {
    for (template, smbios3, checksum_offset, length_offset, version_offset) in [
        (smbios2_entry(), false, 4, 5, 6),
        (smbios3_entry(0x12340000, 4096), true, 5, 6, 7),
    ] {
        for (offset, value) in [
            (0, b'?'),
            (length_offset, template[length_offset] - 1),
            (length_offset, template[length_offset] + 1),
            (version_offset, template[version_offset] - 1),
        ] {
            let mut bytes = template.clone();
            bytes[offset] = value;
            // Keep the checksum valid so it cannot hide a missing field check.
            checksum(&mut bytes, checksum_offset);
            assert_eq!(
                parse_smbios_entry_point(&bytes, smbios3),
                Err(SmbiosDetectionError::InvalidSmbios),
                "smbios3={smbios3}, offset={offset}, value={value}"
            );
        }
    }
}

#[test]
fn extended_entry_point_lengths_are_checked() {
    for (template, smbios3, checksum_offset, length_offset) in [
        (smbios2_entry(), false, 4, 5),
        (smbios3_entry(0x12340000, 4096), true, 5, 6),
    ] {
        for header_length in [64u8, 65, u8::MAX] {
            let mut bytes = template.clone();
            bytes.resize(usize::from(header_length), 0);
            bytes[length_offset] = header_length;
            checksum(&mut bytes, checksum_offset);
            assert_eq!(
                parse_smbios_entry_point(&bytes, smbios3),
                Ok(SmbiosTableLocation {
                    address: 0x12340000,
                    length: 4096
                }),
                "smbios3={smbios3}, header length {header_length}"
            );
            bytes[usize::from(header_length) - 1] ^= 1;
            assert_eq!(
                parse_smbios_entry_point(&bytes, smbios3),
                Err(SmbiosDetectionError::InvalidSmbios),
                "smbios3={smbios3}, corrupted header length {header_length}"
            );
        }
    }
}

#[test]
fn smbios2_intermediate_anchor_is_checked() {
    let mut bytes = smbios2_entry();
    bytes[16] = b'?';
    // Both checksums must remain valid to isolate the intermediate anchor check.
    checksum(&mut bytes[16..31], 5);
    checksum(&mut bytes, 4);
    assert_eq!(parse_smbios_entry_point(&bytes, false), Err(SmbiosDetectionError::InvalidSmbios));
}

#[test]
fn smbios2_intermediate_checksum_is_checked() {
    let mut bytes = smbios2_entry();
    bytes[21] ^= 1;
    // Repair only the outer checksum so the intermediate checksum is still invalid.
    checksum(&mut bytes, 4);
    assert_eq!(parse_smbios_entry_point(&bytes, false), Err(SmbiosDetectionError::InvalidSmbios));
}

#[test]
fn nvidia_grace_and_generic_profiles() {
    for (manufacturer, profile) in [
        (&b"NVIDIA"[..], Profile::NvidiaGrace),
        (&b" nvidia "[..], Profile::NvidiaGrace),
        (&b"Ampere Computing"[..], Profile::Generic),
        (&b"Microsoft Corporation"[..], Profile::Generic),
        (&b"Intel Corporation"[..], Profile::Generic),
        (&b"NVIDIA Corporation"[..], Profile::Generic),
    ] {
        let bytes = table(&[(manufacturer, true)]);
        let detection = detect_profile(&bytes).unwrap();
        assert_eq!(detection.profile, profile, "manufacturer={manufacturer:?}");
        assert_eq!(detection.manufacturer.as_bytes(), manufacturer.trim_ascii());
    }
}

#[test]
fn unpopulated_sockets_do_not_affect_detection() {
    let bytes = table(&[(b"", false), (b"NVIDIA", true)]);
    let result = detect_profile(&bytes).unwrap();
    assert_eq!(result.profile, Profile::NvidiaGrace);
    assert_eq!(result.populated_processors, 1);
}

#[test]
fn matching_processor_profiles_are_counted() {
    for (first, second, profile) in [
        (&b"NVIDIA"[..], &b"NVIDIA"[..], Profile::NvidiaGrace),
        (&b"Intel"[..], &b"Ampere"[..], Profile::Generic),
    ] {
        let bytes = table(&[(first, true), (second, true)]);
        let detection = detect_profile(&bytes).unwrap();
        assert_eq!(detection.profile, profile);
        assert_eq!(detection.populated_processors, 2);
    }
}

#[test]
fn conflicting_processors_are_rejected() {
    assert_eq!(
        detect_profile(&table(&[(b"NVIDIA", true), (b"Ampere", true)])),
        Err(SmbiosDetectionError::InvalidProcessorInfo)
    );
}

#[test]
fn missing_populated_processors_are_rejected() {
    assert_eq!(detect_profile(&table(&[])), Err(SmbiosDetectionError::InvalidProcessorInfo));
    assert_eq!(detect_profile(&table(&[(b"", false)])), Err(SmbiosDetectionError::InvalidProcessorInfo));
}

#[test]
fn invalid_manufacturer_index_is_rejected() {
    for index in [0, 2] {
        let mut bytes = table(&[(b"NVIDIA", true)]);
        bytes[7] = index;
        assert_eq!(detect_profile(&bytes), Err(SmbiosDetectionError::InvalidProcessorInfo), "index={index}");
    }
}

#[test]
fn manufacturer_uses_its_string_index() {
    let mut bytes = table(&[(b"socket\0NVIDIA\0processor version", true)]);
    bytes[7] = 2;
    let result = detect_profile(&bytes).unwrap();
    assert_eq!(result.manufacturer, "NVIDIA");
    assert_eq!(result.profile, Profile::NvidiaGrace);
}

#[test]
fn invalid_manufacturer_is_rejected() {
    for manufacturer in [&b" "[..], &[255], "NVIDI\u{00c1}".as_bytes()] {
        assert_eq!(
            detect_profile(&table(&[(manufacturer, true)])),
            Err(SmbiosDetectionError::InvalidProcessorInfo),
            "manufacturer={manufacturer:?}"
        );
    }
}

#[test]
fn truncated_tables_are_rejected() {
    let bytes = table(&[(b"NVIDIA", true)]);
    for length in 0..bytes.len() {
        assert_eq!(
            detect_profile(&bytes[..length]),
            Err(SmbiosDetectionError::InvalidSmbios),
            "truncated length {length}"
        );
    }
}

#[test]
fn invalid_record_lengths_are_rejected() {
    for length in [0, 3, 25, 255] {
        let mut bytes = table(&[(b"NVIDIA", true)]);
        bytes[1] = length;
        assert_eq!(detect_profile(&bytes), Err(SmbiosDetectionError::InvalidSmbios), "record length {length}");
    }
}

#[test]
fn nonprocessor_records_and_padding_are_allowed() {
    let mut bytes = vec![1, 4, 0, 0, b'x', 0, 0];
    bytes.extend(table(&[(b"Ampere", true)]));
    bytes.extend_from_slice(&[255; 100]);
    assert_eq!(detect_profile(&bytes).unwrap().profile, Profile::Generic);
}

#[test]
fn active_addon_comparison_preserves_firmware_errors() {
    let expected = b"verified template";
    assert!(active_addon_matches(Ok(Some(expected.to_vec())), expected).unwrap());
    assert!(!active_addon_matches(Ok(Some(b"different".to_vec())), expected).unwrap());
    assert!(!active_addon_matches(Ok(None), expected).unwrap());
    assert!(!active_addon_matches(Err(Status::NOT_FOUND.into()), expected).unwrap());
    for status in [Status::BAD_BUFFER_SIZE, Status::DEVICE_ERROR, Status::ACCESS_DENIED] {
        let error = active_addon_matches(Err(status.into()), expected).unwrap_err();
        assert_eq!(error.status(), status);
    }
}

#[test]
fn sbat_records_are_well_formed() {
    let rows = include_str!("../src/sbat.csv");
    assert!(rows.ends_with('\n'));
    for row in rows.lines() {
        assert_eq!(row.split(',').count(), 6);
        assert!(row.split(',').all(|field| !field.is_empty() && field.is_ascii()));
    }
}
