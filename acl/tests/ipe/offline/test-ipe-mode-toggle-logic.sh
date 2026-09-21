#!/bin/bash
# shellcheck disable=SC2034 # Variables below are consumed by sourced functions.
# Offline unit tests for the pure (non-VM) logic in
# run-ipe-mode-toggle-test.sh: the acl-node-security-profile tag -> expected
# runtime mode mapping, and the 'enforcing must never be observed' safety
# assertions. The reboot/IMDS orchestration itself requires a live Azure VM
# and is exercised by run-ipe-mode-toggle-test.sh directly in pipeline runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export SCRIPT_DIR

# Sourcing (rather than executing) skips main() — see the
# BASH_SOURCE-vs-$0 guard at the bottom of the toggle test script — while
# still loading the exact same helper functions it uses at runtime.
source "${SCRIPT_DIR}/acl/tests/ipe/run-ipe-mode-toggle-test.sh"

test_expected_mode_for_tag() {
    local case_spec input expected actual
    for case_spec in "disabled:off" "off:off" ":off" "audit:permissive" \
        "permissive:permissive" "enforcing:off" "bogus:off"; do
        input="${case_spec%%:*}"
        expected="${case_spec##*:}"
        actual="$(expected_mode_for_tag "${input}")"
        [[ "${actual}" == "${expected}" ]] ||
            { echo "expected_mode_for_tag('${input}') = '${actual}', want '${expected}'" >&2; return 1; }
    done
}

test_assert_ipe_mode_matches() {
    get_ipe_mode() { echo "off"; }
    assert_ipe_mode "off"
    get_ipe_mode() { echo "permissive"; }
    assert_ipe_mode "permissive"
}

test_assert_ipe_mode_mismatch_fails() {
    get_ipe_mode() { echo "off"; }
    if assert_ipe_mode "permissive" 2>/dev/null; then
        echo "assert_ipe_mode accepted a mismatched mode" >&2; return 1
    fi
}

# ---- Safety: 'enforcing' observed anywhere must fail loudly, regardless
# of what was expected, and must never be silently accepted. ----
test_assert_ipe_mode_rejects_enforcing() {
    get_ipe_mode() { echo "enforcing"; }
    local output
    if output="$(assert_ipe_mode "off" 2>&1)"; then
        echo "assert_ipe_mode accepted an observed 'enforcing' state" >&2; return 1
    fi
    grep -Fq "CRITICAL: IPE is ENFORCING at runtime" <<< "${output}" ||
        { echo "missing CRITICAL enforcing diagnostic" >&2; return 1; }
}

test_assert_ipe_not_enforcing() {
    get_ipe_mode() { echo "off"; }
    assert_ipe_not_enforcing
    get_ipe_mode() { echo "permissive"; }
    assert_ipe_not_enforcing

    get_ipe_mode() { echo "enforcing"; }
    local output
    if output="$(assert_ipe_not_enforcing 2>&1)"; then
        echo "assert_ipe_not_enforcing accepted an observed 'enforcing' state" >&2; return 1
    fi
    grep -Fq "CRITICAL: IPE is ENFORCING at runtime" <<< "${output}" ||
        { echo "missing CRITICAL enforcing diagnostic" >&2; return 1; }
}

test_acl_security_profile_value_reused() {
    # The toggle test reuses acl_security_profile_value() from the
    # production security-profile helper; confirm it parses the way the
    # in-guest loader expects.
    [[ "$(acl_security_profile_value 'ipe=audit,foo=bar' 'ipe')" == "audit" ]]
    [[ "$(acl_security_profile_value '' 'ipe')" == "" ]]
}

test_security_profile_updates_preserve_unrelated_keys() {
    [[ "$(
        security_profile_with_key 'ipe=audit,selinux=enforcing,foo=bar' \
            'selinux' 'permissive'
    )" == "ipe=audit,foo=bar,selinux=permissive" ]]
    [[ "$(
        security_profile_with_key 'selinux=enforcing,foo=bar' 'ipe' 'disabled'
    )" == "selinux=enforcing,foo=bar,ipe=disabled" ]]
    [[ "$(security_profile_with_key '' 'ipe' 'audit')" == "ipe=audit" ]]
}

test_tag_state_distinguishes_absent_from_empty() (
    local call_log="${TMPDIR:-/tmp}/security-profile-tag-calls.$$"
    local absent_state present_empty_state
    trap 'rm -f "${call_log}"' EXIT

    absent_state='{"present":false,"value":""}'
    present_empty_state='{"present":true,"value":""}'
    VM_RG="test-rg"
    VM_NAME="test-vm"
    imds_security_profile_state() { printf '%s\n' "${MOCK_IMDS_STATE}"; }
    az() {
        if [[ "$1 $2" == "vm show" ]]; then
            printf '%s\n' "/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/test"
            return 0
        fi
        printf '%s\n' "$*" >> "${call_log}"
    }

    MOCK_IMDS_STATE="${absent_state}"
    set_security_profile_tag_state "${absent_state}"
    grep -Fq 'tag update' "${call_log}"
    grep -Fq -- '--operation delete' "${call_log}"

    : > "${call_log}"
    MOCK_IMDS_STATE="${present_empty_state}"
    set_security_profile_tag_state "${present_empty_state}"
    grep -Fq -- '--operation merge' "${call_log}"
    grep -Fq -- '--tags acl-node-security-profile=' "${call_log}"
)

test_host_imds_rejects_multiple_documents() (
    ssh_cmd() { printf '%s' '[{"name":"acl-node-security-profile","value":"ipe=audit"}] []'; }

    if imds_security_profile_state >/dev/null 2>&1; then
        echo "host IMDS parser accepted multiple JSON documents" >&2
        return 1
    fi
)

test_cleanup_preserves_primary_failure() {
    local status

    set +e
    (
        ORIGINAL_SECURITY_PROFILE_STATE='{"present":false,"value":""}'
        SECURITY_PROFILE_MUTATED=true
        azure_security_profile_state() { printf '%s\n' '{"present":true,"value":"ipe=audit"}'; }
        set_security_profile_tag_state() { return 1; }
        section() { :; }
        warn() { :; }
        (exit 7)
        restore_security_profile_on_exit
    )
    status=$?
    set -e

    [[ "${status}" -eq 7 ]] || {
        echo "cleanup replaced primary status 7 with ${status}" >&2
        return 1
    }
}

test_cleanup_reboots_after_any_mutation() {
    local reboot_log="${TMPDIR:-/tmp}/security-profile-reboot.$$"
    local status
    rm -f "${reboot_log}"

    set +e
    (
        ORIGINAL_SECURITY_PROFILE_STATE='{"present":true,"value":"selinux=enforcing"}'
        SECURITY_PROFILE_MUTATED=true
        set_security_profile_tag_state() { return 0; }
        reboot_and_wait() { printf 'rebooted\n' > "${reboot_log}"; }
        section() { :; }
        info() { :; }
        warn() { :; }
        (exit 7)
        restore_security_profile_on_exit
    )
    status=$?
    set -e

    [[ "${status}" -eq 7 ]] || {
        echo "cleanup replaced primary status 7 with ${status}" >&2
        rm -f "${reboot_log}"
        return 1
    }
    [[ -s "${reboot_log}" ]] || {
        echo "cleanup skipped reboot after a profile mutation" >&2
        rm -f "${reboot_log}"
        return 1
    }
    rm -f "${reboot_log}"
}

test_expected_mode_for_tag
test_assert_ipe_mode_matches
test_assert_ipe_mode_mismatch_fails
test_assert_ipe_mode_rejects_enforcing
test_assert_ipe_not_enforcing
test_acl_security_profile_value_reused
test_security_profile_updates_preserve_unrelated_keys
test_tag_state_distinguishes_absent_from_empty
test_host_imds_rejects_multiple_documents
test_cleanup_preserves_primary_failure
test_cleanup_reboots_after_any_mutation

echo "IPE mode toggle logic tests passed"
