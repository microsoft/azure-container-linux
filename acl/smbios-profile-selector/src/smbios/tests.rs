// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use alloc::vec;

use super::*;

const SMBIOS2_CHECKSUM_OFFSET: usize = 4;
const SMBIOS3_CHECKSUM_OFFSET: usize = 5;
const SMBIOS2_INTERMEDIATE_CHECKSUM_OFFSET: usize = 5;

fn processor(manufacturer: &[u8], populated: bool) -> Vec<u8> {
    let enabled_status = 1;
    let mut record = vec![0; PROCESSOR_MIN_BYTES];
    record[RECORD_TYPE_OFFSET] = PROCESSOR_RECORD_TYPE;
    record[RECORD_LENGTH_OFFSET] = u8::try_from(PROCESSOR_MIN_BYTES).unwrap();
    record[PROCESSOR_MANUFACTURER_OFFSET] = 1;
    record[PROCESSOR_STATUS_OFFSET] = if populated {
        PROCESSOR_POPULATED_MASK | enabled_status
    } else {
        0
    };
    record.extend_from_slice(manufacturer);
    record.extend_from_slice(&STRING_SET_TERMINATOR);
    record
}

fn table(records: &[(&[u8], bool)]) -> Vec<u8> {
    let mut result = Vec::new();
    for (manufacturer, populated) in records {
        result.extend(processor(manufacturer, *populated));
    }
    let end_of_table = [
        END_OF_TABLE_RECORD_TYPE,
        u8::try_from(RECORD_HEADER_BYTES).unwrap(),
        0,
        0,
    ];
    result.extend_from_slice(&end_of_table);
    result.extend_from_slice(&STRING_SET_TERMINATOR);
    result
}

fn checksum(bytes: &mut [u8], offset: usize) {
    bytes[offset] = 0;
    bytes[offset] = 0u8.wrapping_sub(bytes.iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)));
}

fn smbios3_entry(address: u64, length: u32) -> Vec<u8> {
    let anchor = b"_SM3_";
    let mut bytes = vec![0; SMBIOS3_ENTRY_POINT_BYTES];
    bytes[..anchor.len()].copy_from_slice(anchor);
    bytes[SMBIOS3_LENGTH_OFFSET] = u8::try_from(SMBIOS3_ENTRY_POINT_BYTES).unwrap();
    bytes[SMBIOS3_MAJOR_VERSION_OFFSET] = SMBIOS3_MIN_MAJOR_VERSION;
    bytes[SMBIOS3_TABLE_MAX_SIZE_RANGE].copy_from_slice(&length.to_le_bytes());
    bytes[SMBIOS3_TABLE_ADDRESS_RANGE].copy_from_slice(&address.to_le_bytes());
    checksum(&mut bytes, SMBIOS3_CHECKSUM_OFFSET);
    bytes
}

fn smbios2_entry() -> Vec<u8> {
    let anchor = b"_SM_";
    let table_length = 4096u16;
    let table_address = 0x1234_0000u32;
    let mut bytes = vec![0; SMBIOS2_ENTRY_POINT_BYTES];
    bytes[..anchor.len()].copy_from_slice(anchor);
    bytes[SMBIOS2_LENGTH_OFFSET] = u8::try_from(SMBIOS2_ENTRY_POINT_BYTES).unwrap();
    bytes[SMBIOS2_MAJOR_VERSION_OFFSET] = SMBIOS2_MIN_MAJOR_VERSION;
    bytes[SMBIOS2_INTERMEDIATE_ANCHOR_RANGE].copy_from_slice(b"_DMI_");
    bytes[SMBIOS2_TABLE_LENGTH_RANGE].copy_from_slice(&table_length.to_le_bytes());
    bytes[SMBIOS2_TABLE_ADDRESS_RANGE].copy_from_slice(&table_address.to_le_bytes());
    checksum(&mut bytes[SMBIOS2_INTERMEDIATE_HEADER_RANGE], SMBIOS2_INTERMEDIATE_CHECKSUM_OFFSET);
    checksum(&mut bytes, SMBIOS2_CHECKSUM_OFFSET);
    bytes
}

#[test]
fn valid_entry_points() {
    for (bytes, is_smbios3, address, length) in [
        (smbios2_entry(), false, 0x12340000, 4096),
        (smbios3_entry(1, 1), true, 1, 1),
        (smbios3_entry(0x1_0000_0000, MAX_SMBIOS_TABLE_BYTES as u32), true, 0x1_0000_0000, MAX_SMBIOS_TABLE_BYTES),
    ] {
        assert_eq!(
            parse_smbios_entry_point(&bytes, is_smbios3),
            Ok(SmbiosTableLocation { address, length }),
            "is_smbios3={is_smbios3}, address={address:#x}, length={length}"
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
    let region_start = 0x1000;
    let table_offset = 0x40;
    let address = region_start + table_offset;
    let region_end = 0x2000;
    let maximum = 2 * boot::PAGE_SIZE;
    let location = parse_smbios_entry_point(&smbios3_entry(address as u64, maximum as u32), true).unwrap();
    let length = firmware_read_length(location.address as usize, location.length, region_end).unwrap();
    assert_eq!(length, boot::PAGE_SIZE - table_offset);
    let mut bytes = table(&[(b"NVIDIA", true)]);
    let truncated = bytes.len() - 1;
    bytes.resize(length, 0xff);
    assert_eq!(parse_processors(&bytes[..length]).unwrap(), ["NVIDIA"]);
    assert_eq!(firmware_read_length(address, ENTRY_POINT_PREFIX_BYTES, region_end), Some(ENTRY_POINT_PREFIX_BYTES));
    let length = firmware_read_length(address, truncated, region_end).unwrap();
    assert_eq!(length, truncated);
    assert_eq!(parse_processors(&bytes[..length]), Err(SmbiosDetectionError::InvalidSmbios));
}

#[test]
fn firmware_read_length_rejects_invalid_ranges() {
    for (address, length, region_end) in [
        (0, 1, 0x2000),
        (0x1000, 0, 0x2000),
        (0x2000, 1, 0x2000),
        (0x2001, 1, 0x2000),
    ] {
        assert_eq!(firmware_read_length(address, length, region_end), None);
    }
}

#[test]
fn entry_point_truncation_is_rejected() {
    for (bytes, is_smbios3) in [(smbios2_entry(), false), (smbios3_entry(0x12340000, 4096), true)] {
        for length in 0..bytes.len() {
            assert_eq!(
                parse_smbios_entry_point(&bytes[..length], is_smbios3),
                Err(SmbiosDetectionError::InvalidSmbios),
                "is_smbios3={is_smbios3}, truncated length {length}"
            );
        }
    }
}

#[test]
fn entry_point_identity_and_declared_lengths_are_checked() {
    for (template, is_smbios3, checksum_offset, length_offset, version_offset) in [
        (smbios2_entry(), false, SMBIOS2_CHECKSUM_OFFSET, SMBIOS2_LENGTH_OFFSET, SMBIOS2_MAJOR_VERSION_OFFSET),
        (
            smbios3_entry(0x12340000, 4096),
            true,
            SMBIOS3_CHECKSUM_OFFSET,
            SMBIOS3_LENGTH_OFFSET,
            SMBIOS3_MAJOR_VERSION_OFFSET,
        ),
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
                parse_smbios_entry_point(&bytes, is_smbios3),
                Err(SmbiosDetectionError::InvalidSmbios),
                "is_smbios3={is_smbios3}, offset={offset}, value={value}"
            );
        }
    }
}

#[test]
fn extended_entry_point_lengths_are_checked() {
    for (template, is_smbios3, checksum_offset, length_offset) in [
        (smbios2_entry(), false, SMBIOS2_CHECKSUM_OFFSET, SMBIOS2_LENGTH_OFFSET),
        (smbios3_entry(0x12340000, 4096), true, SMBIOS3_CHECKSUM_OFFSET, SMBIOS3_LENGTH_OFFSET),
    ] {
        for header_length in [64u8, 65, u8::MAX] {
            let mut bytes = template.clone();
            bytes.resize(usize::from(header_length), 0);
            bytes[length_offset] = header_length;
            checksum(&mut bytes, checksum_offset);
            assert_eq!(
                parse_smbios_entry_point(&bytes, is_smbios3),
                Ok(SmbiosTableLocation {
                    address: 0x12340000,
                    length: 4096
                }),
                "is_smbios3={is_smbios3}, header length {header_length}"
            );
            bytes[usize::from(header_length) - 1] ^= 1;
            assert_eq!(
                parse_smbios_entry_point(&bytes, is_smbios3),
                Err(SmbiosDetectionError::InvalidSmbios),
                "is_smbios3={is_smbios3}, corrupted header length {header_length}"
            );
        }
    }
}

#[test]
fn smbios2_intermediate_anchor_is_checked() {
    let mut bytes = smbios2_entry();
    bytes[SMBIOS2_INTERMEDIATE_ANCHOR_RANGE.start] = b'?';
    // Both checksums must remain valid to isolate the intermediate anchor check.
    checksum(&mut bytes[SMBIOS2_INTERMEDIATE_HEADER_RANGE], SMBIOS2_INTERMEDIATE_CHECKSUM_OFFSET);
    checksum(&mut bytes, SMBIOS2_CHECKSUM_OFFSET);
    assert_eq!(parse_smbios_entry_point(&bytes, false), Err(SmbiosDetectionError::InvalidSmbios));
}

#[test]
fn smbios2_intermediate_checksum_is_checked() {
    let mut bytes = smbios2_entry();
    bytes[SMBIOS2_INTERMEDIATE_HEADER_RANGE.start + SMBIOS2_INTERMEDIATE_CHECKSUM_OFFSET] ^= 1;
    // Repair only the outer checksum so the intermediate checksum is still invalid.
    checksum(&mut bytes, SMBIOS2_CHECKSUM_OFFSET);
    assert_eq!(parse_smbios_entry_point(&bytes, false), Err(SmbiosDetectionError::InvalidSmbios));
}

#[test]
fn processor_manufacturers_are_parsed() {
    for manufacturer in [
        &b"NVIDIA"[..],
        b" nvidia ",
        b"Ampere Computing",
        b"Microsoft Corporation",
        b"Intel Corporation",
        b"NVIDIA Corporation",
    ] {
        let bytes = table(&[(manufacturer, true)]);
        let processors = parse_processors(&bytes).unwrap();
        assert_eq!(processors[0].as_bytes(), manufacturer.trim_ascii());
    }
}

#[test]
fn unpopulated_sockets_do_not_affect_detection() {
    let bytes = table(&[(b"", false), (b"NVIDIA", true)]);
    let processors = parse_processors(&bytes).unwrap();
    assert_eq!(processors, ["NVIDIA"]);
}

#[test]
fn different_processor_manufacturers_are_preserved() {
    let bytes = table(&[(b"NVIDIA", true), (b"Ampere", true)]);
    let processors = parse_processors(&bytes).unwrap();
    assert_eq!(processors, ["NVIDIA", "Ampere"]);
}

#[test]
fn no_populated_processors_yields_an_empty_list() {
    for bytes in [table(&[]), table(&[(b"", false)])] {
        let processors = parse_processors(&bytes).unwrap();
        assert!(processors.is_empty());
    }
}

#[test]
fn invalid_manufacturer_index_is_rejected() {
    for index in [0, 2] {
        let mut bytes = table(&[(b"NVIDIA", true)]);
        bytes[PROCESSOR_MANUFACTURER_OFFSET] = index;
        assert_eq!(parse_processors(&bytes), Err(SmbiosDetectionError::InvalidProcessorInfo), "index={index}");
    }
}

#[test]
fn manufacturer_uses_its_string_index() {
    let mut bytes = table(&[(b"socket\0NVIDIA\0processor version", true)]);
    bytes[PROCESSOR_MANUFACTURER_OFFSET] = 2;
    assert_eq!(parse_processors(&bytes).unwrap(), ["NVIDIA"]);
}

#[test]
fn invalid_manufacturer_is_rejected() {
    for manufacturer in [&b" "[..], &[255], "NVIDI\u{00c1}".as_bytes()] {
        assert_eq!(
            parse_processors(&table(&[(manufacturer, true)])),
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
            parse_processors(&bytes[..length]),
            Err(SmbiosDetectionError::InvalidSmbios),
            "truncated length {length}"
        );
    }
}

#[test]
fn invalid_record_lengths_are_rejected() {
    let truncated_header = u8::try_from(RECORD_HEADER_BYTES - 1).unwrap();
    let truncated_processor = u8::try_from(PROCESSOR_MIN_BYTES - 1).unwrap();
    for length in [0, truncated_header, truncated_processor, u8::MAX] {
        let mut bytes = table(&[(b"NVIDIA", true)]);
        bytes[RECORD_LENGTH_OFFSET] = length;
        assert_eq!(parse_processors(&bytes), Err(SmbiosDetectionError::InvalidSmbios), "record length {length}");
    }
}

#[test]
fn end_of_table_length_is_checked() {
    for length in 0..=u8::MAX {
        let mut bytes = processor(b"NVIDIA", true);
        let end_offset = bytes.len();
        bytes.extend_from_slice(&[END_OF_TABLE_RECORD_TYPE, length, 0, 0]);
        bytes.resize(end_offset + usize::from(length).max(RECORD_HEADER_BYTES), 0xff);
        bytes.extend_from_slice(&STRING_SET_TERMINATOR);
        let expected = if usize::from(length) == RECORD_HEADER_BYTES {
            Ok(vec!["NVIDIA"])
        } else {
            Err(SmbiosDetectionError::InvalidSmbios)
        };
        assert_eq!(parse_processors(&bytes), expected, "end-of-table length {length}");
    }
}

#[test]
fn nonprocessor_records_and_padding_are_allowed() {
    let mut bytes = vec![1, 4, 0, 0, b'x', 0, 0];
    bytes.extend(table(&[(b"Ampere", true)]));
    bytes.extend_from_slice(&[255; 100]);
    assert_eq!(parse_processors(&bytes).unwrap(), ["Ampere"]);
}
