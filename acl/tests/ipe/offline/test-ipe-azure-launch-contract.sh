#!/bin/bash
# shellcheck disable=SC1091,SC2016,SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

# shellcheck source=../../../../build_library/rpm/ipe_artifact.sh
source "${SCRIPT_DIR}/build_library/rpm/ipe_artifact.sh"

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        echo "Expected failure: $*" >&2
        return 1
    fi
}

create_certificate() {
    local directory="$1"
    local subject='/CN=IPE Azure launch test/'
    if [[ -n "${MSYSTEM:-}" && "${MSYS2_ARG_CONV_EXCL:-}" != "*" ]]; then
        subject='//CN=IPE Azure launch test'
    fi
    mkdir -p "${directory}"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -subj "${subject}" \
        -keyout "${directory}/ca.key" \
        -out "${directory}/uki-signing-ca.pem" \
        -days 1 >/dev/null 2>&1
}

prepare_vhd() {
    local directory="$1"
    mkdir -p "${directory}"
    printf 'vhd\n' > "${directory}/acl_production_azure_test_image.vhd"
}

test_marker_contract() {
    local directory="${TEST_DIR}/marker"
    mkdir -p "${directory}"

    printf 'ephemeral\n' > "${directory}/ipe-signing-mode"
    [[ "$(ipe_resolve_artifact_signing_mode "${directory}")" == "ephemeral" ]]
    printf 'esrp\n' > "${directory}/ipe-signing-mode"
    [[ "$(ipe_resolve_artifact_signing_mode "${directory}")" == "esrp" ]]

    printf 'esrp' > "${directory}/ipe-signing-mode"
    expect_failure ipe_resolve_artifact_signing_mode "${directory}"
    printf 'esrp\n\n' > "${directory}/ipe-signing-mode"
    expect_failure ipe_resolve_artifact_signing_mode "${directory}"
    printf 'esrp\r\n' > "${directory}/ipe-signing-mode"
    expect_failure ipe_resolve_artifact_signing_mode "${directory}"

    rm -f "${directory}/ipe-signing-mode"
    if [[ -z "${MSYSTEM:-}" ]] &&
        ln -s missing "${directory}/ipe-signing-mode" 2>/dev/null; then
        expect_failure ipe_resolve_artifact_signing_mode "${directory}"
        rm -f "${directory}/ipe-signing-mode"
    fi
    mkdir "${directory}/ipe-signing-mode"
    expect_failure ipe_resolve_artifact_signing_mode "${directory}"
    rmdir "${directory}/ipe-signing-mode"

    [[ "$(ipe_resolve_artifact_signing_mode "${directory}")" == "disabled" ]]
    expect_failure ipe_resolve_artifact_signing_mode "${directory}" true
    mkdir "${directory}/acl-ipe-policy"
    expect_failure ipe_resolve_artifact_signing_mode "${directory}"
}

test_local_vhd_contract() {
    local directory="${TEST_DIR}/vhd"
    local image="${directory}/acl_production_azure_test_image.vhd"
    prepare_vhd "${directory}"

    [[ "$(ipe_validate_local_vhd_contract "${image}")" == "disabled" ]]
    create_certificate "${directory}"
    [[ "$(ipe_validate_local_vhd_contract "${image}")" == "disabled" ]]

    printf 'ephemeral\n' > "${directory}/ipe-signing-mode"
    [[ "$(ipe_validate_local_vhd_contract "${image}")" == "ephemeral" ]]

    printf 'not-a-certificate\n' > "${directory}/uki-signing-ca.pem"
    expect_failure ipe_validate_local_vhd_contract "${image}"
    create_certificate "${directory}"
    mv "${directory}/uki-signing-ca.pem" "${directory}/real-cert.pem"
    if [[ -z "${MSYSTEM:-}" ]] &&
        ln -s real-cert.pem "${directory}/uki-signing-ca.pem" 2>/dev/null; then
        expect_failure ipe_validate_local_vhd_contract "${image}"
    fi
}

test_trust_derivation() {
    local directory="${TEST_DIR}/trust"
    local image="${directory}/acl_production_azure_test_image.vhd"
    local runtime_image="/work/artifacts/acl_production_azure_test_image.vhd"
    prepare_vhd "${directory}"
    create_certificate "${directory}"
    printf 'esrp\n' > "${directory}/ipe-signing-mode"

    unset ACL_IPE_CAPABLE ACL_IPE_SIGNING_MODE
    unset AZURE_DISK_URI AZURE_TRUSTED_LAUNCH AZURE_SECURE_BOOT_CERTIFICATES
    ipe_configure_azure_trust "${image}" "${runtime_image}"
    [[ "${ACL_IPE_CAPABLE}" == "true" ]]
    [[ "${ACL_IPE_SIGNING_MODE}" == "esrp" ]]
    [[ "${AZURE_TRUSTED_LAUNCH}" == "true" ]]
    [[ "${AZURE_SECURE_BOOT_CERTIFICATES}" == "/work/artifacts/uki-signing-ca.pem" ]]

    AZURE_TRUSTED_LAUNCH=false
    expect_failure ipe_configure_azure_trust "${image}" "${runtime_image}"
    AZURE_TRUSTED_LAUNCH=true
    AZURE_SECURE_BOOT_CERTIFICATES="/work/other.pem"
    expect_failure ipe_configure_azure_trust "${image}" "${runtime_image}"

    AZURE_DISK_URI="/subscriptions/example/image"
    AZURE_SECURE_BOOT_CERTIFICATES="/work/artifacts/uki-signing-ca.pem"
    expect_failure ipe_configure_azure_trust "${image}" "${runtime_image}"
    unset AZURE_SECURE_BOOT_CERTIFICATES
    ACL_IPE_CAPABLE=true
    AZURE_TRUSTED_LAUNCH=""
    ipe_configure_azure_trust "${image}" "${runtime_image}"
    [[ "${AZURE_TRUSTED_LAUNCH}" == "true" ]]
}

test_argument_contracts() {
    local argument
    local forbidden=(
        "--security-type Standard"
        "--secu=Standard"
        "--security-t=Standard"
        "--enable-vtpm false"
        "--enable-v=false"
        "--enable-secure-boot false"
        "--enable-s=false"
        "--enable-secure-b=false"
        "--image other"
        "--ima=other"
    )

    for argument in "${forbidden[@]}"; do
        local -a parsed=()
        ipe_split_argument_string parsed "${argument}"
        expect_failure ipe_reject_azure_ipe_overrides "${parsed[@]}"
    done
    ipe_reject_azure_ipe_overrides --user-data config.ign

    expect_failure ipe_reject_arm_size_overrides --size Standard_D2s_v5
    expect_failure ipe_reject_arm_size_overrides --si=Standard_D2s_v5
    expect_failure ipe_reject_arm_size_overrides --siz=Standard_D2s_v5

    local -a multiline=()
    ipe_split_argument_string multiline $'--priority Regular\n--user-data config.ign'
    [[ "${multiline[*]}" == "--priority Regular --user-data config.ign" ]]

    expect_failure ipe_reject_kola_managed_overrides false --azure-image-file=other.vhd
    expect_failure ipe_reject_kola_managed_overrides false --azure-disk-uri=id
    expect_failure ipe_reject_kola_managed_overrides false --azure-blob-url=url
    expect_failure ipe_reject_kola_managed_overrides false --azure-hyper-v-generation=V1
    expect_failure ipe_reject_kola_managed_overrides false --azure-trusted-launch=false
    expect_failure ipe_reject_kola_managed_overrides false --enable-secureboot=false
    expect_failure ipe_reject_kola_managed_overrides false --azure-secureboot-certificate=other.pem
    expect_failure ipe_reject_kola_managed_overrides false --azure-use-gallery
    ipe_reject_kola_managed_overrides true --azure-use-gallery
    expect_failure ipe_reject_kola_managed_overrides true --azure-use-gallery=false
}

test_build_wrapper_contract() {
    local build_script="${SCRIPT_DIR}/acl/build_rpm_image.sh"
    eval "$(sed -n '/^validate_ipe_boot_path() {/,/^}/p' "${build_script}")"
    error() { :; }

    ACL_IPE_CAPABLE=true
    BOOTLOADER_MODE=uki
    SECURE_BOOT_ENABLED=true
    AZ_VM_ARGS="--user-data config.ign"
    validate_ipe_boot_path azure

    AZ_VM_ARGS="--enable-secure-boot false"
    expect_failure validate_ipe_boot_path azure
    AZ_VM_ARGS="--ima=other"
    expect_failure validate_ipe_boot_path azure

    ACL_IPE_CAPABLE=false
    validate_ipe_boot_path azure
}

test_artifact_preflight_ordering() {
    local validate_common="${SCRIPT_DIR}/acl/validate/validate_common.sh"
    local image_to_vm="${SCRIPT_DIR}/image_to_vm.sh"
    local preflight_line cleanup_line

    preflight_line="$(grep -nF '_prepare_local_ipe_artifact_contract "${vm_image_path}"' "${validate_common}" | cut -d: -f1)"
    cleanup_line="$(grep -nF '    remove_old_vm' "${validate_common}" | cut -d: -f1)"
    [[ -n "${preflight_line}" && -n "${cleanup_line}" ]]
    [[ "${preflight_line}" -lt "${cleanup_line}" ]]
    grep -Fq 'printf '\''%s\n'\'' "${ipe_signing_mode}" > "$(_dst_dir)/ipe-signing-mode"' \
        "${image_to_vm}"
}

test_marker_contract
test_local_vhd_contract
test_trust_derivation
test_argument_contracts
test_build_wrapper_contract
test_artifact_preflight_ordering

grep -Fq 'configure_local_ipe_azure_trust "${host_image}" "${azure_image}" || return 1' \
    "${SCRIPT_DIR}/run_azure_tests.sh"
grep -Fq 'ipe_configure_azure_trust "${AZURE_IMAGE_NAME:-}" "${AZURE_IMAGE_NAME:-}"' \
    "${SCRIPT_DIR}/ci-automation/vendor-testing/azure.sh"
grep -Fq 'ipe_reject_kola_managed_overrides false "$@"' \
    "${SCRIPT_DIR}/ci-automation/vendor-testing/azure.sh"
grep -Fq 'images/${CIA_ARCH}/${CIA_VERNUM}/ipe-signing-mode' \
    "${SCRIPT_DIR}/ci-automation/vendor-testing/azure.sh"

echo "IPE Azure launch contract tests passed"
