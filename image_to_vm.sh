#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a usable virtual machine
# disk image, supporting a variety of different targets.


# Helper scripts should be run from the same location as this script.
SCRIPT_ROOT=$(dirname "$(readlink -f "$0")")
. "${SCRIPT_ROOT}/common.sh" || exit 1

# Script must run inside the chroot
assert_inside_chroot

assert_not_root_user

. "${BUILD_LIBRARY_DIR}/toolchain_util.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/build_image_util.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/vm_image_util.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/cros_vm_constants.sh" || exit 1
# shellcheck disable=SC1091 # BUILD_LIBRARY_DIR is initialized by common.sh.
. "${BUILD_LIBRARY_DIR}/rpm/ipe_artifact.sh" || exit 1

# UKI mode uses a dedicated disk layout without BIOS and unused partitions
if [[ "${BOOTLOADER_MODE:-}" == "uki" ]]; then
  export DISK_LAYOUT_FILE="${BUILD_LIBRARY_DIR}/disk_layout_uki.json"
fi

# Flags
DEFINE_string board "${DEFAULT_BOARD}" \
  "Board for which the image was built"

# We default to TRUE so the buildbot gets its image. Note this is different
# behavior from image_to_usb.sh
DEFINE_string format "" \
  "Output format, one of: ${VALID_IMG_TYPES[*]}"
DEFINE_string from "" \
  "Directory containing the production image file."
DEFINE_string disk_layout "" \
  "The disk layout type to use for this image."
DEFINE_integer mem "${DEFAULT_MEM}" \
  "Memory size for the vm config in MBs."
DEFINE_string to "" \
  "Destination folder for VM output file(s)"
DEFINE_string oem_pkg "" \
  "OEM package to install"
DEFINE_string image_name "" \
  "Override the base image name. If not set, defaults to flatcar_production_image.bin"
DEFINE_boolean getbinpkg "${FLAGS_FALSE}" \
  "Download binary packages from remote repository."
DEFINE_string getbinpkgver "" \
  "Use binary packages from a specific version."

# include upload options
. "${BUILD_LIBRARY_DIR}/release_util.sh" || exit 1

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
switch_to_strict_mode

if [[ -z "${FLAGS_format}" ]]; then
    FLAGS_format="$(get_default_vm_type ${FLAGS_board})"
fi

if ! set_vm_type "${FLAGS_format}"; then
    die_notrace "Invalid format: ${FLAGS_format}"
fi

if [ ! -z "${FLAGS_oem_pkg}" ] && ! set_vm_oem_pkg "${FLAGS_oem_pkg}"; then
  die_notrace "Invalid oem : ${FLAGS_oem_pkg}"
fi

if [ -z "${FLAGS_board}" ] ; then
  die_notrace "--board is required."
fi

# If downloading packages is enabled ensure the board is configured properly.
if [[ ${FLAGS_getbinpkg} -eq ${FLAGS_TRUE} ]]; then
  "${SRC_ROOT}/scripts/setup_board" --board="${FLAGS_board}" \
      --getbinpkgver="${FLAGS_getbinpkgver}" --regen_configs_only
fi

# Loaded late because board_options depends on setup_board
. "${BUILD_LIBRARY_DIR}/board_options.sh" || exit 1

# Override image name if provided via flag
if [[ -n "${FLAGS_image_name}" ]]; then
  FLATCAR_PRODUCTION_IMAGE_NAME="${FLAGS_image_name}"
  # Also update sysext base name to match custom image name
  FLATCAR_PRODUCTION_IMAGE_SYSEXT_BASE="${FLAGS_image_name%.bin}_sysext.squashfs"
  info "Using custom image name: ${FLATCAR_PRODUCTION_IMAGE_NAME}"
  info "Using custom sysext base name: ${FLATCAR_PRODUCTION_IMAGE_SYSEXT_BASE}"
else
  info "Using default image name: ${FLATCAR_PRODUCTION_IMAGE_NAME}"
fi

IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
# Default to the most recent image
if [ -z "${FLAGS_from}" ] ; then
  FLAGS_from="$(${SCRIPT_ROOT}/get_latest_image.sh --board=${FLAGS_board})"
else
  pushd "${FLAGS_from}" >/dev/null && FLAGS_from=`pwd` && popd >/dev/null
fi
if [ -z "${FLAGS_to}" ] ; then
  FLAGS_to="${FLAGS_from}"
fi

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f $FOO` won't work.
FLAGS_from=`eval readlink -f $FLAGS_from`
FLAGS_to=`eval readlink -f $FLAGS_to`

# If source includes version.txt switch to its version information
if [ -f "${FLAGS_from}/version.txt" ]; then
    source "${FLAGS_from}/version.txt"
    FLATCAR_VERSION_STRING="${FLATCAR_VERSION}"
fi

set_vm_paths "${FLAGS_from}" "${FLAGS_to}" "${FLATCAR_PRODUCTION_IMAGE_NAME}" "${FLATCAR_PRODUCTION_IMAGE_SYSEXT_BASE}"

# Make sure things are cleaned up on failure
trap vm_cleanup EXIT

fix_mtab

# Setup new (raw) image, possibly resizing filesystems
setup_disk_image "${FLAGS_disk_layout}"

# Install OEM package (oem-release for sysext activation in all modes,
# plus grub.cfg in GRUB mode or a UKI addon in UKI mode).
install_oem_package
install_oem_sysext
run_fs_hook

has_ipe_assets() {
    local artifact_dir="$1" esp_dir="$2"

    [[ -e "${artifact_dir}/acl-ipe-policy/acl-ipe-policy.p7b.cred" ]] ||
        find "${esp_dir}/EFI/Linux" -type f \
            \( -path '*.efi.extra.d/acl-ipe-policy.p7b.cred' \
            -o -path '*.efi.extra.d/verity-usr-*.p7s.cred' \) \
            -print -quit 2>/dev/null |
            grep -q .
}

validate_ipe_marker_consistency() {
    local artifact_dir="$1" esp_dir="$2"
    local signing_mode

    signing_mode="$(ipe_resolve_artifact_signing_mode "${artifact_dir}")" ||
        return 1
    if [[ "${signing_mode}" == "disabled" ]] &&
        has_ipe_assets "${artifact_dir}" "${esp_dir}"; then
        echo "IPE assets are present without a valid ipe-signing-mode marker" >&2
        return 1
    fi
    printf '%s\n' "${signing_mode}"
}

# Sign UKI EFI files with an ephemeral key for Secure Boot testing. At this
# point the ESP is still mounted at ${VM_TMP_ROOT}/boot with all EFI files in
# place (UKI + addons). The public certificate is written to the image
# output directory so _write_qemu_uefi_secure_conf() can enroll it in the OVMF
# Secure Boot db.
if [[ "${PACKAGE_SOURCE_MODE}" == "RPM" && "${BOOTLOADER_MODE:-uki}" == "uki" ]]; then
    ipe_signing_mode="$(
        validate_ipe_marker_consistency "${FLAGS_from}" "${VM_TMP_ROOT}/boot"
    )" || die_notrace "IPE artifact metadata is inconsistent with installed assets"
    if [[ "${ipe_signing_mode}" != "disabled" ]]; then
        ephemeral_cert_dir="${FLAGS_from}/acl-ipe-ephemeral"
        "${BUILD_LIBRARY_DIR}/rpm/ensure_ephemeral_cert.sh" \
            "${ephemeral_cert_dir}" require ||
            die_notrace "IPE artifact has missing or invalid signing material"
        bash "${BUILD_LIBRARY_DIR}/rpm/verify_ipe_signer_continuity.sh" \
            "${ephemeral_cert_dir}" \
            "${FLAGS_from}" \
            "${VM_TMP_ROOT}/boot" ||
            die_notrace "IPE artifact signing material does not match its policy and verity signatures"
    else
        # Disabled images still need one shared Secure Boot signer across test
        # and production conversions, but source artifacts may be read-only.
        ephemeral_cert_dir="${ACL_EPHEMERAL_CERT_DIR:-$(dirname "${FLAGS_to}")/.acl-secureboot-signing}"
        "${BUILD_LIBRARY_DIR}/rpm/ensure_ephemeral_cert.sh" \
            "${ephemeral_cert_dir}" create ||
            die_notrace "Failed to prepare the per-build Secure Boot certificate"
    fi
    "${BUILD_LIBRARY_DIR}/rpm/sign_uki_ephemeral.sh" \
        "${VM_TMP_ROOT}/boot" \
        "$(_dst_dir)" \
        "${ephemeral_cert_dir}"
    if [[ "${ipe_signing_mode}" == "disabled" ]]; then
        rm -f "$(_dst_dir)/ipe-signing-mode"
    else
        printf '%s\n' "${ipe_signing_mode}" > "$(_dst_dir)/ipe-signing-mode"
    fi
fi

# Changes done, glue it together
write_vm_disk
write_vm_conf "${FLAGS_mem}"
write_vm_bundle

vm_cleanup
trap - EXIT

declare -a compressed_images uploadable_files
compress_disk_images VM_GENERATED_FILES

# Ready to set sail!
okboat
command_completed
print_readme
