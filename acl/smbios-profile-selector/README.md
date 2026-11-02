# SMBIOS Profile Selector

A signed UEFI application that selects a boot profile from SMBIOS processor information before Linux starts. Populated Type 4 records with manufacturer `NVIDIA` select the NVIDIA Grace profile; other valid manufacturers select Generic. Missing, malformed or conflicting processor information stops the boot path. The app does not identify an Azure VM SKU or distinguish MAIA 200 from other Intel-based VMs.

## Build and test

Run from this directory. The crate has its own lockfile and Rust toolchain configuration.

```sh
cargo test --locked --lib
cargo build --locked --release --target aarch64-unknown-uefi
cargo build --locked --release --target x86_64-unknown-uefi
```

The EFI binary is `target/<target>/release/smbios-profile-selector.efi`. Implementation is in [lib/lib.rs](lib/lib.rs), native unit tests in [tests/unit.rs](tests/unit.rs), and the thin EFI entrypoint in [src/main.rs](src/main.rs).

## Boot integration

The app runs after the original shim and before systemd-boot. On ARM64, install the signed loader as `EFI/BOOT/grubaa64.efi`, the signed selector alongside it as `smbios-profile-selector.efi`, and systemd-boot as `EFI/BOOT/3rdaa64.efi`.

Build and sign a command-line-only addon from [nvidia-grace-kernel-parameters.txt](boot/nvidia-grace-kernel-parameters.txt), without `.linux` or `.uname` sections. The app uses these ESP paths:

| ESP path | Role |
| --- | --- |
| `EFI/BOOT/profiles/nvidia-grace.addon.efi` | Inactive, pre-signed NVIDIA Grace template. |
| `loader/addons/acl-nvidia-grace.addon.efi` | Selector-owned global addon; present for NVIDIA Grace, absent for Generic. |
| `loader/addons/acl-nvidia-grace.addon.efi.tmp` | Temporary file used while replacing the active addon. |

The image must create `loader/addons/`, leave the hardware addon inactive, and keep the NVIDIA Grace arguments out of the default UKI and other active addons. The selector asks shim to verify the template, flushes the temporary file, then renames it in place. Generic removes only the selector-owned addon. Other addons and the UKI remain unchanged.

**Compatibility:** Replace `EFI/BOOT/profiles/grace.addon.efi` with the renamed template and remove legacy `.extra.d/acl-grace.addon.efi` and `loader/addons/acl-grace.addon.efi` copies, so only the new layout is signed and activated.
