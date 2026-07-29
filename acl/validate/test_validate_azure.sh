#!/usr/bin/env bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

az() {
    printf '{"error":{"code":"%s","message":"%s"}}\n' \
        "${AZ_ERROR_CODE}" "${AZ_ERROR_MESSAGE}" >&2
    return 1
}

assert_classification() {
    local error_code="$1"
    local error_message="$2"
    local expected_rc="$3"
    local expected_result="$4"

    AZ_ERROR_CODE="${error_code}"
    AZ_ERROR_MESSAGE="${error_message}"

    local rc=0
    local result
    result=$(_try_vm_create test-rg test-vm test-image test-sku test-region 2>/dev/null) || rc=$?

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
    1 RETRYABLE_VM_CREATE_ERROR
assert_classification AllocationFailed \
    "Allocation failed because the requested VM size is unavailable." \
    1 RETRYABLE_VM_CREATE_ERROR
assert_classification ZonalAllocationFailed \
    "Allocation failed in the requested zone." \
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
