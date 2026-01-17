#!/bin/bash
# Copyright (c) 2025 The Flatcar Maintainers.
# Use of this source code is governed by the Apache 2.0 license.

# Unified package installation wrapper supporting both Portage and RPM sources
#
# In HYBRID mode, this module:
# 1. Audits all dependencies Portage would install
# 2. Routes each dependency through the package catalog
# 3. Installs RPM packages first (provides base system utilities)
# 4. Installs remaining Portage packages with --nodeps

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${SCRIPT_DIR}/package_source_config.sh" || exit 1

source "${SCRIPT_DIR}/rpm_install.sh" || exit 1

# Load dependency audit module for RPM mode
if [[ "${PACKAGE_SOURCE_MODE:-PORTAGE}" == "RPM" ]]; then
    source "${SCRIPT_DIR}/dependency_audit.sh" || exit 1
fi

# Unified package installation function
# Routes packages to appropriate installer based on configuration
# In HYBRID mode: audits all deps, routes each through catalog explicitly
install_packages_to_image() {
    local root_fs_dir="$1"; shift
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    info "Processing ${#packages[@]} packages for installation"
    info "Package source mode: ${PACKAGE_SOURCE_MODE}"

    # In RPM mode, use the audit-based explicit installation
    # This ensures ALL dependencies (not just top-level packages) are routed
    # through the catalog and honor RPM/Portage preferences
    if [[ "${PACKAGE_SOURCE_MODE}" == "RPM" ]]; then
        install_rpm_with_audit "${root_fs_dir}" "${packages[@]}"
        return $?
    fi

    # For non-HYBRID modes, use simple categorization (original behavior)
    local portage_pkgs=()
    local rpm_pkgs=()
    local missing_pkgs=()

    # Categorize packages by source
    for pkg in "${packages[@]}"; do
        local source=$(get_package_source "$pkg")

        case "$source" in
            PORTAGE)
                portage_pkgs+=("$pkg")
                ;;
            RPM)
                local rpm_name=$(get_rpm_package_name "$pkg")
                if [[ -n "$rpm_name" ]]; then
                    rpm_pkgs+=("$rpm_name")
                else
                    warn "Package $pkg marked as RPM but no mapping found"
                    missing_pkgs+=("$pkg")
                fi
                ;;
            SKIP)
                info "Skipping package $pkg (marked as SKIP in catalog)"
                ;;
            MISSING)
                warn "Package $pkg not available in current mode: ${PACKAGE_SOURCE_MODE}"
                missing_pkgs+=("$pkg")
                ;;
            *)
                warn "Unknown source '$source' for package $pkg"
                missing_pkgs+=("$pkg")
                ;;
        esac
    done

    # Report package distribution
    if [[ ${#rpm_pkgs[@]} -gt 0 ]]; then
        info "Installing ${#rpm_pkgs[@]} packages from RPM: ${rpm_pkgs[*]}"
    fi

    if [[ ${#portage_pkgs[@]} -gt 0 ]]; then
        info "Installing ${#portage_pkgs[@]} packages from Portage: ${portage_pkgs[*]}"
    fi

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        warn "Missing packages (not available): ${missing_pkgs[*]}"
    fi

    # Install RPM packages first (base system)
    if [[ ${#rpm_pkgs[@]} -gt 0 ]]; then
        rpm_install_to_image "${root_fs_dir}" "${rpm_pkgs[@]}"
        if [[ $? -ne 0 ]]; then
            error "Failed to install RPM packages"
            return 1
        fi
    fi

    # Install Portage packages second (Flatcar-specific)
    if [[ ${#portage_pkgs[@]} -gt 0 ]]; then
        emerge_to_image_portage "${root_fs_dir}" "${portage_pkgs[@]}"
        if [[ $? -ne 0 ]]; then
            error "Failed to install Portage packages"
            return 1
        fi
    fi

    return 0
}

# Query all installed packages from both sources
image_packages_unified() {
    local root_fs_dir="$1"

    # Get packages from both sources and merge
    {
        # Portage packages
        if [[ -d "${root_fs_dir}/var/db/pkg" ]]; then
            image_packages_portage "${root_fs_dir}" 2>/dev/null || true
        fi

        # RPM packages
        if [[ -d "${root_fs_dir}/var/lib/rpm" ]]; then
            rpm_query_packages "${root_fs_dir}" "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}" 2>/dev/null || true
        fi
    } | sort -u
}

# Get metadata from appropriate source
get_metadata_unified() {
    local root_fs_dir="$1"
    local pkg="$2"
    local key="$3"

    # Try RPM first
    if [[ -d "${root_fs_dir}/var/lib/rpm" ]]; then
        local rpm_meta=$(rpm_get_metadata "${root_fs_dir}" "${pkg}" "${key}" 2>/dev/null)
        if [[ -n "$rpm_meta" ]]; then
            echo "$rpm_meta"
            return 0
        fi
    fi

    # Fall back to Portage
    if [[ -d "${root_fs_dir}/var/db/pkg" ]]; then
        # Use existing get_metadata function from build_image_util.sh
        get_metadata "${root_fs_dir}" "${pkg}" "${key}"
        return $?
    fi

    return 1
}

# Export functions
export -f install_packages_to_image
export -f image_packages_unified
export -f get_metadata_unified
