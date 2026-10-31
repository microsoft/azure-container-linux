#!/bin/bash
# check_pmc_staleness.sh
#
# Each ACL SPEC that was forked from PMC carries two tracking macros:
#   %define pmc_base_version  <version we last rebased from>
#   %define pmc_base_release  <release we last rebased from>
#
# This script queries PMC for the latest version-release of each such
# package and fails the build when PMC has moved ahead.
#
# Usage:  check_pmc_staleness.sh <installroot> [staleness_exceptions]
#
set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../" && pwd)"

# Logging
info()  { echo "[INFO]  $*" >&2; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; }

INSTALLROOT="${1:?Usage: check_pmc_staleness.sh <installroot>}"
if [[ ! -d "${INSTALLROOT}" ]]; then
    error "Install root does not exist: ${INSTALLROOT}"
    exit 1
fi
DNF5_BIN="${DNF5_BIN:-/usr/bin/dnf5}"
RPM_BIN="${RPM_BIN:-rpm}"
snapshot_args=()
if [[ -n "${PACKAGE_SNAPSHOT_TIME:-}" ]]; then
    if [[ ! "${PACKAGE_SNAPSHOT_TIME}" =~ ^[1-9][0-9]{9}$ ]]; then
        error "PACKAGE_SNAPSHOT_TIME must be a ten-digit Unix UTC timestamp"
        exit 1
    fi
    if ! "${DNF5_BIN}" --help | grep -- '--snapshot-time' >/dev/null; then
        error "SDK DNF5 does not support --snapshot-time; rebuild the SDK with the snapshot plugin"
        exit 1
    fi
    snapshot_args+=(--snapshot-time="${PACKAGE_SNAPSHOT_TIME}" --snapshot-exclude-repos=azurelinux-local-cache)
fi

# Use BOARD when available so cross-architecture builds query the target repos.
case "${BOARD:-}" in
    arm64-usr)
        ARCH="aarch64"
        forcearch_args=(--forcearch=aarch64)
        ;;
    amd64-usr)
        ARCH="x86_64"
        forcearch_args=(--forcearch=x86_64)
        ;;
    *)
        ARCH="$(uname -m)"
        forcearch_args=()
        ;;
esac

# Second arg: space-separated list of packages exempt from staleness failure
STALENESS_EXCEPTIONS="${2:-}"
declare -A EXCEPTIONS=()
for _exc in ${STALENESS_EXCEPTIONS}; do
    EXCEPTIONS["${_exc}"]=1
done
set +u
if [[ ${#EXCEPTIONS[@]} -gt 0 ]]; then
    info "Staleness exceptions: ${!EXCEPTIONS[*]}"
fi
set -u

SPECS_DIR="${REPO_ROOT}/acl/SPECS"
STALE=0

# Mark a package as stale - respects exception list
# Usage: mark_stale <pkg> <base_ver> <base_rel> <upstream_vr>
mark_stale() {
    local pkg="$1" base_ver="$2" base_rel="$3" upstream="$4"
    set +u; local _exc="${EXCEPTIONS[${pkg}]+x}"; set -u
    if [[ -n "${_exc}" ]]; then
        warn "  ${pkg}: STALE (EXCEPTED) - based on ${base_ver}-${base_rel}, upstream is at ${upstream}"
    else
        warn "  ${pkg}: STALE - based on ${base_ver}-${base_rel}, upstream is at ${upstream}"
        STALE=$((STALE + 1))
    fi
}

# Compare two RPM version-release strings and print -1, 0, or 1.
rpm_compare() {
    local left="$1" right="$2" result
    result="$("${RPM_BIN}" --eval "%{lua: print(rpm.vercmp([==[${left}]==], [==[${right}]==]))}")" || {
        error "Failed to compare RPM versions: ${left} and ${right}"
        return 1
    }
    case "${result}" in
        -1|0|1) printf '%s\n' "${result}" ;;
        *) error "Unexpected RPM comparison result '${result}' for ${left} and ${right}"; return 1 ;;
    esac
}

spec_applies_to_arch() {
    local preprocessed="$1" constraint
    constraint="$(sed -n 's/^ExclusiveArch:[[:space:]]*//p' <<< "${preprocessed}" | head -n1)"
    if [[ -n "${constraint}" ]]; then
        [[ " ${constraint} " == *" ${ARCH} "* ]] || return 1
    fi
    constraint="$(sed -n 's/^ExcludeArch:[[:space:]]*//p' <<< "${preprocessed}" | head -n1)"
    if [[ -n "${constraint}" ]]; then
        [[ " ${constraint} " != *" ${ARCH} "* ]] || return 1
    fi
    return 0
}

# Collect packages that have pmc_base tracking macros
declare -A BASE_VER BASE_REL
for spec_file in "${SPECS_DIR}"/*/*.spec; do
    bv="$(grep -m1 '^%define pmc_base_version' "${spec_file}" | awk '{print $3}')" || true
    br="$(grep -m1 '^%define pmc_base_release' "${spec_file}" | awk '{print $3}')" || true
    [[ -z "${bv}" || -z "${br}" ]] && continue
    preprocessed="$(rpmspec -P --target "${ARCH}" "${spec_file}")" || {
        error "Failed to preprocess ${spec_file} for ${ARCH}"
        exit 1
    }
    pkg="$(sed -n 's/^Name:[[:space:]]*//p' <<< "${preprocessed}" | head -n1)"
    [[ -z "${pkg}" ]] && continue
    spec_applies_to_arch "${preprocessed}" || continue
    BASE_VER["${pkg}"]="${bv}"
    BASE_REL["${pkg}"]="${br}"
done

if [[ ${#BASE_VER[@]} -eq 0 ]]; then
    info "No packages with pmc_base tracking macros found."
    exit 0
fi

# Determine which upstream to check against:
#   - Fasttrack builds: FASTTRACK_REPO_FILE is set -> check against fasttrack repo
#     (has the latest packages before they reach PMC)
#   - Prod/dev builds: FASTTRACK_REPO_FILE not set -> check against PMC directly
info "=== PMC Staleness Check ==="

declare -A UPSTREAM
pkg_list="${!BASE_VER[*]}"

PMC_BASE="https://packages.microsoft.com/azurelinux/3.0/prod/base/${ARCH}"
PMC_EXTENDED="https://packages.microsoft.com/azurelinux/3.0/prod/extended/${ARCH}"

if [[ -n "${FASTTRACK_REPO_FILE:-}" ]]; then
    if [[ ! -f "${FASTTRACK_REPO_FILE}" ]]; then
        error "FASTTRACK_REPO_FILE set but file not found: ${FASTTRACK_REPO_FILE}"
        exit 1
    fi
    # Fasttrack build: query fasttrack + PMC (fasttrack has latest, PMC covers the rest)
    FASTTRACK_URL="$(awk '/^[[:space:]]*baseurl[[:space:]]*=/ {sub(/^[[:space:]]*baseurl[[:space:]]*=[[:space:]]*/, ""); print; exit}' "${FASTTRACK_REPO_FILE}")"
    if [[ -z "${FASTTRACK_URL}" ]]; then
        error "No baseurl found in ${FASTTRACK_REPO_FILE}"
        exit 1
    fi
    info "Checking against fasttrack repo: ${FASTTRACK_URL}"
    info "  + PMC base: ${PMC_BASE}"
    info "  + PMC extended: ${PMC_EXTENDED}"
    info "Querying for ${#BASE_VER[@]} packages..."

    dnf_output="$(timeout 120 "${DNF5_BIN}" repoquery \
        --repofrompath=fasttrack-check,${FASTTRACK_URL} \
        --repofrompath=pmc-base,${PMC_BASE} \
        --repofrompath=pmc-extended,${PMC_EXTENDED} \
        --repo=fasttrack-check --repo=pmc-base --repo=pmc-extended \
        --setopt=fasttrack-check.gpgcheck=0 \
        --setopt=pmc-base.gpgcheck=0 \
        --setopt=pmc-extended.gpgcheck=0 \
        "${forcearch_args[@]}" \
        "${snapshot_args[@]}" \
        --available --latest-limit=1 \
        --queryformat="%{name}|%{epoch}:%{version}-%{release}\n" \
        ${pkg_list} 2>/dev/null)" || { error "Failed to query FastTrack and PMC repositories"; exit 1; }
else
    # Prod/dev build: check against PMC directly
    info "Checking against PMC (no fasttrack repo configured)"
    info "  base: ${PMC_BASE}"
    info "  extended: ${PMC_EXTENDED}"
    info "Querying for ${#BASE_VER[@]} packages..."

    dnf_output="$(timeout 120 "${DNF5_BIN}" repoquery \
        --repofrompath=pmc-base,${PMC_BASE} \
        --repofrompath=pmc-extended,${PMC_EXTENDED} \
        --repo=pmc-base --repo=pmc-extended \
        --setopt=pmc-base.gpgcheck=0 \
        --setopt=pmc-extended.gpgcheck=0 \
        "${forcearch_args[@]}" \
        "${snapshot_args[@]}" \
        --available --latest-limit=1 \
        --queryformat="%{name}|%{epoch}:%{version}-%{release}\n" \
        ${pkg_list} 2>/dev/null)" || { error "Failed to query PMC repositories"; exit 1; }
fi

# Parse results into UPSTREAM associative array
# Note: use "set +u" around array access to avoid "unbound variable" error
# on bash <4.4 when the associative array is empty.
while IFS='|' read -r name vr extra; do
    [[ -z "${name}" ]] && continue
    set +u
    [[ -n "${BASE_VER[${name}]+x}" ]] || { set -u; continue; }
    set -u
    if [[ -z "${vr}" || -n "${extra}" || ! "${vr}" =~ ^[0-9]+:.+-.+$ ]]; then
        error "Malformed repository result for tracked package ${name}: ${name}|${vr}${extra:+|${extra}}"
        exit 1
    fi
    set +u
    current="${UPSTREAM[${name}]:-}"
    set -u
    # Strip dist tag (".azl3")
    candidate="${vr%.azl*}"
    if [[ -z "${current}" ]]; then
        UPSTREAM["${name}"]="${candidate}"
    else
        comparison="$(rpm_compare "${current}" "${candidate}")" || exit 1
        if [[ "${comparison}" == "-1" ]]; then
            UPSTREAM["${name}"]="${candidate}"
        fi
    fi
done <<< "${dnf_output}"

set +u
upstream_count=${#UPSTREAM[@]}
set -u
info "  Found ${upstream_count} of ${#BASE_VER[@]} packages in upstream"
missing=0
for pkg in "${!BASE_VER[@]}"; do
    set +u
    found="${UPSTREAM[${pkg}]+x}"
    set -u
    if [[ -z "${found}" ]]; then
        error "Tracked package ${pkg} was not found in the target upstream repositories."
        missing=$((missing + 1))
    fi
done
if [[ ${missing} -gt 0 ]]; then
    error "Repository query omitted ${missing} of ${#BASE_VER[@]} tracked packages."
    exit 1
fi

# Compare each tracked package against upstream
for pkg in "${!BASE_VER[@]}"; do
    base_ver="${BASE_VER[${pkg}]}"
    base_rel="${BASE_REL[${pkg}]}"
    set +u
    pmc="${UPSTREAM[${pkg}]:-}"
    set -u

    base_vr="0:${base_ver}-${base_rel}"
    comparison="$(rpm_compare "${base_vr}" "${pmc}")" || exit 1
    case "${comparison}" in
        -1) mark_stale "${pkg}" "${base_ver}" "${base_rel}" "${pmc}" ;;
        0) info "  ${pkg}: OK" ;;
        1) info "  ${pkg}: OK (ACL version newer than upstream)" ;;
    esac
done


info "=== PMC Staleness Check Complete ==="

if [[ ${STALE} -gt 0 ]]; then
    warn "${STALE} package(s) need a PMC rebase."
    warn "Update the affected SPEC(s): rebase, then bump pmc_base_version/pmc_base_release."
    error "Build blocked - rebase stale packages first."
    exit 1
else
    info "All ACL packages are up-to-date with upstream."
fi
