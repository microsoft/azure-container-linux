#!/bin/bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_ROOT}/build_library/rpm/rpm_install.sh"

die() { echo "$*" >&2; exit 1; }
error() { echo "$*" >&2; }
info() { :; }
sudo() {
    if [[ "$1" == /usr/bin/dnf5 ]]; then
        printf '%s\n' "$@" > "${work_dir}/query-args"
        [[ "${query_failure:-false}" != true ]] || return 1
        printf '%s\n' "${mock_candidates}"
    else
        "$@"
    fi
}
/usr/bin/dnf5() { echo '--snapshot-time'; }
rpm_query_manifest() { printf '%s\n' "${mock_installed}"; }

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
PACKAGE_SNAPSHOT_TIME=1700000000
unset FASTTRACK_REPO_FILE
snapshot_flags=()
rpm_snapshot_args snapshot_flags
[[ "${snapshot_flags[*]}" == '--snapshot-time=1700000000 --snapshot-exclude-repos=azurelinux-local-cache,azurelinux-pipeline-cache' ]] ||
    die "Normal builds must keep the existing snapshot policy"

FASTTRACK_REPO_FILE="${work_dir}/selected-preview.repo"
printf '[fasttrack-preview]\nenabled=1\npriority=1\n' > "${FASTTRACK_REPO_FILE}"
snapshot_flags=()
rpm_snapshot_args snapshot_flags
[[ "${snapshot_flags[*]}" == '--snapshot-time=1700000000 --snapshot-exclude-repos=azurelinux-local-cache,azurelinux-pipeline-cache,fasttrack-preview' ]] ||
    die "FastTrack must bypass the cutoff without exempting PMC"
mkdir -p "${work_dir}/root/etc/yum.repos.d"
printf '[fasttrack-preview]\nbaseurl=https://example.invalid/stale\n' > \
    "${work_dir}/root/etc/yum.repos.d/fasttrack-preview.repo"
rpm_setup_repos "${work_dir}/root" 3.0
cmp "${FASTTRACK_REPO_FILE}" "${work_dir}/root/etc/yum.repos.d/fasttrack-preview.repo" ||
    die "The selected FastTrack repository must replace the inherited definition"
rm -rf "${work_dir}/root/etc"
rpm_setup_fasttrack_repo "${work_dir}/root"
cmp "${FASTTRACK_REPO_FILE}" "${work_dir}/root/etc/yum.repos.d/fasttrack-preview.repo" ||
    die "FastTrack repository staging must recover from a sysext mangler removing /etc"
[[ "$(grep -Fc 'rpm_setup_fasttrack_repo "${BUILD_DIR}/${FLAGS_install_root_basename}"' \
    "${SCRIPT_ROOT}/build_sysext")" -eq 2 ]] ||
    die "build_sysext must stage the selected FastTrack repository before install and after mangling"
grep -Fq '"FASTTRACK_REPO_FILE=${FASTTRACK_REPO_FILE:-}"' \
    "${SCRIPT_ROOT}/build_library/sysext_prod_builder" ||
    die "Embedded sysext builds must preserve FASTTRACK_REPO_FILE through sudo"
[[ "$(grep -Fc -- '-e FASTTRACK_REPO_FILE="${fasttrack_repo_file}"' "${SCRIPT_ROOT}/run_sdk_container")" -eq 2 ]] ||
    die "SDK container creation and entry must use the translated FastTrack repository path"
if grep -Fq -- 'FASTTRACK_REPO_FILE="${FASTTRACK_REPO_FILE:+' "${SCRIPT_ROOT}/run_sdk_container"; then
    die "A hard-coded FastTrack repository path must not override the selected file"
fi

mock_candidates=$'kernel\t0:6.6.100.1-2.azl3\tx86_64\nkernel-uvm\t0:6.6.100.1-2.azl3\tx86_64'
mock_installed=$'kernel\t6.6.100.1-2.azl3\t1\t1\tMicrosoft\t(none)\t1\tx86_64\t0\tkernel.src.rpm'
rpm_validate_fasttrack_packages "${work_dir}/root"
grep -Fxq -- '--snapshot-exclude-repos=azurelinux-local-cache,azurelinux-pipeline-cache,fasttrack-preview' "${work_dir}/query-args"
grep -Fxq -- '--arch=x86_64,noarch' "${work_dir}/query-args"

mock_installed="${mock_installed/6.6.100.1-2.azl3/6.6.100.1-1.azl3}"
if rpm_validate_fasttrack_packages "${work_dir}/root" >"${work_dir}/mismatch" 2>&1; then
    die "An older installed kernel must block the build"
fi
grep -q 'FastTrack version mismatch for kernel.x86_64' "${work_dir}/mismatch"

new_kernel=$'kernel\t6.6.100.1-2.azl3\t1\t1\tMicrosoft\t(none)\t1\tx86_64\t0\tkernel.src.rpm'
old_kernel=$'kernel\t6.6.100.1-1.azl3\t1\t1\tMicrosoft\t(none)\t1\tx86_64\t0\tkernel.src.rpm'
for mock_installed in "${old_kernel}"$'\n'"${new_kernel}" "${new_kernel}"$'\n'"${old_kernel}"; do
    if rpm_validate_fasttrack_packages "${work_dir}/root" >"${work_dir}/multiple-versions" 2>&1; then
        die "Every installed version of a FastTrack package must be verified"
    fi
    grep -q 'installed 0:6.6.100.1-1.azl3, expected 0:6.6.100.1-2.azl3' \
        "${work_dir}/multiple-versions"
done

printf '%s\n' "${new_kernel}" > "${work_dir}/sysext-manifest"
mock_installed="${old_kernel}"
rpm_validate_fasttrack_packages "${work_dir}/root" "${work_dir}/sysext-manifest"
grep -Fq 'RPM_DEFER_FASTTRACK_VALIDATION=true' "${SCRIPT_ROOT}/build_sysext" ||
    die "build_sysext must defer FastTrack validation until all packages are installed"
grep -Fq '"${BUILD_DIR}/.rpm-sysext-manifest.tmp"' "${SCRIPT_ROOT}/build_sysext" ||
    die "build_sysext must validate only its changed-package manifest"

mock_candidates=$'kernel-uvm\t0:6.6.100.1-2.azl3\tx86_64'
rpm_validate_fasttrack_packages "${work_dir}/root"

BOARD=arm64-usr
mock_candidates=$'kernel\t0:6.6.100.1-2.azl3\taarch64'
mock_installed=$'kernel\t6.6.100.1-2.azl3\t1\t1\tMicrosoft\t(none)\t1\taarch64\t0\tkernel.src.rpm'
rpm_validate_fasttrack_packages "${work_dir}/root"
grep -Fxq -- '--forcearch=aarch64' "${work_dir}/query-args"
grep -Fxq -- '--arch=aarch64,noarch' "${work_dir}/query-args"

mock_candidates=""
if rpm_validate_fasttrack_packages "${work_dir}/root" >"${work_dir}/empty-error" 2>&1; then
    die "Empty preview metadata must not pass verification"
fi
grep -q 'FastTrack repository has no package candidates' "${work_dir}/empty-error"

mock_candidates=$'kernel\t0:6.6.100.1-2.azl3\taarch64'
mock_installed="invalid manifest"
if rpm_validate_fasttrack_packages "${work_dir}/root" >"${work_dir}/manifest-error" 2>&1; then
    die "Malformed installed metadata must not pass verification"
fi
grep -q 'Invalid installed package manifest' "${work_dir}/manifest-error"

query_failure=true
if rpm_validate_fasttrack_packages "${work_dir}/root" >"${work_dir}/query-error" 2>&1; then
    die "A failed FastTrack query must block the build"
fi
grep -q 'Failed to query FastTrack package versions' "${work_dir}/query-error"

FASTTRACK_REPO_FILE="${work_dir}/missing.repo"
if rpm_setup_repos "${work_dir}/missing-root" 3.0 >"${work_dir}/missing-error" 2>&1; then
    die "Missing FastTrack configuration must block the build"
fi
grep -q 'FASTTRACK_REPO_FILE must reference a file' "${work_dir}/missing-error"
