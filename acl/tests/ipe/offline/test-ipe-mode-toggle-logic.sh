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

test_shared_cmdline_fields() {
    local cmdline='usrhash=ABC usrhash=DEF acl.ipe.policy_sha256=123 systemd.verity_usr_options=foo=bar,root-hash-signature=/expected,other=value'

    [[ "$(ipe_cmdline_field "${cmdline}" usrhash)" == "ABC" ]]
    [[ "$(ipe_cmdline_field "${cmdline}" acl.ipe.policy_sha256)" == "123" ]]
    [[ -z "$(ipe_cmdline_field "${cmdline}" unknown)" ]]
    [[ "$(ipe_cmdline_field \
        "$(ipe_cmdline_field "${cmdline}" systemd.verity_usr_options)" \
        root-hash-signature ',')" == "/expected" ]]
}

test_host_imds_matches_guest_parser() (
    acl_usrbin() { command "$@"; }
    local response expected_state expected_value

    for response in \
        '[]' \
        '[{"name":"acl-node-security-profile","value":""}]' \
        '[{"name":"acl-node-security-profile","value":"ipe=audit"}]'; do
        ssh_cmd() { printf '%s' "${response}"; }
        expected_state="$(imds_security_profile_state)"
        expected_value="$(jq -r '.value' <<< "${expected_state}")"
        [[ "$(printf '%s' "${response}" | acl_security_profile_parse)" == "${expected_value}" ]]
    done
    [[ "$(jq -r '.present' <<< "${expected_state}")" == "true" ]]
    ssh_cmd() { printf '%s' '[{"name":"acl-node-security-profile","value":""}]'; }
    [[ "$(jq -r '.present' <<< "$(imds_security_profile_state)")" == "true" ]]
    ssh_cmd() { printf '%s' '[]'; }
    [[ "$(jq -r '.present' <<< "$(imds_security_profile_state)")" == "false" ]]

    for response in \
        '{}' \
        '[{"name":"acl-node-security-profile","value":null}]' \
        '[{"name":"acl-node-security-profile","value":"ipe=audit"},{"name":"acl-node-security-profile","value":"ipe=off"}]' \
        '[{"name":"acl-node-security-profile","value":"ipe=audit"}] []'; do
        ssh_cmd() { printf '%s' "${response}"; }
        if imds_security_profile_state >/dev/null 2>&1 ||
            printf '%s' "${response}" | acl_security_profile_parse >/dev/null 2>&1; then
            echo "host or guest accepted invalid IMDS response: ${response}" >&2
            return 1
        fi
    done
)

mock_guest_cmdline() {
    cat() {
        if [[ "$1" == "/proc/cmdline" ]]; then
            printf 'usrhash=not-a-hash\n'
        else
            command cat "$@"
        fi
    }
    export -f cat
}

test_streamed_guest_contains_cmdline_parser() (
    local payload="${TMPDIR:-/tmp}/ipe-guest-payload.$$"
    trap 'rm -f "${payload}" "${payload}.out"' EXIT
    VM_SSH_USER=tester
    VM_IP=test-vm
    ssh() { cat > "${payload}"; }

    run_permissive_validation
    bash -n "${payload}"
    grep -Fq 'ipe_cmdline_field() {' "${payload}"
    grep -Fq 'usr_hash="$(ipe_cmdline_field "${cmdline}" usrhash)"' "${payload}"
    mock_guest_cmdline
    if bash -s < "${payload}" > "${payload}.out" 2>&1; then
        echo "Streamed guest script accepted an invalid root hash" >&2
        return 1
    fi
    grep -Fq 'FAILED: could not read the /usr dm-verity SHA-256 root hash from the command line' \
        "${payload}.out"
)

test_copied_guest_script_needs_no_sibling_file() (
    local test_dir script output_log
    test_dir="$(mktemp -d)"
    trap 'rm -rf "${test_dir}"' EXIT
    script="${SCRIPT_DIR}/acl/tests/ipe/run-ipe-permissive-test.sh"
    output_log="${test_dir}/output"
    VM_SSH_USER=tester
    VM_SSH_KEY=unused
    SCRIPT_RESULTS_NAMES=()
    SCRIPT_RESULTS_STATUS=()
    info() { :; }
    error() { :; }
    scp() {
        local source_file="${@: -2:1}"
        cp "${source_file}" "${test_dir}/$(basename "${source_file}")"
    }
    ssh() {
        mock_guest_cmdline
        bash "${test_dir}/$(basename "${script}")" > "${output_log}" 2>&1
    }

    if run_scripts_on_vm test-vm "${script}"; then
        echo "Guest script accepted an invalid root hash" >&2
        return 1
    fi
    grep -Fq 'FAILED: could not read the /usr dm-verity SHA-256 root hash from the command line' \
        "${output_log}"
    [[ "${SCRIPT_RESULTS_STATUS[0]}" -eq 1 ]]
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
test_shared_cmdline_fields
test_host_imds_matches_guest_parser
test_streamed_guest_contains_cmdline_parser
test_copied_guest_script_needs_no_sibling_file
test_cleanup_preserves_primary_failure
test_cleanup_reboots_after_any_mutation

echo "IPE mode toggle logic tests passed"
