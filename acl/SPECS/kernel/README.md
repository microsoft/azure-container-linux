# Experimental Btrfs IPE kernel

This is an opt-in diagnostic for ACL bug 24258, not a production kernel or
servicing solution. Stock builds are unchanged. It requires the policy-only
IPE implementation identified in `source.json`.

The vendor spec, architecture configs, supporting sources and IPE patch are
checked in here like the other ACL packages. There is no generated spec tree.
`kernel` stays out of `acl/packages.yaml`; only `ACL_BTRFS_IPE_KERNEL=1`
adds it to the build list and writes the staging provenance manifest.

The patch preserves IPE's existing `s_bdev` lookup. For Btrfs it introduces a
filesystem callback that returns a referenced device only for a read-only,
single-device filesystem on a read-only block device. Degraded, missing,
seeded, writable and replacement configurations fail closed. IPE still
requires the dm-verity signature allow rule; being Btrfs does not grant trust.

## Recorded fixture result (2026-10-07)

Both vendor kernels compiled and booted in nested AMD64 VMs on the Azure
fixture builder. The unchanged signed Btrfs fixtures produced **26 `/usr`
denial records with stock and zero with the patch**. All ten probes per
kernel passed the evidence verifier. Patched trusted probes had positive
signature BPRM/MMAP evidence; unsigned, writable and overlay-copy controls
still produced denials, enforcing mode blocked the writable executable,
and the corrupted signature was rejected. Audit loss was zero.

Tested patch SHA-256:
`945a28dafcd2a26022ef7a1277ff31ba4f616f58d15da7e0fbd9aef43401068f`.
Retrieved audit evidence was independently rechecked locally against this
patch. This fixture does **not** qualify full ACL RPM/image builds,
SELinux-enforcing ACL VMs or ARM64.

## Build a diagnostic ACL image

Use the corresponding acl-pipelines development branch and definition **5303
(acldevel)**, not production definition 5304. Publish both branches first.
Set `aclScriptsRef` to the candidate branch and pin the run's
`azure_container_linux` repository resource `version` to its commit. Parameters:

```yaml
btrfsIpeKernel: true
aclScriptsRef: aadagarwal/btrfs-ipe-kernel-proof
arch: amd64
bootloaderMode: uki
rpmSource: default
reuseRpmsFromBuildId: none
testOnly: false
buildAclTemplate: false
runSmokeAzure: true
runKolaAzure: true
```

The flag builds pinned Azure Linux kernel RPMs with release
`1.btrfsipe1.azl3`, bypasses the shared RPM cache, selects IPE audit mode and
ephemeral signing, and signs the final `/usr` verity root using the existing
shared lab certificate. The public signature is installed as a UKI companion
credential. Positive IPE auditing is enabled.
Diagnostic images also install the `audit` RPM so the guest validator can
require zero kernel-reported audit loss using `/usr/sbin/auditctl -s`.
The diagnostic kernel command line and auditd rules set an 8192-record backlog
to retain the extra success events during boot and auditd startup.
Stock images do not gain this test dependency.
Diagnostic Azure Kola VMs must use Trusted Launch with Secure Boot to expose
the enrolled ephemeral certificate through the kernel's platform keyring.
The pipeline opts into those launch flags only for this experiment and uses
an ARM v6 size (v5 does not support Trusted Launch). It requires the published
gallery image rather than an unsigned-trust VHD fallback. This is an ephemeral
lab-key requirement, not a claim that production IPE policy trust requires
Trusted Launch.

QEMU pipeline images, staging-bundle publication, ACL-T customization and
A/B servicing are not qualified by this experiment. The development flag
skips QEMU and A/B tests and staging-bundle publication, and rejects ACL-T.
Test-only, hydrated-artifact and RPM-reuse configurations are rejected during
template expansion so a skipped build cannot validate a stock kernel instead.
The normal Azure smoke IPE-toggle test selects
`acl/tests/ipe/btrfs/run-usr-audit-test.sh` for the candidate kernel. It requires:

- The exact candidate kernel, SELinux enforcing, and an active IPE audit policy.
- Signed dm-verity backing Btrfs, with no explicit root-hash policy allow rule.
- PID-correlated signature ALLOW events for executable loading and MMAP of
  `/usr/bin/true`, `/usr/bin/ls` and `/usr/bin/bash`.
- No base `/usr` or unclassified library-path denial in retained current-boot
  evidence, and zero kernel-reported audit loss. Sysext denials are accepted only
  after matching the first visible read-only extension layer, file bytes and
  audit inode. An overlay pathname alone is not evidence of base-file provenance.
- Expected denials for both containerd in a sysext and a copied writable executable.

Before the initial diagnostic audit scan, the host toggle test verifies the
existing mode/assets and reboots with the same profile. Earlier smoke tests
launch an nginx container: its `/usr/sbin/nginx` denial names the container's
filesystem, not host `/usr`. Audit paths alone cannot reconstruct a departed
mount namespace. A fresh boot isolates host evidence without whitelisting
nginx or silently discarding unclassified denials. Stock tests do not gain
this extra reboot.

A normal AMD64 acldevel image from run 1220256 was also checked directly:
1,893 base ELF executable mappings and 310 command executions produced signed
ALLOW evidence with no base denials or new audit loss. Sysext and writable-copy
controls produced DENY. That bounded post-boot result did not establish a
lossless full boot or ARM64 qualification.

The same exhaustive check was subsequently repeated on run 1220426's AMD64
`acldevel-test` image and ARM64 `acldevel-arm64` image. Each passed all 1,893
base ELF mappings and 310 executions (31 commands, four concurrent workers),
with no missing positive evidence, skipped commands or base denials. Both
reported zero lost audit events before and after the test; sysext and writable
controls still denied. Both also passed the source-aware guest validator.
The AMD64 test image booted with the enrolled ephemeral key in `.platform`
under Trusted Launch, unlike the default non-Trusted-Launch Kola launch.
Full pipeline qualification remains pending the diagnostic launch correction.

Do not count a successful command exit in audit mode as proof. Preserve the
guest logs, pipeline artifacts, RPM provenance manifest and source commits.
Repeat the full Azure image test with `arch: aarch64`; the nested runner below
does not cover ARM64. The version alone is not provenance: keep the patch hash
and build artifacts together because this is a fixed experimental release.

## Isolated stock-versus-patched VM regression

On a disposable AMD64 Linux builder with KVM, kernel build dependencies,
QEMU, `busybox-static`, Btrfs tools, cryptsetup, audit tools and Python:

```sh
sudo bash acl/tests/ipe/btrfs/build-vm-proof.sh \
  /var/tmp/btrfs-ipe-new-proof acl/SPECS/kernel/btrfs-ipe.patch
```

This builds the pinned stock and patched kernels and boots both under QEMU,
without replacing the builder's kernel. The same signed fixtures must fail
under stock IPE and pass under the patched kernel. Unsigned dm-verity,
plain Btrfs, writable files, overlay copy-up and corrupt signatures remain
negative controls. Signed direct/overlay paths and enforced execution are
checked using `verify-results.py`, with zero audit loss required.

This fixture is **not** a complete ACL/Secure Boot/SELinux qualification.
Multi-device/degraded/replacement concurrency and production signing/servicing
still require separate validation and kernel-maintainer review.

Host tests:

```sh
python3 -m unittest discover -s acl/tests/ipe/btrfs -p 'test_*.py'
```
