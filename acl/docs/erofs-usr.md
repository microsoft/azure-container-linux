# EROFS `/usr`

New ACL RPM images default to EROFS, including official builds. Explicit Btrfs
selection and non-ACL Portage behavior remain supported. ROOT, OEM and standalone
SquashFS sysexts are unchanged; this does not migrate existing machines.

```sh
./acl/build_rpm_image.sh --build-image --build-vm-image
# Explicit selection: --usr-fs=erofs or --usr-fs=btrfs
# Pipeline/SDK environment: ACL_USR_FS=erofs
```

## Selection and conversion

The CLI overrides the environment. The fresh-image builder resolves an unset
or empty `ACL_USR_FS` to EROFS in RPM mode and exports it before staging,
sealing and initramfs generation. SDK create/exec and login setup carry the
selection, clearing stale values when a container is reused.
RPM-only builds and VM-only commands do not select a new `/usr` filesystem
when the selector is unset, so existing GRUB images remain usable.

Image `version.txt` records `ACL_USR_FS_METADATA_VERSION=1`, `ACL_USR_FS`,
`ACL_USR_BOARD` and `ACL_USR_BOOTLOADER`. Conversion adopts the source filesystem
when no explicit selection was supplied. Untagged legacy images remain Btrfs.
The reader accepts the former `ACL_EXPERIMENTAL_USR_FS` metadata field, but
new images write only `ACL_USR_FS`; contradictory old/new fields fail.
Unknown metadata versions, board/bootloader mismatches and explicit filesystem
conflicts also fail. Conversion never silently changes an existing filesystem.

## Build and boot

EROFS requires RPM/UKI, AMD64/ARM64 and base/QEMU/Azure layouts. Rootfs
verification must stay enabled. Container/prodtar/writable-debug images and
legacy update-engine payload generation are not supported for EROFS.

Rebuild the SDK: `sdk-depends` revision 58 adds pinned `erofs-utils-1.7.1`.
The checked kernel.org source package includes an LZ4 round-trip test. An old
`ACL_SDK_IMAGE` override is not repaired during the image build. The SDK and
builder check the tool version: `mkfs.erofs` prints it through its no-argument
usage error; `fsck.erofs -V` prints it directly.
The imported SDK keeps its filesystem helper beside the entrypoint, so lean
standalone images retain validation after their source checkout is removed.

The build uses a writable staging directory beside the disk image, bind-mounted
at `/usr`. RPM installation and metadata changes finish there before the builder
remounts staging read-only and packs it:

```sh
mkfs.erofs -b4096 -zlz4hc,12 -Elegacy-compress --preserve-mtime \
  -U "$uuid" -L "$label" "$packed" "$staging_mount"
fsck.erofs --extract "$packed"
```

The supported format is single-device, 4096-byte blocks and legacy LZ4
compression. UUID, label, superblock, feature profile and packed size are checked.
Partition bounds, matching A/B data/hash slots and hash capacity are validated
before writes. The copy is bounded to USR-A and zero-padded; the written
filesystem is checked again before verity and UKI generation.
Failed staging is retained for diagnosis; successful staging is removed.
EROFS cannot be mounted writable or resized in place.

The existing 1-GiB USR and 10-MiB HASH budgets are retained; every payload must
fit. The kernel must support EROFS, xattrs, ACLs, security labels and compression.
Dracut includes `erofs`; modular kernels are checked for its presence in the
initramfs. The existing main UKI command line and Image Customizer fstab keep
`/usr` read-only; no filesystem-specific slot-addon change is required.

EROFS images default `systemd-sysext` to buffered loop I/O to avoid observed
sector-zero I/O failures while refreshing SquashFS extensions through the `/usr`
overlay. The wrapper preserves explicit `SYSTEMD_LOOP_DIRECT_IO` settings,
executable metadata and invocation arguments; Btrfs and `systemd-confext` are
unchanged. It is installed before sealing and does not alter SELinux or IPE.

## Consumers and validation

Test images are conversions of the sealed production image, not separate
`build_image test` roots. Docker is injected into OEM and addons into ESP;
`/usr` and its hash geometry stay unchanged while ROOT may grow. Build the
standalone sysexts first; conversion requires `docker.raw`.

Image Customizer must copy the mounted read-only tree with owners, modes,
hardlinks, symlinks, capabilities and SELinux xattrs, customize in staging,
repack, regenerate verity, and then sign. `fsck.erofs --extract=DIR` in 1.7.1
does not restore xattrs and cannot replace that copy. Compatible Image
Customizer and Trident releases are prerequisites for deployment and servicing.

```sh
bash acl/tests/usr-filesystem/run.sh
# Only inside a rebuilt privileged Linux SDK:
sudo ACL_RUN_PRIVILEGED_FS_TESTS=1 bash acl/tests/usr-filesystem/run.sh
```

The suite covers selection, legacy conversion, geometry, overflow, packing,
metadata and verity. Skipped native tests are not passes. Full images on both
architectures, boot/reboot/Ignition/sysext, customization/COSI, installation,
A/B interruption and rollback require separate qualification. Signed-IPE
runtime validation is also separate; this change does not modify its policy.
