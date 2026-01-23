#!/bin/bash
# Copyright (c) 2026, Microsoft Corporation.

# Build mode configuration for package sources

# Source the package catalog
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${SCRIPT_DIR}/package_catalog.sh" || exit 1

# Build modes:
#   PORTAGE - Use only Portage/Gentoo packages (default, traditional)
#   RPM     - Use Azure Linux RPMs where available, Portage for Flatcar-specific
PACKAGE_SOURCE_MODE="${PACKAGE_SOURCE_MODE:-PORTAGE}"

# RPM installation method (native, docker, or predownload)
# Will be set by init_rpm_environment() but default to empty for PORTAGE mode
RPM_INSTALL_METHOD="${RPM_INSTALL_METHOD:-}"

# Azure Linux repository configuration
RPM_REPO_URL="${RPM_REPO_URL:-https://packages.microsoft.com/azurelinux/3.0/prod/base}"
RPM_RELEASEVER="${RPM_RELEASEVER:-3.0}"
RPM_ARCH="${RPM_ARCH:-x86_64}"

# Determine package source based on mode and package
get_package_source() {
    local portage_pkg="$1"
    local status=$(get_package_status "$portage_pkg")

    # Check for SKIP status first, before any overrides
    if [[ "$status" == "SKIP" ]]; then
        echo "SKIP"
        return
    fi

    # Apply mode-based logic
    case "$PACKAGE_SOURCE_MODE" in
        PORTAGE)
            echo "PORTAGE"
            ;;
        RPM)
            case "$status" in
                RPM)
                    echo "RPM"
                    ;;
                SKIP)
                    # Explicitly skip this package in RPM mode
                    echo "SKIP"
                    ;;
                UNKNOWN)
                    if [[ "$RPM_FALLBACK_TO_PORTAGE" == "true" ]]; then
                        echo "PORTAGE"
                    else
                        echo "MISSING"
                    fi
                    ;;
                *)
                    if [[ "$RPM_FALLBACK_TO_PORTAGE" == "true" ]]; then
                        echo "PORTAGE"
                    else
                        echo "MISSING"
                    fi
                    ;;
            esac
            ;;
        *)
            echo "PORTAGE"
            ;;
    esac
}

# Validate configuration
validate_package_source_config() {
    local errors=0

    info "Validating package source configuration..."
    info "  Mode: ${PACKAGE_SOURCE_MODE}"
    info "  RPM Repo: ${RPM_REPO_URL}"
    info "  Architecture: ${RPM_ARCH}"

    # Check if mode is valid
    case "$PACKAGE_SOURCE_MODE" in
        PORTAGE_ONLY|RPM_ONLY|HYBRID)
            ;;
        *)
            error "Invalid PACKAGE_SOURCE_MODE: ${PACKAGE_SOURCE_MODE}"
            error "Valid values: PORTAGE, RPM"
            ((errors++))
            ;;
    esac

    # Check RPM tools availability if needed
    if [[ "$PACKAGE_SOURCE_MODE" != "PORTAGE" ]]; then
        # Priority order: native RPM > Docker > predownload
        # Native RPM provides full functionality (deps + scriptlets)
        if command -v rpm &>/dev/null; then
            info "✓ RPM tools available in SDK - using native RPM installation"
            info "  Full dependency resolution and scriptlet execution enabled"
            export RPM_INSTALL_METHOD="native"

            if ! command -v tdnf &>/dev/null && ! command -v dnf &>/dev/null; then
                warn "Neither tdnf nor dnf found - will use rpm directly"
            fi
        # Check if Docker is available (for Docker-based RPM installation)
        elif command -v docker &>/dev/null; then
            info "Docker available - will use Docker-based RPM installation"
            info "  Full dependency resolution and scriptlet execution enabled"
            export RPM_INSTALL_METHOD="docker"
        # Fall back to pre-downloaded RPMs if neither RPM nor Docker available
        elif [[ -n "${RPM_STAGING_DIR:-}" ]] && [[ -d "${RPM_STAGING_DIR}" ]]; then
            info "Using pre-downloaded RPMs from ${RPM_STAGING_DIR}"
            warn "  Note: Using rpm2targz - dependencies pre-resolved, scriptlets NOT executed"
            export RPM_INSTALL_METHOD="predownload"
        else
            error "No RPM installation method available"
            error "Please either:"
            error "  1. Rebuild SDK with RPM tools (app-arch/rpm ebuild)"
            error "  2. Install Docker on the host"
            error "  3. Set RPM_STAGING_DIR with pre-downloaded RPMs"
            return 1
        fi

        # Check repo accessibility (basic check)
        if ! curl -s -f -I "${RPM_REPO_URL}/${RPM_ARCH}/repodata/repomd.xml" &>/dev/null; then
            warn "Cannot access RPM repository at ${RPM_REPO_URL}/${RPM_ARCH}"
            warn "Continuing anyway, but RPM installation may fail"
        fi
    fi

    if [[ $errors -gt 0 ]]; then
        return 1
    fi

    return 0
}

# Show package source decisions for a list of packages
show_package_sources() {
    local packages=("$@")

    info "Package source decisions for current configuration:"
    printf "%-50s %-10s %-20s\n" "PACKAGE" "SOURCE" "RPM NAME"
    printf "%-50s %-10s %-20s\n" "$(printf '%.0s-' {1..50})" "$(printf '%.0s-' {1..10})" "$(printf '%.0s-' {1..20})"

    for pkg in "${packages[@]}"; do
        local source=$(get_package_source "$pkg")
        local rpm_name=""
        if [[ "$source" == "RPM" ]]; then
            rpm_name=$(get_rpm_package_name "$pkg")
        fi
        printf "%-50s %-10s %-20s\n" "$pkg" "$source" "$rpm_name"
    done
}

# Export functions
export -f get_package_source
export -f validate_package_source_config
export -f show_package_sources
