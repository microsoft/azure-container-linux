#!/bin/bash
# Copyright (c) 2025 The Flatcar Maintainers.
# Use of this source code is governed by the Apache 2.0 license.

# Dependency auditing and explicit installation for hybrid builds
#
# This module provides:
# 1. Audit mechanism to discover all dependencies Portage would install
# 2. Explicit installation that routes each dependency through the catalog

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Ensure we have logging functions
if ! type info &>/dev/null; then
    info() { echo "INFO: $*"; }
    warn() { echo "WARN: $*" >&2; }
    error() { echo "ERROR: $*" >&2; }
fi


# Get all dependencies for a package using emerge --pretend
# Returns list of category/package names that would be installed
# Usage: get_portage_dependencies "/path/to/root" "coreos-base/coreos"
get_portage_dependencies() {
    local root_fs_dir="$1"
    local package="$2"

    # Parse emerge output to extract package atoms
    # Format: [ebuild  N     ] category/package-version::repository
    # Use same environment as emerge_to_image_portage
    # In RPM mode, use --emptytree to see all deps without needing binary packages
    # In PORTAGE mode, use --usepkgonly to match actual build behavior
    local emerge_flags="--pretend"
    if [[ "${PACKAGE_SOURCE_MODE:-PORTAGE}" == "RPM" ]]; then
        # RPM: Don't require binary packages, just resolve dependencies
        emerge_flags+=" --emptytree"
    else
        # PORTAGE: Use binary packages as in normal builds
        emerge_flags+=" --usepkgonly"
    fi

    # Determine the correct config root
    # For sysext builds, use the board config; for image builds, use BUILD_DIR/configroot
    local config_root="/build/${BOARD:-amd64-usr}"
    if [[ -d "${BUILD_DIR}/configroot" ]]; then
        config_root="${BUILD_DIR}/configroot"
    fi

    local emerge_output
    info "Resolving dependencies for ${package} using: emerge ${emerge_flags}"
    emerge_output=$(emerge-amd64-usr --pretend --verbose --tree "${package}" 2>&1) || true

    # Parse [binary N] or [ebuild N] lines
    # Format: [ebuild  N     ] category/package-version:slot/subslot::repo  USE="..." SIZE
    # We want to extract just "category/package"
    local parsed_pkgs
    parsed_pkgs=$(echo "$emerge_output" | \
        grep -E '^\[(binary|ebuild)' | \
        sed -E 's/^\[[^]]+\]\s+//' | \
        sed -E 's/-[0-9]+(\.[0-9]+)*.*$//' | \
        sort -u) || true

    if [[ -z "$parsed_pkgs" ]]; then
        warn "No packages found in emerge output for ${package}. Checking for errors..."
        # Check for common issues
        if echo "$emerge_output" | grep -q "USE changes are necessary"; then
            warn "USE flag changes required - check package.use configuration"
        fi
        if echo "$emerge_output" | grep -q "blocked by"; then
            warn "Package blockers detected"
        fi
        info Emerge output:
        info "$emerge_output"
        info "End of emerge output."

        exit 1
    fi

    echo "$parsed_pkgs"
}

# Get dependencies for multiple packages
# Usage: get_all_dependencies "/path/to/root" "pkg1" "pkg2" ...
get_all_dependencies() {
    local root_fs_dir="$1"; shift
    local packages=("$@")
    local all_deps=()

    for pkg in "${packages[@]}"; do
        # Check if package is already in RPM catalog with RPM status
        local pkg_status=$(get_package_status "$pkg")

        if [[ "$pkg_status" == "RPM" ]]; then
            # Package has RPM mapping - add it directly without resolving Portage deps
            info "Package $pkg is in RPM catalog - skipping dependency resolution"
            all_deps+=("$pkg")
        else
            # Package not in RPM catalog - resolve Portage dependencies
            info "Resolving Portage dependencies for $pkg (status: $pkg_status)"
            local deps
            deps=$(get_portage_dependencies "${root_fs_dir}" "${pkg}")
            while IFS= read -r dep; do
                [[ -n "$dep" ]] && all_deps+=("$dep")
            done <<< "$deps"
        fi
    done

    # Return unique sorted list
    if [[ ${#all_deps[@]} -gt 0 ]]; then
        printf '%s\n' "${all_deps[@]}" | sort -u
    fi
}

# Audit dependencies and report catalog status for each
# Usage: audit_dependencies "/path/to/root" "coreos-base/coreos"
# Returns: tab-separated list of "package\tsource\trpm_name"
audit_dependencies() {
    local root_fs_dir="$1"
    local package="$2"

    info "Auditing dependencies for: ${package}"

    local deps
    deps=$(get_portage_dependencies "${root_fs_dir}" "${package}")

    local rpm_count=0
    local portage_count=0
    local skip_count=0
    local missing_count=0

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue

        local source=$(get_package_source "$dep")
        local rpm_name=""

        case "$source" in
            RPM)
                rpm_name=$(get_rpm_package_name "$dep")
                ((rpm_count++))
                ;;
            PORTAGE)
                ((portage_count++))
                ;;
            SKIP)
                ((skip_count++))
                ;;
            *)
                ((missing_count++))
                ;;
        esac

        printf '%s\t%s\t%s\n' "$dep" "$source" "${rpm_name:-N/A}"
    done <<< "$deps"

    info "Dependency audit summary:"
    info "  RPM:     ${rpm_count} packages"
    info "  Portage: ${portage_count} packages (Flatcar-specific)"
    info "  Skip:    ${skip_count} packages"
    info "  Missing: ${missing_count} packages (not in catalog)"
}

# Install packages explicitly, honoring catalog preferences
# This replaces implicit Portage dependency resolution with explicit routing
# Usage: install_packages_explicit "/path/to/root" "pkg1" "pkg2" ...
install_packages_explicit() {
    local root_fs_dir="$1"; shift
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    info "Explicit package installation: ${#packages[@]} packages"

    # Categorize all packages by their catalog source
    local rpm_pkgs=()
    local portage_pkgs=()
    local skip_pkgs=()

    for pkg in "${packages[@]}"; do
        local source=$(get_package_source "$pkg")

        case "$source" in
            RPM)
                local rpm_name=$(get_rpm_package_name "$pkg")
                if [[ -n "$rpm_name" ]]; then
                    rpm_pkgs+=("$rpm_name")
                else
                    warn "No RPM mapping for $pkg, falling back to Portage"
                    portage_pkgs+=("$pkg")
                fi
                ;;
            PORTAGE)
                portage_pkgs+=("$pkg")
                ;;
            SKIP)
                skip_pkgs+=("$pkg")
                info "Skipping: $pkg (not needed in hybrid mode)"
                ;;
            *)
                # Unknown packages fall back to Portage
                warn "Unknown package source for $pkg, using Portage"
                portage_pkgs+=("$pkg")
                ;;
        esac
    done

    info "Package distribution:"
    info "  RPM:     ${#rpm_pkgs[@]} packages"
    info "  Portage: ${#portage_pkgs[@]} packages"
    info "  Skipped: ${#skip_pkgs[@]} packages"

    # Install RPM packages first (provides base system utilities like ldconfig)
    if [[ ${#rpm_pkgs[@]} -gt 0 ]]; then
        info "Installing ${#rpm_pkgs[@]} packages from RPM..."
        rpm_install_to_image "${root_fs_dir}" "${rpm_pkgs[@]}" || {
            error "Failed to install RPM packages"
            return 1
        }
    fi

    # Install Portage packages with --nodeps (deps already satisfied by RPM)
    if [[ ${#portage_pkgs[@]} -gt 0 ]]; then
        info "Installing ${#portage_pkgs[@]} packages from Portage (nodeps)..."
        emerge_to_image_explicit "${root_fs_dir}" "${portage_pkgs[@]}" || {
            error "Failed to install Portage packages"
            return 1
        }
    fi

    return 0
}

# Install Portage packages explicitly without dependency resolution
# Dependencies are assumed to already be installed (via RPM or previous Portage)
emerge_to_image_explicit() {
    local root_fs_dir="$1"; shift
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    info "Emerging packages (nodeps): ${#packages[@]} packages"

    # Determine the correct config root
    # For sysext builds, use the board config; for image builds, use BUILD_DIR/configroot
    local config_root="/build/${BOARD:-amd64-usr}"
    if [[ -d "${BUILD_DIR}/configroot" ]]; then
        config_root="${BUILD_DIR}/configroot"
    fi

    # Use --nodeps since we're managing dependencies explicitly
    # Use --oneshot to avoid adding to world file
    # Use same environment as emerge_to_image_portage
    sudo -E ROOT="${root_fs_dir}" \
        FEATURES="-ebuild-locks" \
        PORTAGE_CONFIGROOT="${config_root}" \
        emerge --usepkgonly --jobs="${NUM_JOBS:-1}" --nodeps --oneshot --quiet-build "${packages[@]}"
}

# Full RPM mode installation workflow:
# 1. Audit all dependencies for requested packages (including SKIP packages)
# 2. Route each dependency through catalog and filter out SKIP packages
# 3. Install RPM packages first
# 4. Install remaining Portage packages with --nodeps
install_rpm_with_audit() {
    local root_fs_dir="$1"; shift
    local packages=("$@")

    info "=== RPM Mode Installation with Dependency Audit ==="
    info "Requested packages: ${packages[*]}"

    # Step 1: Get complete dependency tree (resolve even SKIP packages to get their deps)
    info "Step 1: Auditing dependencies..."
    local all_deps
    all_deps=$(get_all_dependencies "${root_fs_dir}" "${packages[@]}")

    local dep_count=$(echo "$all_deps" | grep -c . || echo 0)
    info "Total dependencies found: ${dep_count}"

    # Step 2: Categorize and report
    info "Step 2: Categorizing packages by source..."
    local rpm_pkgs=()
    local portage_pkgs=()
    local skip_count=0

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue

        local source=$(get_package_source "$dep")
        case "$source" in
            RPM)
                local rpm_name=$(get_rpm_package_name "$dep")
                [[ -n "$rpm_name" ]] && rpm_pkgs+=("$rpm_name")
                ;;
            PORTAGE)
                portage_pkgs+=("$dep")
                ;;
            SKIP)
                # Don't install, dependency satisfied elsewhere or not needed
                info "DEBUG: Skipping package: $dep"
                skip_count=$((skip_count + 1))
                ;;
        esac
    done <<< "$all_deps"

    info "Categorization complete:"
    info "  Will install from RPM: ${#rpm_pkgs[@]} packages"
    info "  Will install from Portage: ${#portage_pkgs[@]} packages"
    info "  Skipped: ${skip_count} packages"

    # Step 3: Install RPM packages (base layer)
    if [[ ${#rpm_pkgs[@]} -gt 0 ]]; then
        info "Step 3a: Installing RPM packages..."
        # Remove duplicates
        local unique_rpm_pkgs=($(printf '%s\n' "${rpm_pkgs[@]}" | sort -u))
        rpm_install_to_image "${root_fs_dir}" "${unique_rpm_pkgs[@]}" || {
            error "Failed to install RPM packages during RPM mode installation"
            error "Root filesystem: ${root_fs_dir}"
            error "Attempted to install: ${unique_rpm_pkgs[*]}"
            return 1
        }
    fi

    # Step 4: Install Portage packages with --nodeps
    if [[ ${#portage_pkgs[@]} -gt 0 ]]; then
        info "Step 3b: Installing Portage packages (nodeps)..."
        # Remove duplicates - use mapfile to handle packages safely
        local unique_portage_pkgs=()
        while IFS= read -r pkg; do
            [[ -n "$pkg" ]] && unique_portage_pkgs+=("$pkg")
        done < <(printf '%s\n' "${portage_pkgs[@]}" | sort -u)

        # Debug: show what packages we're about to install
        info "DEBUG: Installing ${#unique_portage_pkgs[@]} Portage packages:"
        for pkg in "${unique_portage_pkgs[@]}"; do
            info "DEBUG:   - '$pkg'"
        done

        emerge_to_image_explicit "${root_fs_dir}" "${unique_portage_pkgs[@]}" || {
            error "Failed to install Portage packages"
            return 1
        }
    fi

    info "=== RPM mode installation complete ==="
    return 0
}

# Generate a dependency report file
# Usage: generate_dependency_report "/path/to/root" "pkg1" "pkg2" ... > report.txt
generate_dependency_report() {
    local root_fs_dir="$1"; shift
    local packages=("$@")

    echo "# Dependency Report for Hybrid Build"
    echo "# Generated: $(date)"
    echo "# Requested packages: ${packages[*]}"
    echo "#"
    echo "# Format: package_atom | source | rpm_name"
    echo "#"

    local all_deps
    all_deps=$(get_all_dependencies "${root_fs_dir}" "${packages[@]}")

    local rpm_count=0
    local portage_count=0
    local skip_count=0
    local missing_count=0

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue

        local source=$(get_package_source "$dep")
        local rpm_name="N/A"

        case "$source" in
            RPM)
                rpm_name=$(get_rpm_package_name "$dep")
                ((rpm_count++))
                ;;
            PORTAGE)
                ((portage_count++))
                ;;
            SKIP)
                ((skip_count++))
                ;;
            *)
                source="MISSING"
                ((missing_count++))
                ;;
        esac

        printf '%s | %s | %s\n' "$dep" "$source" "$rpm_name"
    done <<< "$all_deps"

    echo "#"
    echo "# Summary:"
    echo "#   RPM packages:     ${rpm_count}"
    echo "#   Portage packages: ${portage_count}"
    echo "#   Skipped:          ${skip_count}"
    echo "#   Missing/Unknown:  ${missing_count}"
}

# Export functions
export -f get_portage_dependencies
export -f get_all_dependencies
export -f audit_dependencies
export -f install_packages_explicit
export -f emerge_to_image_explicit
export -f install_rpm_with_audit
export -f generate_dependency_report
