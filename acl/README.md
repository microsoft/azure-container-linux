# Azure Container Linux (ACL) Architecture

## Overview

Azure Container Linux (ACL) is a Microsoft derivative of [Flatcar Container Linux](https://www.flatcar.org/). It replaces the traditional Portage-based build system with **Azure Linux 3.0 RPM packages**, giving Microsoft a **sovereign supply chain** — every binary in the image is built, scanned, and signed within Microsoft's Azure Linux infrastructure. This means CVE fixes flow through Azure Linux's rapid package rebuild pipeline and can be picked up by ACL without waiting for upstream Flatcar releases, dramatically reducing the time-to-patch for critical vulnerabilities. Leveraging Azure Linux packages also enables first-class NVIDIA GPU support delivered as system extensions (CUDA, vGPU, container toolkit, fabric manager).

ACL currently tracks **Flatcar Linux stable** as its upstream base.

## Relationship with Flatcar

ACL preserves a high degree of parity with Flatcar Linux:

- The SDK container, board setup, and image build pipeline reuse the Flatcar `build_library` infrastructure.
- The Flatcar update model, partition layout (USR-A/USR-B A/B scheme, OEM, ROOT), and OEM package model are retained.
- Test collateral runs against the same `kola` harness (from the Mantle project) used by upstream Flatcar.

Where ACL diverges:

- Package installation uses RPMs sourced from Azure Linux repositories instead of Portage ebuilds.
- An RPM-to-Portage package catalog (`build_library/rpm/package_catalog.sh`) maps Flatcar category/package names to their Azure Linux RPM equivalents.
- UKI boot mode with `systemd-boot` is the primary boot path (see below).
- Partition growing, dm-verity device setup, fstab generation, and the initramfs build all use **upstream systemd tooling** (`systemd-repart`, `systemd-growfs`, `systemd-veritysetup-generator`, `systemd-fstab-generator`) instead of the custom CoreOS/Flatcar bootengine generators, reducing maintenance burden and aligning with conventions that are becoming the industry standard.
- The initramfs is a **single-stage dracut image** instead of Flatcar's two-stage bootengine approach (minimal embedded initrd → squashfs). Flatcar's bootengine is still included for the `/etc` overlay setup and Ignition provisioning, but its verity and `/usr` mount modules are replaced by their systemd equivalents.

## Image Outputs

The build system produces a base OS image (`acl_production_image.bin`) and then converts it into platform-specific disk images via `image_to_vm.sh`:

- **Azure VHD** — the production output, published to the Azure Compute Gallery. Includes the `oem-azure` package and platform sysexts.
- **QEMU/KVM qcow2** (`qemu_uefi`) — the development and CI target, used for local iteration and automated kola testing.

## System Extensions (sysexts)

ACL uses **systemd-sysext** squashfs images to deliver optional functionality on top of the read-only `/usr` partition.

**Base sysexts** — baked into the rootfs during `build_image`:

- `containerd` — containerd runtime

**Standalone sysexts** — built and shipped alongside the disk image:

- **GPU**:
  - `nvidia-driver-cuda-open`
  - `nvidia-driver-cuda`
  - `nvidia-driver-vgpu`
  - `nvidia-container-toolkit`
  - `nvidia-fabric-manager`
- **Scenario-specific**:
  - `docker`
- **OEM**:
  - `oem-azure`
  - `oem-qemu`

Standalone sysexts are defined in `standalone_sysexts.yaml`. Package names can be RPM names (e.g. `cuda-open`) or portage-style names (e.g. `app-containers/docker`) — the build system tries direct RPM installation first and falls back to the catalog. The `archs` field controls which architectures to build for; omitting it builds for all. An optional mangle script (`build_library/sysext_mangle_<name>`) can relocate files that RPMs install outside `/usr`.

## Supported Platforms

Platform-specific integration is provided through OEM packages and sysexts:

| Platform | OEM Package | Notes |
| --- | --- | --- |
| Azure | `oem-azure` | Primary target; VHD with optional Secure Boot |
| QEMU/KVM | `oem-qemu` | Main development and CI target (`qemu_uefi`) |

## Test Collateral

ACL reuses the Flatcar **Mantle/Kola** test framework:

- **Kola** is the test harness that boots images and runs test cases against them.
- **Mantle** is the container that packages kola along with platform-specific plumbing (QEMU, cloud SDKs, etc.).

Test execution is driven by `run_local_tests.sh` (local) and the Azure Pipelines CI definitions in `acl-pipelines/`. The primary test target is `qemu_uefi`.

Test categories include:

- `cl.basic` — fundamental OS health checks
- `cl.verity` — dm-verity integrity validation
- `cl.ignition.*` — Ignition provisioning scenarios
- `cl.cloudinit.*` — cloud-init configuration
- `cl.update.*` — A/B update lifecycle
- `sysext.*` — sysext activation and runtime behavior

**`kola_enforcing.txt`** — a curated allowlist of kola test names that must pass before any image is published.

Results are emitted in TAP format and converted to Markdown summaries.

Additional ACL-specific tests live in `acl/tests/`:

- Secure Boot verification (`run-secureboot-test.sh`)
- systemd service health (`run-systemd-health-test.sh`)
- Disk I/O error detection (`run-dmesg-io-error-test.sh`)
- Container runtime smoke tests (`run-container-test.sh`)
- SELinux AVC check (`run-selinux-avc-test.sh`)

## Feature Set

### dm-verity for `/usr`

The `/usr` partition (USR-A) is a read-only btrfs filesystem with zstd compression. **dm-verity** provides block-level integrity verification:

- The verity hash tree is appended to the USR partition data.
- At boot, `systemd-veritysetup` activates the verity device using kernel command-line parameters embedded in the UKI: `systemd.verity_usr_data`, `systemd.verity_usr_hash`, and `systemd.verity_usr_options=hash-offset=<N>,panic-on-corruption`.
- Any corruption of `/usr` causes an immediate kernel panic, preventing the system from running a tampered image.

The A/B partition scheme (USR-A / USR-B) enables safe updates: the inactive slot is written, verified, and then atomically switched on reboot.

### `/etc` Overlay from `/usr`

`/etc` is mounted as an **overlayfs** with:

- **Lower (read-only)**: `/usr/share/distro/etc` — defaults shipped in the image.
- **Upper (writable)**: persisted on the ROOT partition.

This allows `/usr` to remain fully immutable and verity-protected while giving services and users a writable `/etc`. The overlay is configured early in boot by Flatcar's BootEngine.

### systemd-boot, UKI, and Addons

ACL's primary boot path uses **systemd-boot** with **Unified Kernel Images (UKI)**:

- `ukify` packs the kernel, initramfs, kernel command line (including verity parameters), and an EFI stub into a single signed PE binary installed on the EFI System Partition.
- **systemd-boot** is the UEFI bootloader that discovers and launches UKIs from the ESP.

**Addons** extend UKI behaviour without rebuilding the image:

- **First-boot addon** — an addon that triggers Ignition provisioning on the initial boot cycle. After first-boot processing completes, the addon is removed so subsequent boots skip provisioning.
- **OEM selection addon** — injects the `oem_id` and Ignition platform identifier for the target cloud or hypervisor, allowing a single UKI to adapt to different environments.

### SELinux

ACL ships with **SELinux in enforcing mode by default**. The policy is aligned with Flatcar's upstream SELinux policy, which focuses on strict separation between the host OS and container workloads — host system services run in confined domains while containers are isolated by the `container_t` type.

### Ignition

[Ignition](https://coreos.github.io/ignition/) is the first-boot provisioning tool. It processes a JSON configuration delivered through platform metadata (Azure custom data, QEMU `fw_cfg`, etc.) to:

- Write files, create users, and configure SSH keys.
- Set up systemd units, mount points, and network configuration.
- Format and mount additional disks.

In UKI mode, Ignition execution is gated by the first-boot addon described above.

### systemd Partition Growth

The ROOT partition (partition 9 in the disk layout) is created at a minimal size in the shipped image. On first boot, **systemd-repart** and **systemd-growfs** automatically expand it to fill all remaining disk space, giving workloads access to the full disk without manual intervention.
