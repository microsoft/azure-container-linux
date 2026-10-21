# EROFS /usr: design overview

## Overall picture

This change makes EROFS the default `/usr` filesystem for new ACL RPM images.
The OS is assembled in a writable directory, packed into read-only EROFS, then
protected by the existing dm-verity and UKI flow. It does not migrate a running
machine or change IPE policy/signing.

```text
CLI / ACL_USR_FS -> SDK -> writable /usr staging -> RPMs and metadata
    -> read-only staging -> EROFS packing and checks -> USR-A
    -> dm-verity HASH-A -> UKI -> QEMU/Azure image conversion
```

## Key logic

| Code | Responsibility |
|------|----------------|
| `acl/build_rpm_image.sh`, `build_library/usr_filesystem.sh` | Resolve and validate selection; CLI wins over environment. |
| `run_sdk_container`, `sdk_lib/sdk_entry.sh` | Forward selection into fresh/reused SDKs and remove stale login-shell values. Support both checkout and standalone entrypoints. |
| `build_library/disk_util` | Stage, pack, validate and bound partition writes; reject incompatible geometry or in-place filesystem migration. |
| `build_library/build_image_util.sh` | Seal `/usr` only after image customization, before verity generation. |
| `build_library/rpm/dracut_install.sh` | Require EROFS kernel support and include its driver in the initramfs. |
| `image_to_vm.sh` | Restore source-image filesystem metadata instead of silently applying the new-build default. |

## Key decisions

- **EROFS for new RPM builds, Btrfs still explicit.** Portage defaults and ROOT,
  OEM and standalone SquashFS extensions stay unchanged.
- **Build writable, seal once.** Preserve ownership, capabilities and SELinux
  labels through normal build operations; never try to modify EROFS in place.
- **Pin a small format contract.** SDK erofs-utils 1.7.1, 4096-byte blocks,
  single-device legacy LZ4, existing 1-GiB USR and 10-MiB HASH budgets. Reject
  unsupported features or overflow rather than silently changing the format.
- **Conversion preserves the source.** Versioned metadata records filesystem,
  board and bootloader. Untagged legacy sources remain Btrfs; conflicts fail.
- **Limit the sysext workaround.** EROFS images use buffered loop I/O for
  `systemd-sysext` only; explicit settings and `systemd-confext` stay unchanged.

## Boundaries and readiness

EROFS is supported here for RPM/UKI AMD64 and ARM64 base/QEMU/Azure images.
GRUB, writable debug roots and legacy update payloads require Btrfs. This PR
does not add signed `/usr` root hashes or change the A/B servicing protocol.

The companion acl-pipelines change selects the filesystem and probes the built
image. Image Customizer needs separate EROFS discovery/repack support. Trident
installation, A/B update and rollback must be qualified; these changes alone
do not prove that Trident needs a code update.

The offline suite covers contracts and failure cases; privileged Linux tests
exercise native filesystem behavior. Neither replaces final-revision builds,
boots and consumer/servicing tests on both architectures. A skipped test or a
run using an older source revision is not qualification of this PR.

See [EROFS usage and validation](erofs-usr.md) for commands and detailed limits.
