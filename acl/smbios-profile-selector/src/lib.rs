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

mod entrypoint;
mod smbios;
mod uki;

#[cfg(test)]
mod tests;

pub use entrypoint::entrypoint;
