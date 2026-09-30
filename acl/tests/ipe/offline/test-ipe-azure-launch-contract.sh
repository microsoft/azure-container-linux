#!/bin/bash
# shellcheck disable=SC1091,SC2016,SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

# shellcheck source=../../../../build_library/rpm/ipe_artifact.sh
source "${SCRIPT_DIR}/build_library/rpm/ipe_artifact.sh"
source "${SCRIPT_DIR}/acl/tests/ipe/offline/function-extraction.sh"

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

    ipe_validate_signing_certificate "${directory}/uki-signing-ca.pem"
    printf 'not-a-certificate\n' > "${directory}/uki-signing-ca.pem"
    expect_failure ipe_validate_signing_certificate "${directory}/uki-signing-ca.pem"
    create_certificate "${directory}"
    mv "${directory}/uki-signing-ca.pem" "${directory}/real-cert.pem"
    if [[ -z "${MSYSTEM:-}" ]] &&
        ln -s real-cert.pem "${directory}/uki-signing-ca.pem" 2>/dev/null; then
        expect_failure ipe_validate_signing_certificate "${directory}/uki-signing-ca.pem"
    fi
    rm -f "${directory}/uki-signing-ca.pem"
    expect_failure ipe_validate_signing_certificate "${directory}/uki-signing-ca.pem"
    printf 'esrp\n' > "${directory}/ipe-signing-mode"
    [[ "$(ipe_validate_local_vhd_contract "${image}" true)" == esrp ]]
    expect_failure ipe_validate_local_vhd_contract "${image}" false
    : > "${image}"
    expect_failure ipe_validate_local_vhd_contract "${image}" true
}

test_argument_contracts() {
    local argument
    local forbidden=(
        "--image other"
        "--ima=other"
    )
    local allowed=(
        "--security-type Standard"
        "--secu=Standard"
        "--security-t=Standard"
        "--enable-vtpm false"
        "--enable-v=false"
        "--enable-secure-boot false"
        "--enable-s=false"
        "--enable-secure-b=false"
        "--size Standard_D2s_v5"
        "--si=Standard_D2s_v5"
        "--siz=Standard_D2s_v5"
    )

    for argument in "${forbidden[@]}"; do
        local -a parsed=()
        ipe_split_argument_string parsed "${argument}"
        expect_failure ipe_reject_azure_image_overrides "${parsed[@]}"
    done
    for argument in "${allowed[@]}"; do
        local -a parsed=()
        ipe_split_argument_string parsed "${argument}"
        ipe_reject_azure_image_overrides "${parsed[@]}"
    done
    ipe_reject_azure_image_overrides --user-data config.ign

    local -a multiline=()
    ipe_split_argument_string multiline $'--priority Regular\n--user-data config.ign'
    [[ "${multiline[*]}" == "--priority Regular --user-data config.ign" ]]

}

test_build_wrapper_contract() {
    local build_script="${SCRIPT_DIR}/acl/build_rpm_image.sh"
    source_test_functions "${build_script}" validate_ipe_boot_path
    error() { :; }

    ACL_IPE_CAPABLE=true
    BOOTLOADER_MODE=uki
    SECURE_BOOT_ENABLED=true
    AZ_VM_ARGS="--user-data config.ign"
    validate_ipe_boot_path azure
    SECURE_BOOT_ENABLED=false
    validate_ipe_boot_path azure
    SECURE_BOOT_ENABLED=true

    AZ_VM_ARGS="--enable-secure-boot false"
    validate_ipe_boot_path azure
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

# shellcheck disable=SC2329
check_build_test_selection() (
    local expected_secure_boot_tests="$1"
    shift
    source_test_functions "${SCRIPT_DIR}/acl/build_rpm_image.sh" \
        parse_args validate_ipe_boot_path
    validate_ipe_mode_value() { :; }
    load_reused_vm_type() { :; }
    configure_ipe_mode() { :; }
    operation_uses_local_image_artifact() { return 1; }
    operation_uses_gallery_image() { return 1; }
    operation_uses_vm_image() { return 0; }
    error() { echo "$*" >&2; }

    local BOARD=amd64-usr GROUP=production VM_TYPE=azure RETRY_ATTEMPTS=0
    local BUILD_VM_IMAGE=false START_VM=false REUSE_IMAGE=false ACG_IMAGE_VERSION_ID=""
    local ACL_IPE_CAPABLE=true BOOTLOADER_MODE=uki AZ_VM_ARGS="" SECURE_BOOT_ENABLED=true
    local -a RUN_SCRIPTS=() RUN_HOST_SCRIPTS=()
    unset RUN_TESTS
    parse_args "$@"

    local script secure_boot_tests=0
    for script in "${RUN_SCRIPTS[@]}"; do
        if [[ "${script}" == "./acl/tests/run-secureboot-test.sh" ]]; then
            secure_boot_tests=$((secure_boot_tests + 1))
        fi
    done
    [[ "${secure_boot_tests}" == "${expected_secure_boot_tests}" ]]
    if [[ "${RUN_TESTS:-false}" == true ]]; then
        [[ " ${RUN_HOST_SCRIPTS[*]} " == *" ./acl/tests/ipe/run-ipe-mode-toggle-test.sh "* ]]
    fi
)

test_marker_contract
test_local_vhd_contract
test_argument_contracts
test_build_wrapper_contract
test_artifact_preflight_ordering
check_build_test_selection 1 --run-tests
check_build_test_selection 1 --run-tests --no-secure-boot
check_build_test_selection 1 --no-secure-boot --run-tests
check_build_test_selection 2 --run-tests --no-secure-boot --run-script=./acl/tests/run-secureboot-test.sh
check_build_test_selection 1 --board=arm64-usr --run-tests --no-secure-boot
check_build_test_selection 0 --run-script=custom-test.sh

echo "IPE Azure launch contract tests passed"
