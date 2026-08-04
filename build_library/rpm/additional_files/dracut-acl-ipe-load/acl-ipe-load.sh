#!/bin/bash

set -euo pipefail

POLICY_NAME="acl_ipe_boot_policy"
IPE_DIR="/sys/kernel/security/ipe"
ESP_LABEL="EFI-SYSTEM"
ESP_MNT="/run/acl-ipe-esp"
POLICY_REL="acl-ipe/acl.pol.p7b"
esp_mounted=0

fail() {
    echo "acl-ipe-load: $*" >&2
    exit 1
}

cleanup() {
    if [[ "${esp_mounted}" -eq 1 ]]; then
        umount "${ESP_MNT}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ ! -e "${IPE_DIR}/new_policy" ]]; then
    mkdir -p /sys/kernel/security
    mount -t securityfs securityfs /sys/kernel/security ||
        fail "unable to mount securityfs"
fi
[[ -e "${IPE_DIR}/new_policy" ]] ||
    fail "IPE securityfs interface is unavailable"

if [[ ! -d "${IPE_DIR}/policies/${POLICY_NAME}" ]]; then
    esp_device=$(findfs "LABEL=${ESP_LABEL}" 2>/dev/null) ||
        fail "unable to find the EFI system partition"

    mkdir -p "${ESP_MNT}"
    mount -t vfat -o ro "${esp_device}" "${ESP_MNT}" ||
        fail "unable to mount the EFI system partition"
    esp_mounted=1

    policy_file="${ESP_MNT}/${POLICY_REL}"
    [[ -s "${policy_file}" ]] ||
        fail "signed IPE policy is missing"

    cat "${policy_file}" > "${IPE_DIR}/new_policy" ||
        fail "kernel rejected the signed IPE policy"
fi

active_node="${IPE_DIR}/policies/${POLICY_NAME}/active"
[[ -w "${active_node}" ]] ||
    fail "IPE policy activation node is unavailable"

echo 1 > "${active_node}" ||
    fail "unable to activate IPE policy"

[[ "$(cat "${active_node}")" == "1" ]] ||
    fail "IPE policy did not become active"
