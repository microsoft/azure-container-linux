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

create_test_signer() {
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "${TEST_DIR}/external.key" \
        -out "${TEST_DIR}/external.pem" \
        -subj "/CN=IPE policy test/" >/dev/null 2>&1
}

sign_policy() {
    local input="$1" output="$2"
    openssl smime -sign -binary -in "${input}" \
        -signer "${TEST_DIR}/external.pem" \
        -inkey "${TEST_DIR}/external.key" \
        -noattr -nodetach -nosmimecap -outform der -out "${output}"
}

test_ipe_disabled_by_default() {
    prepare_case default
    unset ACL_IPE_ASSET_MODE ACL_IPE_POLICY_PATH ACL_IPE_VERITY_SIGNATURE

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ "$(<"${BUILD_DIR}/ipe-asset-mode")" == "disabled" ]]
    [[ "$(<"${BUILD_DIR}/ipe-verity-signature")" == "true" ]]
    [[ ! -e "${CASE_ROOT}/usr/lib/ipe/acl.pol.p7b" ]]
}

test_external_policy_is_installed() {
    local external="${TEST_DIR}/external.p7b"
    sign_policy "${policy}" "${external}"
    prepare_case external
    export ACL_IPE_ASSET_MODE=external
    export ACL_IPE_POLICY_PATH="${external}"

    rpm_install_ipe_policy "${CASE_ROOT}"

    cmp -s "${external}" "${CASE_ROOT}/usr/lib/ipe/acl.pol.p7b"
    [[ ! -e "${BUILD_DIR}/acl-ipe-ephemeral/ca.key" ]]
    [[ "$(<"${BUILD_DIR}/ipe-asset-mode")" == "external" ]]
}

test_mismatched_external_policy_is_rejected() {
    local wrong_policy="${TEST_DIR}/wrong.pol"
    printf '\n' > "${wrong_policy}"
    sign_policy "${wrong_policy}" "${TEST_DIR}/wrong.p7b"
    prepare_case wrong
    export ACL_IPE_ASSET_MODE=external
    export ACL_IPE_POLICY_PATH="${TEST_DIR}/wrong.p7b"

    if (rpm_install_ipe_policy "${CASE_ROOT}") 2>/dev/null; then
        echo "mismatched external policy was accepted" >&2
        return 1
    fi
}

test_ephemeral_policy_is_generated() {
    prepare_case ephemeral
    export ACL_IPE_ASSET_MODE=ephemeral
    export ACL_IPE_POLICY_PATH=

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ -s "${BUILD_DIR}/acl-ipe-ephemeral/ca.key" ]]
    openssl smime -verify -inform der -binary \
        -in "${CASE_ROOT}/usr/lib/ipe/acl.pol.p7b" \
        -noverify -out "${TEST_DIR}/verified.pol" >/dev/null 2>&1
    cmp -s "${policy}" "${TEST_DIR}/verified.pol"
    [[ "$(<"${BUILD_DIR}/ipe-asset-mode")" == "ephemeral" ]]
}

test_ephemeral_policy_is_generated_without_verity_signature() {
    prepare_case ephemeral-unsigned
    export ACL_IPE_ASSET_MODE=ephemeral
    export ACL_IPE_POLICY_PATH=
    export ACL_IPE_VERITY_SIGNATURE=false

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ -s "${BUILD_DIR}/acl-ipe-ephemeral/ca.key" ]]
    [[ -s "${CASE_ROOT}/usr/lib/ipe/acl.pol.p7b" ]]
    [[ "$(<"${BUILD_DIR}/ipe-asset-mode")" == "ephemeral" ]]
    [[ "$(<"${BUILD_DIR}/ipe-verity-signature")" == "false" ]]
    unset ACL_IPE_VERITY_SIGNATURE
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

test_gallery_validation_defaults_to_disabled_asset_mode() {
    local test_option="$1"
    local gallery_id="/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/galleries/test/images/test/versions/1.0.0"
    local log="${TEST_DIR}/gallery-${test_option#--}.log"

    if (
        unset ACL_IPE_ASSET_MODE ACL_IPE_POLICY_PATH
        NO_TTY=true "${SCRIPT_DIR}/acl/build_rpm_image.sh" \
            --acg-image-version-id="${gallery_id}" \
            --vm-type=invalid \
            "${test_option}=true"
    ) > "${log}" 2>&1; then
        echo "gallery validation unexpectedly accepted an invalid VM type for ${test_option}" >&2
        return 1
    fi

    if ! grep -Fq \
        "ACL_IPE_ASSET_MODE is not set for gallery image validation; defaulting to disabled" \
        "${log}"; then
        cat "${log}" >&2
        echo "gallery asset-mode default did not run for ${test_option}" >&2
        return 1
    fi
    if ! grep -Fq "Invalid VM type: invalid" "${log}"; then
        cat "${log}" >&2
        echo "gallery validation did not continue with the disabled asset-mode default for ${test_option}" >&2
        return 1
    fi
}

test_external_gallery_validation_does_not_require_policy_input() {
    local gallery_id="/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/galleries/test/images/test/versions/1.0.0"
    local log="${TEST_DIR}/gallery-external.log"

    if (
        unset ACL_IPE_POLICY_PATH
        ACL_IPE_ASSET_MODE=external \
        NO_TTY=true "${SCRIPT_DIR}/acl/build_rpm_image.sh" \
            --acg-image-version-id="${gallery_id}" \
            --vm-type=invalid \
            --run-script=true
    ) > "${log}" 2>&1; then
        echo "gallery validation unexpectedly accepted an invalid VM type" >&2
        return 1
    fi

    ! grep -Fq "requires --ipe-policy-path" "${log}" ||
        {
            cat "${log}" >&2
            echo "gallery reuse incorrectly required the original external policy input" >&2
            return 1
        }
    grep -Fq "Invalid VM type: invalid" "${log}" ||
        {
            cat "${log}" >&2
            echo "gallery validation did not reach normal argument validation" >&2
            return 1
        }
}

test_external_image_build_requires_policy_input() {
    local log="${TEST_DIR}/build-external.log"

    if (
        unset ACL_IPE_POLICY_PATH
        ACL_IPE_ASSET_MODE=external \
        NO_TTY=true "${SCRIPT_DIR}/acl/build_rpm_image.sh" --build-image
    ) > "${log}" 2>&1; then
        echo "external image build was accepted without a signed policy" >&2
        return 1
    fi

    grep -Fq \
        "External IPE asset mode requires --ipe-policy-path when building an image" \
        "${log}" ||
        {
            cat "${log}" >&2
            echo "external image build did not report the missing policy input" >&2
            return 1
        }
}

test_ipe_disabled_by_default
create_test_signer
test_external_policy_is_installed
test_mismatched_external_policy_is_rejected
test_ephemeral_policy_is_generated
test_ephemeral_policy_is_generated_without_verity_signature
test_verity_roothash_matches_kernel_input
test_gallery_validation_defaults_to_disabled_asset_mode --run-script
test_gallery_validation_defaults_to_disabled_asset_mode --run-host-script
test_external_gallery_validation_does_not_require_policy_input
test_external_image_build_requires_policy_input

echo "IPE policy input tests passed"
