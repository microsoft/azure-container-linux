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
    for case_spec in "disabled:off" "off:off" ":off" "audit:audit" \
        "permissive:off" "enforcing:off" "bogus:off"; do
        input="${case_spec%%:*}"
        expected="${case_spec##*:}"
        actual="$(expected_mode_for_tag "${input}")"
        [[ "${actual}" == "${expected}" ]] ||
            { echo "expected_mode_for_tag('${input}') = '${actual}', want '${expected}'" >&2; return 1; }
    done
}

test_get_ipe_mode_reports_audit() (
    ssh_cmd() {
        case "$*" in
            *"test -r"*) return 0 ;;
            *"/active"*) echo 1 ;;
            *"/enforce"*) echo 0 ;;
            *) echo "Unexpected guest command: $*" >&2; return 1 ;;
        esac
    }
    [[ "$(get_ipe_mode)" == audit ]]
)

test_assert_ipe_mode_matches() {
    get_ipe_mode() { echo "off"; }
    assert_ipe_mode "off"
    get_ipe_mode() { echo "audit"; }
    assert_ipe_mode "audit"
}

test_assert_ipe_mode_mismatch_fails() {
    get_ipe_mode() { echo "off"; }
    if assert_ipe_mode "audit" 2>/dev/null; then
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
    get_ipe_mode() { echo "audit"; }
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
    local option_key options='foo=bar,root-hash-signature=/expected-path_with-punctuation,other=value'

    [[ "$(ipe_cmdline_field "${cmdline}" usrhash)" == "ABC" ]]
    [[ "$(ipe_cmdline_field "${cmdline}" acl.ipe.policy_sha256)" == "123" ]]
    [[ -z "$(ipe_cmdline_field "${cmdline}" unknown)" ]]
    [[ "$(ipe_cmdline_field \
        "$(ipe_cmdline_field "${cmdline}" systemd.verity_usr_options)" \
        root-hash-signature ',')" == "/expected" ]]
    for option_key in systemd.verity_usr_options systemd.verity-usr-options \
        systemd.verity_usr-options systemd.verity-usr_options; do
        [[ "$(ipe_cmdline_field "${option_key}=${options}" systemd.verity_usr_options)" == "${options}" ]]
        [[ "$(ipe_cmdline_field \
            "$(ipe_cmdline_field "${option_key}=${options}" systemd.verity_usr_options)" \
            root-hash-signature ',')" == "/expected-path_with-punctuation" ]]
    done
}

test_root_signature_detection() {
    local cmdline option_key
    if ipe_has_root_hash_signature \
        'usrhash=abc systemd.verity_usr_options=hash-offset=4096,panic-on-corruption'; then
        echo "unsigned verity was classified as requiring a signature" >&2
        return 1
    fi
    for cmdline in \
        'root-hash-signature=/unexpected' \
        'systemd.verity_usr_options=root-hash-signature=/unexpected' \
        'systemd.verity_usr_options=hash-offset=4096,root-hash-signature=,panic-on-corruption' \
        'systemd.verity_usr_options=hash-offset=4096 systemd.verity_usr_options=root-hash-signature=/unexpected'; do
        ipe_has_root_hash_signature "${cmdline}" || {
            echo "required root signature was missed: ${cmdline}" >&2
            return 1
        }
    done
    for option_key in systemd.verity_usr_options systemd.verity-usr-options \
        systemd.verity_usr-options systemd.verity-usr_options; do
        ipe_has_root_hash_signature "${option_key}=panic-on-corruption,root-hash-signature=/expected"
        if ipe_has_root_hash_signature "${option_key}=panic-on-corruption" ||
           ipe_has_root_hash_signature "${option_key}=root_hash_signature=/unexpected"; then
            echo "Unsigned verity or an invalid inner option was classified as signed: ${option_key}" >&2
            return 1
        fi
    done
}

test_usr_verity_signature_contract() {
    local hash unsigned_cmdline signed_cmdline unsigned_table signed_table option_key="${1:-systemd.verity_usr_options}"
    hash="$(printf '%064d' 1)"
    unsigned_cmdline="usrhash=${hash} ${option_key}=panic-on-corruption"
    signed_cmdline="${unsigned_cmdline},root-hash-signature=/.extra/credentials/verity-usr-${hash}.p7s.cred"
    unsigned_table="0 2097152 verity 1 8:2 8:3 4096 4096 262144 1 sha256 ${hash} abcd 1 panic_on_corruption"
    signed_table="${unsigned_table/1 panic_on_corruption/3 panic_on_corruption root_hash_sig_key_desc test-key}"

    [[ "$(ipe_validate_usr_verity_table "${unsigned_cmdline}" "${unsigned_table}" none)" == none ]]
    [[ "$(ipe_validate_usr_verity_table "${unsigned_cmdline}" "${unsigned_table}" auto)" == none ]]
    [[ "$(ipe_validate_usr_verity_table "${signed_cmdline}" "${signed_table}" required)" == required ]]
    if ipe_validate_usr_verity_table "${signed_cmdline}" "${unsigned_table}" required ||
       ipe_validate_usr_verity_table "${unsigned_cmdline}" "${signed_table}" none ||
       ipe_validate_usr_verity_table "${unsigned_cmdline}" "${unsigned_table}" required ||
       ipe_validate_usr_verity_table "${signed_cmdline}" "${signed_table}" none ||
       ipe_validate_usr_verity_table "${signed_cmdline}" "${signed_table/${hash}/wrong-hash}" required ||
       ipe_validate_usr_verity_table "${signed_cmdline/.p7s.cred/.wrong}" "${signed_table}" required ||
       ipe_validate_usr_verity_table "${unsigned_cmdline},root-hash-signature=" "${signed_table}" required ||
       ipe_validate_usr_verity_table "${signed_cmdline}" "${signed_table% test-key}" required ||
       ipe_validate_usr_verity_table "${unsigned_cmdline}" "${unsigned_table}" invalid; then
        echo "Accepted an inconsistent /usr signature contract" >&2
        return 1
    fi
}

test_toggle_preserves_usr_signature_mode() (
    local hash unsigned_cmdline unsigned_table option_key="${1:-systemd.verity_usr_options}"
    hash="$(printf '%064d' 1)"
    unsigned_cmdline="usrhash=${hash} acl.ipe.policy_sha256=${hash} ${option_key}=panic-on-corruption"
    unsigned_table="0 2097152 verity 1 8:2 8:3 4096 4096 262144 1 sha256 ${hash} abcd 1 panic_on_corruption"
    export MOCK_CMDLINE="${unsigned_cmdline},root-hash-signature=/.extra/credentials/verity-usr-${hash}.p7s.cred"
    export MOCK_TABLE="${unsigned_table/1 panic_on_corruption/3 panic_on_corruption root_hash_sig_key_desc test-key}"
    local mock_active=1
    EXPECTED_USR_SIGNATURE_MODE=auto
    VM_SSH_USER=tester
    VM_IP=test-vm
    SSH_OPTS=()
    ssh_cmd() {
        case "$*" in
            "cat /proc/cmdline") printf '%s\n' "${MOCK_CMDLINE}" ;;
            *"test -r"*) return 0 ;;
            *"/active"*) printf '%s\n' "${mock_active}" ;;
            *) echo "Unexpected guest command: $*" >&2; return 1 ;;
        esac
    }
    cat() {
        if [[ "${1:-}" == /proc/cmdline ]]; then
            printf '%s\n' "${MOCK_CMDLINE}"
        else
            command cat "$@"
        fi
    }
    readlink() { echo /dev/dm-0; }
    findmnt() { echo /dev/dm-0; }
    dmsetup() {
        case "$1" in
            info) echo usr ;;
            table) printf '%s\n' "${MOCK_TABLE}" ;;
            *) echo "Unexpected dmsetup command: $*" >&2; return 1 ;;
        esac
    }
    sudo() { "$@"; }
    export -f cat readlink findmnt dmsetup sudo
    ssh() { bash -c "${@: -1}"; }

    assert_ipe_assets_present 1
    [[ "${EXPECTED_USR_SIGNATURE_MODE}" == required ]]
    mock_active=0
    assert_ipe_assets_present 0
    MOCK_CMDLINE="${unsigned_cmdline}"
    MOCK_TABLE="${unsigned_table}"
    if assert_ipe_assets_present 0; then
        echo "Disabling IPE allowed the root signature requirement to disappear" >&2
        return 1
    fi
    # The independent expectation rejects an unsigned first boot in both
    # the toggle assertion and the ordinary streamed audit invocation.
    EXPECTED_USR_SIGNATURE_MODE=required
    if assert_ipe_assets_present 0; then
        echo "Signed qualification accepted an unsigned first boot" >&2
        return 1
    fi
    local failure
    if failure="$(run_audit_validation 2>&1)"; then
        echo "Ordinary audit accepted an unsigned signed-qualification image" >&2
        return 1
    fi
    [[ "${failure}" == *"expected required, got none"* ]]
    EXPECTED_USR_SIGNATURE_MODE=none
    assert_ipe_assets_present 0
    EXPECTED_USR_SIGNATURE_MODE=auto
    assert_ipe_assets_present 0
    [[ "${EXPECTED_USR_SIGNATURE_MODE}" == none ]]
    MOCK_CMDLINE="${unsigned_cmdline},root-hash-signature=/.extra/credentials/verity-usr-${hash}.p7s.cred"
    MOCK_TABLE="${unsigned_table/1 panic_on_corruption/3 panic_on_corruption root_hash_sig_key_desc test-key}"
    if assert_ipe_assets_present 0; then
        echo "Unsigned-root baseline changed during IPE toggling" >&2
        return 1
    fi
)

test_toggle_accepts_caller_expectation() (
    local mode output
    for mode in required none auto; do
        output="$(ACL_EXPECTED_USR_SIGNATURE_MODE="${mode}" bash -c '
            source "${SCRIPT_DIR}/acl/tests/ipe/run-ipe-mode-toggle-test.sh"
            printf "%s" "${EXPECTED_USR_SIGNATURE_MODE}"
        ')"
        [[ "${output}" == "${mode}" ]]
    done
    if ACL_EXPECTED_USR_SIGNATURE_MODE=invalid bash -c '
        source "${SCRIPT_DIR}/acl/tests/ipe/run-ipe-mode-toggle-test.sh"
    '; then
        echo "Invalid qualification expectation was accepted" >&2
        return 1
    fi
)

test_signed_and_unsigned_probe_expectations() {
    local usr_event writable_event
    usr_event='type=1420 ipe_op=EXECUTE enforcing=0 pid=123 path="/usr/bin/true" rule="DEFAULT op=EXECUTE action=DENY"'
    writable_event='type=1420 ipe_op=EXECUTE enforcing=0 pid=456 path="/var/tmp/probe" rule="DEFAULT op=EXECUTE action=DENY"'
    ipe_assert_probe_audit "${writable_event}" /usr/bin/true 123 allow
    ipe_assert_probe_audit "${usr_event}" /usr/bin/true 123 deny
    ipe_assert_probe_audit "${writable_event}" /var/tmp/probe 456 deny
    if ipe_assert_probe_audit "${usr_event}" /usr/bin/true 123 allow ||
       ipe_assert_probe_audit "${writable_event}" /usr/bin/true 123 deny ||
       ipe_assert_probe_audit "${usr_event}" /var/tmp/probe 456 deny ||
       ipe_assert_probe_audit "" /usr/bin/true invalid allow; then
        echo "Accepted an incorrect signed/unsigned audit result" >&2
        return 1
    fi
}

test_signed_btrfs_probe_defers_no_denial_assertion() (
    local event output
    event='type=1420 ipe_op=EXECUTE enforcing=0 pid=123 path="/usr/bin/true" rule="DEFAULT op=EXECUTE action=DENY"'
    blkid() { echo btrfs; }
    output="$(ipe_assert_usr_probe_audit "${event}" /usr/bin/true 123 required)"
    grep -Fq "WARN: Skipping signed /usr no-denial assertion" <<< "${output}"
    ipe_assert_usr_probe_audit "" /usr/bin/true 123 required
    ipe_assert_usr_probe_audit "${event}" /usr/bin/true 123 none
    if ipe_assert_usr_probe_audit "" /usr/bin/true 123 none; then
        echo "Unsigned /usr lost its denial assertion" >&2
        return 1
    fi

    blkid() { echo ext4; }
    ipe_assert_usr_probe_audit "" /usr/bin/true 123 required
    if ipe_assert_usr_probe_audit "${event}" /usr/bin/true 123 required; then
        echo "Signed non-btrfs /usr lost its no-denial assertion" >&2
        return 1
    fi
    blkid() { return 1; }
    if ipe_assert_usr_probe_audit "${event}" /usr/bin/true 123 required; then
        echo "Filesystem detection failure bypassed the audit assertion" >&2
        return 1
    fi
)

test_probe_denial_correlation() {
    local event='type=1420 ipe_op=EXECUTE ipe_hook=BPRM_CHECK enforcing=0 pid=123 comm="true" path="/usr/bin/true" rule="DEFAULT op=EXECUTE action=DENY"'
    local invalid
    [[ "$(ipe_find_denial_event "${event}" /usr/bin/true 123)" == "${event}" ]]
    for invalid in \
        "${event/pid=123/pid=1234}" \
        "${event/\/usr\/bin\/true/\/var\/tmp\/true}" \
        "${event/enforcing=0/enforcing=1}" \
        "${event/ipe_op=EXECUTE/ipe_op=READ}" \
        "${event/action=DENY/action=ALLOW}" \
        ""; do
        if ipe_find_denial_event "${invalid}" /usr/bin/true 123 >/dev/null; then
            echo "unrelated or missing audit record satisfied the /usr probe" >&2
            return 1
        fi
    done
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
    ssh() {
        [[ "${*: -1}" == "sudo bash -s -- --expected-usr-signature-mode 'required'" ]]
        cat > "${payload}"
    }

    EXPECTED_USR_SIGNATURE_MODE=required
    run_audit_validation
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
    script="${SCRIPT_DIR}/acl/tests/ipe/run-ipe-audit-test.sh"
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

test_audit_fallback_restores_containerd() (
    local test_dir expected actual
    test_dir="$(mktemp -d)"
    trap 'rm -rf "${test_dir}"' EXIT
    get_ipe_mode() { echo audit; }
    ssh_cmd() {
        case "$*" in
            *"sudo test ! -e"*) ;;
            *"sudo bash -s"*)
                cat > "${test_dir}/setup"
                echo setup >> "${test_dir}/calls"
                return "${expected}"
                ;;
            *"sudo rm -f"*) echo restore >> "${test_dir}/calls" ;;
            *) echo "Unexpected guest command: $*" >&2; return 1 ;;
        esac
    }
    for expected in 0 7; do
        : > "${test_dir}/calls"
        set +e
        (set -e; run_audit_fallback_validation)
        actual=$?
        set -e
        [[ "${actual}" -eq "${expected}" ]]
        [[ "$(cat "${test_dir}/calls")" == $'setup\nrestore' ]]
        bash -n "${test_dir}/setup"
    done
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
test_get_ipe_mode_reports_audit
test_assert_ipe_mode_matches
test_assert_ipe_mode_mismatch_fails
test_assert_ipe_mode_rejects_enforcing
test_assert_ipe_not_enforcing
test_acl_security_profile_value_reused
test_security_profile_updates_preserve_unrelated_keys
test_tag_state_distinguishes_absent_from_empty
test_host_imds_rejects_multiple_documents
test_shared_cmdline_fields
test_root_signature_detection
test_toggle_accepts_caller_expectation
for option_key in systemd.verity_usr_options systemd.verity-usr-options \
    systemd.verity_usr-options systemd.verity-usr_options; do
    test_usr_verity_signature_contract "${option_key}"
    test_toggle_preserves_usr_signature_mode "${option_key}"
done
test_signed_and_unsigned_probe_expectations
test_signed_btrfs_probe_defers_no_denial_assertion
test_probe_denial_correlation
test_host_imds_matches_guest_parser
test_streamed_guest_contains_cmdline_parser
test_copied_guest_script_needs_no_sibling_file
test_audit_fallback_restores_containerd
test_cleanup_preserves_primary_failure
test_cleanup_reboots_after_any_mutation

echo "IPE mode toggle logic tests passed"
