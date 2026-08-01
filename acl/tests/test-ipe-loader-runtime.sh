#!/bin/bash
# Verify that the initramfs loader selects IPE enforcement at runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOADER="${SCRIPT_DIR}/build_library/rpm/additional_files/dracut-acl-ipe-load/acl-ipe-load.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

run_case() {
    local requested_mode="$1" expected_enforce="$2" expected_active="$3"
    local case_dir="${TMP_DIR}/${requested_mode:-absent}"
    local ipe_dir="${case_dir}/ipe"

    mkdir -p "${ipe_dir}/policies/acl_ipe_boot_policy"
    : > "${ipe_dir}/new_policy"
    printf '9\n' > "${ipe_dir}/enforce"
    printf '0\n' > "${ipe_dir}/policies/acl_ipe_boot_policy/active"
    printf 'flatcar.oem.id=azure\n' > "${case_dir}/cmdline"

    cat > "${case_dir}/security-profile.sh" <<EOF
acl_security_profile() {
    printf '%s\n' 'ipe=${requested_mode}'
}
acl_security_profile_value() {
    printf '%s\n' '${requested_mode}'
}
EOF

    ACL_IPE_DIR="${ipe_dir}" \
    ACL_IPE_CMDLINE_FILE="${case_dir}/cmdline" \
    ACL_IPE_POLICY_FILE="${case_dir}/policy.p7b" \
    ACL_IPE_SECURITY_PROFILE_HELPER="${case_dir}/security-profile.sh" \
        bash "${LOADER}" >/dev/null 2>&1

    [[ "$(<"${ipe_dir}/enforce")" == "${expected_enforce}" ]]
    [[ "$(<"${ipe_dir}/policies/acl_ipe_boot_policy/active")" == "${expected_active}" ]]
}

run_case "" 9 0
run_case off 9 0
run_case invalid 9 0
run_case permissive 0 1
run_case enforcing 1 1

echo "IPE loader runtime mode tests passed"
