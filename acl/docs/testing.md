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

## Opt-in Azure security-profile diagnostics

For an isolated diagnostic replay, set `ACL_SECURITY_PROFILE_DIAGNOSTICS=1`
and `DIAGNOSTICS_DIR` to the published test-results directory. The smoke runner
already provides the latter. The default is unchanged.

The shared IPE/SELinux helper records SSH diagnostics, HTTP and process exit
status, requested/observed profiles, and poll timestamps. On the first terminal
failure, before profile restoration and VM cleanup, it collects bounded ARM
state, activity/effective-NSG information, raw serial output and a best-effort
guest journal. Each diagnostic command retains separate stdout/stderr and its
status; serial SAS URLs are not saved. Guest journal collection can fail if SSH
is unavailable; serial and control-plane reads do not depend on guest SSH.

Assertions, test order, convergence/reboot timeouts and cleanup are unchanged.
Diagnostic commands have their own bounds and can delay cleanup. No diagnostic
failure converts the original test failure into success. This instrumentation
does not establish or fix the underlying failure, nor the separate issue where
restoring a profile without a `selinux` key retains the current SELinux mode.

Run the local helper regression with:

```bash
bash acl/tests/test-azure-security-profile-test-common.sh
```
