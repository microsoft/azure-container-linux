#!/bin/bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECKER="${SCRIPT_ROOT}/build_library/rpm/check_pmc_staleness.sh"

fail() { echo "$*" >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
mkdir -p "${work_dir}/root" "${work_dir}/bin"

cat > "${work_dir}/bin/dnf5" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${DNF5_ARGS_FILE}"
printf '%s' "${DNF5_OUTPUT:-}"
EOF
chmod +x "${work_dir}/bin/dnf5"

tracked_package=""
for spec_file in "${SCRIPT_ROOT}"/acl/SPECS/*/*.spec; do
    package_name="$(awk '/^Name:/ {print $2; exit}' "${spec_file}")"
    base_version="$(awk '/^%define pmc_base_version/ {print $3; exit}' "${spec_file}")"
    base_release="$(awk '/^%define pmc_base_release/ {print $3; exit}' "${spec_file}")"
    if [[ -n "${package_name}" && -n "${base_version}" && -n "${base_release}" ]]; then
        tracked_package="${package_name} ${base_version}-${base_release}.azl3"
        break
    fi
done
[[ -n "${tracked_package}" ]] || fail "No PMC-tracked package found for the test fixture"

DNF5_ARGS_FILE="${work_dir}/dnf5-args" \
DNF5_OUTPUT="${tracked_package}" \
DNF5_BIN="${work_dir}/bin/dnf5" \
BOARD=arm64-usr \
bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/arm64.log" 2>&1

grep -Fxq -- '--forcearch=aarch64' "${work_dir}/dnf5-args" ||
    fail "ARM64 staleness query did not pass --forcearch=aarch64"
grep -Fxq -- '--repofrompath=pmc-base,https://packages.microsoft.com/azurelinux/3.0/prod/base/aarch64' \
    "${work_dir}/dnf5-args" || fail "ARM64 staleness query used the wrong PMC repository"

if DNF5_ARGS_FILE="${work_dir}/dnf5-args" \
    DNF5_OUTPUT='' \
    DNF5_BIN="${work_dir}/bin/dnf5" \
    BOARD=amd64-usr \
    bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/empty.log" 2>&1; then
    fail "An empty repository query must fail the staleness check"
fi
grep -Fq 'Repository query returned no tracked packages.' "${work_dir}/empty.log" ||
    fail "Empty repository query did not report the expected error"

# Verify start_image_rpm explicitly exports an unexported target BOARD to the checker.
info() { :; }
warn() { :; }
error() { :; }
die() { fail "$*"; }
sudo() { "$@"; }
BUILD_LIBRARY_DIR="${SCRIPT_ROOT}/build_library"
source "${BUILD_LIBRARY_DIR}/rpm/build_image_util.sh"
rpm_install_init() { :; }
rpm_install_package() { :; }
rpm_use_official_repos() { :; }
start_image_uids_rpm() { :; }
download_bootloader_packages_rpm() { :; }

mkdir -p "${work_dir}/library/rpm"
cat > "${work_dir}/library/rpm/check_pmc_staleness.sh" <<EOF
#!/bin/bash
printf '%s' "\${BOARD:-}" > "${work_dir}/checker-board"
EOF
BUILD_LIBRARY_DIR="${work_dir}/library"
BOARD=arm64-usr
start_image_rpm "${work_dir}/root"
[[ "$(cat "${work_dir}/checker-board")" == 'arm64-usr' ]] ||
    fail "start_image_rpm did not pass BOARD to the staleness checker"
