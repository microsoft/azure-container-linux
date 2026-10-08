# Experimental EROFS `/usr`

This is a qualification path, not a production-support or migration promise.
Btrfs defaults and production IPE policy are unchanged. It layers on the
[shared filesystem selector](usr-filesystems.md):

```sh
./acl/build_rpm_image.sh --usr-fs=erofs --build-image --build-vm-image
# Pipeline task environment: ACL_EXPERIMENTAL_USR_FS=erofs
```

Only RPM/UKI, AMD64/ARM64 and base/VM/Azure layouts are supported. The existing
pipeline filenames and versioned filesystem/board/bootloader provenance remain
unchanged. This environment variable is not a shared pipeline YAML parameter.
Image conversion preserves the filesystem; it is not a Btrfs-to-EROFS migration.

## Pipeline and test-image scope

A public pipeline selector may map `btrfs` to an empty `ACL_EXPERIMENTAL_USR_FS`
for fresh builds, and `ext4`/`erofs` to their exact values. Empty is deliberately
different from explicit `btrfs`: conversion adopts source `version.txt` when
no format is requested. A Btrfs control conversion must pass `--usr-fs=btrfs`
or verify source metadata against the public parameter before reuse. Explicit
filesystem conflicts fail; never silently validate a different filesystem.

`--build-test-image --vm-type=qemu` and `--build-test-image --vm-type=azure`
call `image_to_vm.sh` on the existing sealed prod image. They do not invoke
`build_image test`. Docker is injected into OEM; OEM/timeout addons go to ESP.
The same readonly EROFS `/usr` and exact USR/HASH geometry are retained while
ROOT may grow. These derived test images are within the source-level experiment,
not a live-tested boot/sysext claim. Do not force them to Btrfs and count that
as EROFS validation.

Build the prod image and required standalone sysext artifacts first. Test
conversion requires `docker.raw`; a missing Docker sysext is a hard failure.
With RPM inputs staged and the rebuilt SDK selected, a complete build invocation is:

```sh
./acl/build_rpm_image.sh --board=amd64-usr --usr-fs=erofs \
  --build-image --build-standalone-sysexts --build-test-image --vm-type=qemu
```

Use `arm64-usr` for ARM64 and `--vm-type=azure` for Azure test conversion.
Standalone sysexts remain separate SquashFS artifacts; their builder uses the
sysext base produced with this image, not a mutable EROFS `/usr`.
Actual SDK packing, QEMU/Azure conversion and boot remain unverified until the
approved Linux execution gate. Container/prodtar/writable-debug roots and
`--noenable_rootfs_verification` are rejected for opt-in filesystems; disabled
verification would bypass sealing. Ordinary debug logging addons must not
override verity/trust settings.

## Build contract

`sdk-depends` revision 58 installs pinned `erofs-utils-1.7.1`. Rebuild the SDK;
an older `ACL_SDK_IMAGE` override is not repaired by installing tools during an
image build. The package uses the upstream kernel.org snapshot, a checked
Portage Manifest and an LZ4 round-trip package test. Its bytes match the former
Ubuntu source archive; the SDK does not require access to Ubuntu's archive.
`mkfs.erofs` 1.7.1 has no `-V` option: its no-argument
usage failure prints the version; `fsck.erofs -V` supplies the checker version.
Unexpected versions fail explicitly both in the SDK update image's smoke check
and when building an EROFS image.

`disk_util format --erofs-staging` creates a separate directory beside the disk
image and binds it into the build root's `/usr`. It does **not** format a
target-sized writable staging partition. RPM installation, final tree changes
and SELinux labeling therefore have the build volume's available capacity.
Host ENOSPC remains a build error. The stage is exclusively owned by that image
build; do not mutate it through another path while sealing.

After all mutations, `seal_erofs` remounts the bind read-only and runs:

```sh
mkfs.erofs -b4096 -zlz4hc,12 -Elegacy-compress --preserve-mtime \
  -U "$uuid" -L "$label" "$packed" "$staging_mount"
fsck.erofs --extract "$packed"
```

This emits a single-device block-backed filesystem: no file-backed/fscache
mount, external blob, multi-device image, large block or new incompat feature.
The output UUID, superblock, size and profile are checked. Data/hash destinations,
exact slot geometry and verity capacity are checked before writes. Packed
overflow fails before touching the target partition. Copying is bounded to the
partition, zeros padding, fsyncs and rechecks the written filesystem. Only then
does the existing verity/UKI path hash and bind the result.
Configured `fs_label` values are passed to the formatter and checked in the
packed superblock; absent labels stay empty. Labels must fit 16 UTF-8 bytes.

The original 1-GiB USR and 10-MiB HASH budgets are retained, **not qualified as
sufficient for the complete payload**. `*.erofs.json` records packed/data/headroom
bytes and formatter profile; `*_verity-capacity.json` records hash capacity.
These budgets differ from the EXT4 experiment. A shared 4-GiB/64-MiB layout is
not assumed here, and cross-profile A/B compatibility requires separate review
and qualification.
Failed staging is retained for diagnosis. Successful staging alone is removed.
Final EROFS cannot be mounted writable, tuned into writable form or resized.
Unsealed staging cannot be hashed or treated as a converted image.

The target kernel must support EROFS, xattrs, ACLs, security labels and compressed
data. Dracut receives `erofs` through `add_drivers`; modular kernels must actually
contain the module in the generated initrd. `/usr` gets `ro` in its slot addon
and Image Customizer discovery fstab, with no EXT4-only flags in the main UKI.

## Consumers and qualification

ACL currently pins Trident 0.29.0, which does not recognize EROFS. An explicitly
reviewed EROFS-capable consumer build is required before COSI deployment or
servicing. Do not infer support from a filesystem-only image build.

Image Customizer must mount EROFS read-only, copy the complete tree with owners,
modes, hardlinks, symlinks, capabilities and SELinux xattrs into writable staging,
apply customization, repack, regenerate verity, and only then sign. Version 1.7.1
`fsck.erofs --extract=DIR` does not restore xattrs and is **not** a substitute for
that metadata-complete copy. `--extract` without a destination, used above, only
checks compressed data. A workflow that write-mounts `/usr` and only regenerates
verity must reject EROFS until this companion lifecycle is available.

Portable and optional native tests:

```sh
bash acl/tests/usr-filesystem/run.sh
# Inside a rebuilt, privileged Linux SDK with the required kernel/filesystem tools:
sudo ACL_RUN_PRIVILEGED_FS_TESTS=1 bash acl/tests/usr-filesystem/run.sh
```

The privileged tests pack a tree larger than its target slot, check actual
metadata/content and readonly mounts, verify dm-verity, and reject incompressible
overflow without changing the slot. Once opted in, missing prerequisites fail;
ordinary skipped integration tests are not passes.

Before merge qualification: build the SDK package and full images on both
architectures; measure payload/capacity; boot/reboot and test Ignition/sysext;
test companion Image Customizer/COSI metadata round trips; test install,
A/B update, interruption and rollback with the reviewed Trident consumer; and
run controlled pipeline validation. IPE validation additionally requires a
reviewed composition with microsoft/azure-container-linux#52, signed root-hash
delivery and real policy evidence. No fixture-only or mocked test substitutes
for these gates, and no SELinux/IPE enforcement change is implied.
