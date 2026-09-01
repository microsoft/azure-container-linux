#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
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
    unset ACL_IPE_MODE ACL_IPE_SIGNING_MODE

    rpm_install_ipe_policy "${CASE_ROOT}"

    # Absent marker means disabled; no marker file, no staged artifacts.
    [[ ! -f "${BUILD_DIR}/ipe-signing-mode" ]]
    [[ ! -d "${BUILD_DIR}/acl-ipe-policy" ]]
}

test_ipe_disabled_stages_nothing() {
    prepare_case disabled-explicit
    export ACL_IPE_MODE=disabled
    unset ACL_IPE_SIGNING_MODE

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ ! -f "${BUILD_DIR}/ipe-signing-mode" ]]
    [[ ! -d "${BUILD_DIR}/acl-ipe-policy" ]]
}

test_disabled_cleanup_removes_stale_assets() {
    prepare_case disabled-cleanup
    mkdir -p "${BUILD_DIR}/acl-ipe-ephemeral" "${BUILD_DIR}/acl-ipe-policy"
    printf 'stale-key\n' > "${BUILD_DIR}/acl-ipe-ephemeral/ca.key"
    printf 'stale-cred\n' > "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred"
    printf 'ephemeral\n' > "${BUILD_DIR}/ipe-signing-mode"

    export ACL_IPE_MODE=disabled
    unset ACL_IPE_SIGNING_MODE

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ ! -f "${BUILD_DIR}/ipe-signing-mode" ]]
    [[ ! -d "${BUILD_DIR}/acl-ipe-policy" ]]
    [[ ! -d "${BUILD_DIR}/acl-ipe-ephemeral" ]]
}

test_audit_ephemeral_stages_candidate() {
    prepare_case audit-ephemeral
    export ACL_IPE_MODE=audit
    export ACL_IPE_SIGNING_MODE=ephemeral

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ -s "${BUILD_DIR}/acl-ipe-ephemeral/ca.key" ]]
    [[ -s "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" ]]
    [[ -s "${BUILD_DIR}/acl-ipe-policy/acl-ipe-boot-policy.pol" ]]
    # Verify the CMS wraps the canonical policy
    openssl smime -verify -inform der -binary \
        -in "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" \
        -noverify -out "${TEST_DIR}/verified.pol" >/dev/null 2>&1
    cmp -s "${policy}" "${TEST_DIR}/verified.pol"
    [[ "$(<"${BUILD_DIR}/ipe-signing-mode")" == "ephemeral" ]]
}

test_audit_esrp_stages_candidate() {
    prepare_case audit-esrp
    export ACL_IPE_MODE=audit
    export ACL_IPE_SIGNING_MODE=esrp

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ -s "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" ]]
    [[ -s "${BUILD_DIR}/acl-ipe-policy/acl-ipe-boot-policy.pol" ]]
    # Verify the CMS wraps the canonical policy
    openssl smime -verify -inform der -binary \
        -in "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" \
        -noverify -out "${TEST_DIR}/ext-verified.pol" >/dev/null 2>&1
    cmp -s "${policy}" "${TEST_DIR}/ext-verified.pol"
    [[ "$(<"${BUILD_DIR}/ipe-signing-mode")" == "esrp" ]]
}

test_enforcing_mode_rejected() {
    prepare_case enforcing-rejected
    export ACL_IPE_MODE=enforcing

    if (rpm_install_ipe_policy "${CASE_ROOT}") 2>/dev/null; then
        echo "reserved 'enforcing' mode was accepted by the producer" >&2
        return 1
    fi
    unset ACL_IPE_MODE
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

test_markerless_secure_boot_cert_remains_disabled() {
    local build_script="${SCRIPT_DIR}/acl/build_rpm_image.sh"
    eval "$(sed -n '/^load_artifact_ipe_signing_mode() {/,/^}/p' "${build_script}")"
    configure_ipe_mode() { :; }
    error() { echo "$*" >&2; }

    prepare_case markerless-secure-boot-cert
    mkdir -p "${BUILD_DIR}/acl-ipe-ephemeral"
    printf 'test-cert\n' > "${BUILD_DIR}/acl-ipe-ephemeral/uki-signing-ca.pem"
    IPE_MODE_OVERRIDE_SET=false
    ACL_IPE_MODE=audit
    ACL_IPE_SIGNING_MODE=ephemeral

    load_artifact_ipe_signing_mode "${BUILD_DIR}"
    [[ "${ACL_IPE_MODE}" == "disabled" ]]

    mkdir -p "${BUILD_DIR}/acl-ipe-policy"
    if load_artifact_ipe_signing_mode "${BUILD_DIR}" 2>/dev/null; then
        echo "markerless IPE policy assets were accepted" >&2
        return 1
    fi
}

test_ipe_disabled_by_default
test_ipe_disabled_stages_nothing
test_disabled_cleanup_removes_stale_assets
test_audit_ephemeral_stages_candidate
test_audit_esrp_stages_candidate
test_enforcing_mode_rejected
test_verity_roothash_matches_kernel_input
test_uki_binds_policy_before_writing_cmdline
test_vm_conversions_share_secure_boot_cert
test_markerless_secure_boot_cert_remains_disabled

echo "IPE policy input tests passed"
