// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

//! SMBIOS-based boot-profile selection for Azure Container Linux.
//!
//! efitreeloader runs this selector after shim and before systemd-boot. It prepares
//! hardware-specific kernel parameters through an addon, without changing the UKI.
//!
//! Populated SMBIOS Type 4 processor records determine the profile:
//!
//! - Manufacturer `NVIDIA`: activate the signed NVIDIA Grace command-line addon.
//! - Other valid manufacturers: remove the selector-owned addon for Generic.
//!
//! The NVIDIA Grace template is passed to shim for verification before activation.
//! Unrelated addons remain unchanged. Missing, malformed, or conflicting processor
//! information and addon-update failures return errors rather than silently falling
//! back to Generic.

#![no_std]

extern crate alloc;

use alloc::{vec, vec::Vec};
use core::{slice, str};
use uefi::{
    CStr16, Result as EfiResult, Status, boot, cstr16,
    mem::memory_map::MemoryMap,
    println,
    proto::{
        media::file::{Directory, File, FileAttribute, FileInfo, FileMode, RegularFile},
        shim::ShimLock,
    },
    system,
    table::cfg::ConfigTableEntry,
};

const MAX_SMBIOS_TABLE_BYTES: usize = 1024 * 1024;
const MAX_ADDON_BYTES: u64 = 1024 * 1024;
const NVIDIA_GRACE_TEMPLATE_PATH: &CStr16 = cstr16!("\\EFI\\BOOT\\profiles\\nvidia-grace.addon.efi");
const NVIDIA_GRACE_ACTIVE_ADDON_PATH: &CStr16 = cstr16!("\\loader\\addons\\acl-nvidia-grace.addon.efi");
const NVIDIA_GRACE_TEMP_ADDON_PATH: &CStr16 = cstr16!("\\loader\\addons\\acl-nvidia-grace.addon.efi.tmp");
const NVIDIA_GRACE_ADDON_FILENAME: &CStr16 = cstr16!("acl-nvidia-grace.addon.efi");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Profile {
    Generic,
    NvidiaGrace,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SmbiosTableLocation {
    address: u64,
    length: usize,
}

#[derive(Debug, PartialEq, Eq)]
struct SmbiosDetection<'a> {
    profile: Profile,
    manufacturer: &'a str,
    populated_processors: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SmbiosDetectionError {
    InvalidSmbios,
    InvalidProcessorInfo,
}

/// Prepare the hardware boot settings before efitreeloader starts systemd-boot.
/// Read SMBIOS and enable or remove the NVIDIA Grace addon.
/// Return an error on failure so the loader does not continue with an unprepared profile.
pub fn entrypoint() -> EfiResult {
    uefi::helpers::init()?;
    // Detect and report the hardware profile from SMBIOS.
    let table = read_smbios()?;
    let detection = detect_profile(&table).map_err(|error| {
        println!("Cannot determine CPU profile from SMBIOS: {error:?}");
        Status::COMPROMISED_DATA
    })?;
    println!(
        "SMBIOS profile selector: profile={:?}, manufacturer={}, processors={}",
        detection.profile, detection.manufacturer, detection.populated_processors
    );
    // Apply the selected profile before allowing boot to continue.
    apply_profile(detection.profile)
        .inspect_err(|error| println!("Cannot prepare {:?} addon: {error:?}", detection.profile))?;
    println!("SMBIOS profile selector: configuration complete; returning to efitreeloader.");
    Ok(())
}

/// Find the SMBIOS table provided by firmware and return an owned copy of its bytes.
/// Use SMBIOS 3 by default; fall back to SMBIOS 2 if the SMBIOS 3 entry is not found.
fn read_smbios() -> EfiResult<Vec<u8>> {
    // Find the preferred SMBIOS entry-point header in the firmware configuration tables.
    let (address, smbios3) = system::with_config_table(|entries| {
        entries
            .iter()
            .find(|entry| entry.guid == ConfigTableEntry::SMBIOS3_GUID)
            .map(|entry| (entry.address as usize, true))
            .or_else(|| {
                entries
                    .iter()
                    .find(|entry| entry.guid == ConfigTableEntry::SMBIOS_GUID)
                    .map(|entry| (entry.address as usize, false))
            })
    })
    .ok_or_else(|| {
        println!("No SMBIOS configuration table was provided by firmware.");
        Status::NOT_FOUND
    })?;
    // Read the header prefix to determine how many entry-point bytes to copy.
    let header = read_firmware_memory(address, 7, false)?;
    let length = usize::from(header[if smbios3 { 6 } else { 5 }]);
    // Validate the full header, then copy the table from its reported memory range.
    let entry = read_firmware_memory(address, length, false)?;
    let location = parse_smbios_entry_point(&entry, smbios3).map_err(|error| {
        println!("Invalid SMBIOS entry point: {error:?}");
        Status::COMPROMISED_DATA
    })?;
    let address = usize::try_from(location.address).map_err(|_| Status::INVALID_PARAMETER)?;
    // SMBIOS 3 reports an upper bound; the parser still requires a complete Type 127 end marker.
    read_firmware_memory(address, location.length, smbios3)
}

/// Validate an SMBIOS 2 or 3 header and return the table's memory address and read bound.
/// Reject invalid header markers, checksums, versions, or table ranges.
fn parse_smbios_entry_point(entry: &[u8], smbios3: bool) -> Result<SmbiosTableLocation, SmbiosDetectionError> {
    // Validate the minimum header size, format marker, and declared length.
    let minimum = if smbios3 { 24 } else { 31 };
    let length_offset = if smbios3 { 6 } else { 5 };
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
        if entry[7] < 3 {
            return Err(SmbiosDetectionError::InvalidSmbios);
        }
        (
            u64::from_le_bytes(entry[16..24].try_into().unwrap()),
            u32::from_le_bytes(entry[12..16].try_into().unwrap()) as usize,
        )
    } else {
        if entry[6] < 2 || &entry[16..21] != b"_DMI_" {
            return Err(SmbiosDetectionError::InvalidSmbios);
        }
        if entry[16..31].iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)) != 0 {
            return Err(SmbiosDetectionError::InvalidSmbios);
        }
        (
            u64::from(u32::from_le_bytes(entry[24..28].try_into().unwrap())),
            usize::from(u16::from_le_bytes(entry[22..24].try_into().unwrap())),
        )
    };
    // Enforce the table-size limit and reject empty, null, or overflowing ranges.
    if address == 0 || length == 0 || length > MAX_SMBIOS_TABLE_BYTES || address.checked_add(length as u64).is_none() {
        return Err(SmbiosDetectionError::InvalidSmbios);
    }
    Ok(SmbiosTableLocation { address, length })
}

/// Choose a boot profile from populated Type 4 processor records in the SMBIOS table.
/// Manufacturer `NVIDIA` selects NVIDIA Grace; other valid manufacturers select Generic.
/// Reject malformed tables, missing processor information, or records that disagree on the profile.
fn detect_profile(mut table: &[u8]) -> Result<SmbiosDetection<'_>, SmbiosDetectionError> {
    let mut detection: Option<SmbiosDetection<'_>> = None;
    while !table.is_empty() {
        // Validate the record header before reading its formatted fields.
        let header = table.get(..4).ok_or(SmbiosDetectionError::InvalidSmbios)?;
        let length = usize::from(header[1]);
        if length < 4 {
            return Err(SmbiosDetectionError::InvalidSmbios);
        }
        let formatted = table.get(..length).ok_or(SmbiosDetectionError::InvalidSmbios)?;
        let trailing = &table[length..];
        // Every record ends with a string set terminated by two NUL bytes.
        let terminator = trailing
            .windows(2)
            .position(|bytes| bytes == [0, 0])
            .ok_or(SmbiosDetectionError::InvalidSmbios)?;
        let strings = &trailing[..terminator];
        table = &trailing[terminator + 2..];
        // Stop at the end marker and skip records that do not describe processors.
        if header[0] == 127 {
            return detection.ok_or(SmbiosDetectionError::InvalidProcessorInfo);
        }
        if header[0] != 4 {
            continue;
        }
        if length < 26 {
            return Err(SmbiosDetectionError::InvalidSmbios);
        }
        // Ignore empty sockets; bit 6 in the processor status marks a populated CPU.
        if formatted[24] & 0x40 == 0 {
            continue;
        }
        // Resolve the manufacturer using its one-based index into the record's string set.
        let manufacturer = usize::from(formatted[7])
            .checked_sub(1)
            .and_then(|index| strings.split(|byte| *byte == 0).nth(index))
            .and_then(|bytes| str::from_utf8(bytes).ok())
            .map(str::trim_ascii)
            .filter(|value| !value.is_empty() && value.is_ascii())
            .ok_or(SmbiosDetectionError::InvalidProcessorInfo)?;
        // Select the profile and require all populated processors to agree.
        let profile = if manufacturer.eq_ignore_ascii_case("NVIDIA") {
            Profile::NvidiaGrace
        } else {
            Profile::Generic
        };
        if let Some(current) = detection.as_mut() {
            if current.profile != profile {
                return Err(SmbiosDetectionError::InvalidProcessorInfo);
            }
            current.populated_processors += 1;
        } else {
            detection = Some(SmbiosDetection {
                profile,
                manufacturer,
                populated_processors: 1,
            });
        }
    }
    // Exhausting the input without an end marker means the table is incomplete.
    Err(SmbiosDetectionError::InvalidSmbios)
}

/// Bound a read to the end of a validated firmware data region.
/// Only SMBIOS 3 table reads may be shorter than their advertised maximum.
fn firmware_read_length(address: usize, length: usize, allow_short: bool, region_end: u64) -> Option<usize> {
    let available = region_end.checked_sub(address as u64)?;
    if address == 0 || length == 0 || available == 0 || (!allow_short && length as u64 > available) {
        return None;
    }
    usize::try_from((length as u64).min(available)).ok()
}

/// Copy firmware bytes into owned memory after validating them against the UEFI memory map.
/// Header and SMBIOS 2 reads are exact; SMBIOS 3 table reads may stop at the mapped region's end.
fn read_firmware_memory(address: usize, length: usize, allow_short: bool) -> EfiResult<Vec<u8>> {
    address.checked_add(length).ok_or(Status::INVALID_PARAMETER)?;
    let memory = boot::memory_map(boot::MemoryType::LOADER_DATA)?;
    let read_length = memory.entries().find_map(|entry| {
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
        firmware_read_length(address, length, allow_short, end)
    });
    let read_length = read_length.ok_or_else(|| {
        println!(
            "Error: Cannot read SMBIOS data at {address:#x} ({length} bytes): \
             expected a nonzero address and a nonempty range within one firmware data region."
        );
        Status::COMPROMISED_DATA
    })?;
    // Firmware owns these identity-mapped tables before ExitBootServices.
    // The checked range excludes MMIO/code regions and stays within one allocation.
    Ok(unsafe { slice::from_raw_parts(address as *const u8, read_length) }.to_vec())
}

/// Apply the selected profile without modifying the UKI or unrelated addons.
/// Generic removes the active file; NVIDIA Grace asks shim to verify its template and installs it if needed.
fn apply_profile(profile: Profile) -> EfiResult {
    let mut filesystem = boot::get_image_file_system(boot::image_handle())?;
    let mut root = filesystem.open_volume()?;
    // Generic needs no active hardware addon and does not require the template.
    if profile == Profile::Generic {
        return remove_file(&mut root, NVIDIA_GRACE_ACTIVE_ADDON_PATH);
    }
    // Ask shim to verify the NVIDIA Grace template before modifying addon files.
    let bytes = read_addon(&mut root, NVIDIA_GRACE_TEMPLATE_PATH)?.ok_or(Status::BAD_BUFFER_SIZE)?;
    let handle = boot::get_handle_for_protocol::<ShimLock>()?;
    let verifier = boot::open_protocol_exclusive::<ShimLock>(handle)?;
    verifier.verify(&bytes)?;
    // Avoid rewriting an unchanged addon on every boot.
    if active_addon_matches(read_addon(&mut root, NVIDIA_GRACE_ACTIVE_ADDON_PATH), &bytes)? {
        return Ok(());
    }
    // Stage and flush so an interrupted write cannot publish partial active contents.
    // systemd-stub ignores .tmp.
    remove_file(&mut root, NVIDIA_GRACE_TEMP_ADDON_PATH)?;
    let mut output = open_file(&mut root, NVIDIA_GRACE_TEMP_ADDON_PATH, FileMode::CreateReadWrite)?;
    output.write(&bytes).map_err(|error| error.to_err_without_payload())?;
    output.flush()?;
    // SetInfo renames the flushed file in place; FileSystem::rename copies then deletes.
    remove_file(&mut root, NVIDIA_GRACE_ACTIVE_ADDON_PATH)?;
    let info = output.get_boxed_info::<FileInfo>()?;
    let mut storage = [0; 256];
    let renamed = FileInfo::new(
        &mut storage,
        info.file_size(),
        info.physical_size(),
        *info.create_time(),
        *info.last_access_time(),
        *info.modification_time(),
        info.attribute(),
        NVIDIA_GRACE_ADDON_FILENAME,
    )
    .map_err(|_| Status::BAD_BUFFER_SIZE)?;
    output.set_info(renamed)?;
    output.flush()
}

/// Treat a missing or invalid-size active addon as replaceable, but retain file I/O errors.
fn active_addon_matches(existing: EfiResult<Option<Vec<u8>>>, expected: &[u8]) -> EfiResult<bool> {
    match existing {
        Ok(existing) => Ok(existing.as_deref() == Some(expected)),
        Err(error) if error.status() == Status::NOT_FOUND => Ok(false),
        Err(error) => Err(error),
    }
}

/// Read the complete addon, returning None for an invalid file size.
/// Keep firmware errors separate: metadata failures may also report BAD_BUFFER_SIZE.
fn read_addon(root: &mut Directory, path: &CStr16) -> EfiResult<Option<Vec<u8>>> {
    let mut file = open_file(root, path, FileMode::Read)?;
    // Validate the reported size before allocating the read buffer.
    let size = file.get_boxed_info::<FileInfo>()?.file_size();
    if !(1..=MAX_ADDON_BYTES).contains(&size) {
        println!("Invalid addon size at {path}: {size} bytes.");
        return Ok(None);
    }
    // Reject a short read rather than returning an incomplete file buffer.
    let mut bytes = vec![0; size as usize];
    if file.read(&mut bytes)? != bytes.len() {
        return Err(Status::DEVICE_ERROR.into());
    }
    Ok(Some(bytes))
}

/// Delete a regular file if it exists, treating an already-missing path as success.
/// Propagate other failures, including firmware deletion warnings.
fn remove_file(root: &mut Directory, path: &CStr16) -> EfiResult {
    // An absent file already satisfies removal; all other failures must remain visible.
    match open_file(root, path, FileMode::ReadWrite) {
        Ok(file) => file.delete(),
        Err(error) if error.status() == Status::NOT_FOUND => Ok(()),
        Err(error) => Err(error),
    }
}

/// Open an ESP path as a regular file, with access controlled by `mode`.
/// Reject directories so callers cannot mistake them for addon files.
fn open_file(root: &mut Directory, path: &CStr16, mode: FileMode) -> EfiResult<RegularFile> {
    // UEFI can return a directory handle, but addon callers require a regular file.
    root.open(path, mode, FileAttribute::empty())?
        .into_regular_file()
        .ok_or_else(|| Status::INVALID_PARAMETER.into())
}

#[cfg(test)]
#[path = "../tests/unit.rs"]
mod tests;
