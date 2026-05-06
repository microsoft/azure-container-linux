# Azure Linux vs Azure Container Linux on AKS

This document compares the two Microsoft Linux distributions available as AKS node OS images: **Azure Linux (AzL)** and **Azure Container Linux (ACL)**.

## At a Glance

| | Azure Linux (AzL) | Azure Container Linux (ACL) |
| --- | --- | --- |
| **Heritage** | CBL-Mariner → Azure Linux 3.0 | Flatcar Container Linux + Azure Linux packages |
| **Design philosophy** | General-purpose server OS | Container-optimized, immutable OS |
| **AKS OS SKU** | `AzureLinux` | `AzureContainerLinux` (via `aks-preview` CLI extension) |
| **Root filesystem** | Read-write ext4 | Multi-partition A/B layout: read-only `/usr` (btrfs + zstd, dm-verity protected), overlayfs `/etc` (read-only defaults + writable upper), writable ROOT for `/etc` upper layer and state, OEM partition, EFI System Partition with UKI |
| **Package manager** | `tdnf` / `dnf` (RPM-based, runtime) | None at runtime — packages baked at build time |
| **System extensions** | N/A — install packages directly | systemd-sysext (squashfs overlays on `/usr`) |
| **Update model** | Node image upgrade, node pool replacement, or package-update (`dnf`) | Node image upgrade (`NodeImage`), node pool replacement, or in-place A/B image-based updates (planned) |
| **Init provisioning** | cloud-init | Ignition (first-boot only) |
| **Boot path** | GRUB2 + standard kernel/initramfs | systemd-boot + Unified Kernel Image (UKI) |
| **Mandatory access control** | AppArmor (optional) | SELinux (enforcing) |
| **GPU support** | Packages installed via `tdnf`, built by AzL team | NVIDIA sysexts (CUDA, vGPU, container toolkit, fabric manager), built by AzL team|
| **Container runtime** | containerd | containerd (delivered as a base sysext) |
| **Architectures** | amd64, arm64 | amd64, arm64 |
| **VM generation** | Gen1, Gen2 | Gen2 only |
| **Trusted Launch / Secure Boot / vTPM** | Supported (Gen2) | Required |
| **FIPS 140-2/140-3** | Supported (FIPS-enabled node pools) | Planned |
| **Pod sandboxing (Kata Containers)** | Supported | Planned |
| **Artifact streaming** | Supported | Planned |
| **Confidential VMs** | Supported | Planned |

## Architecture Differences

### Filesystem & Immutability

**Azure Linux** uses a conventional mutable filesystem. Administrators can install packages, modify system files, and apply updates in place — familiar to anyone who has worked with a traditional Linux server.

**Azure Container Linux** treats the OS as an **immutable image** with a multi-partition disk layout:

- **USR-A / USR-B** — A/B pair of read-only btrfs partitions (zstd compressed) protected by **dm-verity**. The verity hash tree is appended to the partition data; any block-level corruption triggers an immediate kernel panic. Only one slot is active at a time; the inactive slot is used for updates.
- **ROOT** — a writable ext4 partition that holds the `/etc` overlay upper layer, `/var`, and other persistent state. Created at minimal size and auto-expanded on first boot by `systemd-repart` / `systemd-growfs` to fill all remaining disk space.
- **OEM** — carries platform-specific integration (e.g., `oem-azure` for Azure, `oem-qemu` for dev/CI).
- **EFI System Partition (ESP)** — holds the systemd-boot bootloader and the signed UKI binary.
- `/etc` is mounted as an **overlayfs**: lower layer from `/usr/share/distro/etc` (read-only defaults from the image), upper layer on the ROOT partition (writable, persistent).
- There is no runtime package manager. All software in the image is determined at build time.

This makes Azure Container Linux nodes inherently more tamper-resistant and reproducible — every node booted from the same image version is byte-for-byte identical.

### Update Model

**Azure Linux** supports multiple update strategies on AKS:

- **Node image upgrade** — AKS rolls a new VHD to nodes, replacing the entire OS image.
- **SecurityPatch** — applies security patches without a full node image upgrade.
- **Package-based update** — update individual packages in place via `dnf`/`tdnf` (e.g., for targeted CVE patches between image refreshes).

**Azure Container Linux** currently supports **node image upgrade** on AKS, and will provide **in-place A/B image-based updates** (planned) using **Trident** (on-node update client) and **Nebraska** (update server), orchestrated by the AKS resource provider via the **Omaha** protocol:

1. AKS RP orchestrates updates through Nebraska, which serves update metadata via the Omaha protocol.
2. Trident on the node polls Nebraska, downloads the new image to the inactive USR partition slot (e.g., USR-B while running on USR-A).
3. The new slot's dm-verity hash tree is validated.
4. The bootloader is atomically switched to the new slot on the next reboot.
5. If the new slot fails to boot, the system rolls back to the previous slot.

This gives Azure Container Linux update atomicity and built-in rollback at the OS level.

### Boot Path

**Azure Linux** boots with GRUB2, a conventional kernel image, and a standard initramfs.

**Azure Container Linux** uses **systemd-boot** and **Unified Kernel Images (UKI)**:

- `ukify` packs the kernel, initramfs, kernel command line (including dm-verity parameters), and an EFI stub into a single signed PE binary.
- UKI addons provide first-boot gating (for Ignition) and OEM selection without rebuilding the image.
- Secure Boot validates the entire UKI as one artifact — there is no gap between bootloader, kernel, and command line. This extends the chain of trust from Azure TrustedLaunch through to the dm-verity assured contents of the usr partition.

### Provisioning

**Azure Linux** uses **cloud-init**, which runs with module frequency controls (e.g., per-instance, per-boot) and supports a wide range of configuration modules (users, packages, write_files, runcmd, etc.).

**Azure Container Linux** uses **Ignition**, which runs **once on first boot from the initramfs** — before the root filesystem is mounted. It processes a JSON config (delivered via Azure custom data) to write files, create users, configure SSH keys, set up systemd units, and format disks. After first-boot processing, the Ignition addon is removed so subsequent boots skip provisioning entirely.

### System Extensions (sysexts)

Since Azure Container Linux has no runtime package manager, post-build composability is delivered as **systemd-sysext** images — squashfs archives that overlay onto `/usr` at boot:

- **containerd** — container runtime (base sysext, baked into the image)
- **oem-azure** — Azure platform integration
- **azure-acr-credential-provider** — ACR authentication
- **ig** — Inspektor Gadget
- **kubectl** and **kubelet** — Kubernetes node components (version dynamically selected to match the Kubernetes version being deployed)
- **node-exporter-kubernetes** — Prometheus node metrics
- **node-problem-detector-kubernetes** — node health monitoring
- **NVIDIA GPU drivers** — `nvidia-driver-cuda-open`, `nvidia-driver-cuda`, `nvidia-driver-vgpu` (deployed only on GPU SKUs)
- **NVIDIA container toolkit** and **fabric manager** (deployed only on GPU SKUs)

Azure Linux delivers equivalent functionality through standard RPM packages installed via `tdnf`.

### Mandatory Access Control

Both distributions enforce mandatory access control (MAC) but use different frameworks:

**Azure Linux** uses **AppArmor**, a path-based MAC system. AppArmor profiles define access rules based on file paths rather than file labels. This makes policies easier to write and audit — you can read a profile and immediately see which paths a process may access. AKS integrates AppArmor natively: pods can reference AppArmor profiles via annotations, and the default `docker-default` / `cri-containerd.apparmor.d` profile is applied to containers automatically.

**Azure Container Linux** uses **SELinux in enforcing mode**. SELinux is a label-based MAC system — every file, process, port, and socket carries a security context label, and the policy defines which label-to-label interactions are permitted. This provides stronger isolation guarantees because labels follow objects regardless of path (e.g., a renamed or hard-linked file retains its label). ACL's policy is based on the upstream refpolicy (aligned with Flatcar's SELinux configuration) with ACL-specific patches for container runtimes, systemd, and Kubernetes. The policy enforces strict separation between host OS services and container workloads (isolated under the `container_t` type). The policy source and patches are maintained in [`acl/SPECS/selinux-policy/`](https://dev.azure.com/mariner-org/ACL/_git/acl-scripts?path=/acl/SPECS/selinux-policy). Kubernetes pod security contexts can set `seLinuxOptions` to assign specific labels to containers.

Key practical differences:

| | AppArmor (Azure Linux) | SELinux (ACL) |
| --- | --- | --- |
| **Policy model** | Path-based rules | Label-based rules |
| **Ease of authoring** | Simpler — profiles reference file paths | More complex — requires understanding of type enforcement and label transitions |
| **Isolation granularity** | Per-path access control | Per-object label; survives renames, hard links, and mount changes |
| **Kubernetes integration** | Pod `securityContext.appArmorProfile` | Pod `securityContext.seLinuxOptions` |
| **Default container policy** | `cri-containerd.apparmor.d` | `container_t` type with Flatcar-aligned policy |

## AKS Deployment

### Azure Linux

Azure Linux is a first-class AKS OS SKU. Creating a cluster is straightforward:

```bash
az aks create \
  --resource-group myRG \
  --name azl-cluster \
  --os-sku AzureLinux
```

### Azure Container Linux

ACL is available through the **aks-preview** Azure CLI extension. This is currently available for internal (Microsoft) use and requires approval for external usage.

```bash
# Install or update the aks-preview extension
az extension add --name aks-preview
az extension update --name aks-preview

# Create an ACL cluster
az aks create \
  --resource-group myRG \
  --name acl-cluster \
  --os-sku AzureContainerLinux \
  --ssh-key-value ~/.ssh/id_rsa.pub
```

> **Note:** External (non-Microsoft) access to ACL requires approval. Contact the ACL team for onboarding.

> **Note:** ACL requires Gen2 VM sizes with Trusted Launch support. Ensure your node pool uses a VM SKU that supports Gen2 (e.g., `Standard_D4s_v3` or newer `_v4`/`_v5` series).

## When to Use Which

| Scenario | Recommended |
| --- | --- |
| General-purpose AKS workloads | Azure Linux |
| Need to install custom packages on nodes | Azure Linux |
| Familiar Linux administration experience | Azure Linux |
| Maximum node immutability / tamper resistance | Azure Container Linux |
| Atomic OS updates with rollback | Azure Container Linux |
| Strict supply-chain security requirements | Azure Container Linux |
| GPU workloads with sysext-based driver delivery | Azure Container Linux |
| Minimal, container-only node OS (reduced attack surface) | Azure Container Linux |

## Supply Chain

Both distributions share the same **Azure Linux RPM package pipeline** — every binary is built, scanned, and signed within Microsoft's infrastructure.

- **Azure Linux**: the base image is constructed offline with packages baked in at build time. Additional packages can be installed and existing packages can be updated at runtime via `tdnf`.
- **Azure Container Linux**: all packages are embedded in the image at build time with no runtime package manager. CVE fixes flow through Azure Linux's rapid package rebuild pipeline and are picked up in the next ACL image build, reducing time-to-patch without requiring runtime package installation.

## Further Reading

- [ACL Architecture](./architecture.md)
- [Azure Linux OS Guard vs ACL](./OSGUARD_VS_ACL_AKS.md)
- [Flatcar vs Azure Container Linux](./FLATCAR_VS_ACL_AKS.md)
- [Provisioning ACL on AKS](./PROVISION_ACL_AKS_CLUSTER.md)
- [Building BYOI Images from acldevel](./BYOI_AKS_FROM_ACLDEVEL.md)
- [Azure Linux documentation](https://learn.microsoft.com/en-us/azure/azure-linux/)
- [Flatcar Container Linux](https://www.flatcar.org/)
