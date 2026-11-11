// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use uefi::{Result as EfiResult, Status, println};

use crate::{
    smbios::{parse_processors, read_smbios},
    uki::{apply_profile, detect_profile},
};

/// Prepare the hardware boot settings before efitreeloader starts systemd-boot.
/// Read SMBIOS and enable or remove the NVIDIA Grace addon.
/// Return an error on failure so the loader does not continue with an unprepared profile.
pub fn entrypoint() -> EfiResult {
    uefi::helpers::init()?;
    // Detect and report the hardware profile from SMBIOS.
    let table = read_smbios()?;
    let processors = parse_processors(&table).map_err(|error| {
        println!("Cannot parse CPU information in the SMBIOS table: {error:?}");
        Status::COMPROMISED_DATA
    })?;
    let profile = detect_profile(&processors).map_err(|error| {
        println!("Cannot select boot profile: no populated CPUs or conflicting profiles ({error:?}).");
        Status::COMPROMISED_DATA
    })?;
    println!(
        "SMBIOS profile selector: profile={:?}, manufacturer={}, processors={}",
        profile,
        processors[0],
        processors.len()
    );
    // Apply the selected profile before allowing boot to continue.
    apply_profile(profile).inspect_err(|error| println!("Cannot apply {profile:?} boot settings: {error:?}"))?;
    println!("SMBIOS profile selector: configuration complete; returning to efitreeloader.");
    Ok(())
}
