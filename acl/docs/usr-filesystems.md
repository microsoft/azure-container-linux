# Opt-in `/usr` filesystems

Btrfs remains the default. EXT4 is an opt-in **qualification path**, not a
production-support or existing-machine migration claim. It currently accepts
RPM/UKI, AMD64/ARM64, and base/QEMU/Azure disk layouts. Official builds, GRUB,
container layouts and legacy update-engine payload generation reject the opt-in.
Rootfs verification must remain enabled: disabling it bypasses filesystem sealing
and verity generation, so unverified outputs are rejected before layout checks.

```sh
./acl/build_rpm_image.sh --usr-fs=ext4 --build-image --build-vm-image
# Equivalent pipeline variable: ACL_EXPERIMENTAL_USR_FS=ext4
```

Unset/empty or explicit `btrfs` keeps the existing layout and formatter. The CLI
overrides the environment. Existing pipeline artifact names remain unchanged.
`build_library/usr_filesystem.sh` owns shell validation, SDK profile clearing,
source-image metadata validation and native readonly mount options.
The wrapper's `--build-test-image` converts the verified prod artifact to QEMU or
Azure with test additions in OEM/ESP; it is not a separate core `test` image type
and retains the selected readonly `/usr` filesystem.

SDK create/exec forwards the selector; login setup refreshes or clears it.
`version.txt` records `ACL_USR_FS_METADATA_VERSION=1` and the resolved
`ACL_EXPERIMENTAL_USR_FS`, `ACL_USR_BOARD` and `ACL_USR_BOOTLOADER`.
Conversion rejects board/bootloader mismatches and adopts the source selection only when the
caller did not explicitly select another format. Legacy untagged Btrfs images
remain usable; missing opt-in provenance, unknown metadata versions and explicit
format conflicts fail. Conversion does not migrate an existing filesystem.

EXT4 uses checksum-enabled, journal-less filesystems with the native `read-only`
feature. Sealing and unsealing run fsck before and after checksum-aware
`tune2fs -O read-only` / `^read-only`. Offline mounts use `ro,noload`; unsealing
invalidates the previous verity tree/signature and requires regeneration.
Format-specific mount flags live in each slot's UKI addon, never in the shared
main UKI, so EXT4's `noload` is not inherited by a Btrfs rollback slot.

The current EXT4 budget is 4 GiB per USR slot and 64 MiB per HASH slot. **These
are not qualified final production sizes.** Builds emit
`*_verity-capacity.json`: data/filesystem/used/free bytes, inode headroom, exact
SHA-256 tree requirement, hash capacity and hash headroom. Hash overflow, actual
EXT4-size mismatch, wrong hash destinations, overlapping/out-of-image extents,
and incompatible existing USR/HASH geometry fail before sealing/writing.
Image probes use actual rather than proposed enlarged partition ranges.
Unrelated ROOT growth for VM conversion remains supported.

Old 1-GiB-USR layouts require reimaging or a separately qualified migration.
`disk_util update` cannot silently resize verity slots or change their filesystem.
Trident/device-side layout admission and Image Customizer's
unseal/customize/reseal lifecycle require companion validation; these source
checks do not replace those consumers.

Run `bash acl/tests/usr-filesystem/run.sh`. The suite covers Btrfs defaults,
both architectures, provenance, SDK reuse, readonly features, capacity and
pre-write rejection. Native regular-file e2fsprogs/verity checks run only on
an existing Linux environment with the tools present; a skip is not a pass.
These checks require neither mounts nor privileged changes to a host OS.

Full SDK images and capacity measurements for both architectures, new-image
boot/reboot/Ignition/sysext tests, customization/COSI round trips, A/B interruption
and rollback, and controlled CI remain acceptance gates. IPE is a separate
test-integration dependency on microsoft/azure-container-linux#52; this change
does not install a policy, supply production signing or alter audit fallback.
Fixture-only results and detailed lab reports are intentionally outside this
shipping change.
