# Azure Linux with OS Guard vs Azure Container Linux on AKS

> **⚠️ Future Deprecation:** Azure Linux with OS Guard is expected to be deprecated once ACL incorporates all OS Guard features (IPE, verified container layers, FIPS). At that point, ACL will be the single hardened immutable container OS for AKS.

[Azure Linux with OS Guard](https://learn.microsoft.com/en-us/azure/aks/use-azure-linux-os-guard) is a hardened, immutable variant of Azure Linux that adds many of the same security properties ACL provides. Understanding the overlap — and the differences — is important when choosing a node OS.

## At a Glance

| | Azure Linux + OS Guard | Azure Container Linux |
| --- | --- | --- |
| **Base** | Azure Linux 3.0 | Flatcar Container Linux + Azure Linux packages |
| **Immutability** | Read-only `/usr` via dm-verity | Read-only `/usr` via dm-verity (btrfs + zstd) |
| **Boot path** | UKI (systemd-boot) | UKI (systemd-boot) |
| **Code integrity** | dm-verity + IPE LSM (audit mode during preview) | dm-verity on `/usr`; no LSM-based exec policy yet |
| **Mandatory access control** | SELinux — stringent policy confining host + containers (permissive during preview) | SELinux (enforcing) — policy focused on host/container split; selectable policy levels planned |
| **Provisioning** | cloud-init | Ignition (first-boot only, from initramfs) |
| **Package manager** | `tdnf`/`dnf` still present for `root` (mutable `/`) | None — packages baked at build time |
| **Root filesystem** | Mutable `/` (ext4, growfs) | Multi-partition A/B layout; overlayfs `/etc` |
| **A/B update support** | Single-slot design today (no A/B partition pair); A/B was prototyped but dropped from preview scope due to AKS RP integration gaps | Full A/B partition pair (USR-A/USR-B) from day one |
| **Container image verification** | Verified container layers via signed dm-verity hashes + IPE | Standard containerd image pulls (image verification planned) |
| **FIPS** | Always enabled | Planned |
| **Trusted Launch / Secure Boot** | Required (all images) | Required |
| **System extensions** | systemd-sysext (squashfs overlays on `/usr`) | systemd-sysext (squashfs overlays on `/usr`) |
| **GPU support** | Not yet supported | NVIDIA sysexts (CUDA, vGPU, container toolkit) |
| **OS upgrade channels** | `NodeImage` or `None` only; in-place A/B update planned | `NodeImage` or `None` only; in-place A/B update planned |
| **Kubernetes version** | ≥ 1.32.0 required | ≥ 1.34.0 required |
| **Architectures** | amd64 only (preview) | amd64, arm64 |
| **Pod sandboxing (Kata)** | Not supported | Planned |
| **Artifact streaming** | Not supported | Planned |
| **Confidential VMs** | Not supported | Planned |

## Disk Layout

OS Guard's [image configuration](https://github.com/microsoft/azurelinux/blob/3.0/toolkit/imageconfigs/osguard-amd64.yaml) defines the following partition scheme:

| Partition | Type | Size | Mount | Notes |
| --- | --- | --- | --- | --- |
| ESP | EFI System | 512 MB | `/boot/efi` | `nodev,noexec` |
| boot-a | linux-generic | 100 MB | `/boot` | `nodev,noexec,nosuid` |
| usr-a | linux-generic | 1 GB | `/usr` (via verity) | `nodev,ro` — dm-verity protected |
| usr-hash-a | usr-verity | 128 MB | — | Hash tree for usr-a |
| root-a | root | 12 GB | `/` | `nodev,nosuid,x-systemd.growfs` — mutable ext4 |

ACL's disk layout is similar but differs in key ways:

| Partition | Type | Size | Mount | Notes |
| --- | --- | --- | --- | --- |
| EFI-A | EFI System | 128 MB | `/boot` | Holds UKI |
| USR-A | btrfs + zstd | ~1.5 GB | `/usr` | dm-verity protected, read-only |
| USR-B | btrfs + zstd | ~1.5 GB | — | Inactive slot for A/B updates |
| OEM | ext4 | 64 MB | `/oem` | First-boot Ignition config |
| ROOT | ext4 | Remainder | `/` | Writable state |

Key difference: OS Guard ships with a **single boot/usr slot** (`-a` only) today — B slots will be created at runtime as part of A/B update enablement. ACL ships with a full **A/B partition pair** from the start.

## Key Differences

### Immutability Depth

Both protect `/usr` with dm-verity. ACL goes further: there is no runtime package manager at all, and `/etc` is an overlayfs with read-only defaults.

### MAC Enforcement

Both use SELinux, but the policy scope differs. OS Guard's SELinux policy is more stringent — it confines host processes as well as containers, locking down the entire system. ACL's policy focuses on the split between host and container workloads: containers run under `container_t` with strict isolation from host services, but the host policy is lighter, relying on immutability and dm-verity rather than per-daemon confinement.

In terms of enforcement state: ACL runs SELinux in enforcing mode today and supports toggling enforcement via node image tags. OS Guard ships SELinux in permissive mode during preview — it logs violations but does not block them.

> **Planned:** ACL will support multiple SELinux policy levels, allowing customers to choose the right degree of enforcement for their workloads — from the current container-focused policy up to stricter host-confinement profiles similar to OS Guard.

### Code Integrity (IPE)

OS Guard adds the [Integrity Policy Enforcement](https://docs.kernel.org/next/admin-guide/LSM/ipe.html) LSM, which restricts execution to binaries on trusted dm-verity volumes. ACL does not currently have an exec-based integrity policy — its protection model relies on the absence of a package manager and dm-verity for `/usr`. IPE is a meaningful additional defense-in-depth layer, though it is audit-only during OS Guard's preview. IPE is planned for ACL.

### Verified Container Layers

OS Guard validates container image layers using signed dm-verity hashes at runtime, ensuring only verified layers execute. ACL currently uses standard containerd image pull and verification; container-layer dm-verity is not yet implemented.

### Provisioning Model

OS Guard uses cloud-init (same as standard Azure Linux); ACL uses Ignition, which runs once from the initramfs before the root is mounted and then removes itself. Ignition's declarative, one-shot model avoids re-processing drift on subsequent boots.

### Sysext Composability

Both OS Guard and ACL support systemd-sysext for post-build composability (squashfs overlays on `/usr`). ACL has a more mature sysext ecosystem — GPU drivers (CUDA, vGPU, container toolkit), containerd, and custom extensions are all delivered as sysexts. OS Guard supports the sysext mechanism but does not ship GPU sysexts.

### Maturity

OS Guard is in public preview with several restrictions (no arm64, no Kata, no CVM, no artifact streaming, Kubernetes ≥ 1.32 only). ACL is in preview with broader architecture support but with its own feature gaps (FIPS, Kata, CVM planned).

## When to Choose Which

For most AKS hardened-OS scenarios, **ACL is the recommended path** — it provides SELinux enforcing, immutable rootfs with dm-verity, sysext composability, GPU support, arm64, smaller image footprint, and declarative provisioning via Ignition.

Choose **OS Guard** only if your workload specifically requires IPE (integrity-policy enforcement on exec) or verified container layers today, and you can accept the preview-stage limitations (no arm64, no Kata, no CVM, Kubernetes ≥ 1.32 only). Note that OS Guard-specific features such as IPE are planned for inclusion in ACL in coming months.

| Scenario | Recommended |
| --- | --- |
| Need IPE (exec-from-verified-volume enforcement) today | OS Guard |
| Need verified container layers today | OS Guard |
| Require FIPS 140-2/140-3 today | OS Guard (always-on) |
| Coming from standard Azure Linux — want hardening with minimal operational change | OS Guard |
| Need GPU sysexts today | ACL |
| Need SELinux in enforcing mode today | ACL |
| Need arm64 nodes | ACL |
| Ignition-based declarative provisioning | ACL |
| Atomic A/B OS updates with rollback (planned) | ACL |

## Further Reading

- [Azure Linux with OS Guard documentation](https://learn.microsoft.com/en-us/azure/azure-linux/intro-azure-linux-os-guard)
- [OS Guard image config (osguard-amd64.yaml)](https://github.com/microsoft/azurelinux/blob/3.0/toolkit/imageconfigs/osguard-amd64.yaml)
- [Azure Linux vs ACL](./AZL_VS_ACL_AKS.md)
- [ACL Architecture](./architecture.md)
