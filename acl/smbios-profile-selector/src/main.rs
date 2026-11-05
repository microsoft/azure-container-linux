// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

#![no_main]
#![no_std]

use uefi::{ResultExt, Status, entry, println};

#[unsafe(link_section = ".sbat")]
#[used]
static SBAT: [u8; include_bytes!(concat!(env!("OUT_DIR"), "/sbat.csv")).len()] =
    *include_bytes!(concat!(env!("OUT_DIR"), "/sbat.csv"));

/// Run the selector, print any failure, and return a UEFI status to the calling loader.
#[entry]
fn main() -> Status {
    // The EFI caller expects a status code, not a Rust Result.
    smbios_profile_selector::entrypoint()
        .inspect_err(|error| println!("SMBIOS profile selector failed: {error:?}"))
        .status()
}
