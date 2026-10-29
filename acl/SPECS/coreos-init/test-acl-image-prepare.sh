#!/bin/bash
set -euo pipefail

SCRIPT="${1:-$(dirname "${BASH_SOURCE[0]}")/acl-image-prepare}"
# shellcheck source=acl/SPECS/coreos-init/acl-image-prepare
source "${SCRIPT}"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
BOOT="${ROOT}/boot"
TEMPLATE="${BOOT}/acl/uki-addons/firstboot.addon.efi"
ADDON="${BOOT}/EFI/Linux/vmlinuz-test.efi.extra.d/firstboot.addon.efi"
COUNT=0

fixture() {
    rm -rf "${ROOT:?}/boot"
    mkdir -p "${ROOT}/etc" "${BOOT}/acl/uki-addons" "${BOOT}/loader" \
        "${BOOT}/EFI/Linux" "${ROOT}/var/lib/containerd"
    printf 'ID=azurelinux\nVARIANT_ID=azurecontainerlinux\n' > "${ROOT}/etc/os-release"
    printf 'default vmlinuz-test.efi\n' > "${BOOT}/loader/loader.conf"
    printf 'uki-fixture\n' > "${BOOT}/EFI/Linux/vmlinuz-test.efi"
    printf 'signed-addon-fixture\n' > "${TEMPLATE}"
    printf 'preserve-machine-id\n' > "${ROOT}/etc/machine-id"
    printf 'preserve-container-data\n' > "${ROOT}/var/lib/containerd/test-data"
    mountpoint() { return 0; }
    sync() { printf '%s\n' "$*" > "${ROOT}/sync"; }
}

expect_failure() {
    if acl_image_prepare "${ROOT}" > "${ROOT}/output" 2>&1; then
        echo "FAIL: unexpectedly prepared an invalid image" >&2
        exit 1
    fi
    [[ ! -e "${BOOT}/flatcar/first_boot" ]]
}

check() {
    fixture
    "$@"
    COUNT=$((COUNT + 1))
    echo "PASS: $*"
}

prepares_without_erasing_data() {
    acl_image_prepare "${ROOT}"
    cmp "${TEMPLATE}" "${ADDON}"
    [[ -f "${BOOT}/flatcar/first_boot" ]]
    [[ "$(cat "${ROOT}/etc/machine-id")" == preserve-machine-id ]]
    [[ "$(cat "${ROOT}/var/lib/containerd/test-data")" == preserve-container-data ]]
    [[ ! -e "${ROOT}/selective-os-reset" ]]
    [[ "$(cat "${ROOT}/sync")" == "-f ${BOOT}" ]]
    acl_image_prepare "${ROOT}"
    cmp "${TEMPLATE}" "${ADDON}"
}

uses_selected_kernel_not_running_kernel() {
    printf 'other-uki\n' > "${BOOT}/EFI/Linux/vmlinuz-other.efi"
    printf 'default vmlinuz-other.efi\n' > "${BOOT}/loader/loader.conf"
    acl_image_prepare "${ROOT}"
    cmp "${TEMPLATE}" "${BOOT}/EFI/Linux/vmlinuz-other.efi.extra.d/firstboot.addon.efi"
    [[ ! -e "${ADDON}" ]]
}

supports_legacy_uki_name_and_os_identity() {
    printf 'ID=azurecontainerlinux\n' > "${ROOT}/etc/os-release"
    mv "${BOOT}/EFI/Linux/vmlinuz-test.efi" "${BOOT}/EFI/Linux/acl.efi"
    printf 'default acl.efi\n' > "${BOOT}/loader/loader.conf"
    acl_image_prepare "${ROOT}"
    cmp "${TEMPLATE}" "${BOOT}/EFI/Linux/acl.efi.extra.d/firstboot.addon.efi"
}

repairs_stale_addon() {
    mkdir -p "${ADDON%/*}"
    printf 'stale\n' > "${ADDON}"
    acl_image_prepare "${ROOT}"
    cmp "${TEMPLATE}" "${ADDON}"
}

rejects_other_os() {
    printf 'ID=azurelinux\n' > "${ROOT}/etc/os-release"
    expect_failure
}

rejects_unmounted_boot() {
    mountpoint() { return 1; }
    expect_failure
}

rejects_missing_or_empty_template() {
    : > "${TEMPLATE}"
    expect_failure
    rm "${TEMPLATE}"
    expect_failure
}

rejects_ambiguous_defaults() {
    local value
    for value in 'vmlinuz-*.efi' '@saved' '../acl.efi' ''; do
        printf 'default %s\n' "${value}" > "${BOOT}/loader/loader.conf"
        expect_failure
    done
    printf 'default vmlinuz-test.efi\ndefault acl.efi\n' > "${BOOT}/loader/loader.conf"
    expect_failure
}

rejects_missing_boot_files() {
    rm "${BOOT}/EFI/Linux/vmlinuz-test.efi"
    expect_failure
    rm "${BOOT}/loader/loader.conf"
    expect_failure
}

propagates_copy_failure() (
    install() { return 17; }
    expect_failure
    [[ ! -e "${ADDON}" ]]
    [[ -z "$(find "${BOOT}/EFI/Linux" -name '.firstboot.addon.*' -print)" ]]
)

propagates_rename_failure() (
    mv() { return 18; }
    expect_failure
    [[ ! -e "${ADDON}" ]]
)

propagates_flush_failure() (
    sync() { return 19; }
    if acl_image_prepare "${ROOT}" > "${ROOT}/output" 2>&1; then
        echo "FAIL: flush failure was ignored" >&2
        exit 1
    fi
)

check prepares_without_erasing_data
check uses_selected_kernel_not_running_kernel
check supports_legacy_uki_name_and_os_identity
check repairs_stale_addon
check rejects_other_os
check rejects_unmounted_boot
check rejects_missing_or_empty_template
check rejects_ambiguous_defaults
check rejects_missing_boot_files
check propagates_copy_failure
check propagates_rename_failure
check propagates_flush_failure
bash "${SCRIPT}" --help >/dev/null
if bash "${SCRIPT}" --unknown > "${ROOT}/output" 2>&1; then
    echo "FAIL: invalid command-line arguments were accepted" >&2
    exit 1
fi
echo "PASS: ${COUNT} ACL image preparation cases and CLI checks"
