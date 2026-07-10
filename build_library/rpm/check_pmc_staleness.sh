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
# Usage:  check_pmc_staleness.sh <installroot>
#
set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../" && pwd)"

# Logging
info()  { echo "[INFO]  $*" >&2; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; }

INSTALLROOT="${1:?Usage: check_pmc_staleness.sh <installroot>}"

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

# Is $1 older than $2?  (version strings)
is_older() {
    if command -v rpmdev-vercmp &>/dev/null; then
        rpmdev-vercmp "$1" "$2" 2>/dev/null | grep -q "is older"
    else
        # Fallback: version-aware comparison via sort -V
        [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" && "$1" != "$2" ]]
    fi
}

# Collect packages that have pmc_base tracking macros
declare -A BASE_VER BASE_REL
for spec_file in "${SPECS_DIR}"/*/*.spec; do
    # Use the RPM Name: field
    pkg="$(grep -m1 '^Name:' "${spec_file}" | awk '{print $2}')" || true
    [[ -z "${pkg}" ]] && continue
    bv="$(grep -m1 '^%define pmc_base_version' "${spec_file}" | awk '{print $3}')" || true
    br="$(grep -m1 '^%define pmc_base_release' "${spec_file}" | awk '{print $3}')" || true
    [[ -z "${bv}" || -z "${br}" ]] && continue
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

# Detect architecture - use BOARD if set (handles cross-arch builds on x86_64 hosts)
if [[ "${BOARD:-}" == "arm64-usr" ]]; then
    ARCH="aarch64"
else
    ARCH="$(uname -m)"
fi
declare -A UPSTREAM
pkg_list="${!BASE_VER[*]}"

PMC_BASE="https://packages.microsoft.com/azurelinux/3.0/prod/base/${ARCH}"
PMC_EXTENDED="https://packages.microsoft.com/azurelinux/3.0/prod/extended/${ARCH}"

if [[ -n "${FASTTRACK_REPO_FILE:-}" ]] && [[ -f "${FASTTRACK_REPO_FILE}" ]]; then
    # Fasttrack build: query fasttrack + PMC (fasttrack has latest, PMC covers the rest)
    FASTTRACK_URL="$(grep -m1 '^baseurl=' "${FASTTRACK_REPO_FILE}" | cut -d= -f2-)"
    info "Checking against fasttrack repo: ${FASTTRACK_URL}"
    info "  + PMC base: ${PMC_BASE}"
    info "  + PMC extended: ${PMC_EXTENDED}"
    info "Querying for ${#BASE_VER[@]} packages..."

    dnf_output="$(timeout 120 /usr/bin/dnf5 repoquery \
        --repofrompath=fasttrack-check,${FASTTRACK_URL} \
        --repofrompath=pmc-base,${PMC_BASE} \
        --repofrompath=pmc-extended,${PMC_EXTENDED} \
        --repo=fasttrack-check --repo=pmc-base --repo=pmc-extended \
        --setopt=fasttrack-check.gpgcheck=0 \
        --setopt=pmc-base.gpgcheck=0 \
        --setopt=pmc-extended.gpgcheck=0 \
        --available --latest-limit=1 \
        --queryformat="%{name} %{version}-%{release}\n" \
        ${pkg_list} 2>/dev/null)" || { warn "Failed to query repos - skipping staleness check"; exit 0; }
else
    # Prod/dev build: check against PMC directly
    info "Checking against PMC (no fasttrack repo configured)"
    info "  base: ${PMC_BASE}"
    info "  extended: ${PMC_EXTENDED}"
    info "Querying for ${#BASE_VER[@]} packages..."

    dnf_output="$(timeout 120 /usr/bin/dnf5 repoquery \
        --repofrompath=pmc-base,${PMC_BASE} \
        --repofrompath=pmc-extended,${PMC_EXTENDED} \
        --repo=pmc-base --repo=pmc-extended \
        --setopt=pmc-base.gpgcheck=0 \
        --setopt=pmc-extended.gpgcheck=0 \
        --available --latest-limit=1 \
        --queryformat="%{name} %{version}-%{release}\n" \
        ${pkg_list} 2>/dev/null)" || { warn "Failed to query PMC repos - skipping staleness check"; exit 0; }
fi

# Parse results into UPSTREAM associative array
# Note: use "set +u" around array access to avoid "unbound variable" error
# on bash <4.4 when the associative array is empty.
while IFS=' ' read -r name vr; do
    [[ -z "${name}" ]] && continue
    [[ -z "${vr}" ]] && continue
    # Only keep the first (latest) result per package
    set +u
    [[ -n "${UPSTREAM[${name}]+x}" ]] && { set -u; continue; }
    set -u
    # Strip dist tag (".azl3")
    UPSTREAM["${name}"]="${vr%.azl*}"
done <<< "${dnf_output}"

set +u
info "  Found ${#UPSTREAM[@]} of ${#BASE_VER[@]} packages in upstream"
set -u

# Compare each tracked package against upstream
for pkg in "${!BASE_VER[@]}"; do
    base_ver="${BASE_VER[${pkg}]}"
    base_rel="${BASE_REL[${pkg}]}"
    set +u
    pmc="${UPSTREAM[${pkg}]:-}"
    set -u

    if [[ -z "${pmc}" ]]; then
        info "  ${pkg}: not found in upstream repos - skipping"
        continue
    fi

    pmc_ver="${pmc%%-*}"
    pmc_rel="${pmc#*-}"

    # Compare versions first, then releases
    if [[ "${pmc_ver}" != "${base_ver}" ]]; then
        if is_older "${base_ver}" "${pmc_ver}"; then
            mark_stale "${pkg}" "${base_ver}" "${base_rel}" "${pmc}"
        else
            info "  ${pkg}: OK (ACL version newer than upstream)"
        fi
    elif [[ "${pmc_rel}" -gt "${base_rel}" ]] 2>/dev/null; then
        mark_stale "${pkg}" "${base_ver}" "${base_rel}" "${pmc}"
    else
        info "  ${pkg}: OK"
    fi
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
