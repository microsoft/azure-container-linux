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

## Azure smoke private networking

The pipeline smoke runner requires an existing private subnet and its region.
The validator accepts `--az-private-subnet-id=<full subnet ARM ID>` (or
`AZ_PRIVATE_SUBNET_ID`), together with `--az-region=<region>` and
`--az-backup-regions=`. Pass the same options to subsequent host-script calls.
The subnet must be in `AZ_SUB_ID`, already exist in the selected region, and be
routable from the orchestrating agent. The exact gallery image version must be
replicated there before provisioning; the pipeline handles replica readiness.

Private mode creates no public IP and no NIC-level NSG. It reuses the subnet's
existing network policy without changing the shared VNet, subnet or NSG. It
rejects placement overrides, cross-region fallback, and using the network's
resource group for the disposable VM. Same-region SKU fallback is retained.
The selected private address is saved in the normal VM state and reused by
every host helper, including reboot and profile restoration. A missing or
ambiguous address fails rather than falling back to public SSH. Generic
validator callers that omit the private-subnet option retain their legacy
public-IP behavior; the pipeline smoke entrypoint does not permit that path.

Security-profile convergence errors distinguish SSH transport/session failure,
remote IMDS request failure, malformed IMDS data and valid-but-stale metadata.
SSH/curl stderr is retained even without opt-in diagnostics. A failed SSH probe
does not prove that IMDS or SELinux failed. Polling assertions and timeouts are
unchanged, and a test still fails when convergence cannot be verified.

## Opt-in Azure security-profile diagnostics

For an isolated diagnostic replay, set `ACL_SECURITY_PROFILE_DIAGNOSTICS=1`
and `DIAGNOSTICS_DIR` to the published test-results directory. The smoke runner
already provides the latter. The default is unchanged.

In addition to the default error classification, the shared IPE/SELinux helper
records SSH diagnostics, HTTP and process exit
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
bash acl/validate/test_validate_azure.sh
```
