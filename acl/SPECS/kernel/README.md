# Experimental Btrfs IPE kernel package

Opt-in implementation for ACL bug 24258, based on the policy-only IPE
dependency identified in `source.json`. This is not a production servicing
solution. Stock builds remain unchanged.

The vendor spec, both architecture configs, supporting sources and patch are
checked in here like other ACL packages. `kernel` remains absent from
`acl/packages.yaml`. Set `ACL_BTRFS_IPE_KERNEL=1` to build it through
`acl/build.sh`; the flag is forwarded through the SDK container and entrypoint.
The build pins the Azure Linux toolkit using `source.json` and publishes
`btrfs-ipe-kernel.json` with that provenance and the actual patch SHA-256.
RPM installation selects `6.6.157.1-1.btrfsipe1.azl3` explicitly, rejects
unmarked staging or unrequested experimental RPMs, and checks the UKI kernel.

The patch preserves IPE's existing `s_bdev` lookup. Its Btrfs callback returns
a referenced device only for a read-only single-device filesystem on a
read-only block device. Degraded, missing, seeded, writable and replacement
configurations fail closed. IPE still requires the dm-verity signature allow
rule: being Btrfs does not grant trust. Patch SHA-256:
`945a28dafcd2a26022ef7a1277ff31ba4f616f58d15da7e0fbd9aef43401068f`.

## Branch boundaries

`aadagarwal/btrfs-ipe-kernel` in ACL and acl-pipelines contains packaging,
build/select/install wiring, fresh-build guards and regression tests.
The pipeline flag `btrfsIpeKernel: true` does not change IPE mode, signing,
audit tooling, root-hash credentials or VM security settings.
Use fresh default-source RPMs, `sdkMode: customize`, `bootloaderMode: uki`,
`testOnly: false`, `reuseRpmsFromBuildId: none`, and no ACL-T customization.
Pin both repository resource versions when queueing a development build.

Dependent `aadagarwal/btrfs-ipe-diagnostics` branches add the separately
opted-in lab signing and VM/audit validation. Independent
`aadagarwal/kola-architecture-cleanup` branches contain the cross-architecture
Kola cleanup fix. Diagnostic qualification composes those CI branches by merge;
the focused kernel branches do not include them.

This package alone does not establish trusted `/usr`: root-hash signing and
certificate enrollment belong to the signing/validation environment, not the
kernel implementation. No policy allow rule is weakened here. Multi-device
concurrency, production signing and servicing require separate review.

## Local regression tests

```sh
python3 -m unittest discover -s acl/tests/ipe/btrfs -p 'test_*.py'
bash acl/tests/ipe/offline/test-btrfs-kernel-package-selection.sh
TMPDIR="$PWD/.test-scratch" bash acl/tests/ipe/offline/test-btrfs-kernel-install.sh
bash acl/tests/ipe/offline/test-ipe-policy-input.sh
```
