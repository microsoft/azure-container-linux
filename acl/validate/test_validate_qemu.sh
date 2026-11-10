#!/usr/bin/env bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Regression tests for the serial console handling in the QEMU boot wait.
# A mock `virsh console` stands in for the VM, so the suite needs expect but
# no VM.

(
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

info() { :; }
warn() { :; }
error() { printf 'ERROR: %s\n' "$*" >&2; }

unset _VALIDATE_QEMU_LOADED
# shellcheck source=acl/validate/validate_qemu.sh
source "${SCRIPT_DIR}/validate_qemu.sh"

# MOCK_VM_STATE=booting models systemd-boot's startup key check: a key in the
# first 2 seconds opens its boot menu, which loader.conf's "timeout 0" leaves
# waiting for input; otherwise the VM logs in automatically. MOCK_VM_STATE=menu
# models a VM already stopped at that menu.
cat > "${TEST_TMPDIR}/virsh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "console" ]] || exit 1
echo "Connected to domain '$2'"
echo "Escape character is ^] (Ctrl + ])"
if [[ "${MOCK_VM_STATE}" == "menu" ]] || IFS= read -rs -n 1 -t 2 _; then
    echo "Reboot Into Firmware Interface"
else
    echo "acl login: azureuser (automatic login)"
fi
# Ctrl+] detaches, as it does from the real console.
while IFS= read -rs -n 1 key; do
    [[ "${key}" == $'\x1d' ]] && exit 0
done
EOF
chmod +x "${TEST_TMPDIR}/virsh"
export PATH="${TEST_TMPDIR}:${PATH}"
export MOCK_VM_STATE

# Usage: assert_boot_wait <description> <expected status> [console text]...
assert_boot_wait() {
    local description="$1"
    local expected_rc="$2"
    shift 2
    local rc=0 marker

    if wait_for_vm_boot_qemu acl 5 >"${TEST_TMPDIR}/console.log" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    if [[ ${rc} -ne ${expected_rc} ]]; then
        printf 'FAIL: %s: returned %s, expected %s\n' \
            "${description}" "${rc}" "${expected_rc}" >&2
        cat "${TEST_TMPDIR}/console.log" >&2
        return 1
    fi
    for marker in "$@"; do
        if ! grep -qF -- "${marker}" "${TEST_TMPDIR}/console.log"; then
            printf 'FAIL: %s: console output lacks "%s"\n' \
                "${description}" "${marker}" >&2
            cat "${TEST_TMPDIR}/console.log" >&2
            return 1
        fi
    done

    printf 'PASS: %s\n' "${description}"
}

# The fresh-boot case catches a boot wait that types only if the mock's key
# check reacts to a key.
mock_output="$(printf '\r' | MOCK_VM_STATE=booting virsh console acl)"
if [[ "${mock_output}" != *"Reboot Into Firmware Interface"* ]]; then
    printf 'FAIL: the mock ignored a key during its startup key check\n' >&2
    exit 1
fi
printf 'PASS: a key during the startup key check opens the mock boot menu\n'

MOCK_VM_STATE=booting
assert_boot_wait "fresh VM reaches its login prompt without console input" 0 \
    "Login prompt detected"

MOCK_VM_STATE=menu
assert_boot_wait "VM stopped at the systemd-boot menu fails the boot wait" 1 \
    "Reboot Into Firmware Interface" "Timeout waiting for login prompt"
)
