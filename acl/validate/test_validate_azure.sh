#!/usr/bin/env bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

(
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

export AZ_SUB_ID=test-subscription
export AZ_STORAGE_RG=test-storage-rg
export AZ_STORAGE_ACC=teststorage
export AZ_STORAGE_CONTAINER=test-container
export AZ_GALLERY_RG=test-gallery-rg
export AZ_ACG=test-gallery

# shellcheck source=acl/validate/validate_azure.sh
unset _VALIDATE_AZURE_LOADED
source "${SCRIPT_DIR}/validate_azure.sh"

VM_SSH_USER=tester
VM_SSH_KEY="${TMPDIR:-/tmp}/test-key"
SECURE_BOOT_ENABLED=false

AZ_ERROR_CODE=""
AZ_ERROR_MESSAGE=""
AZ_ERROR_TARGET=""
TEST_BOOT_DIAGNOSTICS_STORAGE=$(get_boot_diagnostics_storage_name test-rg)

az() {
    if [[ " $* " != *" --boot-diagnostics-storage ${TEST_BOOT_DIAGNOSTICS_STORAGE} "* ]]; then
        printf 'missing create-time boot diagnostics storage argument\n' >&2
        return 2
    fi
    if [[ -n "${AZ_ERROR_TARGET}" ]]; then
        printf '{"error":{"code":"%s","message":"%s","target":"%s"}}\n' \
            "${AZ_ERROR_CODE}" "${AZ_ERROR_MESSAGE}" "${AZ_ERROR_TARGET}" >&2
    else
        printf '{"error":{"code":"%s","message":"%s"}}\n' \
            "${AZ_ERROR_CODE}" "${AZ_ERROR_MESSAGE}" >&2
    fi
    return 1
}

assert_classification() {
    local error_code="$1"
    local error_message="$2"
    local expected_rc="$3"
    local expected_result="$4"
    local error_target="${5:-}"

    AZ_ERROR_CODE="${error_code}"
    AZ_ERROR_MESSAGE="${error_message}"
    AZ_ERROR_TARGET="${error_target}"

    local rc=0
    local result
    result=$(_try_vm_create \
        test-rg test-vm test-image test-sku test-region 2>/dev/null) || rc=$?

    if [[ ${rc} -ne ${expected_rc} || "${result}" != "${expected_result}" ]]; then
        printf 'FAIL: %s returned rc=%s result=%q; expected rc=%s result=%q\n' \
            "${error_code}" "${rc}" "${result}" "${expected_rc}" "${expected_result}" >&2
        return 1
    fi

    printf 'PASS: %s\n' "${error_code}"
}

assert_classification SkuNotAvailable \
    "The requested VM size is not available in this location." \
    1 RETRYABLE_VM_CREATE_ERROR
assert_classification OSProvisioningTimedOut \
    "OS provisioning for the VM did not finish in the allotted time." \
    1 PROVISIONING_TIMEOUT
assert_classification AllocationFailed \
    "Allocation failed because the requested VM size is unavailable." \
    1 RETRYABLE_VM_CREATE_ERROR
assert_classification ZonalAllocationFailed \
    "Allocation failed in the requested zone." \
    1 RETRYABLE_VM_CREATE_ERROR
assert_classification InvalidParameter \
    "The selected VM size is incompatible with the image." \
    1 RETRYABLE_VM_CREATE_ERROR \
    vmSize
assert_classification TrustedLaunchNotSupported \
    "The selected VM size does not support TrustedLaunch." \
    1 RETRYABLE_VM_CREATE_ERROR
assert_classification OperationNotAllowed \
    "The operation would exceed the approved regional quota." \
    1 RETRYABLE_VM_CREATE_ERROR
assert_classification OperationNotAllowed \
    "The subscription is not registered for this feature." \
    2 ""
assert_classification AuthorizationFailed \
    "The client is not authorized to create this VM." \
    2 ""

assert_vm_size_family_parsing() {
    local test_case vm_size expected actual
    local cases=(
        "Standard_D2s_v5:Ds_v5"
        "Standard_D2as_v5:Das_v5"
        "Standard_D2ads_v5:Dads_v5"
        "Standard_D2ps_v6:Dps_v6"
        "Standard_D2ps_v5:Dps_v5"
        "Standard_F2s_v2:Fs_v2"
        "custom-size:custom-size"
    )

    for test_case in "${cases[@]}"; do
        vm_size="${test_case%%:*}"
        expected="${test_case#*:}"
        actual=$(get_vm_size_family "$vm_size")
        if [[ "$actual" != "$expected" ]]; then
            printf 'FAIL: family for %s was %s, expected %s\n' \
                "$vm_size" "$actual" "$expected" >&2
            return 1
        fi
    done

    printf 'PASS: VM size families preserve modifiers and generations\n'
}

assert_timeout_configuration_validation() {
    error() { :; }

    local value
    for value in 1 2 10; do
        AZ_MAX_PROVISIONING_TIMEOUTS="$value"
        if ! validate_azure_configuration; then
            printf 'FAIL: valid timeout limit %s was rejected\n' "$value" >&2
            return 1
        fi
    done

    for value in 0 -1 abc ""; do
        AZ_MAX_PROVISIONING_TIMEOUTS="$value"
        if validate_azure_configuration; then
            printf 'FAIL: invalid timeout limit %q was accepted\n' "$value" >&2
            return 1
        fi
    done

    printf 'PASS: provisioning timeout configuration is validated\n'
}

assert_failed_vm_boot_diagnostics() {
    local events_file="${TEST_TMPDIR}/boot-diagnostics-events"
    : > "${events_file}"

    info() { :; }
    warn() { :; }

    az() {
        case "${1:-} ${2:-} ${3:-}" in
            "vm show -g")
                printf 'vm:show\n' >> "${events_file}"
                return 0
                ;;
            "vm boot-diagnostics get-boot-log")
                printf 'diagnostics:get-log\n' >> "${events_file}"
                if [[ " $* " != *" -o tsv "* ]]; then
                    printf 'FAIL: boot diagnostics must request raw TSV output\n' >&2
                    return 1
                fi
                local line
                for line in $(seq 1 25); do
                    printf 'warning line %s\n' "$line" >&2
                done
                for line in $(seq 1 205); do
                    printf 'serial line %s\n' "$line"
                done
                return 0
                ;;
            *)
                printf 'Unexpected az command: %q\n' "$*" >&2
                return 1
                ;;
        esac
    }

    local serial_output
    serial_output=$(capture_failed_vm_boot_diagnostics \
        test-rg test-vm test-sku test-region 2>&1)

    local expected_events actual_events
    expected_events=$'vm:show\ndiagnostics:get-log'
    actual_events=$(cat "${events_file}")
    if [[ "${actual_events}" != "${expected_events}" ]]; then
        printf 'FAIL: boot diagnostics commands ran out of order\nExpected:\n%s\nActual:\n%s\n' \
            "${expected_events}" "${actual_events}" >&2
        return 1
    fi
    if ! grep -qFx '  [serial] serial line 205' <<< "$serial_output" || \
        grep -qFx '  [serial] serial line 5' <<< "$serial_output" || \
        ! grep -qFx '  [serial] serial line 6' <<< "$serial_output"; then
        printf 'FAIL: boot diagnostics serial output was not logged\n' >&2
        return 1
    fi
    if ! grep -qFx '  [az] warning line 25' <<< "$serial_output" || \
        grep -qFx '  [az] warning line 5' <<< "$serial_output" || \
        ! grep -qFx '  [az] warning line 6' <<< "$serial_output"; then
        printf 'FAIL: boot diagnostics stderr was not logged separately\n' >&2
        return 1
    fi

    : > "${events_file}"
    az() {
        case "${1:-} ${2:-} ${3:-}" in
            "vm show -g")
                printf 'vm:show\n' >> "${events_file}"
                return 1
                ;;
            *)
                printf 'Unexpected az command after missing VM: %q\n' "$*" >&2
                return 1
                ;;
        esac
    }

    if ! capture_failed_vm_boot_diagnostics \
        test-rg test-vm test-sku test-region >/dev/null; then
        printf 'FAIL: missing VM resource made diagnostics fatal\n' >&2
        return 1
    fi
    actual_events=$(cat "${events_file}")
    if [[ "${actual_events}" != "vm:show" ]]; then
        printf 'FAIL: missing VM resource still attempted boot diagnostics\n' >&2
        return 1
    fi

    printf 'PASS: failed VM boot diagnostics are captured best-effort\n'
}

assert_provisioning_timeouts_are_bounded() {
    local events_file="${TEST_TMPDIR}/provisioning-timeout-events"
    local attempts_file="${TEST_TMPDIR}/provisioning-timeout-attempts"
    local errors_file="${TEST_TMPDIR}/provisioning-timeout-errors"
    : > "${events_file}"
    : > "${attempts_file}"
    : > "${errors_file}"

    info() { :; }
    warn() { :; }
    error() { printf '%s\n' "$*" >> "${errors_file}"; }
    capture_failed_vm_boot_diagnostics() {
        printf 'diagnostics:capture:%s\n' "$1" >> "${events_file}"
    }

    _try_vm_create() {
        printf '%s\n' "$4" >> "${attempts_file}"
        printf 'create:%s@%s\n' "$4" "$1" >> "${events_file}"
        echo "PROVISIONING_TIMEOUT"
        return 1
    }

    check_image_replicated_to_region() {
        printf 'FAIL: timeout cap allowed a backup-region attempt\n' >&2
        return 1
    }

    az() {
        case "${1:-} ${2:-} ${3:-} ${4:-}" in
            "group create "*)
                printf 'group:create:%s\n' "$4" >> "${events_file}"
                return 0
                ;;
            "network public-ip create "*)
                return 0
                ;;
            "storage account create "*)
                return 0
                ;;
            "group delete "*)
                printf 'group:delete:%s\n' "$4" >> "${events_file}"
                return 0
                ;;
            *)
                printf 'Unexpected az command: %q\n' "$*" >&2
                return 1
                ;;
        esac
    }

    get_vm_rg_name() {
        local group_count
        group_count=$(grep -c '^group:create:' "${events_file}" || true)
        printf 'test-rg-%s\n' "$((group_count + 1))"
    }

    BOARD=amd64-usr
    AZ_VM_SIZE=Standard_D2s_v5
    AZ_BACKUP_VM_SIZES_AMD64="Standard_D2as_v5 Standard_F2s_v2 Standard_B2s_v2"
    AZ_BACKUP_REGIONS=backup-region
    AZ_REGION=primary-region
    AZ_MAX_PROVISIONING_TIMEOUTS=2
    ACG_IMAGE_VERSION_ID=test-image-id
    RESOURCE_TAGS=(createdBy=test)
    VM_NAME=test-vm
    VM_RG=test-rg-1

    if create_vm_azure test-rg-1 test-image-id >/dev/null; then
        printf 'FAIL: provisioning timeouts unexpectedly succeeded\n' >&2
        return 1
    fi

    local expected_attempts actual_attempts
    expected_attempts=$'Standard_D2s_v5\nStandard_D2as_v5'
    actual_attempts=$(cat "${attempts_file}")
    if [[ "${actual_attempts}" != "${expected_attempts}" ]]; then
        printf 'FAIL: provisioning timeout attempts were not bounded across distinct families\nExpected:\n%s\nActual:\n%s\n' \
            "${expected_attempts}" "${actual_attempts}" >&2
        return 1
    fi
    if ! grep -q 'likely image boot failure' "${errors_file}"; then
        printf 'FAIL: provisioning timeout did not report a likely image boot failure\n' >&2
        return 1
    fi

    local create_count
    create_count=$(grep -c '^create:' "${events_file}")
    if [[ ${create_count} -ne 2 ]]; then
        printf 'FAIL: expected 2 VM attempts, got %s\n' "${create_count}" >&2
        return 1
    fi

    printf 'PASS: provisioning timeouts stop after two distinct SKU families\n'
}

assert_single_provisioning_timeout_limit() {
    local attempts_file="${TEST_TMPDIR}/single-timeout-attempts"
    local errors_file="${TEST_TMPDIR}/single-timeout-errors"
    : > "${attempts_file}"
    : > "${errors_file}"

    info() { :; }
    warn() { :; }
    error() { printf '%s\n' "$*" >> "${errors_file}"; }
    capture_failed_vm_boot_diagnostics() { :; }
    _try_vm_create() {
        printf '%s\n' "$4" >> "${attempts_file}"
        echo "PROVISIONING_TIMEOUT"
        return 1
    }
    az() {
        case "${1:-} ${2:-}" in
            "group create"|"network public-ip"|"storage account"|"group delete") return 0 ;;
            *) return 1 ;;
        esac
    }

    BOARD=amd64-usr
    AZ_VM_SIZE=Standard_D2s_v5
    AZ_BACKUP_VM_SIZES_AMD64=Standard_F2s_v2
    AZ_BACKUP_REGIONS=""
    AZ_REGION=primary-region
    AZ_MAX_PROVISIONING_TIMEOUTS=1
    ACG_IMAGE_VERSION_ID=test-image-id
    RESOURCE_TAGS=(createdBy=test)
    VM_NAME=test-vm

    if create_vm_azure test-rg test-image-id >/dev/null; then
        printf 'FAIL: timeout limit 1 unexpectedly succeeded\n' >&2
        return 1
    fi
    if [[ $(wc -l < "${attempts_file}") -ne 1 ]]; then
        printf 'FAIL: timeout limit 1 allowed more than one attempt\n' >&2
        return 1
    fi
    if ! grep -q 'likely image boot failure' "${errors_file}"; then
        printf 'FAIL: timeout limit 1 did not report likely image boot failure\n' >&2
        return 1
    fi

    printf 'PASS: timeout limit 1 stops after the first provisioning timeout\n'
}

assert_all_families_timeout_below_limit() {
    local errors_file="${TEST_TMPDIR}/all-families-timeout-errors"
    : > "${errors_file}"

    info() { :; }
    warn() { :; }
    error() { printf '%s\n' "$*" >> "${errors_file}"; }
    capture_failed_vm_boot_diagnostics() { :; }
    _try_vm_create() {
        echo "PROVISIONING_TIMEOUT"
        return 1
    }
    az() {
        case "${1:-} ${2:-}" in
            "group create"|"network public-ip"|"storage account"|"group delete") return 0 ;;
            *) return 1 ;;
        esac
    }

    BOARD=amd64-usr
    AZ_VM_SIZE=Standard_D2s_v5
    AZ_BACKUP_VM_SIZES_AMD64=""
    AZ_BACKUP_REGIONS=""
    AZ_REGION=primary-region
    AZ_MAX_PROVISIONING_TIMEOUTS=2
    ACG_IMAGE_VERSION_ID=test-image-id
    RESOURCE_TAGS=(createdBy=test)
    VM_NAME=test-vm

    if create_vm_azure test-rg test-image-id >/dev/null; then
        printf 'FAIL: all-family timeout unexpectedly succeeded\n' >&2
        return 1
    fi
    if ! grep -q 'All configured VM SKU families timed out' "${errors_file}" || \
        ! grep -q 'likely image boot failure' "${errors_file}"; then
        printf 'FAIL: all-family timeout below cap was not identified as image boot failure\n' >&2
        return 1
    fi

    printf 'PASS: all-family timeout is identified even below the configured cap\n'
}

assert_mixed_failures_keep_generic_terminal_error() {
    local attempts_file="${TEST_TMPDIR}/mixed-failure-attempts"
    local errors_file="${TEST_TMPDIR}/mixed-failure-errors"
    : > "${attempts_file}"
    : > "${errors_file}"

    info() { :; }
    warn() { :; }
    error() { printf '%s\n' "$*" >> "${errors_file}"; }
    capture_failed_vm_boot_diagnostics() { :; }
    _try_vm_create() {
        local attempt_count
        attempt_count=$(wc -l < "${attempts_file}")
        printf '%s\n' "$4" >> "${attempts_file}"
        if [[ $attempt_count -eq 0 ]]; then
            echo "PROVISIONING_TIMEOUT"
        else
            echo "RETRYABLE_VM_CREATE_ERROR"
        fi
        return 1
    }
    az() {
        case "${1:-} ${2:-}" in
            "group create"|"network public-ip"|"storage account"|"group delete"|"vm delete") return 0 ;;
            *) return 1 ;;
        esac
    }
    get_vm_rg_name() { printf 'mixed-rg-%s\n' "$(wc -l < "${attempts_file}")"; }

    BOARD=amd64-usr
    AZ_VM_SIZE=Standard_D2s_v5
    AZ_BACKUP_VM_SIZES_AMD64="Standard_F2s_v2 Standard_B2s_v2"
    AZ_BACKUP_REGIONS=""
    AZ_REGION=primary-region
    AZ_MAX_PROVISIONING_TIMEOUTS=2
    ACG_IMAGE_VERSION_ID=test-image-id
    RESOURCE_TAGS=(createdBy=test)
    VM_NAME=test-vm

    if create_vm_azure mixed-rg-0 test-image-id >/dev/null; then
        printf 'FAIL: mixed failures unexpectedly succeeded\n' >&2
        return 1
    fi
    if grep -q 'likely image boot failure' "${errors_file}"; then
        printf 'FAIL: mixed timeout/capacity failures were mislabeled as image boot failure\n' >&2
        return 1
    fi
    if ! grep -q 'No VM candidate succeeded' "${errors_file}" || \
        ! grep -q 'Provisioning timeouts:' "${errors_file}"; then
        printf 'FAIL: mixed failures did not preserve generic exhaustion with timeout context\n' >&2
        return 1
    fi

    printf 'PASS: mixed timeout and capacity failures keep generic exhaustion signal\n'
}

assert_fallback_uses_clean_resource_group() {
    local events_file="${TEST_TMPDIR}/fallback-events"
    local attempts_file="${TEST_TMPDIR}/fallback-attempts"
    : > "${events_file}"
    : > "${attempts_file}"

    info() { :; }
    warn() { :; }
    error() { printf 'ERROR: %s\n' "$*" >&2; }
    capture_failed_vm_boot_diagnostics() {
        printf 'diagnostics:capture:%s\n' "$1" >> "${events_file}"
    }

    _try_vm_create() {
        local vm_rg_name="$1"
        local vm_size="$4"
        local attempt_count
        attempt_count=$(wc -l < "${attempts_file}")
        printf '%s\n' "${vm_size}" >> "${attempts_file}"
        printf 'create:%s@%s\n' "${vm_size}" "${vm_rg_name}" >> "${events_file}"

        if [[ ${attempt_count} -eq 0 ]]; then
            echo "PROVISIONING_TIMEOUT"
            return 1
        fi

        if [[ "${vm_rg_name}" == "test-rg-1" ]]; then
            echo "The retry reused the failed resource group." >&2
            return 2
        fi

        echo '{"powerState":"VM running"}'
    }

    az() {
        case "${1:-} ${2:-} ${3:-} ${4:-}" in
            "group create "*)
                printf 'group:create:%s\n' "$4" >> "${events_file}"
                return 0
                ;;
            "network public-ip create "*)
                return 0
                ;;
            "storage account create "*)
                return 0
                ;;
            "group delete "*)
                if [[ " $* " != *" --no-wait "* ]]; then
                    printf 'FAIL: failed resource-group deletion must be asynchronous\n' >&2
                    return 1
                fi
                printf 'group:delete:%s\n' "$4" >> "${events_file}"
                return 0
                ;;
            "vm show "*)
                echo "/subscriptions/test/resourceGroups/test-rg/providers/Microsoft.Network/networkInterfaces/test-nic"
                return 0
                ;;
            "network nic show "*)
                if [[ "$*" == *"ipConfigurations[0].name"* ]]; then
                    echo "test-ip-config"
                else
                    echo "test-nic"
                fi
                return 0
                ;;
            "network nic ip-config update")
                return 0
                ;;
            *)
                printf 'Unexpected az command: %q\n' "$*" >&2
                return 1
                ;;
        esac
    }

    get_vm_rg_name() {
        echo "test-rg-2"
    }

    BOARD=amd64-usr
    AZ_VM_SIZE=primary-sku
    AZ_BACKUP_VM_SIZES_AMD64=fallback-sku
    AZ_BACKUP_REGIONS=""
    AZ_REGION=test-region
    ACG_IMAGE_VERSION_ID=test-image-id
    RESOURCE_TAGS=(createdBy=test)
    VM_NAME=test-vm
    VM_RG=test-rg-1

    if ! create_vm_azure test-rg-1 test-image-id >/dev/null; then
        printf 'FAIL: fallback did not reach the second candidate in a clean resource group\n' >&2
        return 1
    fi

    local expected_events actual_events
    expected_events=$'group:create:test-rg-1\ncreate:primary-sku@test-rg-1\ndiagnostics:capture:test-rg-1\ngroup:delete:test-rg-1\ngroup:create:test-rg-2\ncreate:fallback-sku@test-rg-2'
    actual_events=$(cat "${events_file}")
    if [[ "${actual_events}" != "${expected_events}" ]]; then
        printf 'FAIL: unexpected fallback order\nExpected:\n%s\nActual:\n%s\n' \
            "${expected_events}" "${actual_events}" >&2
        return 1
    fi
    if [[ "${AZ_VM_SIZE}" != "fallback-sku" ]]; then
        printf 'FAIL: successful fallback SKU was not retained\n' >&2
        return 1
    fi
    if [[ "${VM_RG}" != "test-rg-2" ]]; then
        printf 'FAIL: successful fallback resource group was not retained\n' >&2
        return 1
    fi

    printf 'PASS: fallback isolates the next candidate in a clean resource group\n'
}

assert_control_plane_failure_reuses_resource_group() {
    local events_file="${TEST_TMPDIR}/control-plane-retry-events"
    local attempts_file="${TEST_TMPDIR}/control-plane-retry-attempts"
    : > "${events_file}"
    : > "${attempts_file}"

    info() { :; }
    warn() { :; }
    error() { printf 'ERROR: %s\n' "$*" >&2; }
    capture_failed_vm_boot_diagnostics() {
        printf 'FAIL: control-plane rejection attempted boot diagnostics\n' >&2
        return 1
    }

    _try_vm_create() {
        local vm_rg_name="$1"
        local vm_size="$4"
        local attempt_count
        attempt_count=$(wc -l < "${attempts_file}")
        printf '%s\n' "${vm_size}" >> "${attempts_file}"
        printf 'create:%s@%s\n' "${vm_size}" "${vm_rg_name}" >> "${events_file}"

        if [[ ${attempt_count} -eq 0 ]]; then
            echo "RETRYABLE_VM_CREATE_ERROR"
            return 1
        fi

        [[ "${vm_rg_name}" == "test-rg" ]] || return 2
        echo '{"powerState":"VM running"}'
    }

    az() {
        case "${1:-} ${2:-} ${3:-} ${4:-}" in
            "group create "*)
                printf 'group:create:%s\n' "$4" >> "${events_file}"
                return 0
                ;;
            "network public-ip create "*)
                return 0
                ;;
            "storage account create "*)
                return 0
                ;;
            "vm delete -g "*)
                printf 'vm:delete:%s\n' "$4" >> "${events_file}"
                return 0
                ;;
            "vm show "*)
                echo "/subscriptions/test/resourceGroups/test-rg/providers/Microsoft.Network/networkInterfaces/test-nic"
                return 0
                ;;
            "network nic show "*)
                if [[ "$*" == *"ipConfigurations[0].name"* ]]; then
                    echo "test-ip-config"
                else
                    echo "test-nic"
                fi
                return 0
                ;;
            "network nic ip-config update")
                return 0
                ;;
            "group delete "*)
                printf 'FAIL: control-plane rejection recycled its resource group\n' >&2
                return 1
                ;;
            *)
                printf 'Unexpected az command: %q\n' "$*" >&2
                return 1
                ;;
        esac
    }

    BOARD=amd64-usr
    AZ_VM_SIZE=primary-sku
    AZ_BACKUP_VM_SIZES_AMD64=fallback-sku
    AZ_BACKUP_REGIONS=""
    AZ_REGION=test-region
    ACG_IMAGE_VERSION_ID=test-image-id
    RESOURCE_TAGS=(createdBy=test)
    VM_NAME=test-vm
    VM_RG=test-rg

    if ! create_vm_azure test-rg test-image-id >/dev/null; then
        printf 'FAIL: control-plane fallback did not reach the second candidate\n' >&2
        return 1
    fi

    local expected_events actual_events
    expected_events=$'group:create:test-rg\ncreate:primary-sku@test-rg\nvm:delete:test-rg\ncreate:fallback-sku@test-rg'
    actual_events=$(cat "${events_file}")
    if [[ "${actual_events}" != "${expected_events}" ]]; then
        printf 'FAIL: control-plane fallback did not reuse its resource group\nExpected:\n%s\nActual:\n%s\n' \
            "${expected_events}" "${actual_events}" >&2
        return 1
    fi
    if [[ "${VM_RG}" != "test-rg" ]]; then
        printf 'FAIL: control-plane fallback changed the owned resource group\n' >&2
        return 1
    fi

    printf 'PASS: control-plane fallback reuses its resource group\n'
}

assert_resource_group_failure_stops_fallback() {
    local attempts_file="${TEST_TMPDIR}/resource-group-failure-attempts"
    : > "${attempts_file}"

    info() { :; }
    warn() { :; }
    error() { :; }
    capture_failed_vm_boot_diagnostics() { :; }

    _try_vm_create() {
        printf '%s\n' "$4" >> "${attempts_file}"
        echo "PROVISIONING_TIMEOUT"
        return 1
    }

    az() {
        case "${1:-} ${2:-} ${3:-} ${4:-}" in
            "group create "*)
                [[ "$4" == "test-rg-1" ]]
                ;;
            "network public-ip create "*|"storage account create "*|"group delete "*)
                return 0
                ;;
            *)
                printf 'Unexpected az command: %q\n' "$*" >&2
                return 1
                ;;
        esac
    }

    get_vm_rg_name() {
        echo "test-rg-2"
    }

    BOARD=amd64-usr
    AZ_VM_SIZE=primary-sku
    AZ_BACKUP_VM_SIZES_AMD64=fallback-sku
    AZ_BACKUP_REGIONS=""
    AZ_REGION=test-region
    ACG_IMAGE_VERSION_ID=test-image-id
    RESOURCE_TAGS=(createdBy=test)
    VM_NAME=test-vm
    VM_RG=test-rg-1

    if create_vm_azure test-rg-1 test-image-id >/dev/null; then
        printf 'FAIL: fallback continued without a clean resource group\n' >&2
        return 1
    fi

    local attempt_count
    attempt_count=$(wc -l < "${attempts_file}")
    if [[ ${attempt_count} -ne 1 ]]; then
        printf 'FAIL: resource-group setup failure allowed %s VM creation attempts\n' "${attempt_count}" >&2
        return 1
    fi

    printf 'PASS: failed resource-group setup stops fallback before candidate reuse\n'
}

assert_public_ip_failure_cleans_resource_group() {
    local events_file="${TEST_TMPDIR}/public-ip-failure-events"
    : > "${events_file}"

    info() { :; }

    az() {
        case "${1:-} ${2:-} ${3:-} ${4:-}" in
            "group create "*)
                printf 'group:create:%s\n' "$4" >> "${events_file}"
                return 0
                ;;
            "network public-ip create "*)
                printf 'public-ip:create:failed\n' >> "${events_file}"
                return 1
                ;;
            "group delete "*)
                if [[ " $* " != *" --no-wait "* ]]; then
                    printf 'FAIL: partial resource-group deletion must be asynchronous\n' >&2
                    return 1
                fi
                printf 'group:delete:%s\n' "$4" >> "${events_file}"
                return 0
                ;;
            *)
                printf 'Unexpected az command: %q\n' "$*" >&2
                return 1
                ;;
        esac
    }

    if create_vm_resource_group \
        test-rg test-region test-public-ip createdBy=test; then
        printf 'FAIL: public-IP failure unexpectedly succeeded\n' >&2
        return 1
    fi

    local expected_events actual_events
    expected_events=$'group:create:test-rg\npublic-ip:create:failed\ngroup:delete:test-rg'
    actual_events=$(cat "${events_file}")
    if [[ "${actual_events}" != "${expected_events}" ]]; then
        printf 'FAIL: public-IP failure did not clean up its partial resource group\nExpected:\n%s\nActual:\n%s\n' \
            "${expected_events}" "${actual_events}" >&2
        return 1
    fi

    printf 'PASS: public-IP failure cleans up its partial resource group\n'
}

assert_boot_diagnostics_storage_is_provisioned() {
    local events_file="${TEST_TMPDIR}/boot-diagnostics-storage-events"
    : > "${events_file}"

    info() { :; }

    az() {
        case "${1:-} ${2:-} ${3:-} ${4:-}" in
            "group create "*|"network public-ip create "*)
                return 0
                ;;
            "storage account create "*)
                printf '%s\n' "$*" >> "${events_file}"
                return 0
                ;;
            "group delete "*)
                printf 'FAIL: successful diagnostics storage setup deleted its resource group\n' >&2
                return 1
                ;;
            *)
                printf 'Unexpected az command: %q\n' "$*" >&2
                return 1
                ;;
        esac
    }

    if ! create_vm_resource_group \
        test-rg test-region test-public-ip createdBy=test purpose=VM-testing; then
        printf 'FAIL: boot diagnostics storage setup failed\n' >&2
        return 1
    fi

    local storage_name storage_command
    storage_name=$(get_boot_diagnostics_storage_name test-rg)
    storage_command=$(cat "${events_file}")
    if ! [[ "$storage_name" =~ ^bootdiag[0-9a-f]{16}$ ]] || \
        [[ ${#storage_name} -ne 24 ]]; then
        printf 'FAIL: invalid boot diagnostics storage account name: %s\n' "$storage_name" >&2
        return 1
    fi
    if [[ " $storage_command " != *" --name $storage_name "* ||
        " $storage_command " != *" --resource-group test-rg "* ||
        " $storage_command " != *" --location test-region "* ||
        " $storage_command " != *" --sku Standard_LRS "* ||
        " $storage_command " != *" --min-tls-version TLS1_2 "* ||
        " $storage_command " != *" --allow-blob-public-access false "* ||
        " $storage_command " != *" --tags createdBy=test purpose=VM-testing "* ]]; then
        printf 'FAIL: boot diagnostics storage account is missing required configuration: %s\n' \
            "$storage_command" >&2
        return 1
    fi

    printf 'PASS: boot diagnostics storage is provisioned with each VM resource group\n'
}

assert_final_candidate_does_not_create_unused_resource_group() {
    local events_file="${TEST_TMPDIR}/final-candidate-events"
    : > "${events_file}"

    info() { :; }
    warn() { :; }
    error() { :; }
    capture_failed_vm_boot_diagnostics() { :; }

    _try_vm_create() {
        printf 'create:%s@%s\n' "$4" "$1" >> "${events_file}"
        echo "RETRYABLE_VM_CREATE_ERROR"
        return 1
    }

    az() {
        case "${1:-} ${2:-} ${3:-} ${4:-}" in
            "group create "*)
                printf 'group:create:%s\n' "$4" >> "${events_file}"
                return 0
                ;;
            "network public-ip create "*)
                return 0
                ;;
            "storage account create "*)
                return 0
                ;;
            "group delete "*)
                printf 'group:delete:%s\n' "$4" >> "${events_file}"
                return 0
                ;;
            *)
                printf 'Unexpected az command: %q\n' "$*" >&2
                return 1
                ;;
        esac
    }

    BOARD=amd64-usr
    AZ_VM_SIZE=only-sku
    AZ_BACKUP_VM_SIZES_AMD64=""
    AZ_BACKUP_REGIONS=""
    AZ_REGION=test-region
    ACG_IMAGE_VERSION_ID=test-image-id
    RESOURCE_TAGS=(createdBy=test)
    VM_NAME=test-vm
    VM_RG=test-rg-1

    if create_vm_azure test-rg-1 test-image-id >/dev/null; then
        printf 'FAIL: final retryable candidate unexpectedly succeeded\n' >&2
        return 1
    fi

    local expected_events actual_events
    expected_events=$'group:create:test-rg-1\ncreate:only-sku@test-rg-1'
    actual_events=$(cat "${events_file}")
    if [[ "${actual_events}" != "${expected_events}" ]]; then
        printf 'FAIL: final candidate created an unused replacement resource group\nExpected:\n%s\nActual:\n%s\n' \
            "${expected_events}" "${actual_events}" >&2
        return 1
    fi
    if [[ "${VM_RG}" != "test-rg-1" ]]; then
        printf 'FAIL: final control-plane failure lost the owned resource group\n' >&2
        return 1
    fi

    printf 'PASS: final candidate does not create an unused resource group\n'
}

assert_final_candidate_moves_directly_to_backup_region() {
    local events_file="${TEST_TMPDIR}/backup-region-events"
    local attempts_file="${TEST_TMPDIR}/backup-region-attempts"
    : > "${events_file}"
    : > "${attempts_file}"

    info() { :; }
    warn() { :; }
    error() { printf 'ERROR: %s\n' "$*" >&2; }
    capture_failed_vm_boot_diagnostics() { :; }

    check_image_replicated_to_region() {
        [[ "$2" == "backup-region" ]]
    }

    _try_vm_create() {
        local vm_rg_name="$1"
        local vm_size="$4"
        local region="$5"
        local attempt_count
        attempt_count=$(wc -l < "${attempts_file}")
        printf '%s\n' "${vm_size}" >> "${attempts_file}"
        printf 'create:%s@%s/%s\n' "${vm_size}" "${vm_rg_name}" "${region}" >> "${events_file}"

        if [[ ${attempt_count} -eq 0 ]]; then
            echo "RETRYABLE_VM_CREATE_ERROR"
            return 1
        fi

        echo '{"powerState":"VM running"}'
    }

    az() {
        case "${1:-} ${2:-} ${3:-} ${4:-}" in
            "group create "*)
                local region=""
                local previous=""
                for argument in "$@"; do
                    if [[ "${previous}" == "--location" ]]; then
                        region="${argument}"
                        break
                    fi
                    previous="${argument}"
                done
                printf 'group:create:%s/%s\n' "$4" "${region}" >> "${events_file}"
                return 0
                ;;
            "network public-ip create "*)
                return 0
                ;;
            "storage account create "*)
                return 0
                ;;
            "group delete "*)
                printf 'group:delete:%s\n' "$4" >> "${events_file}"
                return 0
                ;;
            "vm delete -g "*)
                printf 'vm:delete:%s\n' "$4" >> "${events_file}"
                return 0
                ;;
            "vm show "*)
                echo "/subscriptions/test/resourceGroups/test-rg-2/providers/Microsoft.Network/networkInterfaces/test-nic"
                return 0
                ;;
            "network nic show "*)
                if [[ "$*" == *"ipConfigurations[0].name"* ]]; then
                    echo "test-ip-config"
                else
                    echo "test-nic"
                fi
                return 0
                ;;
            "network nic ip-config update")
                return 0
                ;;
            *)
                printf 'Unexpected az command: %q\n' "$*" >&2
                return 1
                ;;
        esac
    }

    get_vm_rg_name() {
        echo "test-rg-2"
    }

    BOARD=amd64-usr
    AZ_VM_SIZE=only-sku
    AZ_BACKUP_VM_SIZES_AMD64=""
    AZ_BACKUP_REGIONS=backup-region
    AZ_REGION=primary-region
    ACG_IMAGE_VERSION_ID=test-image-id
    RESOURCE_TAGS=(createdBy=test)
    VM_NAME=test-vm
    VM_RG=test-rg-1

    if ! create_vm_azure test-rg-1 test-image-id >/dev/null; then
        printf 'FAIL: final candidate did not advance directly to the backup region\n' >&2
        return 1
    fi

    local expected_events actual_events
    expected_events=$'group:create:test-rg-1/primary-region\ncreate:only-sku@test-rg-1/primary-region\nvm:delete:test-rg-1\ngroup:delete:test-rg-1\ngroup:create:test-rg-2/backup-region\ncreate:only-sku@test-rg-2/backup-region'
    actual_events=$(cat "${events_file}")
    if [[ "${actual_events}" != "${expected_events}" ]]; then
        printf 'FAIL: backup-region fallback created an intermediate resource group\nExpected:\n%s\nActual:\n%s\n' \
            "${expected_events}" "${actual_events}" >&2
        return 1
    fi
    if [[ "${AZ_REGION}" != "backup-region" || "${VM_RG}" != "test-rg-2" ]]; then
        printf 'FAIL: backup-region fallback state was not retained\n' >&2
        return 1
    fi

    printf 'PASS: final candidate moves directly to a clean backup-region resource group\n'
}

( assert_failed_vm_boot_diagnostics )
( assert_vm_size_family_parsing )
( assert_timeout_configuration_validation )
( assert_provisioning_timeouts_are_bounded )
( assert_single_provisioning_timeout_limit )
( assert_all_families_timeout_below_limit )
( assert_mixed_failures_keep_generic_terminal_error )
( assert_fallback_uses_clean_resource_group )
( assert_control_plane_failure_reuses_resource_group )
( assert_resource_group_failure_stops_fallback )
( assert_public_ip_failure_cleans_resource_group )
( assert_boot_diagnostics_storage_is_provisioned )
( assert_final_candidate_does_not_create_unused_resource_group )
( assert_final_candidate_moves_directly_to_backup_region )
)
