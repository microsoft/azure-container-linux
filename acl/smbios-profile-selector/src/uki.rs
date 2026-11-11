// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

#[cfg(test)]
mod tests;

use alloc::{vec, vec::Vec};
use uefi::{
    CStr16, Result as EfiResult, Status, boot, cstr16, println,
    proto::{
        media::file::{Directory, File, FileAttribute, FileInfo, FileMode, RegularFile},
        shim::ShimLock,
    },
};

use crate::smbios::SmbiosDetectionError;

const MAX_ADDON_BYTES: u64 = 1024 * 1024;
const NVIDIA_GRACE_TEMPLATE_PATH: &CStr16 = cstr16!("\\EFI\\BOOT\\profiles\\nvidia-grace.addon.efi");
const NVIDIA_GRACE_ACTIVE_ADDON_PATH: &CStr16 = cstr16!("\\loader\\addons\\acl-nvidia-grace.addon.efi");
const NVIDIA_GRACE_TEMP_ADDON_PATH: &CStr16 = cstr16!("\\loader\\addons\\acl-nvidia-grace.addon.efi.tmp");
const NVIDIA_GRACE_ADDON_FILENAME: &CStr16 = cstr16!("acl-nvidia-grace.addon.efi");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Profile {
    Generic,
    NvidiaGrace,
}

/// Choose a profile from validated CPU manufacturers.
/// Reject an empty processor list or disagreement on NVIDIA Grace versus Generic.
pub(super) fn detect_profile(processors: &[&str]) -> Result<Profile, SmbiosDetectionError> {
    let (first, rest) = processors
        .split_first()
        .ok_or(SmbiosDetectionError::InvalidProcessorInfo)?;
    let is_nvidia = first.eq_ignore_ascii_case("NVIDIA");
    if rest
        .iter()
        .any(|manufacturer| manufacturer.eq_ignore_ascii_case("NVIDIA") != is_nvidia)
    {
        return Err(SmbiosDetectionError::InvalidProcessorInfo);
    }
    Ok(if is_nvidia {
        Profile::NvidiaGrace
    } else {
        Profile::Generic
    })
}

/// Apply the selected profile without modifying the UKI or unrelated addons.
/// Generic removes the active file; NVIDIA Grace asks shim to verify its template and installs it if needed.
pub(super) fn apply_profile(profile: Profile) -> EfiResult {
    let mut filesystem = boot::get_image_file_system(boot::image_handle())
        .inspect_err(|error| println!("Cannot access the filesystem containing the selector EFI app: {error:?}"))?;
    let mut root = filesystem
        .open_volume()
        .inspect_err(|error| println!("Cannot open the root directory on the selector's filesystem: {error:?}"))?;
    // Generic needs no active hardware addon and does not require the template.
    if profile == Profile::Generic {
        return remove_file(&mut root, NVIDIA_GRACE_ACTIVE_ADDON_PATH);
    }
    // Ask shim to verify the NVIDIA Grace template before modifying addon files.
    let bytes = read_addon(&mut root, NVIDIA_GRACE_TEMPLATE_PATH)?.ok_or(Status::BAD_BUFFER_SIZE)?;
    let shim_handle = boot::get_handle_for_protocol::<ShimLock>()
        .inspect_err(|error| println!("Cannot find shim's image-verification interface (ShimLock): {error:?}"))?;
    let verifier = boot::open_protocol_exclusive::<ShimLock>(shim_handle)
        .inspect_err(|error| println!("Cannot open shim's image-verification interface (ShimLock): {error:?}"))?;
    verifier.verify(&bytes).inspect_err(|error| {
        println!("Shim could not verify the NVIDIA Grace template {NVIDIA_GRACE_TEMPLATE_PATH}: {error:?}")
    })?;
    // Avoid rewriting an unchanged addon on every boot.
    if active_addon_matches(read_addon(&mut root, NVIDIA_GRACE_ACTIVE_ADDON_PATH), &bytes)? {
        return Ok(());
    }
    // Stage and flush so an interrupted write cannot publish partial active contents.
    // systemd-stub ignores .tmp.
    remove_file(&mut root, NVIDIA_GRACE_TEMP_ADDON_PATH)?;
    let mut output = open_file(&mut root, NVIDIA_GRACE_TEMP_ADDON_PATH, FileMode::CreateReadWrite)?;
    output.write(&bytes).map_err(|error| {
        println!("Cannot write the temporary addon {NVIDIA_GRACE_TEMP_ADDON_PATH}: {error:?}");
        error.to_err_without_payload()
    })?;
    output
        .flush()
        .inspect_err(|error| println!("Cannot flush the temporary addon {NVIDIA_GRACE_TEMP_ADDON_PATH}: {error:?}"))?;
    // SetInfo renames the flushed file in place; FileSystem::rename copies then deletes.
    remove_file(&mut root, NVIDIA_GRACE_ACTIVE_ADDON_PATH)?;
    let info = output
        .get_boxed_info::<FileInfo>()
        .inspect_err(|error| println!("Cannot read file information for {NVIDIA_GRACE_TEMP_ADDON_PATH}: {error:?}"))?;
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
    .map_err(|error| {
        println!("Cannot prepare the addon rename to {NVIDIA_GRACE_ADDON_FILENAME}: {error:?}");
        Status::BAD_BUFFER_SIZE
    })?;
    output.set_info(renamed).inspect_err(|error| {
        println!("Cannot rename the temporary addon to {NVIDIA_GRACE_ACTIVE_ADDON_PATH}: {error:?}")
    })?;
    output
        .flush()
        .inspect_err(|error| println!("Cannot flush the active addon {NVIDIA_GRACE_ACTIVE_ADDON_PATH}: {error:?}"))
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
    let size = file
        .get_boxed_info::<FileInfo>()
        .inspect_err(|error| println!("Cannot read file information for addon {path}: {error:?}"))?
        .file_size();
    if !(1..=MAX_ADDON_BYTES).contains(&size) {
        println!("Invalid addon size at {path}: {size} bytes; expected 1 to {MAX_ADDON_BYTES} bytes.");
        return Ok(None);
    }
    // Reject a short read rather than returning an incomplete file buffer.
    let mut bytes = vec![0; size as usize];
    let bytes_read = file
        .read(&mut bytes)
        .inspect_err(|error| println!("Cannot read addon at {path}: {error:?}"))?;
    if bytes_read != bytes.len() {
        println!("Incomplete addon read at {path}: expected {size} bytes, got {bytes_read}.");
        return Err(Status::DEVICE_ERROR.into());
    }
    Ok(Some(bytes))
}

/// Delete a regular file if it exists, treating an already-missing path as success.
/// Propagate other failures, including firmware deletion warnings.
fn remove_file(root: &mut Directory, path: &CStr16) -> EfiResult {
    // An absent file already satisfies removal; all other failures must remain visible.
    match open_file(root, path, FileMode::ReadWrite) {
        Ok(file) => file
            .delete()
            .inspect_err(|error| println!("Cannot delete addon at {path}: {error:?}")),
        Err(error) if error.status() == Status::NOT_FOUND => Ok(()),
        Err(error) => Err(error),
    }
}

/// Open an ESP path as a regular file, with access controlled by `mode`.
/// Reject directories so callers cannot mistake them for addon files.
fn open_file(root: &mut Directory, path: &CStr16, mode: FileMode) -> EfiResult<RegularFile> {
    // UEFI can return a directory handle, but addon callers require a regular file.
    root.open(path, mode, FileAttribute::empty())
        .inspect_err(|error| {
            if error.status() != Status::NOT_FOUND || path == NVIDIA_GRACE_TEMPLATE_PATH {
                println!("Cannot open addon {path} in {mode:?} mode: {error:?}");
            }
        })?
        .into_regular_file()
        .ok_or_else(|| {
            println!("Cannot use addon path {path}: expected a file, not a directory.");
            Status::INVALID_PARAMETER.into()
        })
}
