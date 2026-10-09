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
    local argument option
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
        "--imds-mode Enforced"
        "--imds-profile-id=profile"
        "--include-zones"
        "-o json"
        "-z 1"
    )

    for option in -i --i --im --ima --imag --image; do
        for argument in "${option} other" "${option}=other"; do
            local -a parsed=()
            ipe_split_argument_string parsed "${argument}"
            expect_failure ipe_reject_azure_image_overrides "${parsed[@]}"
        done
    done
    expect_failure ipe_reject_azure_image_overrides -iother
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
    local option
    for option in --i --im --ima --imag --image; do
        for AZ_VM_ARGS in "${option} other" "${option}=other"; do
            ACL_IPE_CAPABLE=true
            expect_failure validate_ipe_boot_path azure
            ACL_IPE_CAPABLE=false
            validate_ipe_boot_path azure
        done
    done
    ACL_IPE_CAPABLE=true
    AZ_VM_ARGS="--imds-mode Enforced --imds-profile-id=profile"
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
test_launch_contract_before_side_effects() (
    source_test_functions "${SCRIPT_DIR}/acl/validate/validate_common.sh" start_vm
    source_test_functions "${SCRIPT_DIR}/acl/validate/validate_azure.sh" \
        _prepare_local_ipe_artifact_contract _enforce_arm_security_contract \
        _enforce_ipe_image_contract start_vm_azure
    local directory="${TEST_DIR}/launch-order"
    local effects="${directory}/effects" rc entrypoint option
    local -a overrides=(-iother)
    for option in -i --i --im --ima --imag --image; do
        overrides+=("${option} other" "${option}=other")
    done
    prepare_vhd "${directory}"
    printf 'ephemeral\n' > "${directory}/ipe-signing-mode"
    local image="${directory}/acl_production_azure_test_image.vhd"
    local VM_TYPE=azure BOARD=amd64-usr VM_NAME=test
    local ACG_IMAGE_VERSION_ID="" REUSE_IMAGE=false SECURE_BOOT_ENABLED=false
    local ACL_IPE_CAPABLE="" AZ_VM_ARGS="" _LOCAL_IPE_ARTIFACT_PATH=""

    error() { echo "$*" >&2; }
    die() { error "$*"; exit 1; }
    remove_old_vm() { echo cleanup >> "${effects}"; }
    section() { echo section >> "${effects}"; exit 97; }
    az() { echo az >> "${effects}"; exit 98; }

    for entrypoint in start_vm start_vm_azure; do
        for AZ_VM_ARGS in "${overrides[@]}"; do
            ACL_IPE_CAPABLE=""
            rc=0
            ("${entrypoint}" "${image}" "${BOARD}") >/dev/null 2>&1 || rc=$?
            [[ "${rc}" -eq 1 && ! -e "${effects}" ]]
        done

        BOARD=arm64-usr
        AZ_VM_ARGS="--user-data=config.ign --siz=Standard_D2ps_v5"
        rc=0
        ("${entrypoint}" "${image}" "${BOARD}") >"${directory}/arm-result" 2>&1 || rc=$?
        [[ "${rc}" -eq 1 && ! -e "${effects}" ]]
        grep -Fq -- '--az-vm-args cannot override size or Trusted Launch security settings for Azure ARM VMs' \
            "${directory}/arm-result"
        BOARD=amd64-usr

        ACL_IPE_CAPABLE=true
        AZ_VM_ARGS=""
        REUSE_IMAGE=true
        rc=0
        ("${entrypoint}" "${image}" "${BOARD}") >/dev/null 2>&1 || rc=$?
        [[ "${rc}" -eq 1 && ! -e "${effects}" ]]
        REUSE_IMAGE=false

        ACG_IMAGE_VERSION_ID=explicit-version
        AZ_VM_ARGS="--image other"
        rc=0
        ("${entrypoint}" "${image}" "${BOARD}") >/dev/null 2>&1 || rc=$?
        [[ "${rc}" -eq 1 && ! -e "${effects}" ]]
        ACG_IMAGE_VERSION_ID=""
    done
)

# shellcheck disable=SC2329
test_gallery_collision_before_cleanup() (
    source_test_functions "${SCRIPT_DIR}/acl/validate/validate_common.sh" start_vm remove_old_vm
    source_test_functions "${SCRIPT_DIR}/acl/validate/validate_azure.sh" \
        _prepare_local_ipe_artifact_contract _enforce_arm_security_contract \
        _enforce_ipe_image_contract get_next_image_version \
        gallery_image_version_exists remove_vm_azure
    local directory="${TEST_DIR}/gallery-collision"
    local image="${directory}/acl_production_azure_test_image.vhd"
    local effects="${directory}/effects" result="${directory}/result"
    local mode rc
    prepare_vhd "${directory}"

    local VM_TYPE=azure BOARD=amd64-usr VM_NAME=test
    local ACG_IMAGE_VERSION_ID="" REUSE_IMAGE=false SECURE_BOOT_ENABLED=false
    local ACL_IPE_CAPABLE="" AZ_VM_ARGS="" BUILD_ID=52
    local AZ_SUB_ID=test-subscription AZ_GALLERY_RG=test-gallery-rg
    local AZ_ACG=test-gallery AZ_VM_IMAGE_DEF=test-image
    local NO_CLEANUP=false _LOCAL_IPE_SIGNING_MODE=disabled
    local _LOCAL_IPE_ARTIFACT_PATH="" VERSION_STATE=Succeeded
    local -a RESOURCE_TAGS=(owner=test)

    error() { echo "$*" >&2; }
    die() { error "$*"; exit 1; }
    info() { :; }
    section() { echo section >> "${effects}"; }
    remove_vm_state() { echo state-removal >> "${effects}"; }
    start_vm_azure() { echo vm-start >> "${effects}"; }
    az() {
        case "$1 $2 $3" in
            "sig image-version show")
                echo lookup >> "${effects}"
                [[ " $* " == *" --subscription test-subscription "* &&
                    " $* " == *" --gallery-image-version 1.0.52 "* ]] || return 2
                [[ "${VERSION_STATE}" == "Succeeded" ]] || return 3
                echo Succeeded
                ;;
            "group list --query") echo group-list >> "${effects}"; echo old-vm-rg ;;
            "group delete -n") echo group-delete >> "${effects}" ;;
            "account set --subscription") echo account-switch >> "${effects}" ;;
            "storage blob upload") echo upload >> "${effects}" ;;
            "vm create") echo vm-create >> "${effects}" ;;
            *) echo "Unexpected Azure call: $*" >&2; return 2 ;;
        esac
    }
    run_launch() {
        local expected_rc="$1"
        rc=0
        (start_vm "${image}" "${BOARD}") > "${result}" 2>&1 || rc=$?
        if [[ "${rc}" -ne "${expected_rc}" ]]; then
            echo "Unexpected launch exit ${rc} (expected ${expected_rc})" >&2
            printf 'Launch output:\n%s\n' "$(<"${result}")" >&2
            return 1
        fi
    }

    for mode in ephemeral esrp; do
        printf '%s\n' "${mode}" > "${directory}/ipe-signing-mode"
        : > "${effects}"
        run_launch 1
        grep -Fq 'Refusing to reuse gallery image version 1.0.52 for an IPE-capable local VHD' "${result}"
        [[ "$(<"${effects}")" == lookup ]]
    done

    VERSION_STATE=Missing
    : > "${effects}"
    run_launch 0
    [[ "$(<"${effects}")" == $'lookup\nstate-removal\ngroup-list\ngroup-delete\nsection\nvm-start' ]]

    VERSION_STATE=Succeeded
    BUILD_ID=""
    : > "${effects}"
    run_launch 0
    [[ "$(<"${effects}")" == $'state-removal\ngroup-list\ngroup-delete\nsection\nvm-start' ]]

    BUILD_ID=52
    rm "${directory}/ipe-signing-mode"
    ACL_IPE_CAPABLE=""
    : > "${effects}"
    run_launch 0
    [[ "$(<"${effects}")" == $'state-removal\ngroup-list\ngroup-delete\nsection\nvm-start' ]]

    ACG_IMAGE_VERSION_ID=explicit-version
    : > "${effects}"
    run_launch 0
    [[ "$(<"${effects}")" == $'state-removal\ngroup-list\ngroup-delete\nsection\nvm-start' ]]

    ACG_IMAGE_VERSION_ID=""
    REUSE_IMAGE=true
    : > "${effects}"
    run_launch 0
    [[ "$(<"${effects}")" == $'state-removal\ngroup-list\ngroup-delete\nsection\nvm-start' ]]
)

# shellcheck disable=SC2329
test_ipe_upload_uses_preflighted_artifact() (
    source_test_functions "${SCRIPT_DIR}/acl/validate/validate_common.sh" start_vm
    source_test_functions "${SCRIPT_DIR}/acl/validate/validate_azure.sh" \
        _prepare_local_ipe_artifact_contract _enforce_arm_security_contract \
        _enforce_ipe_image_contract start_vm_azure get_next_image_version
    local directory="${TEST_DIR}/pinned-artifact"
    local first="${directory}/build-a" second="${directory}/build-b"
    local latest="${directory}/latest"
    local image="${latest}/image.vhd"
    local uploaded="${directory}/uploaded" phase
    mkdir -p "${first}" "${second}"
    printf 'VHD A\n' > "${first}/image.vhd"
    printf 'VHD B\n' > "${second}/image.vhd"
    printf 'ephemeral\n' > "${first}/ipe-signing-mode"
    printf 'ephemeral\n' > "${second}/ipe-signing-mode"
    create_certificate "${first}"
    create_certificate "${second}"
    link_latest() {
        local target="$1"
        local win_latest win_target
        [[ ! -e "${latest}" && ! -L "${latest}" ]] || rm "${latest}"
        if MSYS=winsymlinks:nativestrict ln -s "$(basename "${target}")" "${latest}" 2>/dev/null &&
            [[ -L "${latest}" ]]; then
            return 0
        fi
        rm -f "${latest}"
        if [[ -n "${MSYSTEM:-}" ]] && command -v powershell.exe >/dev/null; then
            win_latest="$(cygpath -w "${latest}")"
            win_target="$(cygpath -w "${target}")"
            powershell.exe -NoProfile -NonInteractive -Command \
                "New-Item -ItemType Junction -Path '${win_latest}' -Target '${win_target}' | Out-Null" \
                >/dev/null 2>&1 && [[ -L "${latest}" ]]
        else
            return 1
        fi
    }
    if ! link_latest "${first}"; then
        echo "SKIP: VHD symlink retarget checks (native symlinks unavailable)" >&2
        return 0
    fi
    local first_physical
    first_physical="$(cd -P "${first}" && pwd -P)"

    local VM_TYPE=azure BOARD=amd64-usr VM_NAME=test IMG_NAME=test
    local ACG_IMAGE_VERSION_ID="" REUSE_IMAGE=false SECURE_BOOT_ENABLED=true
    local ACL_IPE_CAPABLE="" AZ_VM_ARGS="" BUILD_ID=52
    local AZ_SUB_ID=test-subscription AZ_STORAGE_RG=test-rg AZ_REGION=test-region
    local AZ_ACG=test-gallery AZ_VM_IMAGE_DEF=test-image AZ_VM_SIZE=test-size
    local VM_RG="" VM_IP="" _LOCAL_IPE_ARTIFACT_PATH=""
    local _LOCAL_IPE_SIGNING_MODE=disabled _LOCAL_IPE_SIGNING_CERT=""

    error() { echo "$*" >&2; }
    die() { error "$*"; exit 1; }
    info() { :; }
    section() { :; }
    get_vm_rg_name() { echo test-rg; }
    gallery_image_version_exists() { return 1; }
    remove_old_vm() {
        [[ "${phase}" == cleanup ]] && link_latest "${second}"
        return 0
    }
    check_azure_infra() {
        [[ "${phase}" == infra ]] && link_latest "${second}"
        return 0
    }
    upload_vhd_to_storage() {
        printf '%s\n' "$1" "$(<"$1")" "${_LOCAL_IPE_SIGNING_CERT}" > "${uploaded}"
    }
    create_gallery_image_version() { :; }
    create_vm_azure() { :; }
    az() {
        case "$1 $2 $3" in
            "account set --subscription") ;;
            "vm show -d")
                if [[ "$*" == *"provisioningState"* ]]; then
                    echo Succeeded
                else
                    echo 192.0.2.1
                fi
                ;;
            *) echo "Unexpected Azure call: $*" >&2; return 1 ;;
        esac
    }

    phase=cleanup
    start_vm "${image}" "${BOARD}"
    [[ "$(<"${uploaded}")" == "${first_physical}/image.vhd"$'\nVHD A\n'"${first_physical}/uki-signing-ca.pem" ]]
    [[ "$(<"${image}")" == "VHD B" ]]

    link_latest "${first}"
    _LOCAL_IPE_ARTIFACT_PATH=""
    _LOCAL_IPE_SIGNING_MODE=disabled
    ACL_IPE_CAPABLE=""
    phase=infra
    start_vm_azure "${image}"
    [[ "$(<"${uploaded}")" == "${first_physical}/image.vhd"$'\nVHD A\n'"${first_physical}/uki-signing-ca.pem" ]]
    [[ "$(<"${image}")" == "VHD B" ]]

    if MSYS=winsymlinks:nativestrict ln -s image.vhd "${first}/linked.vhd" 2>/dev/null &&
        [[ -L "${first}/linked.vhd" ]]; then
        if (start_vm "${first}/linked.vhd" "${BOARD}") > "${directory}/error" 2>&1; then
            echo "IPE launch accepted a symlinked VHD file" >&2
            return 1
        fi
        grep -Fq 'Azure VHD must be a readable, nonempty regular file' "${directory}/error"
    else
        echo "SKIP: leaf VHD symlink check (native symlinks unavailable)" >&2
    fi

    rm "${first}/ipe-signing-mode" "${second}/ipe-signing-mode"
    link_latest "${first}"
    ACL_IPE_CAPABLE=""
    phase=cleanup
    start_vm "${image}" "${BOARD}"
    [[ "$(<"${uploaded}")" == "${image}"$'\nVHD B' ]]
)

# shellcheck disable=SC2329
test_non_ipe_reuse_and_explicit_ipe_version() (
    source_test_functions "${SCRIPT_DIR}/acl/validate/validate_azure.sh" \
        _enforce_ipe_image_contract start_vm_azure get_latest_image_version
    local calls="${TEST_DIR}/gallery-selection"
    local ACL_IPE_CAPABLE=false REUSE_IMAGE=true ACG_IMAGE_VERSION_ID="" AZ_VM_ARGS=""
    local BOARD=amd64-usr VM_NAME=test AZ_SUB_ID=test AZ_STORAGE_RG=test AZ_REGION=test
    local AZ_ACG=test AZ_VM_IMAGE_DEF=test AZ_VM_SIZE=test AZ_GALLERY_RG=test
    local VM_RG="" VM_IP=""

    info() { :; }
    section() { :; }
    error() { echo "$*" >&2; }
    die() { error "$*"; exit 1; }
    get_vm_rg_name() { echo test-rg; }
    check_azure_infra() { :; }
    create_vm_azure() { printf '%s\n' "$2" >> "${calls}"; }
    az() {
        case "$1 $2 $3" in
            "account set --subscription") ;;
            "sig image-version list") printf '1.0.1\n1.0.2\n' ;;
            "vm show -d")
                if [[ "$*" == *"--query provisioningState"* ]]; then
                    echo Succeeded
                else
                    echo 192.0.2.1
                fi
                ;;
            *) echo "Unexpected Azure call: $*" >&2; return 1 ;;
        esac
    }

    start_vm_azure missing-local-image
    [[ "$(<"${calls}")" == 1.0.2 ]]
    ACL_IPE_CAPABLE=true
    REUSE_IMAGE=false
    ACG_IMAGE_VERSION_ID=explicit-version
    start_vm_azure missing-local-image
    [[ "$(<"${calls}")" == $'1.0.2\nexplicit-version' ]]
)

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
test_launch_contract_before_side_effects
test_gallery_collision_before_cleanup
test_ipe_upload_uses_preflighted_artifact
test_non_ipe_reuse_and_explicit_ipe_version
check_build_test_selection 1 --run-tests
check_build_test_selection 1 --run-tests --no-secure-boot
check_build_test_selection 1 --no-secure-boot --run-tests
check_build_test_selection 2 --run-tests --no-secure-boot --run-script=./acl/tests/run-secureboot-test.sh
check_build_test_selection 1 --board=arm64-usr --run-tests --no-secure-boot
check_build_test_selection 0 --run-script=custom-test.sh

echo "IPE Azure launch contract tests passed"
