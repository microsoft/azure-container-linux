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
# waiting for input; otherwise the VM autologins. MOCK_VM_STATE=running models
# an idle VM whose login prompt reappears only after Enter.
cat > "${TEST_TMPDIR}/virsh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "console" ]] || exit 1
echo "Connected to domain '$2'"
echo "Escape character is ^] (Ctrl + ])"
if [[ "${MOCK_VM_STATE}" == "booting" ]]; then
    if IFS= read -rs -n 1 -t 2 _; then
        echo "Reboot Into Firmware Interface"
    else
        echo "acl login: azureuser (automatic login)"
    fi
elif IFS= read -rs -n 1 -t 3 _; then
    echo "acl login: "
fi
# Ctrl+] detaches, as it does from the real console.
while IFS= read -rs -n 1 key; do
    [[ "${key}" == $'\x1d' ]] && exit 0
done
EOF
chmod +x "${TEST_TMPDIR}/virsh"
export PATH="${TEST_TMPDIR}:${PATH}"
export MOCK_VM_STATE

assert_boot_wait() {
    local description="$1"
    local expected_rc="$2"
    local rc=0

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

    printf 'PASS: %s\n' "${description}"
}

MOCK_VM_STATE=booting
REUSE_VM=false
assert_boot_wait "fresh VM reaches its login prompt without console input" 0

MOCK_VM_STATE=running
REUSE_VM=true
assert_boot_wait "reused VM gets Enter to redraw its login prompt" 0

# Shows the mock can fail: Enter during the key check stops at the menu.
MOCK_VM_STATE=booting
REUSE_VM=true
assert_boot_wait "Enter during systemd-boot's key check stops at its menu" 1
)
