# SMBIOS Profile Selector

A signed UEFI application that selects a boot profile from SMBIOS processor
information before Linux starts. Populated Type 4 records with manufacturer
`NVIDIA` select the NVIDIA Grace profile; other valid manufacturers select
Generic. Missing, malformed or conflicting processor information stops the boot
path. The app does not identify an Azure VM SKU or distinguish MAIA 200 from
other Intel-based VMs.

## Build and test

Run from this directory. The crate has its own lockfile and Rust toolchain
configuration.

For rust-analyzer in VS Code, open `acl/smbios-profile-selector` directly
so its UEFI workspace settings apply.

```sh
cargo test --locked --lib
bash tests/image.sh
cargo build --locked --release --target aarch64-unknown-uefi
cargo build --locked --release --target x86_64-unknown-uefi
```

Each release build produces
`target/<target>/release/smbios-profile-selector.efi`, where `<target>` is
`aarch64-unknown-uefi` or `x86_64-unknown-uefi`. The build embeds SBAT
metadata using the package version in [Cargo.toml](Cargo.toml).

Source layout:

- [main.rs](src/main.rs): UEFI entrypoint and top-level error reporting.
- [entrypoint.rs](src/entrypoint.rs): coordinates detection and boot-profile
  application.
- [smbios.rs](src/smbios.rs): reads and parses SMBIOS processor information.
- [uki.rs](src/uki.rs): selects the boot profile and manages its signed addon.
- unit tests: [SMBIOS](src/smbios/tests.rs), [UKI](src/uki/tests.rs),
  and [SBAT metadata](src/tests.rs).

To build an ARM64 validation image, prepare the SDK as described in the
[image build guide](../docs/BUILD_RPM_IMAGE_README.md), install the pinned Rust
toolchain, and run from the repository root:

```sh
ACL_SMBIOS_PROFILE_SELECTOR=true BOOTLOADER_MODE=uki \
  EFITREELOADER_DIR=/path/to/efitreeloader \
  ./acl/build_rpm_image.sh --build-rpms --build-image --build-vm-image \
    --board=arm64-usr --vm-type=azure
```

This opt-in selects `kernel-hwe` and builds the selector and configured
efitreeloader from source. The dependency checkout is not modified. Normal
builds remain unchanged when the option is off.

Validation images use ephemeral signing keys, not production trust. Existing
installations need the Trident boot-resource update before adopting this boot
chain.

## Boot integration

The app runs after shim and before systemd-boot.

Build and sign a command-line-only addon from
[nvidia-grace-kernel-parameters.txt](boot/nvidia-grace-kernel-parameters.txt),
without `.linux` or `.uname` sections. The app uses these ESP paths:

- `EFI/BOOT/profiles/nvidia-grace.addon.efi`:
  Inactive, pre-signed NVIDIA Grace template.
- `loader/addons/acl-nvidia-grace.addon.efi`:
  Selector-owned global addon; present for NVIDIA Grace, absent for Generic.

The image must create `loader/addons/`, leave the hardware addon inactive, and
keep the NVIDIA Grace arguments out of the default UKI and other active addons.
The selector asks shim to verify the template before activation. Generic removes
only the selector-owned addon. Other addons and the UKI remain unchanged.
