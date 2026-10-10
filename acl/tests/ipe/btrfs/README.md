# Btrfs IPE diagnostic qualification

This dependent test branch adds lab-only `/usr` root-hash signing, audit tools,
an 8192-event backlog, positive IPE audit logging, source-aware guest validation
and fresh-boot isolation. None belongs to the focused kernel implementation.

Set **both** `ACL_BTRFS_IPE_KERNEL=1` and `ACL_BTRFS_IPE_DIAGNOSTIC=1` for
SDK/image builds. The first selects/builds the package; the second enables the
diagnostic environment. With diagnostics off, the kernel flag alone does not
install audit tools, change signing, add root credentials or enable success
logging. SDK entry rejects diagnostics without the kernel, and UKI provisioning
requires IPE assets and ephemeral signing for diagnostics.

In development pipeline 5303 (`acldevel`), use both `btrfsIpeKernel: true` and
`btrfsIpeDiagnostic: true`, `arch: both`, `sdkMode: customize`,
`bootloaderMode: uki`, `rpmSource: default`, `reuseRpmsFromBuildId: none`,
`testOnly: false`, `buildAclTemplate: false`, `runSmokeAzure: true`,
`runKolaAzure: true`, `maxRuns: 1`. Disable QEMU, A/B, GPU and SDK/Mantle pushes.
Pin the `self` and `azure_container_linux` resource versions to exact commits.
The diagnostic flag skips unqualified QEMU/A-B paths. Ephemeral signing keys
are not production signing and no policy allow rule is weakened.

## Branch composition

ACL and acl-pipelines `aadagarwal/btrfs-ipe-diagnostics` depend on their
`aadagarwal/btrfs-ipe-kernel` branches. For live testing they additionally merge
the independent `aadagarwal/kola-architecture-cleanup` branches. That integration
provides the runner's `kolaArch` tag and matching build+architecture cleanup
filter; focused kernel refs do not contain CI changes.

Azure Kola requires a gallery image with the ephemeral certificate enrolled,
Trusted Launch/Secure Boot, and an ARM v6 size. These requirements are specific
to the diagnostic lab key, not a general IPE production-trust requirement.
The guest validator checks signed BPRM/MMAP ALLOW evidence, zero base `/usr`
denials and audit loss, and expected sysext/writable-copy DENY controls.
It rejects unclassified paths rather than assuming overlay means sysext.
Fresh boot isolates prior container smoke namespaces from host audit evidence.

## Previous qualification, before branch separation

[Run 1220805](https://dev.azure.com/mariner-org/ACL/_build/results?buildId=1220805)
succeeded using ACL `96f209f5cc050776439175f1fcbf236272723d24`,
pipelines `1c768f9ca661ee500f75b7ab9cd451572e812198` and Mantle
`4d40d4650289105028671f259bd6941d42ba4ffe`.
Each architecture passed eight smoke checks and 49 required Kola checks:
69 total Kola passes, one skip and two pre-existing exempt `acl.internet`
failures. No exemption was added. Logs 710/744 contain Kola evaluations;
611/792 contain successful AMD64/ARM64 smoke results.

ARM64 smoke needed one unchanged retry: the first VM stopped during the final
profile-restoration reboot after IPE checks and SELinux assertions passed.
Serial collection failed and the cause remains undiagnosed. The retry is not
evidence that reboot reliability was fixed. These results qualify only the old
source composition; a new pinned both-architecture run is required for this split.

Kernel release remains `6.6.157.1-1.btrfsipe1.azl3`, patch SHA-256
`945a28dafcd2a26022ef7a1277ff31ba4f616f58d15da7e0fbd9aef43401068f`.
Retain staging provenance and artifacts: the fixed version alone is insufficient.
Production servicing and multi-device/replacement concurrency remain unqualified.

## Regression tests

```sh
python3 -m unittest discover -s acl/tests/ipe/btrfs -p 'test_*.py'
bash acl/tests/ipe/offline/test-btrfs-ipe-signature.sh
bash acl/tests/ipe/offline/test-btrfs-usr-denials.sh
bash acl/tests/ipe/offline/test-ipe-policy-input.sh
bash acl/tests/ipe/offline/test-ipe-mode-toggle-logic.sh
```

The isolated stock-versus-patched AMD64 fixture requires a disposable Linux
builder with KVM, QEMU, kernel build tools, busybox-static, Btrfs, cryptsetup,
audit tools and Python:

```sh
sudo bash acl/tests/ipe/btrfs/build-vm-proof.sh \
  "$PWD/btrfs-ipe-new-proof" acl/SPECS/kernel/btrfs-ipe.patch
```

It is not full ACL/SELinux/ARM64 qualification. Previous fixtures recorded
26 stock `/usr` denials versus zero patched, with signed positive evidence
and unsigned/writable/corrupt-signature controls preserved.
