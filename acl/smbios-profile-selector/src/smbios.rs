// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use alloc::vec::Vec;
use core::{ops::Range, ptr, slice, str};
use uefi::{
    Result as EfiResult, Status, boot, mem::memory_map::MemoryMap, println, system, table::cfg::ConfigTableEntry,
};

pub(super) const MAX_SMBIOS_TABLE_BYTES: usize = 1024 * 1024;

pub(super) const SMBIOS2_ENTRY_POINT_BYTES: usize = 31;
pub(super) const SMBIOS2_LENGTH_OFFSET: usize = 5;
pub(super) const SMBIOS2_MAJOR_VERSION_OFFSET: usize = 6;
pub(super) const SMBIOS2_MIN_MAJOR_VERSION: u8 = 2;
pub(super) const SMBIOS2_INTERMEDIATE_ANCHOR_RANGE: Range<usize> = 16..21;
pub(super) const SMBIOS2_INTERMEDIATE_HEADER_RANGE: Range<usize> = 16..31;
pub(super) const SMBIOS2_TABLE_LENGTH_RANGE: Range<usize> = 22..24;
pub(super) const SMBIOS2_TABLE_ADDRESS_RANGE: Range<usize> = 24..28;

pub(super) const SMBIOS3_ENTRY_POINT_BYTES: usize = 24;
pub(super) const SMBIOS3_LENGTH_OFFSET: usize = 6;
pub(super) const SMBIOS3_MAJOR_VERSION_OFFSET: usize = 7;
pub(super) const SMBIOS3_MIN_MAJOR_VERSION: u8 = 3;
pub(super) const SMBIOS3_TABLE_MAX_SIZE_RANGE: Range<usize> = 12..16;
pub(super) const SMBIOS3_TABLE_ADDRESS_RANGE: Range<usize> = 16..24;
pub(super) const ENTRY_POINT_PREFIX_BYTES: usize = SMBIOS3_LENGTH_OFFSET + 1;

pub(super) const RECORD_HEADER_BYTES: usize = 4;
pub(super) const RECORD_TYPE_OFFSET: usize = 0;
pub(super) const RECORD_LENGTH_OFFSET: usize = 1;
pub(super) const PROCESSOR_RECORD_TYPE: u8 = 4;
pub(super) const END_OF_TABLE_RECORD_TYPE: u8 = 127;
pub(super) const PROCESSOR_MIN_BYTES: usize = 26;
pub(super) const PROCESSOR_MANUFACTURER_OFFSET: usize = 7;
pub(super) const PROCESSOR_STATUS_OFFSET: usize = 24;
pub(super) const PROCESSOR_POPULATED_MASK: u8 = 0x40;
pub(super) const STRING_SET_TERMINATOR: [u8; 2] = [0, 0];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct SmbiosTableLocation {
    pub(super) address: u64,
    pub(super) length: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum SmbiosDetectionError {
    InvalidSmbios,
    InvalidProcessorInfo,
}

/// Find the SMBIOS table provided by firmware and return an owned copy of its bytes.
/// Use SMBIOS 3 by default; fall back to SMBIOS 2 if the SMBIOS 3 entry is not found.
pub(super) fn read_smbios() -> EfiResult<Vec<u8>> {
    // Find the preferred SMBIOS entry-point header in the firmware configuration tables.
    let (pointer, smbios3) = system::with_config_table(|entries| {
        entries
            .iter()
            .find(|entry| entry.guid == ConfigTableEntry::SMBIOS3_GUID)
            .map(|entry| (entry.address.cast::<u8>(), true))
            .or_else(|| {
                entries
                    .iter()
                    .find(|entry| entry.guid == ConfigTableEntry::SMBIOS_GUID)
                    .map(|entry| (entry.address.cast::<u8>(), false))
            })
    })
    .ok_or_else(|| {
        println!("No SMBIOS entry point in the UEFI configuration table.");
        Status::NOT_FOUND
    })?;
    // Read the header prefix to determine how many entry-point bytes to copy.
    let header = read_firmware_memory(pointer, ENTRY_POINT_PREFIX_BYTES, false)?;
    let length = usize::from(
        header[if smbios3 {
            SMBIOS3_LENGTH_OFFSET
        } else {
            SMBIOS2_LENGTH_OFFSET
        }],
    );
    // Validate the full header, then copy the table from its reported memory range.
    let entry = read_firmware_memory(pointer, length, false)?;
    let location = parse_smbios_entry_point(&entry, smbios3).map_err(|error| {
        println!("Invalid SMBIOS entry-point header at {pointer:p}: {error:?}");
        Status::COMPROMISED_DATA
    })?;
    let address = usize::try_from(location.address).map_err(|error| {
        println!("SMBIOS table address {:#x} exceeds the {}-bit address range: {error}", location.address, usize::BITS);
        Status::INVALID_PARAMETER
    })?;
    // The SMBIOS header gives a physical address, convert it to a pointer first.
    let table_pointer = ptr::with_exposed_provenance::<u8>(address);
    // SMBIOS 3 reports an upper bound; the parser still requires a complete Type 127 end marker.
    read_firmware_memory(table_pointer, location.length, smbios3)
}

/// Validate an SMBIOS 2 or 3 header and return the table's memory address and read bound.
/// Reject invalid header markers, checksums, versions, or table ranges.
pub(super) fn parse_smbios_entry_point(
    entry: &[u8],
    smbios3: bool,
) -> Result<SmbiosTableLocation, SmbiosDetectionError> {
    // Validate the minimum header size, format marker, and declared length.
    let minimum = if smbios3 {
        SMBIOS3_ENTRY_POINT_BYTES
    } else {
        SMBIOS2_ENTRY_POINT_BYTES
    };
    let length_offset = if smbios3 {
        SMBIOS3_LENGTH_OFFSET
    } else {
        SMBIOS2_LENGTH_OFFSET
    };
    if entry.len() < minimum {
        return Err(SmbiosDetectionError::InvalidSmbios);
    }
    let anchor: &[u8] = if smbios3 { b"_SM3_" } else { b"_SM_" };
    let length = usize::from(entry[length_offset]);
    if !entry.starts_with(anchor) || length < minimum || length > entry.len() {
        return Err(SmbiosDetectionError::InvalidSmbios);
    }
    // Verify the checksum before trusting the table location.
    if entry[..length].iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)) != 0 {
        return Err(SmbiosDetectionError::InvalidSmbios);
    }
    // Decode the version-specific address and length; the field bounds were checked above.
    let (address, length) = if smbios3 {
        if entry[SMBIOS3_MAJOR_VERSION_OFFSET] < SMBIOS3_MIN_MAJOR_VERSION {
            return Err(SmbiosDetectionError::InvalidSmbios);
        }
        (
            u64::from_le_bytes(entry[SMBIOS3_TABLE_ADDRESS_RANGE].try_into().unwrap()),
            u32::from_le_bytes(entry[SMBIOS3_TABLE_MAX_SIZE_RANGE].try_into().unwrap()) as usize,
        )
    } else {
        if entry[SMBIOS2_MAJOR_VERSION_OFFSET] < SMBIOS2_MIN_MAJOR_VERSION
            || &entry[SMBIOS2_INTERMEDIATE_ANCHOR_RANGE] != b"_DMI_"
        {
            return Err(SmbiosDetectionError::InvalidSmbios);
        }
        if entry[SMBIOS2_INTERMEDIATE_HEADER_RANGE]
            .iter()
            .fold(0u8, |sum, byte| sum.wrapping_add(*byte))
            != 0
        {
            return Err(SmbiosDetectionError::InvalidSmbios);
        }
        (
            u64::from(u32::from_le_bytes(entry[SMBIOS2_TABLE_ADDRESS_RANGE].try_into().unwrap())),
            usize::from(u16::from_le_bytes(entry[SMBIOS2_TABLE_LENGTH_RANGE].try_into().unwrap())),
        )
    };
    // Enforce the table-size limit and reject empty, null, or overflowing ranges.
    if address == 0 || length == 0 || length > MAX_SMBIOS_TABLE_BYTES || address.checked_add(length as u64).is_none() {
        return Err(SmbiosDetectionError::InvalidSmbios);
    }
    Ok(SmbiosTableLocation { address, length })
}

/// Parse and validate manufacturers from populated Type 4 processor records.
/// Return borrowed strings without applying boot-profile policy.
pub(super) fn parse_processors(mut table: &[u8]) -> Result<Vec<&str>, SmbiosDetectionError> {
    let mut processors = Vec::new();
    while !table.is_empty() {
        // Validate the record header before reading its formatted fields.
        let header = table
            .get(..RECORD_HEADER_BYTES)
            .ok_or(SmbiosDetectionError::InvalidSmbios)?;
        let length = usize::from(header[RECORD_LENGTH_OFFSET]);
        if length < RECORD_HEADER_BYTES {
            return Err(SmbiosDetectionError::InvalidSmbios);
        }
        let formatted = table.get(..length).ok_or(SmbiosDetectionError::InvalidSmbios)?;
        let trailing = &table[length..];
        // Every record ends with a string set terminated by two NUL bytes.
        let terminator = trailing
            .windows(STRING_SET_TERMINATOR.len())
            .position(|bytes| bytes == STRING_SET_TERMINATOR)
            .ok_or(SmbiosDetectionError::InvalidSmbios)?;
        let strings = &trailing[..terminator];
        table = &trailing[terminator + STRING_SET_TERMINATOR.len()..];
        // Stop at the end marker and skip records that do not describe processors.
        if header[RECORD_TYPE_OFFSET] == END_OF_TABLE_RECORD_TYPE {
            if length != RECORD_HEADER_BYTES {
                return Err(SmbiosDetectionError::InvalidSmbios);
            }
            return Ok(processors);
        }
        if header[RECORD_TYPE_OFFSET] != PROCESSOR_RECORD_TYPE {
            continue;
        }
        if length < PROCESSOR_MIN_BYTES {
            return Err(SmbiosDetectionError::InvalidSmbios);
        }
        // Ignore empty sockets; bit 6 in the processor status marks a populated CPU.
        if formatted[PROCESSOR_STATUS_OFFSET] & PROCESSOR_POPULATED_MASK == 0 {
            continue;
        }
        // Resolve the manufacturer using its one-based index into the record's string set.
        let manufacturer = usize::from(formatted[PROCESSOR_MANUFACTURER_OFFSET])
            .checked_sub(1)
            .and_then(|index| strings.split(|byte| *byte == 0).nth(index))
            .and_then(|bytes| str::from_utf8(bytes).ok())
            .map(str::trim_ascii)
            .filter(|value| !value.is_empty() && value.is_ascii())
            .ok_or(SmbiosDetectionError::InvalidProcessorInfo)?;
        processors.push(manufacturer);
    }
    // Exhausting the input without an end marker means the table is incomplete.
    Err(SmbiosDetectionError::InvalidSmbios)
}

/// Bound the slice length to readable firmware bytes before constructing it.
/// Exact-read bounds are checked on the slice afterward.
pub(super) fn firmware_read_length(address: usize, length: usize, region_end: u64) -> Option<usize> {
    let available = region_end.checked_sub(address as u64)?;
    if address == 0 || length == 0 || available == 0 {
        return None;
    }
    usize::try_from((length as u64).min(available)).ok()
}

/// Copy firmware bytes into owned memory after validating them against the UEFI memory map.
/// Header and SMBIOS 2 reads are exact; SMBIOS 3 table reads may stop at the mapped region's end.
fn read_firmware_memory(pointer: *const u8, length: usize, allow_short: bool) -> EfiResult<Vec<u8>> {
    let address = pointer.addr();
    address.checked_add(length).ok_or_else(|| {
        println!("SMBIOS read at {address:#x} for {length} bytes overflows the address range.");
        Status::INVALID_PARAMETER
    })?;
    let memory = boot::memory_map(boot::MemoryType::LOADER_DATA)
        .inspect_err(|error| println!("Cannot query the UEFI memory map for SMBIOS address {address:#x}: {error:?}"))?;
    let bytes = memory.entries().find_map(|entry| {
        if !matches!(
            entry.ty,
            boot::MemoryType::RESERVED
                | boot::MemoryType::LOADER_DATA
                | boot::MemoryType::BOOT_SERVICES_DATA
                | boot::MemoryType::RUNTIME_SERVICES_DATA
                | boot::MemoryType::ACPI_RECLAIM
                | boot::MemoryType::ACPI_NON_VOLATILE
        ) || entry.phys_start > address as u64
        {
            return None;
        }
        let end = entry
            .phys_start
            .checked_add(entry.page_count.checked_mul(boot::PAGE_SIZE as u64)?)?;
        let mapped_length = firmware_read_length(address, length, end)?;
        // Create the slice only after validating the firmware memory range above.
        let bytes = unsafe { slice::from_raw_parts(pointer, mapped_length) };
        let bytes = if allow_short { bytes } else { bytes.get(..length)? };
        Some(bytes.to_vec())
    });
    bytes.ok_or_else(|| {
        println!("SMBIOS read at {address:#x} ({length} bytes) has an invalid or unreadable memory range.");
        Status::COMPROMISED_DATA.into()
    })
}
