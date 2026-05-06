# Ubuntu vs Azure Container Linux on AKS

This document compares **Ubuntu** (the default AKS node OS) and **Azure Container Linux (ACL)** in the context of running container workloads on AKS. Ubuntu is a general-purpose Linux distribution; ACL is a purpose-built, immutable container OS optimized for security and reliability.

## At a Glance

| | Ubuntu (AKS) | Azure Container Linux (ACL) |
| --- | --- | --- |
| **Type** | General-purpose mutable Linux | Purpose-built immutable container OS |
| **Heritage** | Debian/Canonical | Flatcar + Azure Linux packages |
| **Package system** | APT (deb) | Azure Linux RPMs (image-level only) |
| **Filesystem model** | Read-write root (`/`) | Read-only `/usr`, stateless root |
| **Primary boot path** | GRUB2 + kernel + initramfs | systemd-boot + Unified Kernel Image (UKI) |
| **Provisioning** | cloud-init | Ignition (first-boot) |
| **Mandatory access control** | AppArmor | SELinux (enforcing) |
| **Update mechanism** | `unattended-upgrades` / node image upgrade | Node image upgrade (AKS); A/B updates (planned) |
| **Container runtime** | containerd (apt package) | containerd (sysext) |
| **System extensions** | N/A (packages installed to root) | systemd-sysext |
| **GPU support** | NVIDIA drivers (apt packages) | NVIDIA sysexts (CUDA, vGPU, container toolkit, fabric manager), built by AzL team |
| **Supported platforms** | Multi-cloud, bare-metal, QEMU | Azure (primary), QEMU (dev/CI), bare-metal (planned) |
| **Architectures** | amd64, arm64 | amd64, arm64 |
| **Trusted Launch / Secure Boot** | Supported (shim + GRUB2) | Required (Microsoft-signed systemd-boot + signed UKI) |
| **Supply chain** | Canonical upstream + Microsoft patches | Microsoft Azure Linux RPM pipeline |
| **Attack surface** | Full userspace (SSH, shell, package manager, writable rootfs) | Reduced (SSH available via socket activation, shell present, but no package manager, read-only `/usr`, dm-verity, smaller OS footprint) |

## Key Differences

### Immutability

**Ubuntu** is a mutable OS — the root filesystem is read-write, packages can be installed/removed at runtime, and configuration drift is possible over the node's lifetime.

**ACL** is immutable by design:

- `/usr` is mounted read-only and protected by dm-verity (integrity-verified at block level).
- No package manager is available at runtime — the image is composed at build time.
- Runtime customization is done exclusively through systemd-sysext (composable, versioned extensions).
- Configuration drift is eliminated; every node boots an identical, known-good image.

### Security Model

**Ubuntu** uses AppArmor for mandatory access control. The root filesystem is writable, SSH is enabled by default, and the system includes a full shell environment.

**ACL** enforces a defense-in-depth model:

- **SELinux enforcing** — mandatory access control with custom policy.
- **dm-verity** — cryptographic integrity verification of the OS partition at every read.
- **UKI Secure Boot** — the entire boot chain (bootloader + kernel + initramfs + cmdline) is signed as a single artifact.
- **No package manager** — no `apt`, `dnf`, or `tdnf` at runtime. Nothing can be installed on a running node.
- **Read-only `/usr`** — tampering with OS binaries is not possible.

### Boot Path

**Ubuntu** boots via GRUB2 → kernel → initramfs (separate, unsigned components).

**ACL** boots via systemd-boot → UKI (single signed EFI binary containing kernel + initramfs + cmdline). The entire chain of trust extends from UEFI firmware through dm-verity on the root filesystem.

### Update Model

**Ubuntu** on AKS supports:

- **Node image upgrade** — AKS rolls a new VHD to nodes.
- **unattended-upgrades** — in-place package updates (can cause drift between nodes).
- **Package-based patching** — individual CVE fixes via `apt`.

**ACL** on AKS currently uses **node image upgrade** and will provide **in-place A/B updates** (planned) using **Trident** (on-node update client) and **Nebraska** (update server), orchestrated by the AKS resource provider via the **Omaha** protocol:

- AKS RP orchestrates updates through Nebraska, which serves update metadata via the Omaha protocol.
- Trident on the node polls Nebraska, downloads the new image to the inactive USR partition.
- The bootloader is switched atomically on reboot; rollback is automatic on failure.

No partial package updates — the entire OS image is replaced atomically.

### Runtime Composition

**Ubuntu** installs all software (containerd, kubelet, GPU drivers) as system packages into the mutable root filesystem.

**ACL** uses `systemd-sysext` for composable, layered extensions:

- Components are delivered as signed, versioned sysext images.
- Sysexts can be updated independently of the base OS (e.g., kubelet version upgrade without OS image rebuild).
- NVIDIA GPU drivers are delivered as Microsoft-built sysexts with full support.

### Node Consistency

**Ubuntu** nodes can drift over time — different patch levels, manually installed packages, configuration changes. This makes debugging harder and can lead to subtle inconsistencies across a node pool.

**ACL** provides strong node consistency — every node boots the same immutable OS image with a dm-verity-protected read-only `/usr` that cannot be modified at runtime. Updates are image-based (whole-image replacement), not package-based, eliminating the primary vector for drift. While `/etc` and `/var` are writable for runtime state, the OS binaries and libraries remain identical across all nodes in a pool.

## Platform Support on AKS

| | Ubuntu | ACL |
| --- | --- | --- |
| **AKS status** | GA (default OS) | Private preview (GA at //Build 2026) |
| **AKS OS SKU** | `Ubuntu` | `AzureContainerLinux` (via `aks-preview` CLI extension) |
| **AKS node image upgrades** | ✅ | ✅ |
| **AKS GPU node pools** | ✅ (apt packages) | ✅ (NVIDIA sysexts) |
| **AKS Confidential VMs** | ✅ | Planned |
| **Multi-cloud** | ✅ | Azure only |

## When to Use Which on AKS

| Scenario | Recommended |
| --- | --- |
| Default AKS workloads (broad compatibility) | Ubuntu |
| Custom kernel modules or third-party agents requiring host-level install | Ubuntu |
| Third-party agents running as OCI containers | Both (ACL supports containerized agents) |
| Security-hardened, immutable infrastructure | ACL |
| Zero-drift node pools | ACL |
| SELinux enforcing with dm-verity integrity | ACL |
| Minimal attack surface (no package manager, smaller footprint) | ACL |
| NVIDIA GPU with Microsoft-supported sysexts | ACL |
| Atomic OS updates with built-in rollback | ACL |
| Sovereign supply chain (all binaries from Microsoft) | ACL |

> **Note**: Ubuntu remains the default and most broadly compatible AKS OS. ACL is designed for workloads that prioritize security, immutability, and operational consistency over flexibility.

## Further Reading

- [ACL Architecture](./architecture.md)
- [Azure Linux vs Azure Container Linux](./AZL_VS_ACL_AKS.md)
- [Flatcar vs Azure Container Linux](./FLATCAR_VS_ACL_AKS.md)
- [Ubuntu on AKS](https://learn.microsoft.com/en-us/azure/aks/concepts-os-disk)
