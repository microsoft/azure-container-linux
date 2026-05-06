# Flatcar Container Linux vs Azure Container Linux on AKS

> **⚠️ Deprecation Notice:** Flatcar Container Linux is being superseded by Azure Container Linux (ACL) in AKS. Flatcar will be deprecated from public preview and replaced by ACL at GA. Customers currently using Flatcar on AKS should plan to migrate to ACL.

This document compares **Flatcar Container Linux** and **Azure Container Linux (ACL)** in the context of running container workloads on AKS. ACL is built on top of Flatcar's infrastructure but diverges in key areas to integrate Microsoft's supply chain, security model, and Azure platform.

## At a Glance

| | Flatcar Container Linux | Azure Container Linux (ACL) |
| --- | --- | --- |
| **Heritage** | CoreOS Container Linux successor | Flatcar + Azure Linux packages |
| **Package source** | Gentoo Portage ebuilds | Azure Linux RPMs |
| **Build system** | Flatcar SDK + Portage | Flatcar SDK + RPM |
| **Primary boot path** | GRUB2 + kernel/initramfs | systemd-boot + Unified Kernel Image (UKI) |
| **Initramfs** | Two-stage bootengine (embedded initrd → squashfs) | Single-stage dracut image |
| **dm-verity activation** | Custom bootengine generators | `systemd-veritysetup-generator` |
| **Partition growing** | Custom bootengine / `cgpt` | `systemd-repart` + `systemd-growfs` |
| **Provisioning** | Ignition (Flatcar fork, first-boot) | Ignition (Flatcar fork, first-boot) |
| **Mandatory access control** | SELinux (permissive by default) | SELinux (enforcing) |
| **Update mechanism** | Nebraska/Omaha client (`update_engine`) | Node image upgrade (AKS); A/B updates planned |
| **Container runtime** | containerd (sysext) | containerd (sysext) |
| **System extensions** | systemd-sysext | systemd-sysext |
| **GPU support** | Community NVIDIA packages | NVIDIA sysexts (CUDA, vGPU, container toolkit, fabric manager), built by AzL team |
| **Supported platforms** | AWS, Azure, GCP, bare-metal, QEMU, and others | Azure (primary), QEMU (dev/CI), bare-metal (planned) |
| **Architectures** | amd64, arm64 | amd64, arm64 |
| **Trusted Launch / Secure Boot** | Supported (shim + GRUB2 chain, no Flatcar-signed shim — requires workarounds) | Required (Microsoft-signed systemd-boot + signed UKI) |
| **Supply chain** | Gentoo upstream + Flatcar overlay | Microsoft Azure Linux RPM pipeline |

## What ACL Preserves from Flatcar

ACL maintains a high degree of structural parity with Flatcar:

- **SDK and build infrastructure** — same `cork` SDK container, board setup scripts, and `build_library` pipeline.
- **Partition layout** — USR-A/USR-B A/B pair, OEM partition, ROOT partition, EFI System Partition.
- **OEM package model** — platform-specific integration delivered via OEM packages (`oem-azure`, `oem-qemu`, etc.).
- **Ignition provisioning** — same Flatcar-forked Ignition for first-boot configuration.
- **`/etc` overlay** — overlayfs with read-only lower from `/usr/share/distro/etc` and writable upper on ROOT.
- **Test framework** — `kola` test harness from the Mantle project, same test patterns and infrastructure.
- **Update model** — A/B slot scheme with atomic switch and rollback (implementation differs, see below).

## Where ACL Diverges

### Package Source: RPMs Instead of Ebuilds

Flatcar builds all system packages from Gentoo Portage ebuilds maintained in the `coreos-overlay` and `portage-stable` repositories. ACL replaces this with **Azure Linux 3.0 RPMs**:

- A Portage-to-RPM package catalog (`build_library/rpm/package_catalog.sh`) maps Flatcar's `category/package-name` naming convention to Azure Linux RPM equivalents.
- Packages are fetched as pre-built RPMs from Azure Linux repositories and installed into the image during build.
- This gives ACL access to Azure Linux's rapid CVE fix pipeline — patches flow without waiting for upstream Flatcar or Gentoo releases.

### Boot Path: UKI Instead of GRUB2

| | Flatcar | ACL |
| --- | --- | --- |
| **Bootloader** | GRUB2 (with shim for Secure Boot) | systemd-boot |
| **Kernel delivery** | Separate vmlinuz + initramfs files | Unified Kernel Image (single signed PE binary) |
| **Secure Boot chain** | shim → GRUB2 → kernel | systemd-boot → UKI (single artifact validation) |
| **Command line** | GRUB config (`grub.cfg`) | Embedded in UKI at build time |
| **First-boot gating** | Conditional logic in GRUB config | UKI addon (removed after first boot) |
| **OEM selection** | GRUB config + OEM partition detection | UKI addon with `oem_id` parameter |

ACL's UKI approach means Secure Boot validates the kernel, initramfs, and command line as one artifact — there is no TOCTOU gap between loading the bootloader and executing the kernel.

### Initramfs: Single-Stage Dracut vs Two-Stage Bootengine

**Flatcar** uses a two-stage boot:

1. A minimal embedded initrd loads a squashfs bootengine image.
2. The bootengine handles verity setup, `/usr` mount, partition growing, and then pivots to the real root.

**ACL** uses a single-stage dracut initramfs:

- `systemd-veritysetup-generator` handles dm-verity activation using parameters embedded in the UKI command line.
- `systemd-repart` and `systemd-growfs` handle partition growing.
- `systemd-fstab-generator` handles mount configuration.
- Flatcar's bootengine is still included for the `/etc` overlay setup and Ignition, but its verity and mount modules are replaced by systemd equivalents.

This reduces custom code and aligns with upstream systemd conventions.

### SELinux: Enforcing vs Permissive

**Flatcar** ships SELinux in **permissive mode** by default — the policy is loaded and violations are logged, but not blocked. Users can opt in to enforcing mode.

**ACL** ships SELinux in **enforcing mode** — violations are blocked. The policy
is based on upstream refpolicy (aligned with Flatcar's policy modules) with
ACL-specific patches for:

- Container runtimes (`containerd`, CRI)
- Kubernetes components (`kubelet`, `kubectl`)
- Azure platform agents
- systemd service units

The policy source is maintained in `acl/SPECS/selinux-policy/`.

### Runtime Composition and Customization

Both Flatcar and ACL use `systemd-sysext` for runtime composition — delivering components like containerd, Kubernetes binaries, and platform integrations as composable extensions layered onto the immutable base OS.

Several sysexts are shared between Flatcar and ACL (built from the same AKS node components):

- **kubectl / kubelet** — Kubernetes components (version-matched at deploy time)
- **azure-acr-credential-provider** — ACR authentication
- **node-exporter-kubernetes**, **node-problem-detector-kubernetes** — monitoring

**Notable divergence:** Flatcar ships a Docker sysext in the base image by default; ACL does not include Docker — containerd is the sole container runtime.

ACL additionally benefits from Microsoft-built and supported packages:

- **NVIDIA GPU drivers** — CUDA, vGPU, container toolkit, fabric manager — built and validated by the Azure Linux team. GPU sysexts are automatically deployed on GPU-enabled VM SKU sizes (e.g., NC, ND, NV series) during node provisioning.
- **oem-azure** — Azure platform integration

This enables decoupling component versions from the base OS image — e.g., kubelet can be updated independently.

### Update Mechanism

**Flatcar** uses the **Nebraska/Omaha update protocol** (inherited from CoreOS):

- `update_engine` polls a Nebraska server for new image versions.
- Updates are streamed to the inactive USR partition.
- The bootloader is switched atomically on reboot.
- Rollback is automatic if the new slot fails health checks.

**ACL** on AKS currently uses **node image upgrade** — AKS orchestrates rolling new VHD images to nodes. In-place A/B updates are planned using **Trident** (on-node update client) and **Nebraska** (update server), orchestrated by the AKS resource provider via the **Omaha** protocol:

- AKS RP orchestrates updates through Nebraska, which serves update metadata via the Omaha protocol.
- Trident on the node polls Nebraska, downloads the new image to the inactive USR partition.
- The bootloader is switched atomically on reboot; rollback is automatic on failure.

### Supply Chain

| | Flatcar | ACL |
| --- | --- | --- |
| **Package origin** | Gentoo upstream + Flatcar patches | Azure Linux RPM repositories |
| **Build infrastructure** | Flatcar CI (GitHub Actions) | Microsoft internal pipelines (OneBranch/1ES) |
| **Signing** | Flatcar signing keys | Microsoft signing keys |
| **CVE response** | Flatcar team rebuilds from Gentoo/upstream | Azure Linux team rebuilds RPMs; ACL picks up on next image build |
| **SBOM** | Available per release | Generated per build |

ACL's use of Azure Linux packages means every binary is built, scanned, and signed within Microsoft's infrastructure — providing a fully sovereign supply chain.

## Platform Support on AKS

| | Flatcar | ACL |
| --- | --- | --- |
| **AKS status** | Public preview (deprecation path) | Private preview (GA at //Build 2026) |
| **AKS OS SKU** | `FlatcarContainerLinux` | `AzureContainerLinux` (via `aks-preview` CLI extension) |
| **AKS node image upgrades** | ✅ | ✅ |
| **AKS GPU node pools** | N/A | ✅ (NVIDIA sysexts) |
| **Multi-cloud** | ✅ (AWS, GCP, Azure, bare-metal) | Azure only |
| **Dev/CI (QEMU)** | ✅ | ✅ |

ACL is purpose-built for Azure and AKS — it is the successor to Flatcar on AKS. Flatcar supports multi-cloud but is on the deprecation path for AKS.

## When to Use Which on AKS

| Scenario | Recommended |
| --- | --- |
| Azure AKS with Microsoft supply chain | ACL |
| SELinux enforcing out of the box on AKS | ACL |
| NVIDIA GPU node pools with Microsoft support | ACL |
| Sovereign supply chain (all binaries from Microsoft) | ACL |
| UKI-based Secure Boot with single-artifact validation | ACL |
| Rapid CVE patching via Azure Linux pipeline | ACL |
| Multi-cloud container host (AWS, GCP, bare-metal) | Flatcar |
| Community-driven, open-source-first | Flatcar |

> **Note**: Flatcar on AKS is in public preview and on the deprecation path. ACL is its successor — if you are deploying on AKS and want a Microsoft-supported immutable OS, ACL is the recommended choice.

## Further Reading

- [ACL Architecture](./architecture.md)
- [Azure Linux vs Azure Container Linux](./AZL_VS_ACL_AKS.md)
- [Flatcar Container Linux](https://www.flatcar.org/)
- [Flatcar documentation](https://www.flatcar.org/docs/latest/)
