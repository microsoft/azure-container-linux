# Flatcar 4459.2.4 to 4757.2.4: impact on ACL

The rebase updates the tools that build an ACL image. It does not replace the
Azure Linux RPMs inside that image with Flatcar packages. Most importantly,
**Flatcar 4757 ships signed, dm-verity-backed system extensions; the ACL rebase
candidate still produces plain SquashFS extensions.**

This comparison covers Flatcar Stable `4459.2.4` through `4757.2.4`, including
the intermediate `4593` Stable line and point releases. It compares ACL
[`424dd38a`][acl-before] with the rebased code at [`1dbd1b6aa3`][acl-after].
The upstream tags differ on **4,154 paths** with renames counted as a deletion
and an addition (`git diff --no-renames --name-only stable-4459.2.4 stable-4757.2.4`).
Of those, **3,869 (93%)** are under `portage-stable` or `coreos-overlay`, the
package-recipe trees used by Flatcar. They matter to the SDK but are not an ACL
node package manifest.

## Image construction, boot, and system extensions

| Area | What changed in Flatcar Stable | What changes for ACL at the candidate revision |
| --- | --- | --- |
| SDK and toolchain | SDK `4459.0.0` to `4757.0.0`. The two release lines refreshed QEMU, UEFI firmware tools, Go, Rust, CMake, and Meson. | **Adopted for builds.** ACL uses the [4757 SDK baseline][manifest] with its RPM/DNF and UKI tooling. Even with identical RPM inputs, different tools assemble the disk and boot artifacts. |
| Cross-architecture builds | Board setup provides per-target wrappers, using QEMU emulation when needed. The shared builder changed how it runs `ldconfig` and creates locales in the target image. | **Adopted for builds.** The RPM image invokes the [shared helpers][helpers]. An AMD64-only test does not exercise the ARM64 path. |
| SDK and test configuration | In `4757.2.4`, `run_sdk_container` stopped sourcing `.env` and `.sdkenv`; callers pass selected environment variables explicitly. | **Adopted.** ACL's [SDK wrapper][sdk-wrapper] and [test environment allowlist][test-env] carry inputs such as package snapshot, signing mode, Azure image selection, and QEMU firmware. This changes CI behavior, not a node feature. |
| Disk capacity | In `4593`, the generic EFI partition grew from 128 MiB to 1 GiB, each `/usr` slot from 1 to 2 GiB, and OEM from 128 MiB to 1 GiB. | **Only the non-UKI layout grows.** ACL inherits the [generic layout][generic-layout], but its primary [UKI layout][uki-layout] is unchanged: 192 MiB EFI, 1 GiB per `/usr` slot, 128 MiB OEM. A standard ACL UKI image does not gain that extra space. |
| Early boot | In `4593`, a small first-stage initrd opens `/usr` and loads the full boot environment from there. Flatcar reported roughly half the previous kernel-plus-initrd footprint on `/boot`. | **Not adopted.** ACL retains a unified kernel image (UKI) with one dracut initrd. The [builder skips second-stage reporting][initrd-report] for RPM images; Flatcar's size saving is not an ACL result. |
| System extension format and trust | In `4757`, OS-dependent and OEM extensions changed from plain SquashFS to EROFS disk images containing a dm-verity hash tree and signed root hash. Examples include containerd and the Azure OEM extension. | **Present in source, not enabled for ACL.** The [same builder][sysext-builder] calls `mksquashfs` in RPM mode and `systemd-repart` on the Flatcar path. Embedded containerd, Azure OEM, and separately delivered GPU extensions do not gain their own verity protection from this rebase. |
| Extension activation at boot | In `4757`, Flatcar mounts available extensions in the initrd. Their systemd units can participate in normal boot ordering instead of relying on the old late-loading workaround. | **Not adopted as a boot change.** ACL's [dracut config][dracut-config] includes a buffered-loop setting without enabling `systemd-sysext` there. Changing when extensions load is independent of changing their on-disk format. |
| `/etc` and A/B update behavior | `4757` supplies default `/etc` contents via `systemd-confext`, preserving local edits in the writable layer. | **ACL behavior retained.** The [RPM path][etc-builder] keeps defaults under `/usr/share/distro/etc`; only the Flatcar path builds the configuration-extension image. Existing settings must survive an ACL update and rollback. |
| Azure OEM and provisioning | `4757` moved OEM configuration into the build library, prebuilds signed OEM extensions, and changed OEM partition mounting so Ignition no longer handles it by itself. | **Partially adopted.** ACL uses the relocated OEM configuration but keeps its [RPM-specific OEM assembly and UKI addon][oem-builder]. An Azure VHD boot exercises provisioning and `oem-azure` behavior that a QEMU boot cannot establish. |
| Private extension mirrors | `4593` added `flatcar.release_file_server_url` and `flatcar.dev_file_server_url` to redirect extension downloads to private servers. | **Not established for ACL.** These are Flatcar bootengine features. ACL uses packaged boot components and its own standalone-extension delivery path; the rebase alone does not prove that ACL honors these options. |
| Secure Boot, signed `/usr`, and rollback | Upstream changed shim-signing configuration, development certificates, and test firmware handling. Extension signing introduced a separate trust path. | **Shared test tooling changed; ACL's trust design was retained.** ACL still uses its signed UKI, per-slot `/usr` verity metadata, optional root-hash signing, and Trident slot switching. A verified `/usr` does not authenticate a separately downloaded extension. Test an old-image-to-candidate update and rollback as well as fresh boot. |

## Software and platform support

Versions below describe **published Flatcar AMD64 images and extensions**, not
the RPM versions in the candidate. Compare the [4459 artifacts][artifacts-old]
with the [4757 artifacts][artifacts-new] (`flatcar_production_image_packages.txt`
and the package lists under `rootfs-included-sysexts/`).

| Area | What changed in released Flatcar | What changes for ACL |
| --- | --- | --- |
| Kernel, networking, and storage | Linux `6.12.74` to `6.12.118`. The intervening releases enabled netkit, ARM64 function tracing, NVMe/TCP, and AMD64 `FPROBE`. | **Not automatically inherited.** ACL boots an Azure Linux kernel RPM. Check the ACL kernel config and installed modules before claiming any of these features. |
| systemd, dracut, and Ignition | systemd `256.9` to `260.4`, dracut `106` to `110`, and Ignition `2.22.0` to `2.24.0`. Upstream fixed OEM Ignition config loading, PXE OEM customization, and automatic allocation of new partition numbers. | **Build assumptions change; guest versions do not follow Flatcar.** An upstream script may now expect a newer tool, while the ACL guest still gets that tool from RPMs. First-boot provisioning is a compatibility check, not proof that all Flatcar fixes shipped. |
| Container runtime | containerd `2.0.7` to `2.3.5`, runc `1.3.3` to `1.4.3`, and Docker Engine `28.0.4` to `28.4.0`. Flatcar added EROFS tools for containerd. | **No automatic runtime upgrade.** ACL keeps its own containerd RPM, service configuration, and [extension definitions][extensions]. ACL already specified `erofs-utils` in its containerd extension. EROFS tools for container layers and dm-verity protection for the extension itself are different things. |
| SSH, TLS, and trusted certificates | OpenSSH `10.2p1` to `10.4p1` and OpenSSL `3.4.4` to `3.5.9`. Flatcar adopted upstream SSH algorithm defaults, enabling post-quantum key exchange. `4757.2.3` removed 49 S/MIME-only roots from the TLS trust bundle. | **No automatic security or compliance change.** ACL's OpenSSH and OpenSSL RPMs, configuration, and CA bundle determine node behavior. Flatcar's release notes are not evidence of a CVE fix or CA removal in ACL. |
| GPUs and acceleration | `4757` added Intel Arc hardware-offload support in the kernel configuration, built the AMD GPU driver as a module, and enabled `/dev/kfd` on AMD64. | **No automatic driver change.** ACL's Azure Linux kernel and RPM-built NVIDIA CUDA, vGPU, toolkit, and fabric-manager extensions remain authoritative. GPU testing checks that the new builder still produces usable extensions. |
| Cloud and virtualization targets | Flatcar added Oracle Cloud images, refreshed VirtualBox/Vagrant, converted remaining legacy OEMs to sysexts, and dropped Rackspace and Equinix Metal. ARM64 QEMU also gained console diagnostics. | **Mostly outside ACL's product scope.** The shared VM-conversion scripts changed, so Azure VHD and QEMU outputs need testing. The rebase does not make Oracle Cloud or VirtualBox supported ACL targets. |

## Qualification boundary

For the **rebase**, build and boot on AMD64 and ARM64, run a container, exercise
Azure provisioning and GPU extensions, and update from the old ACL image to the
candidate and roll back with `/etc` settings intact. The comparisons above are
source findings for the two ACL commits, not a claim that these tests passed.

For **signed ACL extensions**, separately require a live dm-verity mapping for
both an embedded and a separately delivered extension, rejection of an untrusted
signer, and a failed read on corrupted data. If kernel IPE trust is required,
verify it independently of systemd's userspace signature check. A green rebase
build cannot establish any of those properties while the RPM path emits plain
SquashFS.

Upstream sources: [full tag diff][upstream-diff], [4593 Stable changes][4593],
[4757 Stable changes][4757], [4757.2.3 changes][4757-3],
[4757.2.4 changes][4757-4], and [upstream signing implementation][signing].

[acl-before]: https://github.com/microsoft/azure-container-linux/commit/424dd38a021e5db60c8310556866380aa9a27329
[acl-after]: https://github.com/microsoft/azure-container-linux/commit/1dbd1b6aa3a981acd9eb7520527dabb06299ab9d
[manifest]: ../../sdk_container/.repo/manifests/version.txt
[helpers]: ../../build_library/build_image_util.sh#L109-L125
[sdk-wrapper]: ../../run_sdk_container
[test-env]: ../../sdk_lib/env_mantle.txt
[generic-layout]: ../../build_library/disk_layout.json
[uki-layout]: ../../build_library/disk_layout_uki.json
[initrd-report]: ../../build_library/build_image_util.sh#L1058-L1072
[sysext-builder]: ../../build_sysext#L441-L478
[dracut-config]: ../../build_library/rpm/additional_files/99-acl.conf#L46-L47
[etc-builder]: ../../build_library/build_image_util.sh#L799-L840
[oem-builder]: ../../build_library/vm_image_util.sh#L693-L731
[extensions]: sysexts.md
[artifacts-old]: https://stable.release.flatcar-linux.net/amd64-usr/4459.2.4/
[artifacts-new]: https://stable.release.flatcar-linux.net/amd64-usr/4757.2.4/
[upstream-diff]: https://github.com/flatcar/scripts/compare/stable-4459.2.4..stable-4757.2.4
[4593]: https://github.com/flatcar/scripts/releases/tag/stable-4593.2.0
[4757]: https://github.com/flatcar/scripts/releases/tag/stable-4757.2.0
[4757-3]: https://github.com/flatcar/scripts/releases/tag/stable-4757.2.3
[4757-4]: https://github.com/flatcar/scripts/releases/tag/stable-4757.2.4
[signing]: https://github.com/flatcar/scripts/pull/3162
