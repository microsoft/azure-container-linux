#!/bin/bash
# Test reboot-based IPE mode selection through acl-node-security-profile.

set -euo pipefail

source "${SCRIPT_DIR}/acl/validate/validate_common.sh"
source "${SCRIPT_DIR}/acl/tests/azure-security-profile-test-common.sh"

POLICY_NAME="acl_ipe_boot_policy"
IPE_DIR="/sys/kernel/security/ipe"
POLICY_DIR="${IPE_DIR}/policies/${POLICY_NAME}"

get_ipe_mode() {
    local active enforce
    if ! ssh_cmd "sudo test -r '${POLICY_DIR}/active'"; then
        echo "off"
        return 0
    fi

    active=$(ssh_cmd "sudo cat '${POLICY_DIR}/active'" 2>/dev/null | tr -d '[:space:]')
    if [[ "$active" != "1" ]]; then
        echo "off"
        return 0
    fi

    enforce=$(ssh_cmd "sudo cat '${IPE_DIR}/enforce'" 2>/dev/null | tr -d '[:space:]')
    case "$enforce" in
        0) echo "permissive" ;;
        1) echo "enforcing" ;;
        *) echo "unknown:${enforce}" ;;
    esac
}

assert_ipe_mode() {
    local expected="$1" actual
    actual=$(get_ipe_mode)
    if [[ "$actual" == "$expected" ]]; then
        info "IPE mode is '${actual}' (expected '${expected}')"
        return 0
    fi
    error "IPE mode is '${actual}' but expected '${expected}'"
    return 1
}

main() {
    parse_validate_args "$@"

    section "IPE IMDS Reboot Toggle Test"

    if [[ "$VM_TYPE" != "azure" ]]; then
        info "Skipping IPE toggle test (requires Azure VM with IMDS)"
        exit 0
    fi

    read_vm_state
    setup_ssh_opts

    info "VM: ${VM_NAME} (RG: ${VM_RG}, IP: ${VM_IP})"
    if ! wait_for_ssh "$VM_IP" "$VM_SSH_TIMEOUT"; then
        error "Cannot reach VM via SSH"
        exit 1
    fi

    section "Step 1: Check signed UKI default"
    assert_ipe_mode "permissive"

    section "Step 2: Disable IPE through IMDS and reboot"
    set_security_profile_tag "ipe=off,foo=bar"
    reboot_and_wait
    assert_ipe_mode "off"

    section "Step 3: Restore permissive IPE through IMDS and reboot"
    set_security_profile_tag "ipe=permissive"
    reboot_and_wait
    assert_ipe_mode "permissive"

    section "Step 4: Remove override and verify signed UKI fallback"
    set_security_profile_tag ""
    reboot_and_wait
    assert_ipe_mode "permissive"

    section "IPE IMDS Reboot Toggle Test Summary"
    info "All reboot-based IPE toggle assertions passed"
}

main "$@"
