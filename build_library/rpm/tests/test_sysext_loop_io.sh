#!/bin/bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILD_LIBRARY_DIR="${SCRIPT_ROOT}/build_library"
source "${BUILD_LIBRARY_DIR}/rpm/build_image_util.sh"

die() { echo "$*" >&2; exit 1; }
sudo() { "$@"; }

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
root_fs="${work_dir}/root"
vendor="${root_fs}/usr/lib/systemd/system/systemd-sysext.service.d/60-loop-buffered-io.conf"
override="${root_fs}/etc/systemd/system/systemd-sysext.service.d/60-loop-buffered-io.conf"

mkdir -p "$(dirname "${override}")"
printf '[Service]\nEnvironment=SYSTEMD_LOOP_DIRECT_IO=1\n' > "${override}"
cp "${override}" "${work_dir}/admin-override"
printf '[Service]\nEnvironment=SYSTEMD_LOOP_DIRECT_IO=0\n' > "${work_dir}/expected"

_configure_sysext_rpm "${root_fs}"
cmp "${work_dir}/expected" "${vendor}" ||
    die "Image must install the buffered-loop vendor default"
[[ "$(stat -c '%a' "${vendor}")" == 644 ]] ||
    die "Vendor drop-in must be readable by systemd"

_configure_sysext_rpm "${root_fs}"
cmp "${work_dir}/expected" "${vendor}" ||
    die "Repeated image configuration must not duplicate the drop-in"
cmp "${work_dir}/admin-override" "${override}" ||
    die "Image configuration must preserve administrator overrides"

# Exercise the real finish hook up to the dracut boundary with a fresh drop-in.
rm "${vendor}"
mkdir -p "${root_fs}/boot"
touch "${root_fs}/boot/vmlinuz-test"
(
    info() { :; }
    generate_initramfs_dracut() {
        local install_items=""
        source "${BUILD_LIBRARY_DIR}/rpm/additional_files/99-acl.conf"
        local dropin="/usr/lib/systemd/system/systemd-sysext.service.d/60-loop-buffered-io.conf"
        [[ " ${install_items} " == *" ${dropin} "* ]] ||
            die "Dracut must explicitly include the sysext vendor drop-in"
        cmp "${work_dir}/expected" "${1}${dropin}" ||
            die "Vendor drop-in must exist before initramfs generation"
        cp "${1}${dropin}" "${work_dir}/initramfs-dropin"
        exit 0
    }
    finish_image_rpm "${root_fs}"
)
cmp "${work_dir}/expected" "${work_dir}/initramfs-dropin" ||
    die "Image finish must reach dracut with the buffered-loop default"
cmp "${work_dir}/expected" "${vendor}" ||
    die "Real-root vendor drop-in must remain installed"
cmp "${work_dir}/admin-override" "${override}" ||
    die "Early image configuration must preserve administrator overrides"
