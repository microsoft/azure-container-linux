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
if [[ "${1:-}" == "--help" ]]; then
    echo '  --snapshot-time=TIMESTAMP'
    exit 0
fi
printf '%s\n' "$@" > "${DNF5_ARGS_FILE}"
if [[ -n "${EXPECTED_SNAPSHOT_TIME:-}" ]] &&
    printf '%s\n' "$@" | grep -Fxq -- "--snapshot-time=${EXPECTED_SNAPSHOT_TIME}"; then
    printf '%s' "${DNF5_SNAPSHOT_OUTPUT:-}"
else
    printf '%s' "${DNF5_OUTPUT:-}"
fi
EOF
chmod +x "${work_dir}/bin/dnf5"

declare -a amd64_packages=() arm64_packages=()
tracked_package=""
tracked_name=""
tracked_version=""
for spec_file in "${SCRIPT_ROOT}"/acl/SPECS/*/*.spec; do
    base_version="$(awk '/^%define pmc_base_version/ {print $3; exit}' "${spec_file}")"
    base_release="$(awk '/^%define pmc_base_release/ {print $3; exit}' "${spec_file}")"
    if [[ -n "${base_version}" && -n "${base_release}" ]]; then
        package_name="$(rpmspec -P --target x86_64 "${spec_file}" 2>/dev/null | sed -n 's/^Name:[[:space:]]*//p' | head -n1)"
        [[ -n "${package_name}" ]] || fail "Could not resolve package name from ${spec_file}"
        package_line="${package_name}|0:${base_version}-${base_release}.azl3"
        amd64_packages+=("${package_line}")
        exclusive_arch="$(sed -n 's/^ExclusiveArch:[[:space:]]*//p' "${spec_file}" | head -n1)"
        if [[ -z "${exclusive_arch}" || " $(rpm --eval "${exclusive_arch}") " == *" aarch64 "* ]]; then
            arm64_packages+=("${package_line}")
        fi
        if [[ -z "${tracked_package}" ]]; then
            tracked_package="${package_line}"
            tracked_name="${package_name}"
            tracked_version="${base_version}"
        fi
    fi
done
[[ -n "${tracked_package}" ]] || fail "No PMC-tracked package found for the test fixture"
amd64_output="$(printf '%s\n' "${amd64_packages[@]}")"
arm64_output="$(printf '%s\n' "${arm64_packages[@]}")"

replace_first_package() {
    local replacement="$1" output="$2"
    printf '%s\n' "${replacement}"
    printf '%s\n' "${output}" | tail -n +2
}

replace_package() {
    local name="$1" replacement="$2" output="$3"
    awk -F '|' -v name="${name}" -v replacement="${replacement}" \
        '$1 == name { print replacement; next } { print }' <<< "${output}"
}

DNF5_ARGS_FILE="${work_dir}/dnf5-args" \
DNF5_OUTPUT="${arm64_output}" \
DNF5_BIN="${work_dir}/bin/dnf5" \
BOARD=arm64-usr \
bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/arm64.log" 2>&1

grep -Fxq -- '--forcearch=aarch64' "${work_dir}/dnf5-args" ||
    fail "ARM64 staleness query did not pass --forcearch=aarch64"
grep -Fxq -- '--repofrompath=pmc-base,https://packages.microsoft.com/azurelinux/3.0/prod/base/aarch64' \
    "${work_dir}/dnf5-args" || fail "ARM64 staleness query used the wrong PMC repository"

DNF5_ARGS_FILE="${work_dir}/dnf5-amd64-args" \
DNF5_OUTPUT="${amd64_output}" \
DNF5_BIN="${work_dir}/bin/dnf5" \
BOARD=amd64-usr \
bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/equal.log" 2>&1
grep -Fxq -- '--forcearch=x86_64' "${work_dir}/dnf5-amd64-args" ||
    fail "AMD64 staleness query did not pass --forcearch=x86_64"
grep -Fxq -- '--repofrompath=pmc-base,https://packages.microsoft.com/azurelinux/3.0/prod/base/x86_64' \
    "${work_dir}/dnf5-amd64-args" || fail "AMD64 staleness query used the wrong PMC repository"
grep -Fxq -- '--queryformat=%{name}|%{epoch}:%{version}-%{release}\n' \
    "${work_dir}/dnf5-amd64-args" || fail "Staleness query did not request structured full EVR output"

grep -Fxq 'containerd2|0:2.3.7-1.azl3' <<< "${amd64_output}" ||
    fail "containerd2 was not tracked under its macro-expanded RPM name"
containerd_output="$(replace_package containerd2 'containerd2|0:2.3.8-1.azl3' "${amd64_output}")"
if DNF5_ARGS_FILE="${work_dir}/dnf5-containerd2-args" \
    DNF5_OUTPUT="${containerd_output}" DNF5_BIN="${work_dir}/bin/dnf5" BOARD=amd64-usr \
    bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/containerd2.log" 2>&1; then
    fail "A newer upstream containerd2 must fail the staleness check"
fi
grep -Fq 'containerd2: STALE' "${work_dir}/containerd2.log" ||
    fail "A newer upstream containerd2 did not report STALE"

for failure_case in empty unknown partial; do
    case "${failure_case}" in
        empty) failure_output='' ;;
        unknown) failure_output='not-tracked|0:1-1.azl3' ;;
        partial) failure_output="${tracked_package}" ;;
    esac
    if DNF5_ARGS_FILE="${work_dir}/dnf5-${failure_case}-args" \
        DNF5_OUTPUT="${failure_output}" \
        DNF5_BIN="${work_dir}/bin/dnf5" \
        BOARD=amd64-usr \
        bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/${failure_case}.log" 2>&1; then
        fail "${failure_case} repository output must fail the staleness check"
    fi
    grep -Fq 'Repository query omitted' "${work_dir}/${failure_case}.log" ||
        fail "${failure_case} repository output did not report omitted tracked packages"
done

malformed_output="$(replace_first_package "${tracked_name}|not-an-evr" "${amd64_output}")"
if DNF5_ARGS_FILE="${work_dir}/dnf5-malformed-output-args" \
    DNF5_OUTPUT="${malformed_output}" DNF5_BIN="${work_dir}/bin/dnf5" BOARD=amd64-usr \
    bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/malformed-output.log" 2>&1; then
    fail "A malformed result for a tracked package must fail the staleness check"
fi
grep -Fq "Malformed repository result for tracked package ${tracked_name}" "${work_dir}/malformed-output.log" ||
    fail "A malformed tracked-package result did not report the expected error"

cat > "${work_dir}/bin/rpm-fail" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "${work_dir}/bin/rpm-fail"
duplicate_output="${amd64_output}"$'\n'"${tracked_package}"
if DNF5_ARGS_FILE="${work_dir}/dnf5-comparison-failure-args" \
    DNF5_OUTPUT="${duplicate_output}" DNF5_BIN="${work_dir}/bin/dnf5" \
    RPM_BIN="${work_dir}/bin/rpm-fail" BOARD=amd64-usr \
    bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/comparison-failure.log" 2>&1; then
    fail "An RPM comparison failure while selecting candidates must fail the staleness check"
fi
grep -Fq 'Failed to compare RPM versions' "${work_dir}/comparison-failure.log" ||
    fail "An RPM comparison failure did not report the expected error"

duplicate_newer_output="${amd64_output}"$'\n'"${tracked_name}|0:${tracked_version}-999999.azl3"
if DNF5_ARGS_FILE="${work_dir}/dnf5-duplicate-newer-args" \
    DNF5_OUTPUT="${duplicate_newer_output}" DNF5_BIN="${work_dir}/bin/dnf5" BOARD=amd64-usr \
    bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/duplicate-newer.log" 2>&1; then
    fail "The highest duplicate repository candidate must control the staleness result"
fi
grep -Fq "${tracked_name}: STALE" "${work_dir}/duplicate-newer.log" ||
    fail "The highest duplicate repository candidate was not selected"

stale_output="$(replace_first_package "${tracked_name}|0:${tracked_version}-999999.azl3" "${amd64_output}")"
if DNF5_ARGS_FILE="${work_dir}/dnf5-stale-args" \
    DNF5_OUTPUT="${stale_output}" DNF5_BIN="${work_dir}/bin/dnf5" BOARD=amd64-usr \
    bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/stale.log" 2>&1; then
    fail "A newer upstream package must fail the staleness check"
fi
grep -Fq "${tracked_name}: STALE" "${work_dir}/stale.log" ||
    fail "A newer upstream package did not report STALE"

older_output="$(replace_first_package "${tracked_name}|0:0-1.azl3" "${amd64_output}")"
DNF5_ARGS_FILE="${work_dir}/dnf5-older-args" \
DNF5_OUTPUT="${older_output}" DNF5_BIN="${work_dir}/bin/dnf5" BOARD=amd64-usr \
bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/older.log" 2>&1
grep -Fq "${tracked_name}: OK (ACL version newer than upstream)" "${work_dir}/older.log" ||
    fail "An older upstream package did not report the ACL version as newer"

epoch_output="$(replace_first_package "${tracked_name}|1:0-1.azl3" "${amd64_output}")"
if DNF5_ARGS_FILE="${work_dir}/dnf5-epoch-args" \
    DNF5_OUTPUT="${epoch_output}" DNF5_BIN="${work_dir}/bin/dnf5" BOARD=amd64-usr \
    bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/epoch.log" 2>&1; then
    fail "A newer upstream epoch must fail the staleness check"
fi
grep -Fq "${tracked_name}: STALE" "${work_dir}/epoch.log" ||
    fail "A newer upstream epoch did not report STALE"

# A post-cutoff PMC package must not change a build pinned to an earlier snapshot.
snapshot_time=1793059200
post_cutoff_output="${stale_output}"
for query_mode in pmc fasttrack; do
    fasttrack_repo_file=""
    if [[ "${query_mode}" == "fasttrack" ]]; then
        fasttrack_repo_file="${work_dir}/fasttrack.repo"
        printf '[fasttrack-preview]\nbaseurl=https://example.invalid/fasttrack\n' > "${fasttrack_repo_file}"
    fi
    DNF5_ARGS_FILE="${work_dir}/dnf5-${query_mode}-snapshot-args" \
    DNF5_OUTPUT="${post_cutoff_output}" \
    DNF5_SNAPSHOT_OUTPUT="${amd64_output}" \
    DNF5_BIN="${work_dir}/bin/dnf5" \
    EXPECTED_SNAPSHOT_TIME="${snapshot_time}" \
    PACKAGE_SNAPSHOT_TIME="${snapshot_time}" \
    FASTTRACK_REPO_FILE="${fasttrack_repo_file}" \
    BOARD=amd64-usr \
    bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/${query_mode}-snapshot.log" 2>&1 ||
        fail "${query_mode} staleness query changed outcome due to a post-cutoff package"
    grep -Fxq -- "--snapshot-time=${snapshot_time}" "${work_dir}/dnf5-${query_mode}-snapshot-args" ||
        fail "${query_mode} staleness query did not preserve PACKAGE_SNAPSHOT_TIME"
    grep -Fxq -- '--snapshot-exclude-repos=azurelinux-local-cache' "${work_dir}/dnf5-${query_mode}-snapshot-args" ||
        fail "${query_mode} staleness query did not apply the snapshot exclusion policy"
    if [[ "${query_mode}" == "fasttrack" ]]; then
        grep -Fxq -- '--repofrompath=fasttrack-check,https://example.invalid/fasttrack' \
            "${work_dir}/dnf5-${query_mode}-snapshot-args" ||
            fail "FastTrack staleness query did not include the configured preview repo"
        grep -Fxq -- '--repo=fasttrack-check' "${work_dir}/dnf5-${query_mode}-snapshot-args" ||
            fail "FastTrack staleness query did not enable the preview repo"
    fi
done

if DNF5_ARGS_FILE="${work_dir}/dnf5-missing-fasttrack-args" \
    DNF5_OUTPUT="${amd64_output}" DNF5_BIN="${work_dir}/bin/dnf5" \
    FASTTRACK_REPO_FILE="${work_dir}/missing-fasttrack.repo" BOARD=amd64-usr \
    bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/missing-fasttrack.log" 2>&1; then
    fail "A configured but missing FastTrack repo file must fail"
fi
grep -Fq 'FASTTRACK_REPO_FILE set but file not found' "${work_dir}/missing-fasttrack.log" ||
    fail "Missing FastTrack repo file did not report the expected error"

malformed_fasttrack_repo="${work_dir}/malformed-fasttrack.repo"
printf '[fasttrack-preview]\nname=missing-baseurl\n' > "${malformed_fasttrack_repo}"
if DNF5_ARGS_FILE="${work_dir}/dnf5-malformed-fasttrack-args" \
    DNF5_OUTPUT="${amd64_output}" DNF5_BIN="${work_dir}/bin/dnf5" \
    FASTTRACK_REPO_FILE="${malformed_fasttrack_repo}" BOARD=amd64-usr \
    bash "${CHECKER}" "${work_dir}/root" > "${work_dir}/malformed-fasttrack.log" 2>&1; then
    fail "A FastTrack repo file without baseurl must fail"
fi
grep -Fq 'No baseurl found' "${work_dir}/malformed-fasttrack.log" ||
    fail "Malformed FastTrack repo file did not report the expected error"

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
printf '%s' "\${PACKAGE_SNAPSHOT_TIME:-}" > "${work_dir}/checker-snapshot-time"
EOF
BUILD_LIBRARY_DIR="${work_dir}/library"
BOARD=arm64-usr
PACKAGE_SNAPSHOT_TIME=1793059200
start_image_rpm "${work_dir}/root"
[[ "$(cat "${work_dir}/checker-board")" == 'arm64-usr' ]] ||
    fail "start_image_rpm did not pass BOARD to the staleness checker"
[[ "$(cat "${work_dir}/checker-snapshot-time")" == '1793059200' ]] ||
    fail "start_image_rpm did not pass PACKAGE_SNAPSHOT_TIME to the staleness checker"
rm -f "${work_dir}/library/rpm/check_pmc_staleness.sh"
error() { echo "$*" >&2; }
if start_image_rpm "${work_dir}/root" > "${work_dir}/missing-checker.log" 2>&1; then
    fail "start_image_rpm must fail when the mandatory PMC staleness checker is missing"
fi
grep -Fq 'PMC staleness checker not found' "${work_dir}/missing-checker.log" ||
    fail "Missing PMC staleness checker did not report the expected error"
