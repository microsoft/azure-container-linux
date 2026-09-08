#!/bin/bash
# Test reboot-based IPE mode selection through acl-node-security-profile.
#
# Canonical acl-node-security-profile values are 'disabled' and 'audit';
# 'off' and 'permissive' remain supported runtime aliases (disabled==off,
# audit==permissive) and stay covered below for backward compatibility.
# 'enforcing' is reserved: it must never activate at runtime, and any
# assertion that observes it fails loudly and immediately (see
# assert_ipe_mode / assert_ipe_not_enforcing).
#
# This script accepts whatever acl-node-security-profile tag the VM was
# *created* with (e.g. a smoke-test pipeline tagging
# acl-node-security-profile=ipe=audit before first boot): Step 0 reads and
# validates that initial state without forcing a reset first, then Steps
# 1-4 exercise the canonical disabled/audit reboot toggle, and Step 5
# re-exercises the legacy off/permissive aliases.

set -euo pipefail

source "${SCRIPT_DIR}/acl/validate/validate_common.sh"
source "${SCRIPT_DIR}/acl/tests/azure-security-profile-test-common.sh"
# Reuse the exact same key=value profile parser the in-guest loader uses,
# so the host-side test can never disagree with production parsing.
source "${SCRIPT_DIR}/build_library/rpm/additional_files/acl-node-security-profile.sh"

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

# Maps an acl-node-security-profile 'ipe' value (canonical or legacy alias)
# to the runtime state the loader is expected to produce. Mirrors
# build_library/rpm/additional_files/dracut-acl-ipe-load/acl-ipe-load.sh:
# disabled|off -> inactive, audit|permissive -> active/permissive,
# enforcing (reserved) and anything unrecognized -> inactive.
expected_mode_for_tag() {
    case "$1" in
        disabled|off|"") echo "off" ;;
        audit|permissive) echo "permissive" ;;
        *) echo "off" ;;
    esac
}

# CRITICAL, fails loudly and immediately: 'enforcing' must never be the
# observed runtime state, regardless of what was expected or requested.
assert_ipe_not_enforcing() {
    local actual
    actual=$(get_ipe_mode)
    if [[ "$actual" == "enforcing" ]]; then
        error "CRITICAL: IPE is ENFORCING at runtime; the reserved 'enforcing' value must never activate."
        return 1
    fi
    info "Confirmed IPE is not enforcing (actual='${actual}')"
}

assert_ipe_mode() {
    local expected="$1" actual
    actual=$(get_ipe_mode)
    if [[ "$actual" == "enforcing" ]]; then
        error "CRITICAL: IPE is ENFORCING at runtime; the reserved 'enforcing' value must never activate."
        return 1
    fi
    if [[ "$actual" != "$expected" ]]; then
        error "IPE mode is '${actual}' but expected '${expected}'"
        return 1
    fi
    info "IPE mode is '${actual}' (expected '${expected}')"
}

assert_ipe_assets_present() {
    local expected_active="${1:-0}"
    local cmdline usr_hash expected_signature_path policy_hash policy_active
    cmdline=$(ssh_cmd "cat /proc/cmdline")

    if [[ " ${cmdline} " == *" ipe.enforce="* ]]; then
        error "IPE mode is still embedded in the kernel command line"
        return 1
    fi
    # Verify the policy hash token is present on cmdline
    policy_hash="$(
        tr ' ' '\n' <<< "${cmdline}" |
            sed -n 's/^acl\.ipe\.policy_sha256=//p' |
            head -n 1
    )"
    if ! [[ "${policy_hash}" =~ ^[0-9a-f]{64}$ ]]; then
        error "acl.ipe.policy_sha256 token is missing or malformed in UKI cmdline"
        return 1
    fi
    if ! ssh_cmd "sudo test -r '${POLICY_DIR}/active'"; then
        error "IPE policy was not loaded"
        return 1
    fi
    policy_active="$(
        ssh_cmd "sudo cat '${POLICY_DIR}/active'" 2>/dev/null |
            tr -d '[:space:]'
    )"
    if [[ "${policy_active}" != "${expected_active}" ]]; then
        error "IPE policy active state is '${policy_active}', expected '${expected_active}'"
        return 1
    fi
    usr_hash="$(
        tr ' ' '\n' <<< "${cmdline}" |
            sed -n 's/^usrhash=//p' |
            head -n 1 |
            tr '[:upper:]' '[:lower:]'
    )"
    if ! [[ "${usr_hash}" =~ ^[[:xdigit:]]{64}$ ]]; then
        error "Valid /usr root hash is missing from the UKI"
        return 1
    fi
    expected_signature_path="/.extra/credentials/verity-usr-${usr_hash}.p7s.cred"
    if [[ "${cmdline}" != *"root-hash-signature=${expected_signature_path}"* ]]; then
        error "Hash-matched /usr root-hash signature companion is missing from the UKI"
        return 1
    fi
    info "IPE assets are present and policy active state is '${policy_active}'"
}

run_permissive_validation() {
    ssh "${SSH_OPTS[@]}" "${VM_SSH_USER}@${VM_IP}" \
        "sudo bash -s" \
        < "${SCRIPT_DIR}/acl/tests/ipe/run-ipe-permissive-test.sh"
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

    section "Step 0: Accept the VM's initial acl-node-security-profile state"
    # Read whatever tag the VM was already created/booted with (e.g. a smoke
    # pipeline pre-tagging acl-node-security-profile=ipe=audit) without
    # forcing a reset first, and validate it is honored.
    local initial_profile initial_ipe_value initial_expected expected_tag
    expected_tag="${ACL_EXPECTED_IPE_MODE:-}"
    case "${expected_tag}" in
        disabled|audit|"") ;;
        *)
            error "Invalid ACL_EXPECTED_IPE_MODE: ${expected_tag}"
            exit 1
            ;;
    esac
    if [[ -n "${expected_tag}" ]]; then
        initial_profile="$(imds_security_profile 2>/dev/null)" || {
            error "Could not read initial acl-node-security-profile from IMDS"
            exit 1
        }
    else
        initial_profile="$(imds_security_profile 2>/dev/null || true)"
    fi
    initial_ipe_value="$(acl_security_profile_value "${initial_profile}" "ipe")"
    if [[ -n "${expected_tag}" && "${initial_ipe_value}" != "${expected_tag}" ]]; then
        error "Initial IPE tag is '${initial_ipe_value:-<absent>}' but expected '${expected_tag}'"
        exit 1
    fi
    initial_expected="$(expected_mode_for_tag "${initial_ipe_value}")"
    info "Initial acl-node-security-profile: '${initial_profile:-<absent>}' (ipe='${initial_ipe_value:-<absent>}') -> expected IPE mode '${initial_expected}'"
    assert_ipe_mode "${initial_expected}"
    if [[ "${initial_expected}" == "permissive" ]]; then
        assert_ipe_assets_present 1
        run_permissive_validation
    else
        assert_ipe_assets_present 0
    fi

    section "Step 1: Disable IPE through the canonical 'disabled' value"
    set_security_profile_and_reboot "ipe=disabled"
    assert_ipe_mode "off"
    assert_ipe_assets_present

    section "Step 2: Verify the reserved 'enforcing' value is rejected and never activates"
    set_security_profile_and_reboot "ipe=enforcing"
    assert_ipe_not_enforcing
    assert_ipe_mode "off"
    assert_ipe_assets_present

    section "Step 3: Enable IPE through the canonical 'audit' value"
    set_security_profile_and_reboot "ipe=audit,foo=bar"
    assert_ipe_mode "permissive"
    assert_ipe_assets_present 1
    run_permissive_validation

    section "Step 4: Disable IPE through the canonical 'disabled' value"
    set_security_profile_and_reboot "ipe=disabled"
    assert_ipe_mode "off"
    assert_ipe_assets_present

    section "Step 5: Legacy alias coverage (off/permissive remain supported)"
    set_security_profile_and_reboot "ipe=permissive,foo=bar"
    assert_ipe_mode "permissive"
    assert_ipe_assets_present 1
    run_permissive_validation
    set_security_profile_and_reboot "ipe=off"
    assert_ipe_mode "off"
    assert_ipe_assets_present

    section "IPE IMDS Reboot Toggle Test Summary"
    info "All reboot-based IPE toggle assertions passed"
}

# Allow this script to be sourced (e.g. by an offline unit-test harness)
# without executing main, while preserving the exact same invocation
# contract when run directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
