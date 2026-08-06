# Preloading Container Images into an ACL Image

This guide shows how to bake OCI container images into the containerd content
store of an existing Azure Container Linux (ACL) image, so that they are already
present on first boot and never need to be pulled from a registry.

This is useful for:

- Reducing pod start latency for images that are always needed (for example
  `pause`, CNI, or CSI images).
- Building nodes that can start workloads without registry connectivity.

The approach uses the [Azure Linux Image Customizer][ic] (IC). IC has no
built-in support for OCI or containerd preloading, but its `postCustomization`
hook runs in a chroot on the target root filesystem with `/usr`, `/proc`,
`/sys`, `/dev`, and `/run` mounted, loop devices available, and working
networking. That is enough to run the image's own containerd and pull directly
into `/var/lib/containerd`.

## Overview

1. Obtain an ACL image. IC accepts `vhd`, `vhdx`, `qcow2`, and raw directly, so
   a Marketplace VHD needs no conversion -- see
   [Download an Azure Marketplace Image][dl] for the export procedure.
2. Run IC with a single `postCustomization` script that starts the image's own
   containerd inside the chroot, pulls the images, and pins them.
3. Verify offline, then boot and confirm with `ctr` / `crictl`.
4. Publish the result to an Azure Compute Gallery.

The script must use the **containerd binaries shipped in the target image**. The
metadata store is a bolt database whose schema is tied to the containerd
version; hydrating with a different version can produce a store the image's
containerd will not recover. Because the script runs inside the image, this
happens naturally.

## ACL Marketplace images

ACL ships under the `MicrosoftCBLMariner` publisher and the `azure-linux-3`
offer, with a separate Generation 2 SKU per architecture:

| Architecture | SKU                            | Example URN                                                                    |
| ------------ | ------------------------------ | ------------------------------------------------------------------------------ |
| x64          | `azure-linux-3-acl`            | `MicrosoftCBLMariner:azure-linux-3:azure-linux-3-acl:3.20260706.01`            |
| Arm64        | `azure-linux-3-arm64-gen2-acl` | `MicrosoftCBLMariner:azure-linux-3:azure-linux-3-arm64-gen2-acl:3.20260706.01` |

Both SKUs are versioned in lockstep. To confirm the current SKU list and the
available versions for one:

```sh
az vm image list-skus -l westus3 \
  -p MicrosoftCBLMariner -f azure-linux-3 -o table

az vm image list \
  --publisher MicrosoftCBLMariner \
  --offer azure-linux-3 \
  --sku azure-linux-3-acl \
  --all -o table
```

The exported image is a ~30 GB **fixed-format** VHD. `qemu-img` misdetects it as
`raw`, so pass `-f vpc` explicitly when inspecting it.

## Prerequisites

A Linux host with:

- Docker (to run the Image Customizer container)
- `qemu-img`, `qemu-nbd`, and `qemu-system-x86_64` with OVMF, if you want to
  verify or boot-test the result
- The `az` CLI, to obtain the input image and to publish the result

> **Note**
> Run IC from the published container image, not from an extracted binary. The
> ACL root filesystem uses the ext4 `orphan_file` feature, and `e2fsck` older
> than 1.47 fails on it with exit code 12 (`unsupported feature(s): FEATURE_C12`). The IC container ships a new enough e2fsprogs.

## 1. Write the preload script

`staging/preload.sh`:

```sh
#!/bin/sh
set -eux

SYSEXT=/usr/share/distro/sysext/containerd.raw
SX=/mnt/sx
SOCK=/run/ctrd/c.sock
PLATFORM=linux/amd64          # linux/arm64 for the Arm64 ACL SKU
IMAGES="mcr.microsoft.com/oss/v2/kubernetes/pause:v3.10 mcr.microsoft.com/azurelinux/base/core:3.0"

# /etc is created empty by the Image Customizer, and the CA trust store is only
# populated on first boot. The paths under /etc/pki are Fedora-style symlinks
# back into /etc, so point Go's TLS stack at the real extracted bundle in /usr.
export SSL_CERT_FILE=/usr/share/distro/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

# containerd ships as a system extension rather than in the base /usr tree, and
# systemd only merges it at boot. Loop-mount it to reach the binaries.
mkdir -p "$SX" /run/ctrd /var/lib/containerd
mount -o ro,loop "$SYSEXT" "$SX"

"$SX/usr/bin/containerd" --root /var/lib/containerd --state /run/ctrd \
  --address "$SOCK" > /tmp/ctrd.log 2>&1 &
CTRD_PID=$!
sleep 8

for ref in $IMAGES; do
  "$SX/usr/bin/ctr" -a "$SOCK" -n k8s.io images pull \
    --snapshotter overlayfs --platform "$PLATFORM" "$ref"
  "$SX/usr/bin/ctr" -a "$SOCK" -n k8s.io images label \
    "$ref" io.cri-containerd.pinned=pinned
done

"$SX/usr/bin/ctr" -a "$SOCK" -n k8s.io images ls

kill "$CTRD_PID"; sleep 3
umount "$SX"; rmdir "$SX"
rm -rf /run/ctrd /tmp/ctrd.log

# Use numeric IDs: the ACL root partition has no /etc/passwd, so a symbolic
# `chown root:root` fails with "invalid user".
chown 0:0 /var/lib/containerd
chmod 700 /var/lib/containerd
```

Notes:

- Images must be pulled into the `k8s.io` namespace, which is what the CRI
  plugin uses.
- `ctr` 2.x unpacks the snapshot as part of `pull`; there is no separate
  `ctr images unpack` step.
- The `io.cri-containerd.pinned=pinned` label prevents kubelet's image garbage
  collector from evicting the preloaded images.
- The snapshotter must match what the image's containerd is configured to use
  (`overlayfs` by default).
- containerd writes only to `/var/lib/containerd` and `/run/ctrd`, both of which
  are cleaned up or intended to persist, so the script leaves no other residue.
- `--platform` must match the image being customized. Because the script runs
  the target image's own `containerd` and `ctr` binaries, customizing an Arm64
  ACL image is most straightforward from an Arm64 build host; doing it from x64
  additionally requires `binfmt_misc` and a static `qemu-user` interpreter so
  the chroot can execute those binaries.

## 2. Run the Image Customizer

`staging/config.yaml`:

```yaml
previewFeatures:
  - preview-distro-version
  - uki
  - reinitialize-verity

storage:
  # ACL's root partition is not verity-protected; leaving verity untouched
  # avoids invalidating the existing signatures.
  reinitializeVerity: none

os:
  uki:
    # Reuse the existing signed UKI instead of regenerating (and unsigning) it.
    mode: passthrough

scripts:
  postCustomization:
    - path: preload.sh
```

```sh
# The build directory MUST live on its own mount -- see the note below.
sudo mount -t tmpfs -o size=70G tmpfs /mnt/bd

sudo docker run --rm --privileged=true \
  -v /dev:/dev \
  -v /mnt/bd:/mnt/bd \
  -v "$PWD/staging:/staging" \
  mcr.microsoft.com/azurelinux/imagecustomizer:1.5.0-2 \
  customize \
  --image-file /staging/acl.vhd \
  --config-file /staging/config.yaml \
  --build-dir /mnt/bd \
  --output-image-format vhd-fixed \
  --output-image-file /staging/out/acl-preloaded.vhd
```

Use `vhd-fixed`, not `vhd`, if the result is destined for an Azure Compute
Gallery: Azure only accepts fixed-size VHDs, and requires the virtual size to be
a whole number of MiB. IC satisfies both -- the output carries a `conectix`
footer, and the file is exactly the virtual size plus the 512-byte footer:

```console
$ qemu-img info -f vpc out/acl-preloaded.vhd
file format: vpc
virtual size: 30.4 GiB (32633782272 bytes)   # 31122 MiB exactly
disk size: 624 MiB
```

The file is sparse, so it occupies only the written extents locally even though
it is nominally 30 GB.

Other formats (`qcow2`, `raw`, `vhdx`, `cosi`, ...) are available via the same
flag if the image is only going to be booted locally.

IC expands the input to raw in the build directory regardless of the input
format, so size the build mount for the image's full virtual size (~31 GB for
ACL) rather than for the compressed file on disk.

The `ctr images ls` output from inside the chroot appears in IC's log at
`--log-level debug`, which is a useful early check that the pulls succeeded.

### Known issues and workarounds

| Symptom                                                                            | Cause                                                                                                                                                                                                          | Workaround                                                                                 |
| ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `too many levels of symbolic links` (`ELOOP`) during partition mount               | IC synthesizes ACL's missing mount directories with `lowerdir=<build-dir>/rootmountdirsdir:/`. Because the build directory is a descendant of `/`, the lowerdirs overlap, which overlayfs rejects as `-ELOOP`. | Put `--build-dir` on a separate mount, e.g. a tmpfs at `/mnt/bd`.                          |
| `failed to find rootfs partition`                                                  | The `:latest` tag on MCR is stale (v1.1.0) and predates ACL support.                                                                                                                                           | Pin an explicit tag, e.g. `1.5.0-2`.                                                       |
| `e2fsck` exits 12, `unsupported feature(s): FEATURE_C12`                           | Host `e2fsprogs` is older than 1.47 and does not understand ext4 `orphan_file`.                                                                                                                                | Run IC from the container image.                                                           |
| `tls: failed to verify certificate: x509: certificate signed by unknown authority` | `/etc` is empty during `postCustomization`; the CA trust store is generated on first boot.                                                                                                                     | `export SSL_CERT_FILE=/usr/share/distro/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`. |
| `chown: invalid user 'root:root'`                                                  | The ACL root partition ships no `/etc/passwd`.                                                                                                                                                                 | Use numeric IDs: `chown 0:0`.                                                              |
| `source (.../snapshots/1/fs/bin) is not a file`                                    | `os.additionalDirs` cannot copy symlinks (relevant only to the offline variant below).                                                                                                                         | Ship a tarball via `os.additionalFiles` and unpack it in a `postCustomization` script.     |

ACL images also require `preview-distro-version` in `previewFeatures`, and the
Docker invocation needs `--privileged=true -v /dev:/dev`.

## 3. Verify

### Offline

Mount the output image and check the injected tree:

```sh
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 --read-only -f vpc out/acl-preloaded.vhd
sudo mount -o ro /dev/nbd0p5 /mnt/verify   # ROOT is the fifth partition

ls -la /mnt/verify/var/lib/containerd
strings /mnt/verify/var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db \
  | grep -E 'mcr\.microsoft\.com|pinned'
```

Confirm the directory is `0700` `root:root`.

### Boot test

ACL has no default console login, and under `init=/bin/bash` the containerd
sysext is not merged, so `ctr` does not exist. Boot normally and use systemd's
debug shell on a second serial port instead.

Extract the kernel, initrd, and command line from the UKI on the ESP:

```sh
objcopy -O binary --only-section=.linux   uki.efi vmlinuz
objcopy -O binary --only-section=.initrd  uki.efi initrd
objcopy -O binary --only-section=.cmdline uki.efi cmdline
```

Boot a scratch copy (never the artifact itself -- the boot mutates it),
appending the debug-shell options to the extracted command line:

```sh
cp --sparse=always out/acl-preloaded.vhd test.vhd

qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp 4 -m 4096 \
  -drive file=test.vhd,format=vpc,if=virtio \
  -kernel vmlinuz -initrd initrd \
  -append "$(cat cmdline) console=ttyS0,115200 \
            systemd.debug-shell=ttyS1 systemd.setup-debug-shell=1" \
  -serial file:boot.log \
  -serial unix:/tmp/acl.sock,server,nowait \
  -display none
```

Connect to `/tmp/acl.sock` and confirm:

```console
# ctr -n k8s.io -a /run/containerd/containerd.sock images ls
REF                                              SIZE      LABELS
mcr.microsoft.com/azurelinux/base/core:3.0       30.3 MiB  io.cri-containerd.pinned=pinned
mcr.microsoft.com/oss/v2/kubernetes/pause:v3.10   6.2 MiB  io.cri-containerd.pinned=pinned

# crictl images
IMAGE                                       TAG     IMAGE ID        SIZE
mcr.microsoft.com/azurelinux/base/core      3.0     2b36a7c9158cd   31.8MB
mcr.microsoft.com/oss/v2/kubernetes/pause   v3.10   fc42a8735dcaf   6.55MB
```

The boot log should also show the CRI plugin recovering the images:

```
containerd successfully booted
ImageUpdate name:"mcr.microsoft.com/oss/v2/kubernetes/pause:v3.10" io.cri-containerd.pinned=pinned
```

That the images survive the first boot confirms ACL does not reset `/var`
during provisioning.

## 4. Publish to an Azure Compute Gallery

Upload the fixed VHD into an empty managed disk, then use that disk as the
source for a gallery image version.

```sh
RG=my-images
LOC=westus3
DISK=acl-preloaded

# --upload-size-bytes is the size of the file on disk, footer included.
BYTES=$(stat -c %s out/acl-preloaded.vhd)

az disk create -g "$RG" -n "$DISK" -l "$LOC" \
  --os-type Linux --hyper-v-generation V2 \
  --upload-type Upload --upload-size-bytes "$BYTES" \
  --sku Standard_LRS

SAS=$(az disk grant-access -g "$RG" -n "$DISK" \
        --access-level Write --duration-in-seconds 86400 \
        --query accessSAS -o tsv)

azcopy copy out/acl-preloaded.vhd "$SAS" --blob-type PageBlob

az disk revoke-access -g "$RG" -n "$DISK" -o none
```

Create the image definition once, matching the architecture and generation of
the image you customized, then add a version per build:

```sh
az sig image-definition create -g "$RG" \
  --gallery-name mygallery --gallery-image-definition acl-preloaded \
  --publisher myorg --offer acl --sku preloaded \
  --os-type Linux --os-state generalized \
  --hyper-v-generation V2 --architecture x64      # or Arm64

az sig image-version create -g "$RG" \
  --gallery-name mygallery --gallery-image-definition acl-preloaded \
  --gallery-image-version 1.0.0 \
  --os-snapshot "$DISK"
```

`--upload-size-bytes` must match the file exactly or the upload is rejected,
which is why `vhd-fixed` matters: a dynamic VHD's file size does not have the
fixed `virtual size + 512` relationship Azure expects.

## Appendix: offline (air-gapped) variant

If the build host cannot reach the registry from inside the IC chroot -- for
example in an air-gapped pipeline, or where egress is only permitted from the
build host itself -- hydrate the containerd data root out of band and inject it
as a tarball instead.

Extract containerd from the image's sysext:

```sh
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 --read-only -f vpc staging/acl.vhd

# USR-A is the second partition on the ACL GPT layout.
sudo mount -o ro /dev/nbd0p2 /mnt/usr

# Copy the sysext out before mounting it; loop-mounting a file that lives on
# an nbd-backed btrfs mount can hang.
cp /mnt/usr/share/distro/sysext/containerd.raw /tmp/containerd.raw
sudo mount -o ro,loop /tmp/containerd.raw /mnt/sysext
cp /mnt/sysext/usr/bin/containerd /mnt/sysext/usr/bin/ctr work/bin/

sudo umount /mnt/sysext /mnt/usr
sudo qemu-nbd --disconnect /dev/nbd0
```

Hydrate a scratch data root with the same `pull` / `label` sequence as the
in-chroot script, then tar it, preserving ownership and extended attributes:

```sh
sudo tar --numeric-owner --xattrs --xattrs-include='*' --acls \
  -cf staging/ctrd-root.tar -C staging ctrd-root
```

Ship it via `os.additionalFiles` (not `additionalDirs`, which cannot copy
symlinks) and unpack it in `postCustomization`:

```yaml
os:
  additionalFiles:
    - source: ctrd-root.tar
      destination: /ctrd-root.tar
      permissions: "600"

scripts:
  postCustomization:
    - path: extract.sh
```

```sh
#!/bin/sh
set -eux
rm -rf /var/lib/containerd
tar --numeric-owner --xattrs --xattrs-include='*' --acls \
  -xf /ctrd-root.tar -C /var/lib
mv /var/lib/ctrd-root /var/lib/containerd
chown 0:0 /var/lib/containerd
chmod 700 /var/lib/containerd
rm -f /ctrd-root.tar
```

Both variants produce an equivalent store; the in-chroot flow is preferred
because it needs no host-side containerd, no version matching, and no
multi-hundred-megabyte intermediate tarball.

[dl]: https://microsoft.github.io/azure-linux-image-tools/imagecustomizer/how-to/azure-vm/download-marketplace-image.html
[ic]: https://github.com/microsoft/azure-linux-image-tools
