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
find_rpm_staging_dir() {
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

# Install RPM packages to image using dnf
rpm_install_to_image() {
    local root_fs_dir="$1"; shift
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    info "Installing ${#packages[@]} RPM packages using dnf: ${packages[*]}"

    # Initialize RPM database if needed
    if [[ ! -d "${root_fs_dir}/var/lib/rpm" ]]; then
        rpm_init_database "${root_fs_dir}" || return 1
    fi

    # Setup repositories (use RPM_LOCAL_CACHE if set for local package cache)
    local rpm_staging
    rpm_staging=$(find_rpm_staging_dir)
    local local_cache="${RPM_LOCAL_CACHE:-${rpm_staging}}"
    rpm_setup_repos "${root_fs_dir}" "3.0" "${local_cache}"

    # Mount pseudo-filesystems for scriptlets
    rpm_mount_pseudofs "${root_fs_dir}"

    # Install all packages using dnf
    info "Running: dnf install --installroot=${root_fs_dir} --releasever=3.0 -y --nogpgcheck ${packages[*]}"
    sudo /usr/bin/dnf-3 install --installroot="${root_fs_dir}" --releasever=3.0 -y --nogpgcheck "${packages[@]}" 2>&1 | sudo tee /tmp/rpm-install.log
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

    info "Successfully installed ${#packages[@]} RPM packages"
    return 0
}

# Query installed RPM packages
rpm_query_packages() {
    local root_fs_dir="$1"
    local format="${2:-%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}}"

    if [[ ! -d "${root_fs_dir}/var/lib/rpm" ]]; then
        return 0
    fi

    sudo rpm --root="${root_fs_dir}" -qa --qf "${format}\n" | sort
}

# Get RPM package metadata
rpm_get_metadata() {
    local root_fs_dir="$1"
    local package="$2"
    local key="$3"

    local format=""
    case "$key" in
        LICENSE) format="%{LICENSE}" ;;
        HOMEPAGE) format="%{URL}" ;;
        VERSION) format="%{VERSION}" ;;
        RELEASE) format="%{RELEASE}" ;;
        ARCH) format="%{ARCH}" ;;
        SUMMARY) format="%{SUMMARY}" ;;
        DESCRIPTION) format="%{DESCRIPTION}" ;;
        *) format="%{${key}}" ;;
    esac

    sudo rpm --root="${root_fs_dir}" -q "${package}" --qf "${format}\n" 2>/dev/null
}

# Check if package is available in repository
rpm_repoquery() {
    local package="$1"
    local repo_url="${2:-${RPM_REPO_URL}}"
    local arch="${3:-${RPM_ARCH}}"

    local pkg_mgr=""
    if command -v tdnf &>/dev/null; then
        pkg_mgr="tdnf"
    elif command -v dnf &>/dev/null; then
        pkg_mgr="dnf"
    else
        return 1
    fi

    ${pkg_mgr} repoquery \
        --disablerepo='*' \
        --repofrompath="azl,${repo_url}/${arch}" \
        --enablerepo=azl \
        "${package}" 2>/dev/null
}

# Export functions
export -f rpm_init_database
export -f rpm_setup_repos
export -f rpm_mount_pseudofs
export -f rpm_umount_pseudofs
export -f rpm_install_to_image
export -f rpm_query_packages
export -f rpm_get_metadata
export -f rpm_repoquery
