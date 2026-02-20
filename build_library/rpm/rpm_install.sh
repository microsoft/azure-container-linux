#!/bin/bash
# Copyright (c) 2026, Microsoft Corporation.

# RPM package installation functions for Azure Linux packages
#
# ENVIRONMENT VARIABLES:
#   RPM_LOCAL_CACHE - Optional path to local repository cache directory
#                     If set, will be configured as a local repo with priority=1
#                     If not set, falls back to RPM staging directory
#
# REPOSITORY CONFIGURATION:
#   - Local cache repository (if RPM_LOCAL_CACHE is set) - priority 1
#   - Azure Linux official repositories:
#     * azurelinux-official-base
#     * azurelinux-official-ms-non-oss
#     * azurelinux-official-ms-oss
#     * azurelinux-official-cloud-native

# =============================================================================
# Helper function to find RPM staging directory
# =============================================================================
rpm_get_staging_dir() {
    local rpm_staging=""
    for candidate in \
        "${RPM_STAGING_DIR}" \
        "/mnt/host/source/src/scripts/__build__/rpm-staging" \
        "${SCRIPT_ROOT}/../__build__/rpm-staging" \
        "__build__/rpm-staging"; do
        if [[ -d "${candidate}" ]]; then
            rpm_staging="${candidate}"
            break
        fi
    done
    echo "${rpm_staging}"
}

# Initialize RPM database in target rootfs
rpm_init_database() {
    local root_fs_dir="$1"

    if [[ -d "${root_fs_dir}/var/lib/rpm" ]] && [[ -f "${root_fs_dir}/var/lib/rpm/rpmdb.sqlite" ]]; then
        info "RPM database already initialized in ${root_fs_dir}"
        return 0
    fi

    info "Initializing RPM database in ${root_fs_dir}"
    sudo mkdir -p "${root_fs_dir}/var/lib/rpm"

    sudo rpm --root="${root_fs_dir}" --initdb
    if [[ $? -ne 0 ]]; then
        error "Failed to initialize RPM database"
        return 1
    fi

    return 0
}

# Setup Azure Linux repositories in target rootfs
rpm_setup_repos() {
    local root_fs_dir="$1"
    local releasever="${2:-3.0}"
    local local_repo_dir="${3:-}"  # Optional local repository cache

    local repo_dir="${root_fs_dir}/etc/yum.repos.d"
    sudo mkdir -p "${repo_dir}"

    # Setup GPG directory
    sudo mkdir -p "${root_fs_dir}/etc/pki/rpm-gpg"

    info "Setting up Azure Linux repositories in ${root_fs_dir}"

    # Setup local repository cache if provided and has proper metadata
    if [[ -n "${local_repo_dir}" ]] && [[ -d "${local_repo_dir}" ]]; then
        if [[ -f "${local_repo_dir}/repodata/repomd.xml" ]]; then
            info "  Adding local repository cache: ${local_repo_dir}"
            sudo tee "${repo_dir}/azurelinux-local.repo" > /dev/null <<EOF
[azurelinux-local-cache]
name=Azure Linux Local Package Cache
baseurl=file://${local_repo_dir}
enabled=1
gpgcheck=0
repo_gpgcheck=0
priority=1
EOF
        else
            warn "  Skipping local cache (no repository metadata): ${local_repo_dir}"
            info "  Hint: Run 'createrepo_c ${local_repo_dir}' to create repository metadata"
            exit 1
        fi
    fi

    info "  Setting up official repositories"

    sudo tee "${repo_dir}/azurelinux-official.repo" > /dev/null <<EOF
[azurelinux-official-base]
name=Azure Linux Official Base \$releasever \$basearch
baseurl=https://packages.microsoft.com/azurelinux/\$releasever/prod/base/\$basearch
gpgkey=file:///etc/pki/rpm-gpg/MICROSOFT-RPM-GPG-KEY
gpgcheck=1
repo_gpgcheck=1
enabled=1
skip_if_unavailable=True
sslverify=1

[azurelinux-official-extended]
name=Azure Linux Official Extended \$releasever \$basearch
baseurl=https://packages.microsoft.com/azurelinux/\$releasever/prod/extended/\$basearch
gpgkey=file:///etc/pki/rpm-gpg/MICROSOFT-RPM-GPG-KEY
gpgcheck=1
repo_gpgcheck=1
enabled=1
skip_if_unavailable=True
sslverify=1

[azurelinux-official-ms-non-oss]
name=Azure Linux Official Microsoft Non-Open-Source \$releasever \$basearch
baseurl=https://packages.microsoft.com/azurelinux/\$releasever/prod/ms-non-oss/\$basearch
gpgkey=file:///etc/pki/rpm-gpg/MICROSOFT-RPM-GPG-KEY
gpgcheck=1
repo_gpgcheck=1
enabled=1
skip_if_unavailable=True
sslverify=1

[azurelinux-official-ms-oss]
name=Azure Linux Official Microsoft Open-Source \$releasever \$basearch
baseurl=https://packages.microsoft.com/azurelinux/\$releasever/prod/ms-oss/\$basearch
gpgkey=file:///etc/pki/rpm-gpg/MICROSOFT-RPM-GPG-KEY
gpgcheck=1
repo_gpgcheck=1
enabled=1
skip_if_unavailable=True
sslverify=1

[azurelinux-official-cloud-native]
name=Azure Linux Official Cloud Native \$releasever \$basearch
baseurl=https://packages.microsoft.com/azurelinux/\$releasever/prod/cloud-native/\$basearch
gpgkey=file:///etc/pki/rpm-gpg/MICROSOFT-RPM-GPG-KEY
gpgcheck=1
repo_gpgcheck=1
enabled=1
skip_if_unavailable=True
sslverify=1
EOF

    return 0
}

# Mount pseudo-filesystems needed for RPM scriptlets
rpm_mount_pseudofs() {
    local root_fs_dir="$1"

    # Mount /dev, /proc, /sys for scriptlets
    sudo mkdir -p "${root_fs_dir}"/{dev,proc,sys}

    if ! mountpoint -q "${root_fs_dir}/dev"; then
        sudo mount --bind /dev "${root_fs_dir}/dev"
    fi

    if ! mountpoint -q "${root_fs_dir}/proc"; then
        sudo mount -t proc proc "${root_fs_dir}/proc"
    fi

    if ! mountpoint -q "${root_fs_dir}/sys"; then
        sudo mount -t sysfs sysfs "${root_fs_dir}/sys"
    fi
}

# Unmount pseudo-filesystems
rpm_umount_pseudofs() {
    local root_fs_dir="$1"

    if mountpoint -q "${root_fs_dir}/sys"; then
        sudo umount "${root_fs_dir}/sys" || true
    fi

    if mountpoint -q "${root_fs_dir}/proc"; then
        sudo umount "${root_fs_dir}/proc" || true
    fi

    if mountpoint -q "${root_fs_dir}/dev"; then
        sudo umount "${root_fs_dir}/dev" || true
    fi
}

# Denylist to force remove RPM packages.
# Uses --nodeps to avoid removing packages that depend on these (e.g., git depends on perl)
# MAY BREAK DEPENDENT PACKAGES - use with caution
remove_denylist_rpm_packages() {
    local root_fs_dir="$1"
    local dbpath_fs="${root_fs_dir}/var/lib/rpm"
    local dbpath_root="/var/lib/rpm"
    local denylist_globs=("perl*" "ncurses-term" "texinfo")

    info "RPM mode: Removing denylisted rpm packages"
    if [[ ! -d "${dbpath_fs}" ]]; then
        warn "RPM mode: No RPM database found at ${dbpath_fs}"
        return 0
    fi

    local denylist_packages
    denylist_packages=$(sudo rpm --dbpath="${dbpath_fs}" -qa "${denylist_globs[@]}" 2>/dev/null | sort -u)
    local count_before
    count_before=$(printf '%s\n' "${denylist_packages}" | sed '/^$/d' | wc -l)

    if [[ ${count_before} -eq 0 ]]; then
        info "RPM mode: No denylisted packages found to remove"
        return 0
    fi

    info "RPM mode: Found ${count_before} denylisted packages to remove"

    sudo rpm --root="${root_fs_dir}" --dbpath="${dbpath_root}" -e --nodeps ${denylist_packages} || {
        warn "RPM mode: Some denylisted packages could not be removed (may already be removed)"
    }

    local remaining
    remaining=$(sudo rpm --dbpath="${dbpath_fs}" -qa "${denylist_globs[@]}" 2>/dev/null | sort -u | wc -l)

    info "RPM mode: Removed $((count_before - remaining)) denylisted packages (${remaining} remaining)"
    info "RPM mode: Package cleanup complete"
}

# Install RPM packages to image using dnf5
rpm_install_package() {
    local root_fs_dir="$1"; shift
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    info "Installing ${#packages[@]} RPM packages using dnf5: ${packages[*]}"

    # Build dnf5 command arguments (always use --nodocs to minimize image size)
    # Note: Do NOT use --use-host-config - we want dnf5 to use the repos
    # configured in the installroot (set up by rpm_setup_repos), not the host
    # TODO: if we use RPM for setting up Azure Linux repos, we might want to revisit this.
    local dnf_args=(
        --installroot="${root_fs_dir}"
        --releasever=3.0
        --nodocs
        -y
        --nogpgcheck
    )

    # Mount pseudo-filesystems for scriptlets
    rpm_mount_pseudofs "${root_fs_dir}"

    # Install all packages using dnf5
    info "Running: dnf5 install ${dnf_args[*]} ${packages[*]}"
    sudo /usr/bin/dnf5 install "${dnf_args[@]}" "${packages[@]}" 2>&1 | sudo tee /tmp/rpm-install.log
    local dnf_exit_code=${PIPESTATUS[0]}

    # Check for errors in output
    if grep -q "Error: transaction check" /tmp/rpm-install.log || \
       grep -q "error: transaction check" /tmp/rpm-install.log || \
       grep -q "Error:" /tmp/rpm-install.log || \
       [[ $dnf_exit_code -ne 0 ]]; then
        error "Failed to install RPM packages"
        error "DNF install command failed with exit code: $dnf_exit_code"
        error "Full output:"
        cat /tmp/rpm-install.log | while IFS= read -r line; do
            error "  $line"
        done
        rpm_umount_pseudofs "${root_fs_dir}"
        return 1
    fi

    # Unmount pseudo-filesystems
    rpm_umount_pseudofs "${root_fs_dir}"

    remove_denylist_rpm_packages "${root_fs_dir}"

    # Remove documentation and locale directories that Portage mode excludes via INSTALL_MASK (see make.defaults)
    info "RPM mode: Removing documentation and locale directories (INSTALL_MASK parity)"
    sudo rm -rf "${root_fs_dir}/usr/share/doc"
    sudo rm -rf "${root_fs_dir}/usr/share/man"
    sudo rm -rf "${root_fs_dir}/usr/share/info"
    sudo rm -rf "${root_fs_dir}/usr/share/gtk-doc"
    sudo rm -rf "${root_fs_dir}/usr/share/bash-completion"
    sudo rm -rf "${root_fs_dir}/usr/share/zsh"
    sudo rm -rf "${root_fs_dir}/usr/share/locale"

    # Remove debug info
    info "RPM mode: Removing debug info files"
    sudo rm -rf "${root_fs_dir}/usr/lib/debug"

    info "Successfully installed ${#packages[@]} RPM packages"

    # Append explicitly installed packages to build log
    local pkg_log="${BUILD_DIR}/.rpm-packages-explicit"
    printf '%s\n' "${packages[@]}" | tee -a "${pkg_log}" > /dev/null

    return 0
}

# This handles: database init, repository setup
rpm_install_init() {
    local root_fs_dir="$1"; shift
    
    # Initialize RPM database if needed
    rpm_init_database "${root_fs_dir}" || return 1

    # Setup repositories
    local rpm_staging
    rpm_staging=$(rpm_get_staging_dir 2>/dev/null || echo "")
    local local_cache="${RPM_LOCAL_CACHE:-${rpm_staging}}"
    rpm_setup_repos "${root_fs_dir}" "3.0" "${local_cache}"
}

# Query installed RPM packages
rpm_query_packages() {
    local root_fs_dir="$1"
    local dbpath="${root_fs_dir}/var/lib/rpm"

    if [[ ! -d "${dbpath}" ]]; then
        return 0
    fi

    # Use --dbpath only and simple -qa (default format is NVRA which is what we want)
    sudo rpm --dbpath="${dbpath}" -qa 2>/dev/null | sort
}

# Get RPM package metadata
rpm_get_metadata() {
    local root_fs_dir="$1"
    local package="$2"
    local key="$3"
    local dbpath="${root_fs_dir}/var/lib/rpm"

    local format=""
    case "$key" in
        LICENSE) format="%{LICENSE}" ;;
        HOMEPAGE) format="%{URL}" ;;
        VERSION) format="%{VERSION}" ;;
        RELEASE) format="%{RELEASE}" ;;
        ARCH) format="%{ARCH}" ;;
        SUMMARY) format="%{SUMMARY}" ;;
        DESCRIPTION) format="%{DESCRIPTION}" ;;
        CONTENTS) 
            # For RPM, list files in the package
            sudo rpm --dbpath="${dbpath}" -ql "${package}" 2>/dev/null | sed 's/^/obj /' 
            return
            ;;
        SRC_URI)
            # RPM doesn't have SRC_URI, return URL instead
            format="%{URL}"
            ;;
        *) format="%{${key}}" ;;
    esac

    # Use --dbpath only (not --root which doesn't work correctly)
    local result
    result=$(sudo rpm --dbpath="${dbpath}" -q "${package}" --qf "${format}" 2>/dev/null)
    # Sanitize output - remove control characters that break JSON
    echo "$result" | tr -d '\000-\011\013-\037'
}

# Get all dependencies for a package using emerge --pretend
# Returns list of category/package names that would be installed
# Usage: get_portage_dependencies "/path/to/root" "coreos-base/coreos"
get_portage_dependencies() {
    local root_fs_dir="$1"
    local package="$2"

    # Determine the correct config root
    # For sysext builds, use the board config; for image builds, use BUILD_DIR/configroot
    local config_root="/build/${BOARD:-amd64-usr}"
    if [[ -d "${BUILD_DIR}/configroot" ]]; then
        config_root="${BUILD_DIR}/configroot"
    fi

    local emerge_output
    info "Resolving dependencies for ${package}"
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

        die "Failed to resolve dependencies for ${package} - no packages found in emerge output"
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

# Full RPM mode installation workflow:
# 1. Audit all dependencies for requested packages (including SKIP packages)
# 2. Route each dependency through catalog and filter out SKIP packages
# 3. Install RPM packages first
rpm_install_package_using_portage_name() {
    local root_fs_dir="$1"; shift
    local packages=("$@")

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
    local unrecognized_pkgs=()
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
            *)
                unrecognized_pkgs+=("$dep")
        esac
    done <<< "$all_deps"

    info "Categorization complete:"
    info "  Will install from RPM: ${#rpm_pkgs[@]} packages"
    info "  Will install from Portage: ${#portage_pkgs[@]} packages"
    info "  Skipped: ${skip_count} packages"

    if [[ ${#unrecognized_pkgs[@]} -gt 0 ]]; then
        error "Unrecognized packages: ${unrecognized_pkgs[*]}"
        die "Found ${#unrecognized_pkgs[@]} unrecognized package(s), catalog them first."
    fi

    if [[ ${#portage_pkgs[@]} -gt 0 ]]; then
        die "Installation of Portage packages is disabled. Extend the package catalog accordingly."
    fi
    
    # Step 3: Install RPM packages (base layer)
    if [[ ${#rpm_pkgs[@]} -gt 0 ]]; then
        info "Step 3: Installing RPM packages..."
        # Remove duplicates
        local unique_rpm_pkgs=($(printf '%s\n' "${rpm_pkgs[@]}" | sort -u))
        rpm_install_package "${root_fs_dir}" "${unique_rpm_pkgs[@]}" || {
            error "Failed to install RPM packages during RPM mode installation"
            error "Root filesystem: ${root_fs_dir}"
            error "Attempted to install: ${unique_rpm_pkgs[*]}"
            return 1
        }
        
        # Backup the installed RPM package list for later use by write_packages
        # This is needed because the RPM database may be in a different location
        # or inaccessible when write_packages runs
        # Skip for sysext builds (they don't need the backup and it causes permission issues)
        if [[ -n "${BUILD_DIR:-}" && ! "${BUILD_DIR}" =~ sysext-build ]]; then
            local backup_file="${BUILD_DIR}/.rpm_packages_installed.txt"
            info "Backing up RPM package list to ${backup_file}"
            # Use sudo to remove any existing file (may be owned by root from previous run)
            sudo rm -f "${backup_file}" 2>/dev/null || true
            # Query packages - use default format (no second argument to avoid format issues)
            rpm_query_packages "${root_fs_dir}" | sudo tee "${backup_file}" > /dev/null 2>/dev/null || true
            # Make it readable and writable by the current user for cleanup
            sudo chown "$(id -u):$(id -g)" "${backup_file}" 2>/dev/null || true
            sudo chmod 644 "${backup_file}" 2>/dev/null || true
            local backup_count=$(wc -l < "${backup_file}" 2>/dev/null || echo 0)
            info "  Backed up ${backup_count} packages to ${backup_file}"
        fi
    else
        info "Step 3: No RPM packages to install (skipped)"
    fi

    info "=== RPM mode installation complete ==="
    return 0
}

# Export functions
export -f rpm_install_package_using_portage_name
export -f rpm_get_staging_dir
export -f rpm_install_init
export -f rpm_install_package
export -f rpm_query_packages
export -f rpm_get_metadata
