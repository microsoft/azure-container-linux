#!/bin/bash

acl_usr_filesystem() {
    printf '%s\n' "${ACL_EXPERIMENTAL_USR_FS:-btrfs}"
}

acl_validate_usr_filesystem() {
    case "$(acl_usr_filesystem)" in
        btrfs) return 0 ;;
        ext4) ;;
        *)
            echo "Unsupported ACL_EXPERIMENTAL_USR_FS (expected btrfs or ext4)" >&2
            return 1
            ;;
    esac
    if [[ "${PACKAGE_SOURCE_MODE:-}" != RPM || "${BOOTLOADER_MODE:-}" != uki ]]; then
        echo "Opt-in /usr filesystems require RPM and UKI mode" >&2
        return 1
    fi
    if [[ "${COREOS_OFFICIAL:-0}" == 1 ]]; then
        echo "Opt-in /usr filesystems are not qualified for official builds" >&2
        return 1
    fi
}

acl_usr_mount_options() {
    acl_validate_usr_filesystem || return 1
    case "$(acl_usr_filesystem)" in
        btrfs) printf '%s\n' ro ;;
        ext4) printf '%s\n' ro,noload ;;
    esac
}

acl_preserve_usr_filesystem() {
    local profile="$1"
    acl_validate_usr_filesystem || return 1
    sed -i '/^export ACL_EXPERIMENTAL_USR_FS=/d' "${profile}" || return 1
    printf "export ACL_EXPERIMENTAL_USR_FS='%s'\n" "${ACL_EXPERIMENTAL_USR_FS:-}" >> "${profile}"
}

acl_restore_usr_filesystem() {
    local requested="$1"
    local board="$2"
    local recorded="${ACL_EXPERIMENTAL_USR_FS:-btrfs}"
    local version="${ACL_USR_FS_METADATA_VERSION:-}"
    if [[ -n "${version}" && "${version}" != 1 ]]; then
        echo "Unsupported /usr filesystem metadata version: ${version}" >&2
        return 1
    fi
    if [[ "${recorded}" != btrfs && "${version}" != 1 ]]; then
        echo "Opt-in source image lacks versioned /usr filesystem provenance; rebuild it" >&2
        return 1
    fi
    if [[ "${version}" == 1 ]]; then
        if [[ -z "${ACL_USR_BOARD:-}" || "${ACL_USR_BOARD}" != "${board}" ||
              -z "${ACL_USR_BOOTLOADER:-}" || "${ACL_USR_BOOTLOADER}" != "${BOOTLOADER_MODE:-grub}" ]]; then
            echo "Source image board/bootloader provenance conflicts with conversion settings" >&2
            return 1
        fi
    fi
    if [[ -n "${requested}" && "${requested}" != "${recorded}" ]]; then
        echo "Requested /usr filesystem conflicts with the source image; conversion is not migration" >&2
        return 1
    fi
    export ACL_EXPERIMENTAL_USR_FS="${recorded}"
    acl_validate_usr_filesystem
}
