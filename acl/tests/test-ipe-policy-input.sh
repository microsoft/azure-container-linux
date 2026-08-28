#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="${SCRIPT_DIR}/__build__/ipe-policy-test.$$"
mkdir -p "${TEST_DIR}"
export TMPDIR="${TEST_DIR}"
trap 'rm -rf "${TEST_DIR}"' EXIT

source "${SCRIPT_DIR}/build_library/rpm/rpm_install.sh"
source "${SCRIPT_DIR}/build_library/rpm/ipe_verity.sh"

info() { :; }
die() { echo "$*" >&2; exit 1; }
sudo() {
    if [[ "$1" == "chroot" ]]; then
        return 0
    fi
    command "$@"
}

export BUILD_LIBRARY_DIR="${SCRIPT_DIR}/build_library"
export BOOTLOADER_MODE=uki
policy="${BUILD_LIBRARY_DIR}/rpm/additional_files/ipe/acl-ipe-boot-policy.pol"

prepare_case() {
    local name="$1"
    export BUILD_DIR="${TEST_DIR}/${name}-build"
    CASE_ROOT="${TEST_DIR}/${name}-root"
    mkdir -p "${BUILD_DIR}" "${CASE_ROOT}"
}

test_ipe_disabled_by_default() {
    prepare_case default
    unset ACL_IPE_ASSET_MODE

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ "$(<"${BUILD_DIR}/ipe-asset-mode")" == "disabled" ]]
    # No staged artifacts
    [[ ! -d "${BUILD_DIR}/acl-ipe-policy" ]]
}

test_ipe_disabled_stages_nothing() {
    prepare_case disabled-explicit
    export ACL_IPE_ASSET_MODE=disabled

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ "$(<"${BUILD_DIR}/ipe-asset-mode")" == "disabled" ]]
    [[ ! -d "${BUILD_DIR}/acl-ipe-policy" ]]
}

test_ephemeral_stages_candidate() {
    prepare_case ephemeral
    export ACL_IPE_ASSET_MODE=ephemeral

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ -s "${BUILD_DIR}/acl-ipe-ephemeral/ca.key" ]]
    [[ -s "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" ]]
    [[ -s "${BUILD_DIR}/acl-ipe-policy/acl-ipe-boot-policy.pol" ]]
    # Verify the CMS wraps the canonical policy
    openssl smime -verify -inform der -binary \
        -in "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" \
        -noverify -out "${TEST_DIR}/verified.pol" >/dev/null 2>&1
    cmp -s "${policy}" "${TEST_DIR}/verified.pol"
    [[ "$(<"${BUILD_DIR}/ipe-asset-mode")" == "ephemeral" ]]
}

test_external_stages_candidate() {
    prepare_case external
    export ACL_IPE_ASSET_MODE=external

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ -s "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" ]]
    [[ -s "${BUILD_DIR}/acl-ipe-policy/acl-ipe-boot-policy.pol" ]]
    # Verify the CMS wraps the canonical policy
    openssl smime -verify -inform der -binary \
        -in "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" \
        -noverify -out "${TEST_DIR}/ext-verified.pol" >/dev/null 2>&1
    cmp -s "${policy}" "${TEST_DIR}/ext-verified.pol"
    [[ "$(<"${BUILD_DIR}/ipe-asset-mode")" == "external" ]]
}

test_verity_roothash_matches_kernel_input() {
    local output="${TEST_DIR}/root-hash.txt"
    local roothash="000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"

    ipe_verity_write_roothash "${roothash}" "${output}"
    [[ "$(<"${output}")" == "${roothash,,}" ]]
    [[ "$(wc -c < "${output}")" -eq 64 ]]

    if ipe_verity_write_roothash "${roothash}00" "${output}"; then
        echo "invalid root hash was serialized" >&2
        return 1
    fi
}

test_uki_binds_policy_before_writing_cmdline() {
    local uki_install="${SCRIPT_DIR}/build_library/rpm/uki_install.sh"
    local declaration_line append_line write_line

    declaration_line="$(grep -nF 'local ipe_policy_hash_token=""' "${uki_install}" | cut -d: -f1)"
    append_line="$(grep -nF 'cmdline+=" ${ipe_policy_hash_token}"' "${uki_install}" | cut -d: -f1)"
    write_line="$(grep -nF 'echo "${cmdline}" > "${uki_temp_dir}/cmdline.txt"' "${uki_install}" | cut -d: -f1)"

    [[ -n "${declaration_line}" && -n "${append_line}" && -n "${write_line}" ]]
    [[ "${declaration_line}" -lt "${append_line}" ]]
    [[ "${append_line}" -lt "${write_line}" ]]
    grep -Fq 'EFI/Linux/${uki_name}.extra.d/acl-ipe-policy.p7b.cred' "${uki_install}"
}

test_vm_conversions_share_secure_boot_cert() {
    local cert_dir="${TEST_DIR}/vm-shared-cert"
    local first_cert="${TEST_DIR}/vm-first-cert.pem"
    local image_to_vm="${SCRIPT_DIR}/image_to_vm.sh"
    local ensure_line sign_line cert_arg_line

    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" "${cert_dir}" >/dev/null 2>&1
    cp "${cert_dir}/uki-signing-ca.pem" "${first_cert}"
    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" "${cert_dir}" >/dev/null 2>&1
    cmp -s "${first_cert}" "${cert_dir}/uki-signing-ca.pem"

    ensure_line="$(grep -nF \
        '"${BUILD_LIBRARY_DIR}/rpm/ensure_ephemeral_cert.sh" "${ephemeral_cert_dir}"' \
        "${image_to_vm}" | cut -d: -f1)"
    sign_line="$(grep -nF \
        '"${BUILD_LIBRARY_DIR}/rpm/sign_uki_ephemeral.sh" \' \
        "${image_to_vm}" | cut -d: -f1)"
    cert_arg_line="$(grep -nFx \
        '        "${ephemeral_cert_dir}"' \
        "${image_to_vm}" | cut -d: -f1)"

    [[ -n "${ensure_line}" && -n "${sign_line}" && -n "${cert_arg_line}" ]]
    [[ "${ensure_line}" -lt "${sign_line}" ]]
    [[ "${sign_line}" -lt "${cert_arg_line}" ]]
}

test_ipe_disabled_by_default
test_ipe_disabled_stages_nothing
test_ephemeral_stages_candidate
test_external_stages_candidate
test_verity_roothash_matches_kernel_input
test_uki_binds_policy_before_writing_cmdline
test_vm_conversions_share_secure_boot_cert

echo "IPE policy input tests passed"
