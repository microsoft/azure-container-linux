#!/bin/bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_ROOT}/build_library/rpm/rpm_install.sh"

die() { echo "$*" >&2; exit 1; }
info() { :; }
sudo() { "$@"; }

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
root_fs="${work_dir}/root"
local_repo="${work_dir}/local"
mkdir -p "${local_repo}/repodata"
touch "${local_repo}/repodata/repomd.xml"
touch "${local_repo}/grub2-9-1.x86_64.rpm"

PACKAGE_SNAPSHOT_TIME=1700000000
rpm_setup_repos "${root_fs}" 3.0 "${local_repo}"
grep -qx 'excludepkgs=grub2 grub2-efi grub2-efi-binary shim systemd-boot' \
    "${root_fs}/etc/yum.repos.d/azurelinux-local.repo"

unset PACKAGE_SNAPSHOT_TIME
rpm_setup_repos "${root_fs}" 3.0 "${local_repo}"
if grep -q '^excludepkgs=' "${root_fs}/etc/yum.repos.d/azurelinux-local.repo"; then
    die "Bootloader exclusions must only apply to snapshot builds"
fi

download_dir="${work_dir}/bootloader-rpms"
mkdir -p "${download_dir}"
touch "${download_dir}/grub2-1-1.x86_64.rpm"
selected="$(rpm_bootloader_package_file "${work_dir}/disk.img" grub2 x86_64)"
[[ "${selected}" == "${download_dir}/grub2-1-1.x86_64.rpm" ]] ||
    die "Selected a retained RPM instead of this image's download"

touch "${download_dir}/grub2-2-1.x86_64.rpm"
if (rpm_bootloader_package_file "${work_dir}/disk.img" grub2 x86_64) >/dev/null 2>&1; then
    die "Multiple bootloader RPM versions must fail"
fi
