#!/bin/bash
# Verify that the initramfs loader selects IPE enforcement at runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOADER="${SCRIPT_DIR}/build_library/rpm/additional_files/dracut-acl-ipe-load/acl-ipe-load.sh"
PROFILE_HELPER="${SCRIPT_DIR}/build_library/rpm/additional_files/acl-node-security-profile.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

prepare_case() {
    local name="$1" requested_mode="$2"
    CASE_DIR="${TMP_DIR}/${name}"
    IPE_DIR="${CASE_DIR}/ipe"

    mkdir -p "${IPE_DIR}"
    : > "${IPE_DIR}/new_policy"
    printf '9\n' > "${IPE_DIR}/enforce"
    printf 'flatcar.oem.id=azure\n' > "${CASE_DIR}/cmdline"

    cat > "${CASE_DIR}/security-profile.sh" <<EOF
acl_security_profile() {
    printf '%s\n' 'ipe=${requested_mode}'
}
acl_security_profile_value() {
    printf '%s\n' '${requested_mode}'
}
EOF
}

run_loader() {
    ACL_IPE_DIR="${IPE_DIR}" \
    ACL_IPE_CMDLINE_FILE="${CASE_DIR}/cmdline" \
    ACL_IPE_POLICY_FILE="${CASE_DIR}/policy.p7b" \
    ACL_IPE_SECURITY_PROFILE_HELPER="${CASE_DIR}/security-profile.sh" \
        bash "${LOADER}" >/dev/null 2>&1
}

test_existing_policy_mode() {
    local requested_mode="$1" expected_enforce="$2" expected_active="$3"
    prepare_case "${requested_mode:-absent}" "${requested_mode}"
    mkdir -p "${IPE_DIR}/policies/acl_ipe_boot_policy"
    printf '0\n' > "${IPE_DIR}/policies/acl_ipe_boot_policy/active"

    run_loader

    [[ "$(<"${IPE_DIR}/enforce")" == "${expected_enforce}" ]]
    [[ "$(<"${IPE_DIR}/policies/acl_ipe_boot_policy/active")" == "${expected_active}" ]]
}

test_signed_policy_is_loaded() {
    prepare_case load-policy permissive
    printf 'signed-policy\n' > "${CASE_DIR}/policy.p7b"

    run_loader

    [[ "$(<"${IPE_DIR}/new_policy")" == "signed-policy" ]]
    [[ "$(<"${IPE_DIR}/enforce")" == "0" ]]
}

test_missing_policy_is_ignored() {
    prepare_case missing-policy permissive

    run_loader

    [[ ! -s "${IPE_DIR}/new_policy" ]]
    [[ "$(<"${IPE_DIR}/enforce")" == "9" ]]
}

test_rejected_policy_write_is_ignored() {
    prepare_case rejected-policy permissive
    printf 'signed-policy\n' > "${CASE_DIR}/policy.p7b"
    rm "${IPE_DIR}/new_policy"
    mkdir "${IPE_DIR}/new_policy"

    run_loader

    [[ "$(<"${IPE_DIR}/enforce")" == "9" ]]
}

test_imds_failure_is_cached() {
    (
        source "${PROFILE_HELPER}"
        ACL_SECURITY_PROFILE_CACHE="${TMP_DIR}/node-security-profile"
        ACL_SECURITY_PROFILE_FAILURE_CACHE="${ACL_SECURITY_PROFILE_CACHE}.failed"
        attempts="${TMP_DIR}/imds-attempts"

        systemctl() { :; }
        sleep() { :; }
        acl_usrbin() {
            printf x >> "${attempts}"
            return 1
        }

        ! acl_security_profile >/dev/null 2>&1
        [[ "$(wc -c < "${attempts}")" -eq 30 ]]
        [[ -e "${ACL_SECURITY_PROFILE_FAILURE_CACHE}" ]]
        ! acl_security_profile >/dev/null 2>&1
        [[ "$(wc -c < "${attempts}")" -eq 30 ]]
    )
}

test_existing_policy_mode "" 9 0
test_existing_policy_mode off 9 0
test_existing_policy_mode invalid 9 0
test_existing_policy_mode enforcing 9 0
test_existing_policy_mode permissive 0 1
test_signed_policy_is_loaded
test_missing_policy_is_ignored
test_rejected_policy_write_is_ignored
test_imds_failure_is_cached

echo "IPE loader runtime mode tests passed"
