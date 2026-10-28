#!/bin/bash
set -euo pipefail

validate_firstboot_state() {
    local phase="$1" root="$2" expected="$3" first_boot_id="${4:-}"
    local ID VARIANT_ID boot_id cmdline path
    # shellcheck source=/dev/null
    source "${root}/etc/os-release" || return 1
    if [[ "${ID:-}" != azurecontainerlinux ]] &&
        ! [[ "${ID:-}" == azurelinux && "${VARIANT_ID:-}" == azurecontainerlinux ]]; then
        echo "FAIL: this test requires ACL" >&2
        return 1
    fi
    boot_id="$(cat "${root}/proc/sys/kernel/random/boot_id")" || return 1
    cmdline="$(cat "${root}/proc/cmdline")" || return 1
    if [[ -z "${boot_id}" || -z "${expected}" ]]; then
        echo "FAIL: boot ID and expected sentinel must be nonempty" >&2
        return 1
    fi
    case "${phase}" in
        first)
            if [[ " ${cmdline} " != *" flatcar.first_boot=detected "* ]]; then
                echo "FAIL: first boot did not receive the Ignition kernel argument" >&2
                return 1
            fi
            ;;
        reboot)
            if [[ -z "${first_boot_id}" || "${boot_id}" == "${first_boot_id}" ]]; then
                echo "FAIL: reboot must have a different boot ID" >&2
                return 1
            fi
            if [[ " ${cmdline} " == *" flatcar.first_boot="* ]]; then
                echo "FAIL: Ignition was rearmed on reboot" >&2
                return 1
            fi
            ;;
        *)
            echo "FAIL: phase must be first or reboot" >&2
            return 1
            ;;
    esac

    if [[ ! -f "${root}/etc/acl-prefetch-probe" ]] ||
        [[ "$(cat "${root}/etc/acl-prefetch-probe")" != "${expected}" ]]; then
        echo "FAIL: unique CustomData sentinel was not delivered or changed" >&2
        return 1
    fi
    for path in "${root}/boot/flatcar/first_boot" "${root}/boot/coreos/first_boot" \
        "${root}"/boot/EFI/Linux/*.efi.extra.d/firstboot.addon.efi; do
        if [[ -e "${path}" ]]; then
            echo "FAIL: first-boot trigger was not consumed: ${path}" >&2
            return 1
        fi
    done
    printf 'PASS: phase=%s boot_id=%s CustomData delivered; first-boot triggers consumed\n' \
        "${phase}" "${boot_id}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ $# -lt 2 || $# -gt 3 ]]; then
        echo "Usage: $0 first|reboot EXPECTED_SENTINEL [FIRST_BOOT_ID]" >&2
        exit 2
    fi
    validate_firstboot_state "$1" "" "$2" "${3:-}"
fi
