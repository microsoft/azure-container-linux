#!/bin/bash

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/../..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

# We're invoked only by build_image, which runs in the chroot
assert_inside_chroot

DEFINE_string board "${DEFAULT_BOARD}" \
  "The name of the board"
DEFINE_string target "" \
  "The UEFI target: x86_64-efi or arm64-efi"
DEFINE_string disk_image "" \
  "The disk image containing the EFI System partition."
DEFINE_boolean verity ${FLAGS_FALSE} \
  "Indicates that boot commands should enable dm-verity."
DEFINE_string verity_hash "" \
  "Path to the file containing the dm-verity root hash for /usr."

# Parse flags
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
switch_to_strict_mode

# Must be sourced after flags are parsed
. "${BUILD_LIBRARY_DIR}/toolchain_util.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/board_options.sh"  || exit 1

# Determine EFI architecture suffix
case "${FLAGS_target}" in
    x86_64-efi)
        EFI_ARCH="x64"
        ;;
    arm64-efi)
        EFI_ARCH="aa64"
        ;;
    i386-pc|x86_64-xen)
        # UKI is UEFI-only — nothing to do for legacy targets
        info "UKI: Target ${FLAGS_target} is not UEFI; skipping."
        exit 0
        ;;
    *)
        die_notrace "Unknown target ${FLAGS_target}"
        ;;
esac

uki_install_rpm() {
    info "UKI/RPM mode: Installing systemd-boot and systemd-ukify"

    # Source rpm_install functions for find_rpm_staging_dir
    . "${BUILD_LIBRARY_DIR}/rpm/rpm_install.sh" || die "Failed to source rpm_install.sh"

    # Locate the RPM cache directory
    rpm_staging=$(find_rpm_staging_dir)
    local uki_local_cache="${RPM_LOCAL_CACHE:-${rpm_staging}}"

    if [[ ! -d "${uki_local_cache}" ]]; then
        die "RPM cache directory not found: ${uki_local_cache}"
    fi

    # Find required RPMs in the cache.
    local -A uki_rpms
    for pkg in systemd-boot systemd-ukify python3-pefile; do
        local rpm_file
        rpm_file=$(find "${uki_local_cache}" -name "${pkg}-[0-9]*.rpm" | head -1)
        if [[ -z "${rpm_file}" ]]; then
            die "RPM file not found for package: ${pkg} in ${uki_local_cache}"
        fi
        uki_rpms["${pkg}"]="${rpm_file}"
    done

    info "Installing systemd-boot to BOARD_ROOT"
    sudo rpm --root="${BOARD_ROOT}" --install -vh --force --nodeps \
        "${uki_rpms[systemd-boot]}"

    info "Installing systemd-ukify and python3-pefile to SDK root"
    sudo rpm --install -vh --force --nodeps \
        "${uki_rpms[systemd-ukify]}" "${uki_rpms[python3-pefile]}"

    info "UKI/RPM: Successfully installed systemd-boot, systemd-ukify, and python3-pefile"
}

uki_provision_rpm() {
    local ESP_DIR="$1"

    info "UKI/RPM: Provisioning systemd-boot + UKI on ESP"

    # The kernel and initrd were placed on the ESP by
    # finish_image_rpm().
    local kernel="${ESP_DIR}/flatcar/vmlinuz-a"
    if [[ ! -f "${kernel}" ]]; then
        die "UKI/RPM: Kernel not found at ${kernel}"
    fi

    local initrd="${ESP_DIR}/flatcar/initramfs-a.img"
    if [[ ! -f "${initrd}" ]]; then
        die "UKI/RPM: Initrd not found at ${initrd}"
    fi

    # Temp directory for all intermediate files.
    local uki_temp_dir
    uki_temp_dir=$(mktemp -d)

    # Generate os-release for the UKI.
    local osrelease="${uki_temp_dir}/os-release"
    cat > "${osrelease}" <<-OSREL
		NAME="Azure Container Linux"
		ID=flatcar
		ID_LIKE="flatcar azurelinux"
		VERSION="${FLATCAR_VERSION:-0.0.0}"
		VERSION_ID="${FLATCAR_VERSION_ID:-0.0.0}"
		PRETTY_NAME="Azure Container Linux ${FLATCAR_VERSION:-}"
	OSREL
    info "UKI/RPM: Generated os-release for UKI"

    if ! command -v ukify &>/dev/null; then
        die "UKI/RPM: ukify not found on PATH; uki_install_rpm() should have installed it"
    fi
    info "UKI/RPM: Using ukify from $(command -v ukify)"

    # Read partition UUID and compute verity hash offset from the
    # canonical disk layout so the values never drift from the source.
    local disk_layout_file="${BUILD_LIBRARY_DIR}/disk_layout.json"
    if [[ ! -f "${disk_layout_file}" ]]; then
        die "UKI/RPM: disk_layout.json not found at ${disk_layout_file}"
    fi

    local usr_a_uuid
    usr_a_uuid=$(jq -r '.layouts.base["3"].uuid' "${disk_layout_file}")

    local verity_hash_offset
    verity_hash_offset=$(jq -r \
        '(.layouts.base["3"].fs_blocks | tonumber) as $b | (.metadata.fs_block_size | tonumber) as $s | ($b * $s)' \
        "${disk_layout_file}")

    info "UKI/RPM: USR-A uuid=${usr_a_uuid}  verity hash-offset=${verity_hash_offset}"

    local cmdline=""
    if [[ ${FLAGS_verity} -eq ${FLAGS_TRUE} ]]; then
        local usr_hash=""
        if [[ -n "${FLAGS_verity_hash}" && -f "${FLAGS_verity_hash}" ]]; then
            usr_hash=$(cat "${FLAGS_verity_hash}")
            info "UKI/RPM: Verity hash = ${usr_hash}"
        else
            die "UKI/RPM: Verity enabled but no hash file at ${FLAGS_verity_hash}"
        fi
        cmdline="mount.usr=/dev/mapper/usr mount.usrflags=ro"
        cmdline+=" systemd.verity_usr_data=PARTUUID=${usr_a_uuid}"
        cmdline+=" systemd.verity_usr_hash=PARTUUID=${usr_a_uuid}"
        cmdline+=" systemd.verity_usr_options=hash-offset=${verity_hash_offset},panic-on-corruption"
        cmdline+=" usrhash=${usr_hash}"
    else
        cmdline="mount.usr=PARTUUID=${usr_a_uuid} mount.usrflags=ro"
    fi
    # Common args
    cmdline+=" root=LABEL=ROOT rootflags=rw"
    cmdline+=" consoleblank=0"
    cmdline+=" console=tty0 console=ttyS0,115200n8"
    # OEM / platform identification
    # TODO: Make oem_id configurable (currently hardcoded for generic/qemu images)
    cmdline+=" flatcar.oem.id=qemu ignition.platform.id=qemu"
    # NOTE: first-boot args (flatcar.first_boot=detected, ignition.firstboot=1)
    # are deliberately NOT baked into the UKI cmdline because they must only
    # appear on the very first boot. A separate mechanism (e.g. a first-boot
    # systemd unit or an addons UKI) will handle this later.

    # Write cmdline to a temp file for ukify
    echo "${cmdline}" > "${uki_temp_dir}/cmdline.txt"
    info "UKI/RPM: cmdline = ${cmdline}"

    local efi_stub="${BOARD_ROOT}/usr/lib/systemd/boot/efi/linux${EFI_ARCH}.efi.stub"
    if [[ ! -f "${efi_stub}" ]]; then
        die "UKI/RPM: EFI stub not found at ${efi_stub}"
    fi

    local uki_output="${uki_temp_dir}/acl.efi"
    info "UKI/RPM: Building UKI with ukify"

    sudo ukify build \
        --stub="${efi_stub}" \
        --linux="${kernel}" \
        --initrd="${initrd}" \
        --cmdline=@"${uki_temp_dir}/cmdline.txt" \
        --os-release=@"${osrelease}" \
        --output="${uki_output}"

    if [[ ! -f "${uki_output}" ]]; then
        die "UKI/RPM: ukify failed to produce ${uki_output}"
    fi

    info "UKI/RPM: UKI built successfully ($(du -h "${uki_output}" | cut -f1))"

    # systemd-boot binary from the RPM
    local sd_boot_efi="${BOARD_ROOT}/usr/lib/systemd/boot/efi/systemd-boot${EFI_ARCH}.efi"
    if [[ ! -f "${sd_boot_efi}" ]]; then
        die "UKI/RPM: systemd-boot EFI binary not found at ${sd_boot_efi}"
    fi

    # Install as the default UEFI bootloader
    sudo mkdir -p "${ESP_DIR}/EFI/BOOT"
    sudo cp "${sd_boot_efi}" "${ESP_DIR}/EFI/BOOT/BOOT${EFI_ARCH^^}.EFI"
    info "UKI/RPM: Installed systemd-boot → EFI/BOOT/BOOT${EFI_ARCH^^}.EFI"

    sudo mkdir -p "${ESP_DIR}/EFI/Linux"
    sudo cp "${uki_output}" "${ESP_DIR}/EFI/Linux/acl.efi"
    info "UKI/RPM: Installed UKI → EFI/Linux/acl.efi"

    sudo mkdir -p "${ESP_DIR}/loader"
    sudo tee "${ESP_DIR}/loader/loader.conf" > /dev/null <<-EOF
		timeout 3
		default acl.efi
	EOF
    info "UKI/RPM: Wrote loader/loader.conf"

    # Clean up
    rm -rf "${uki_temp_dir}"
}

info "Installing UKI packages for target ${FLAGS_target}"
uki_install_rpm

# Mount the ESP and provision
ESP_DIR=
LOOP_DEV=

cleanup() {
    if [[ -d "${ESP_DIR}" ]]; then
        if mountpoint -q "${ESP_DIR}"; then
            sudo umount "${ESP_DIR}"
        fi
        rm -rf "${ESP_DIR}"
    fi
    if [[ -b "${LOOP_DEV}" ]]; then
        sudo losetup --detach "${LOOP_DEV}"
    fi
}
trap cleanup EXIT

info "Installing UKI ${FLAGS_target} in ${FLAGS_disk_image##*/}"
LOOP_DEV=$(sudo losetup --find --show --partscan "${FLAGS_disk_image}")
ESP_DIR=$(mktemp --directory)
MOUNTED=

for (( i=0; i<5; ++i )); do
    if sudo mount -t vfat "${LOOP_DEV}p1" "${ESP_DIR}"; then
        MOUNTED=x
        break
    fi
    warn "loopback device node ${LOOP_DEV}p1 still missing, reprobing..."
    sudo blockdev --rereadpt "${LOOP_DEV}"
    sleep "$(bc <<<"scale=1; (2.0 ^ ${i}) / 2.0")"
done
if [[ -z ${MOUNTED} ]]; then
    failboat "${LOOP_DEV}p1 where art thou? udev has forsaken us!"
fi

# Provision systemd-boot + UKI onto the ESP
uki_provision_rpm "${ESP_DIR}"

cleanup
trap - EXIT
command_completed
