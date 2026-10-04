# Testing

ACL reuses the Flatcar **Mantle/Kola** test framework:

- **Kola** is the test harness that boots images and runs test cases against them.
- **Mantle** is the container that packages kola along with platform-specific plumbing (QEMU, cloud SDKs, etc.).

## Test Categories

- `cl.basic` — fundamental OS health checks
- `cl.verity` — dm-verity integrity validation
- `cl.ignition.*` — Ignition provisioning scenarios
- `cl.cloudinit.*` — cloud-init configuration
- `cl.update.*` — A/B update lifecycle
- `sysext.*` — sysext activation and runtime behavior

## Enforcing Tests

**`kola_enforcing.yaml`** — a structured allowlist of kola test names that must pass before any image is published, with per-platform exception rules.

Results are emitted in TAP format and converted to Markdown summaries.

## ACL-Specific Tests

Additional tests live in `acl/tests/`:

- Secure Boot verification (`run-secureboot-test.sh`)
- systemd service health (`run-systemd-health-test.sh`)
- Disk I/O error detection (`run-dmesg-io-error-test.sh`)
- Container runtime smoke tests (`run-container-test.sh`)
- SELinux AVC check (`run-selinux-avc-test.sh`)

## Azure security-profile reboot diagnostics

The IPE and SELinux IMDS toggle tests use the same reboot helper. Each reboot
writes a separate `security-profile-<vm>.*` directory under `DIAGNOSTICS_DIR`
(`/tmp` when unset). Azure smoke runs publish these directories with their test
results. They contain:

- Read-only guest snapshots before and after reboot: SELinux/IPE state, current
  and previous boot journals, AVCs, SSH service state, file labels, and networking.
  SSH key contents are never collected.
- Timestamped boot-ID probe results, SSH stderr, and the reboot command status.
- On timeout, raw serial output and VM instance view. If SSH collection fails,
  a read-only Azure Run Command attempts another guest snapshot; that API returns
  only the output tail, so current state is printed last.

Each collection command has a timeout and separate stdout, stderr, and exit-code
files. Guest SSH snapshots are bounded to 30 seconds; failure-only instance-view,
serial, and Run Command calls are bounded to 20, 30, and 90 seconds respectively
(with a five-second termination grace period). Collection failures emit warnings
and do not hide the original test result. The reboot recovery timeout is unchanged.
Diagnostics run before the existing tag-restoration and VM-cleanup paths; no failed
VMs are retained.

Run the offline helper checks with:

```bash
bash acl/tests/test-azure-security-profile-test-common.sh
bash acl/tests/ipe/offline/test-ipe-mode-toggle-logic.sh
```
