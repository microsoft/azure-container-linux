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
- First-boot state and Ignition replay checks (`run-firstboot-state-test.sh`)

### Recaptured and prefetch-optimized images

An intermediate boot consumes both the legacy first-boot marker and, on UKI
images, the firstboot EFI addon. Generalization must rearm the final image, not
just an earlier Packer capture. Restoring only `/boot/flatcar/first_boot` does
not rearm UKI/systemd-boot images. Do not disable ignition-quench or leave a
permanent first-boot kernel argument as a workaround.

Validate the **final distributed artifact**, including any AIB optimization,
using unique Ignition CustomData that writes a fresh random token to
`/etc/acl-prefetch-probe`. Do not bake that token into the source image.
Include the normal SSH configuration required to access the test VM.

On its first boot, after Ignition completes:

```bash
sudo bash run-firstboot-state-test.sh first "$EXPECTED_SENTINEL"
cat /proc/sys/kernel/random/boot_id
```

Save that boot ID outside the VM, reboot it, and then run:

```bash
sudo bash run-firstboot-state-test.sh reboot "$EXPECTED_SENTINEL" "$FIRST_BOOT_ID"
```

The checks require the first-boot argument on the initial boot, absence of all
first-boot markers/addons after provisioning, the expected CustomData token,
and a genuinely different boot ID without the first-boot argument after reboot.
Repeat on both unoptimized and optimized images before measuring AKS operations.
Preserve the exact source/output image IDs, AIB logs, serial boot logs and both
boot IDs. A successful image build alone is not evidence that the final capture
retained the reset.

Run the local fixture tests with:

```bash
bash acl/tests/test-firstboot-state.sh
```
