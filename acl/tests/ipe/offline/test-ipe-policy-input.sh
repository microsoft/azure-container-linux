#!/bin/bash
# shellcheck disable=SC2034 # Variables below are consumed by extracted functions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TEST_DIR="$(mktemp -d)"
export TMPDIR="${TEST_DIR}"
trap 'rm -rf "${TEST_DIR}"' EXIT

source "${SCRIPT_DIR}/build_library/rpm/rpm_install.sh"
source "${SCRIPT_DIR}/build_library/rpm/ipe_artifact.sh"
source "${SCRIPT_DIR}/acl/tests/ipe/offline/function-extraction.sh"

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
    [[ ! -e "${BUILD_DIR}/acl-ipe-policy/acl-ipe-boot-policy.pol" ]]
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

test_uki_provision_preserves_unsigned_verity() (
    source_test_functions "${SCRIPT_DIR}/build_library/rpm/uki_install.sh" uki_provision_rpm
    sudo() { "$@"; }
    _uki_build_firstboot_addon() { :; }
    _uki_build_fips_addon() { :; }
    _uki_build_kdump_addon() { :; }
    _uki_build_debug_addon() { :; }
    ukify() {
        local argument output="" cmdline=""
        for argument; do
            case "${argument}" in
                --cmdline=@*) cmdline="${argument#--cmdline=@}" ;;
                --output=*) output="${argument#--output=}" ;;
            esac
        done
        cp "${cmdline}" "${BUILD_DIR}/captured.cmdline"
        printf 'test EFI\n' > "${output}"
    }

    local scenario capable esp extra cmdline policy_hash
    local roothash="000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"
    FLAGS_TRUE=0
    for scenario in x64:false x64:true aa64:false aa64:true; do
        EFI_ARCH="${scenario%:*}"
        capable="${scenario#*:}"
        prepare_case "uki-${EFI_ARCH}-${capable}"
        IPE_CAPABLE="${capable}"
        BOARD_ROOT="${CASE_ROOT}/board"
        FLAGS_disk_image="${BUILD_DIR}/image.bin"
        FLAGS_verity_hash="${BUILD_DIR}/usrhash"
        esp="${CASE_ROOT}/esp"
        extra="${esp}/EFI/Linux/vmlinuz-6.6.145.2.efi.extra.d"
        mkdir -p "${esp}/flatcar" "${extra}" \
            "${BOARD_ROOT}/usr/lib/systemd/boot/efi" \
            "${BOARD_ROOT}/boot/efi/EFI/BOOT" \
            "${BUILD_DIR}/acl-ipe-policy"
        touch "${esp}/vmlinuz-6.6.145.2" "${esp}/flatcar/initramfs-a.img" \
            "${BOARD_ROOT}/usr/lib/systemd/boot/efi/linux${EFI_ARCH}.efi.stub" \
            "${BOARD_ROOT}/boot/efi/EFI/BOOT/boot${EFI_ARCH}.efi" \
            "${BOARD_ROOT}/boot/efi/EFI/BOOT/grub${EFI_ARCH}.efi"
        printf 'policy credential\n' > "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred"
        printf 'stale\n' > "${extra}/verity-usr-${roothash,,}.p7s.cred"
        printf 'stale\n' > "${extra}/acl-ipe-policy.p7b.cred"

        FLAGS_verity=0
        printf 'invalid\n' > "${FLAGS_verity_hash}"
        if (uki_provision_rpm "${esp}") >/dev/null 2>&1; then
            echo "UKI accepted an invalid /usr root hash" >&2
            return 1
        fi
        printf '%s\n' "${roothash}" > "${FLAGS_verity_hash}"
        if [[ "${capable}" == "true" ]]; then
            FLAGS_verity=1
            if (uki_provision_rpm "${esp}") >/dev/null 2>&1; then
                echo "IPE-capable UKI accepted disabled /usr verity" >&2
                return 1
            fi
            FLAGS_verity=0
        fi
        uki_provision_rpm "${esp}"
        cmdline="$(<"${BUILD_DIR}/captured.cmdline")"
        [[ " ${cmdline} " == *" usrhash=${roothash,,} "* ]]
        [[ "${cmdline}" == *"mount.usr=/dev/mapper/usr mount.usrflags=ro"* ]]
        [[ "${cmdline}" == *"systemd.verity_usr_options=hash-offset="*",panic-on-corruption"* ]]
        [[ "${cmdline}" != *"root-hash-signature="* ]]
        [[ ! -e "${extra}/verity-usr-${roothash,,}.p7s.cred" ]]
        if [[ "${capable}" == "true" ]]; then
            policy_hash="$(sha256sum "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" | cut -d' ' -f1)"
            [[ " ${cmdline} " == *" acl.ipe.policy_sha256=${policy_hash} "* ]]
            cmp "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" \
                "${extra}/acl-ipe-policy.p7b.cred"
        else
            [[ "${cmdline}" != *"acl.ipe.policy_sha256="* ]]
            [[ ! -e "${extra}/acl-ipe-policy.p7b.cred" ]]
        fi
    done
)

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
    local other_cert_dir="${TEST_DIR}/vm-other-cert"
    local first_cert="${TEST_DIR}/vm-first-cert.pem"
    local artifact_dir="${TEST_DIR}/vm-artifact"
    local esp_dir="${TEST_DIR}/vm-esp"
    local extra_dir="${esp_dir}/EFI/Linux/acl.efi.extra.d"

    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" "${cert_dir}" create >/dev/null 2>&1
    cp "${cert_dir}/uki-signing-ca.pem" "${first_cert}"
    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" "${cert_dir}" require >/dev/null 2>&1
    cmp -s "${first_cert}" "${cert_dir}/uki-signing-ca.pem"

    mkdir -p "${artifact_dir}/acl-ipe-policy" "${extra_dir}"
    openssl smime -sign -binary \
        -in "${policy}" \
        -signer "${cert_dir}/uki-signing-ca.pem" \
        -inkey "${cert_dir}/ca.key" \
        -noattr -nodetach -nosmimecap \
        -outform der \
        -out "${artifact_dir}/acl-ipe-policy/acl-ipe-policy.p7b.cred" 2>/dev/null
    cp "${artifact_dir}/acl-ipe-policy/acl-ipe-policy.p7b.cred" \
        "${extra_dir}/acl-ipe-policy.p7b.cred"

    bash "${SCRIPT_DIR}/build_library/rpm/verify_ipe_signer_continuity.sh" \
        "${cert_dir}" "${artifact_dir}" "${esp_dir}"

    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${other_cert_dir}" create >/dev/null 2>&1
    if bash "${SCRIPT_DIR}/build_library/rpm/verify_ipe_signer_continuity.sh" \
        "${other_cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "matching but unrelated signer pair was accepted" >&2
        return 1
    fi
    printf 'invalid policy credential\n' > "${extra_dir}/acl-ipe-policy.p7b.cred"
    if bash "${SCRIPT_DIR}/build_library/rpm/verify_ipe_signer_continuity.sh" \
        "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "invalid installed policy credential was accepted" >&2
        return 1
    fi
}

test_markerless_ipe_assets_are_rejected() {
    local image_to_vm="${SCRIPT_DIR}/image_to_vm.sh"
    local artifact_dir="${TEST_DIR}/markerless-artifact"
    local esp_dir="${TEST_DIR}/markerless-esp"

    source_test_functions "${image_to_vm}" \
        has_ipe_assets validate_ipe_marker_consistency

    mkdir -p "${artifact_dir}/acl-ipe-policy" "${esp_dir}/EFI/Linux/acl.efi.extra.d"
    : > "${artifact_dir}/acl-ipe-policy/acl-ipe-policy.p7b.cred"
    : > "${esp_dir}/EFI/Linux/acl.efi.extra.d/verity-usr-000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f.p7s.cred"

    if validate_ipe_marker_consistency "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "markerless IPE assets bypassed conversion validation" >&2
        return 1
    fi

    printf 'ephemeral\n' > "${artifact_dir}/ipe-signing-mode"
    if validate_ipe_marker_consistency "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "legacy root-hash signature bypassed policy-only conversion validation" >&2
        return 1
    fi
    rm "${esp_dir}/EFI/Linux/acl.efi.extra.d/verity-usr-000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f.p7s.cred"
    validate_ipe_marker_consistency "${artifact_dir}" "${esp_dir}"
}

test_incomplete_or_mismatched_cert_pair_rejected() {
    local cert_dir="${TEST_DIR}/incomplete-cert"
    local empty_cert_dir="${TEST_DIR}/empty-cert"
    local other_cert_dir="${TEST_DIR}/mismatched-cert"
    local original_cert="${TEST_DIR}/incomplete-original.pem"

    mkdir -p "${empty_cert_dir}"
    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${empty_cert_dir}" create >/dev/null 2>&1
    [[ -s "${empty_cert_dir}/ca.key" ]]
    [[ -s "${empty_cert_dir}/uki-signing-ca.pem" ]]

    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${cert_dir}" create >/dev/null 2>&1
    cp "${cert_dir}/uki-signing-ca.pem" "${original_cert}"
    rm "${cert_dir}/ca.key"
    if "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${cert_dir}" require 2>/dev/null; then
        echo "incomplete certificate pair was accepted" >&2
        return 1
    fi
    if "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${cert_dir}" create 2>/dev/null; then
        echo "incomplete certificate pair was silently rotated" >&2
        return 1
    fi
    cmp -s "${original_cert}" "${cert_dir}/uki-signing-ca.pem"

    rm -rf "${cert_dir}"
    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${cert_dir}" create >/dev/null 2>&1
    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${other_cert_dir}" create >/dev/null 2>&1
    cp "${other_cert_dir}/ca.key" "${cert_dir}/ca.key"
    if "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${cert_dir}" require 2>/dev/null; then
        echo "mismatched certificate pair was accepted" >&2
        return 1
    fi
}

test_markerless_secure_boot_cert_remains_disabled() {
    local build_script="${SCRIPT_DIR}/acl/build_rpm_image.sh"
    source_test_functions "${build_script}" load_artifact_ipe_signing_mode
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

test_pure_vm_reuse_skips_local_artifact() {
    local build_script="${SCRIPT_DIR}/acl/build_rpm_image.sh"
    source_test_functions "${build_script}" \
        operation_uses_vm_image operation_uses_gallery_image \
        operation_uses_local_image_artifact

    BUILD_IMAGE=false
    BUILD_VM_IMAGE=false
    BUILD_TEST_IMAGE=false
    START_VM=true
    RUN_KOLA_TESTS=false
    REUSE_VM=true
    REUSE_IMAGE=false
    ACG_IMAGE_VERSION_ID=""

    if operation_uses_local_image_artifact; then
        echo "pure VM reuse was classified as local-artifact consumption" >&2
        return 1
    fi

    BUILD_VM_IMAGE=true
    operation_uses_local_image_artifact
}

test_reused_vm_type_loaded_from_state() {
    local build_script="${SCRIPT_DIR}/acl/build_rpm_image.sh"
    local state_file="${TEST_DIR}/vm-state.env"
    source_test_functions "${build_script}" load_reused_vm_type
    error() { echo "$*" >&2; }

    REUSE_VM=true
    VM_TYPE=qemu
    printf 'VM_TYPE=azure\n' > "${state_file}"
    load_reused_vm_type "${state_file}"
    [[ "${VM_TYPE}" == "azure" ]]

    printf 'VM_TYPE=invalid\n' > "${state_file}"
    if load_reused_vm_type "${state_file}" 2>/dev/null; then
        echo "invalid reused VM type was accepted" >&2
        return 1
    fi
}

test_ipe_disabled_by_default
test_ipe_disabled_stages_nothing
test_disabled_cleanup_removes_stale_assets
test_audit_ephemeral_stages_candidate
test_audit_esrp_stages_candidate
test_enforcing_mode_rejected
test_uki_provision_preserves_unsigned_verity
test_uki_binds_policy_before_writing_cmdline
test_vm_conversions_share_secure_boot_cert
test_markerless_ipe_assets_are_rejected
test_incomplete_or_mismatched_cert_pair_rejected
test_markerless_secure_boot_cert_remains_disabled
test_pure_vm_reuse_skips_local_artifact
test_reused_vm_type_loaded_from_state

echo "IPE policy input tests passed"
