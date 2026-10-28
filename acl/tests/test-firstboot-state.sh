#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=acl/tests/run-firstboot-state-test.sh
source "${SCRIPT_DIR}/run-firstboot-state-test.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${ROOT}/etc" "${ROOT}/proc/sys/kernel/random" \
    "${ROOT}/boot/flatcar" "${ROOT}/boot/EFI/Linux/vmlinuz-test.efi.extra.d"
printf 'ID=azurelinux\nVARIANT_ID=azurecontainerlinux\n' > "${ROOT}/etc/os-release"
printf 'unique-test-payload\n' > "${ROOT}/etc/acl-prefetch-probe"
printf 'first-id\n' > "${ROOT}/proc/sys/kernel/random/boot_id"
printf 'console=ttyS0 flatcar.first_boot=detected\n' > "${ROOT}/proc/cmdline"

expect_failure() {
    if validate_firstboot_state "$@" > "${ROOT}/output" 2>&1; then
        echo "FAIL: expected validation to reject $*" >&2
        exit 1
    fi
}

validate_firstboot_state first "${ROOT}" unique-test-payload
expect_failure first "${ROOT}" wrong-payload
touch "${ROOT}/boot/flatcar/first_boot"
expect_failure first "${ROOT}" unique-test-payload
rm "${ROOT}/boot/flatcar/first_boot"
touch "${ROOT}/boot/EFI/Linux/vmlinuz-test.efi.extra.d/firstboot.addon.efi"
expect_failure first "${ROOT}" unique-test-payload
rm "${ROOT}/boot/EFI/Linux/vmlinuz-test.efi.extra.d/firstboot.addon.efi"
expect_failure reboot "${ROOT}" unique-test-payload first-id
printf 'second-id\n' > "${ROOT}/proc/sys/kernel/random/boot_id"
expect_failure reboot "${ROOT}" unique-test-payload first-id
printf 'console=ttyS0\n' > "${ROOT}/proc/cmdline"
validate_firstboot_state reboot "${ROOT}" unique-test-payload first-id
expect_failure first "${ROOT}" unique-test-payload
expect_failure reboot "${ROOT}" unique-test-payload
expect_failure unknown "${ROOT}" unique-test-payload
printf 'ID=ubuntu\n' > "${ROOT}/etc/os-release"
expect_failure reboot "${ROOT}" unique-test-payload first-id
echo "PASS: first-boot state regression cases"
