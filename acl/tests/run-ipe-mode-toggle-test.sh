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

assert_ipe_assets_present() {
    local cmdline
    cmdline=$(ssh_cmd "cat /proc/cmdline")

    if [[ " ${cmdline} " == *" ipe.enforce="* ]]; then
        error "IPE mode is still embedded in the kernel command line"
        return 1
    fi
    if ! ssh_cmd "sudo test -s /usr/lib/ipe/acl.pol.p7b"; then
        error "Signed IPE policy is missing from verified /usr"
        return 1
    fi
    if ssh_cmd "sudo test -d '${POLICY_DIR}'"; then
        error "IPE policy was loaded even though no mode was requested"
        return 1
    fi
    if [[ "${cmdline}" != *"root-hash-signature=/etc/verity-usr-roothash.p7s"* ]]; then
        error "Slot-specific /usr root-hash signature is missing from the UKI"
        return 1
    fi
    info "IPE assets are present and no default mode is embedded in the UKI"
}

run_permissive_validation() {
    ssh "${SSH_OPTS[@]}" "${VM_SSH_USER}@${VM_IP}" \
        "sudo bash -s" \
        < "${SCRIPT_DIR}/acl/tests/run-ipe-permissive-test.sh"
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

    section "Step 1: Verify absent IMDS tag leaves IPE off"
    set_security_profile_tag ""
    reboot_and_wait
    assert_ipe_mode "off"
    assert_ipe_assets_present

    section "Step 2: Enable permissive IPE through IMDS"
    set_security_profile_tag "ipe=permissive,foo=bar"
    reboot_and_wait
    assert_ipe_mode "permissive"
    run_permissive_validation

    section "Step 3: Disable IPE through IMDS"
    set_security_profile_tag "ipe=off"
    reboot_and_wait
    assert_ipe_mode "off"

    section "Step 4: Remove tag and verify default remains off"
    set_security_profile_tag ""
    reboot_and_wait
    assert_ipe_mode "off"

    section "IPE IMDS Reboot Toggle Test Summary"
    info "All reboot-based IPE toggle assertions passed"
}

main "$@"
