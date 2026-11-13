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

Here, "enforcing tests" means mandatory release-gate tests, not IPE enforcing
mode. The current ACL IPE integration supports audit, not enforcing mode.

## GitHub Validation

The required `github-acl-pr-validation` status check remains the ACL product
validation gate.

All 13 inherited Flatcar GitHub Actions workflow definitions in
`.github/workflows/` have a `.disabled` suffix. GitHub only discovers workflow
files ending in `.yml` or `.yaml`, so these definitions no longer register
scheduled, pull-request, comment, manual, or reusable workflows. Their contents
and helper scripts are retained for reference.

These legacy workflows assumed Flatcar release channels, package maintenance,
credentials, or runner infrastructure that is not configured for ACL. They
must not be counted as upstream compatibility coverage. Dedicated validation
of ACL changes against upstream Flatcar is follow-up work.

Re-enabling a definition requires removing its `.disabled` suffix in a reviewed
change, adapting its branch, authorization, and runner configuration, and
restoring any required reusable workflows together with their callers.

## ACL-Specific Tests

Additional tests live in `acl/tests/`:

- Secure Boot verification (`run-secureboot-test.sh`)
- systemd service health (`run-systemd-health-test.sh`)
- Disk I/O error detection (`run-dmesg-io-error-test.sh`)
- Container runtime smoke tests (`run-container-test.sh`)
- SELinux AVC check (`run-selinux-avc-test.sh`)

## IPE Tests

See the [IPE operator guide](ipe.md) for host diagnostics and mode changes.
IPE-specific coverage lives in [`acl/tests/ipe/`](../tests/ipe/):

| Test | Coverage |
|---|---|
| [`offline/run.sh`](../tests/ipe/offline/run.sh) | Policy inputs, credential/loader behavior, Azure profile parsing, launch and validation wiring without creating VMs |
| [`run-ipe-audit-test.sh`](../tests/ipe/run-ipe-audit-test.sh) | Active audit policy, effective containerd configuration, signed/unsigned `/usr` state, and execution-correlated would-deny records |
| [`run-ipe-mode-toggle-test.sh`](../tests/ipe/run-ipe-mode-toggle-test.sh) | Azure tag-driven mode transitions across reboots, including disabled/audit and rejection of unsupported enforcing intent |

The `aclmain` GitHub PR entrypoint enables audit, ephemeral signing, and signed
stock `/usr` roots for AMD64 and ARM64 Azure validation. Its Azure smoke path
runs `azure.smoke.ipe-mode-toggle`; QEMU remains IPE-disabled. See the
[build guide](BUILD_RPM_IMAGE_README.md#phase-3-build-the-image) for scope and
entrypoint differences.

Boot success alone does not prove IPE activation. Correlate an audit event with
the probe's exact executable and PID, and verify both `active=1` and
`enforce=0`. Full-journal records may be absent from kernel-only log views.

The signed-Btrfs path currently skips the `/usr` no-denial assertion because
of the known IPE/dm-verity/Btrfs trust issue. Passing the test does not resolve
that limitation. Candidate-image and mode-toggle tests also do not establish
production-signed COSI/A/B servicing or general signed-container qualification.
