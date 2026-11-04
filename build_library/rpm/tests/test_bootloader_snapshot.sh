#!/bin/bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_ROOT}/build_library/rpm/rpm_install.sh"

die() { echo "$*" >&2; exit 1; }
info() { :; }
warn() { echo "$*" >&2; }
sudo() { "$@"; }

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
root_fs="${work_dir}/root"
repo_dir="${root_fs}/etc/yum.repos.d"
local_repo="${work_dir}/local"
pipeline_repo="${work_dir}/pipeline-rpms"
mkdir -p "${local_repo}/repodata" "${pipeline_repo}/repodata"
touch "${local_repo}/repodata/repomd.xml" "${pipeline_repo}/repodata/repomd.xml"
touch "${local_repo}/grub2-9-1.x86_64.rpm"

PACKAGE_SNAPSHOT_TIME=1700000000
rpm_setup_repos "${root_fs}" 3.0 "${local_repo}" "${pipeline_repo}"
grep -qx 'excludepkgs=grub2 grub2-efi grub2-efi-binary shim systemd-boot' \
    "${repo_dir}/azurelinux-local.repo"
grep -Fxq 'excludepkgs=trident* grub2 grub2-efi grub2-efi-binary shim systemd-boot' \
    "${repo_dir}/azurelinux-pipeline.repo"

unset PACKAGE_SNAPSHOT_TIME
rpm_setup_repos "${root_fs}" 3.0 "${local_repo}" "${pipeline_repo}"
if grep -q '^excludepkgs=' "${repo_dir}/azurelinux-local.repo"; then
    die "Bootloader exclusions must only apply to snapshot builds"
fi
grep -Fxq 'excludepkgs=trident*' "${repo_dir}/azurelinux-pipeline.repo"

rpm_snapshot_args() {
    local -n args="$1"
    args+=(--snapshot-time="${PACKAGE_SNAPSHOT_TIME}" "--snapshot-exclude-repos=azurelinux-local-cache,azurelinux-pipeline-cache")
}
dnf5() {
    printf '%s\n' "$@" > "${work_dir}/dnf-args"
}

PACKAGE_SNAPSHOT_TIME=1700000000
remote_root="${work_dir}/remote-root"
rpm_setup_repos "${remote_root}" 3.0
rpm_download_packages "${work_dir}/remote-download" "${remote_root}" grub2
grep -Fxq -- '--snapshot-time=1700000000' "${work_dir}/dnf-args"
if grep -Eq -- '^--disable-repo=azurelinux-(local|pipeline)-cache$' "${work_dir}/dnf-args"; then
    die "Cannot disable a local cache repository that is not configured"
fi

rpm_download_packages "${work_dir}/local-download" "${root_fs}" grub2
grep -Fxq -- '--disable-repo=azurelinux-local-cache' "${work_dir}/dnf-args"
grep -Fxq -- '--disable-repo=azurelinux-pipeline-cache' "${work_dir}/dnf-args"

for unavailable_repo in "" "${work_dir}/nonexistent"; do
    rpm_setup_repos "${root_fs}" 3.0 "${local_repo}" "${pipeline_repo}"
    rpm_setup_repos "${root_fs}" 3.0 "${local_repo}" "${unavailable_repo}"
    [[ ! -f "${repo_dir}/azurelinux-pipeline.repo" ]] ||
        die "An unavailable pipeline cache must not leave a stale repository: ${unavailable_repo:-unset}"
    rpm_download_packages "${work_dir}/local-only-download" "${root_fs}" grub2
    grep -Fxq -- '--disable-repo=azurelinux-local-cache' "${work_dir}/dnf-args"
    if grep -Fxq -- '--disable-repo=azurelinux-pipeline-cache' "${work_dir}/dnf-args"; then
        die "Cannot disable a pipeline cache repository that is not configured"
    fi
done

mkdir -p "${work_dir}/missing-metadata"
if (rpm_setup_repos "${work_dir}/bad-root" 3.0 "${local_repo}" "${work_dir}/missing-metadata") >/dev/null 2>&1; then
    die "A pipeline cache without repository metadata must fail"
fi

rpm_init_database() { :; }
rpm_import_gpg_key() { :; }
RPM_STAGING_DIR="${local_repo}/" rpm_install_init "${work_dir}/discovered-root"
[[ -f "${work_dir}/discovered-root/etc/yum.repos.d/azurelinux-pipeline.repo" ]] ||
    die "Repository initialization must discover the sibling pipeline cache"

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

# FastTrack diagnostic queries must resolve the same snapshot as the install.
fasttrack_repo="${work_dir}/fasttrack-preview.repo"
fasttrack_root="${work_dir}/fasttrack-root"
mkdir -p "${fasttrack_root}/etc/yum.repos.d" "${work_dir}/build"
touch "${fasttrack_repo}" "${fasttrack_root}/etc/yum.repos.d/$(basename "${fasttrack_repo}")"
dnf_trace="${work_dir}/fasttrack-dnf-args"
sudo() {
    if [[ "${1:-}" == "/usr/bin/dnf5" ]]; then
        shift
        printf '%s\n' "$@" >> "${dnf_trace}"
        return 0
    fi
    "$@"
}
rpm_mount_pseudofs() { :; }
rpm_umount_pseudofs() { :; }
remove_denylist_rpm_packages() { :; }
remove_orphaned_perl_scripts() { :; }
remove_orphaned_python_scripts() { :; }
FASTTRACK_REPO_FILE="${fasttrack_repo}"
BUILD_DIR="${work_dir}/build"
rpm_install_package "${fasttrack_root}" snapshot-test-package
[[ "$(grep -Fxc -- '--snapshot-time=1700000000' "${dnf_trace}")" -eq 3 ]] ||
    die "FastTrack diagnostic queries and install must all preserve PACKAGE_SNAPSHOT_TIME"
[[ "$(grep -Fxc -- 'repoquery' "${dnf_trace}")" -eq 2 ]] ||
    die "Expected both FastTrack diagnostic repoqueries to run"
