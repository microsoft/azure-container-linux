#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../../.." && pwd)"
work="${TMPDIR:-${root}/.test-scratch}/btrfs-install-$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
source "$root/acl/tests/ipe/offline/function-extraction.sh"
source_test_functions "$root/build_library/rpm/rpm_install.sh" rpm_install_package rpm_install_init
source_test_functions "$root/build_library/rpm/uki_install.sh" uki_provision_rpm
info() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
rpm_mount_pseudofs() { exit 0; }
rpm_init_database() { :; }
rpm_get_staging_dir() { printf '%s\n' "$work/staging"; }
rpm_setup_repos() { echo repos; }
mkdir "$work/staging"

packages=(kernel kernel-devel kernel-drivers-accessibility kernel-drivers-gpu
          kernel-drivers-intree-amdgpu kernel-drivers-sound kernel-tools coreos-init)
for board in amd64-usr arm64-usr; do
    output="$(BOARD="$board" ACL_BTRFS_IPE_KERNEL=1 rpm_install_package "$work/root" "${packages[@]}")"
    for package in "${packages[@]:0:7}"; do
        [[ " $output " == *" ${package}-6.6.157.1-1.btrfsipe1.azl3 "* ]]
    done
    [[ " $output " == *" coreos-init "* ]]
    output="$(BOARD="$board" ACL_BTRFS_IPE_KERNEL=0 rpm_install_package "$work/root" kernel)"
    [[ "$output" != *btrfsipe1* && "$output" == *": kernel" ]]
done

ACL_BTRFS_IPE_KERNEL=0 rpm_install_init "$work/root" | grep -qx repos
if (ACL_BTRFS_IPE_KERNEL=1 rpm_install_init "$work/root") >"$work/error" 2>&1; then exit 1; fi
grep -q "provenance is missing" "$work/error"
touch "$work/staging/btrfs-ipe-kernel.json"
ACL_BTRFS_IPE_KERNEL=1 rpm_install_init "$work/root" | grep -qx repos
if (ACL_BTRFS_IPE_KERNEL=0 rpm_install_init "$work/root") >"$work/error" 2>&1; then exit 1; fi
grep -q "require ACL_BTRFS_IPE_KERNEL=1" "$work/error"

for version in 6.6.145.2 6.6.157.1-1.btrfsipe1.azl3; do
    mkdir "$work/$version"
    touch "$work/$version/vmlinuz-$version"
    for signing in ephemeral esrp; do
        if (ACL_BTRFS_IPE_KERNEL=1 ACL_BTRFS_IPE_DIAGNOSTIC=0 IPE_CAPABLE=false \
            ACL_IPE_SIGNING_MODE="$signing" uki_provision_rpm "$work/$version") >"$work/error" 2>&1; then exit 1; fi
        if [[ "$version" == 6.6.145.2 ]]; then
            grep -q "selected a stock or unexpected kernel" "$work/error"
        else
            # Reaching initrd validation proves the kernel gate is signing-independent.
            grep -q "Initrd not found" "$work/error"
        fi
    done
done
echo "Btrfs kernel install and provenance tests passed"
