#!/bin/bash

acl_usr_filesystem() {
    local default=btrfs
    [[ "${PACKAGE_SOURCE_MODE:-}" != RPM ]] || default=erofs
    printf '%s\n' "${ACL_USR_FS:-${default}}"
}

acl_validate_usr_filesystem() {
    case "$(acl_usr_filesystem)" in
        btrfs) return 0 ;;
        erofs) ;;
        *)
            echo "Unsupported ACL_USR_FS (expected btrfs or erofs)" >&2
            return 1
            ;;
    esac
    if [[ "${PACKAGE_SOURCE_MODE:-}" != RPM || "${BOOTLOADER_MODE:-}" != uki ]]; then
        echo "Opt-in /usr filesystems require RPM and UKI mode" >&2
        return 1
    fi
}

acl_install_sysext_io_default() {
    local root="$1"
    acl_validate_usr_filesystem || return 1
    [[ "$(acl_usr_filesystem)" != btrfs ]] || return 0

    local binary="${root}/usr/bin/systemd-sysext"
    local original="${binary}.acl-real"
    local template="${BUILD_LIBRARY_DIR}/rpm/systemd-sysext"
    if [[ ! -f "${binary}" || ! -x "${binary}" || -L "${binary}" ||
          -e "${original}" || -L "${original}" ]]; then
        echo "Cannot install sysext I/O default: missing binary or existing wrapper" >&2
        return 1
    fi
    local wrapper
    wrapper="$(sudo mktemp "${binary}.acl-wrapper.XXXXXX")" || return 1
    if ! sudo cp --preserve=mode,ownership,timestamps,xattr -- "${binary}" "${original}" ||
       ! sudo cp --preserve=mode,ownership,timestamps,xattr -- "${binary}" "${wrapper}" ||
       ! sudo sh -c 'cat "$1" > "$2"' -- "${template}" "${wrapper}" ||
       ! sudo mv -T -- "${wrapper}" "${binary}"; then
        sudo rm -f -- "${wrapper}" || return 1
        echo "Failed to install the opt-in sysext I/O default" >&2
        return 1
    fi
}

acl_preserve_usr_filesystem() {
    local profile="$1"
    acl_validate_usr_filesystem || return 1
    sed -i -e '/^export ACL_USR_FS=/d' \
        -e '/^export ACL_EXPERIMENTAL_USR_FS=/d' "${profile}" || return 1
    printf "export ACL_USR_FS='%s'\n" "${ACL_USR_FS:-}" >> "${profile}"
}

acl_restore_usr_filesystem() {
    local requested="$1"
    local board="$2"
    local recorded="${ACL_USR_FS:-${ACL_EXPERIMENTAL_USR_FS:-btrfs}}"
    local version="${ACL_USR_FS_METADATA_VERSION:-}"
    if [[ -n "${ACL_USR_FS:-}" && -n "${ACL_EXPERIMENTAL_USR_FS:-}" &&
          "${ACL_USR_FS}" != "${ACL_EXPERIMENTAL_USR_FS}" ]]; then
        echo "Source image contains conflicting filesystem metadata" >&2
        return 1
    fi
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
    export ACL_USR_FS="${recorded}"
    unset ACL_EXPERIMENTAL_USR_FS
    acl_validate_usr_filesystem
}
