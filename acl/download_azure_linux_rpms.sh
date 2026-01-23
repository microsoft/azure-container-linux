#!/bin/bash
# Download Azure Linux RPMs for Azure Container Linux (ACL) build
# Run this on the host (outside SDK) before building
#
# Usage: download_azure_linux_rpms.sh [staging_dir] [--force]
#   staging_dir: Target directory for RPMs (default: ./__build__/rpm-staging)
#   --force:     Re-download all packages even if already present

set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
STAGING_DIR="${1:-${SCRIPT_DIR}/__build__/rpm-staging}"
FORCE_DOWNLOAD=false

# Parse arguments
for arg in "$@"; do
    if [[ "$arg" == "--force" ]]; then
        FORCE_DOWNLOAD=true
    elif [[ "$arg" != "${STAGING_DIR}" ]]; then
        STAGING_DIR="$arg"
    fi
done

ESSENTIAL_PACKAGES=(
    "filesystem"
    "grub2"
    "grub2-pc"
    "grub2-efi"
    "grub2-efi-binary"
    "shim"
)

echo "=== Downloading Azure Linux RPMs ==="
echo "Target directory: ${STAGING_DIR}"
[[ "$FORCE_DOWNLOAD" == "true" ]] && echo "Mode: Force re-download (--force)" || echo "Mode: Skip existing packages"
echo

mkdir -p "${STAGING_DIR}"

# Configuration
REPO_URL="${RPM_REPO_URL:-https://packages.microsoft.com/azurelinux/3.0/prod/base}"
ARCH="${RPM_ARCH:-x86_64}"

# Use Docker to query available packages
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker required to query Azure Linux packages"
    echo "Please install Docker or manually download RPMs"
    exit 1
fi

echo "Querying Azure Linux repository for package versions..."
echo

# Pull Azure Linux container
docker pull mcr.microsoft.com/azurelinux/base/core:3.0 >/dev/null 2>&1

# Remove duplicates
ESSENTIAL_PACKAGES=($(printf '%s\n' "${ESSENTIAL_PACKAGES[@]}" | sort -u))

echo "Found ${#ESSENTIAL_PACKAGES[@]} unique package names to download"

# Check which packages are already downloaded
ALREADY_HAVE=()
NEED_TO_DOWNLOAD=()

# Helper function to check if an RPM file matches a package name
# Returns 0 if the file is for the exact package (not a subpackage)
rpm_matches_package() {
    local pkg="$1"
    local file="$2"
    local basename=$(basename "$file")
    
    # Strip the package name prefix and first dash
    local suffix="${basename#${pkg}-}"
    
    # If suffix equals basename, the file doesn't start with pkg-
    [[ "$suffix" == "$basename" ]] && return 1
    
    # Check if what follows looks like a version (not a subpackage name)
    # Subpackages have lowercase letters followed by dash (e.g., -libs-, -devel-)
    # Versions start with: digit, or uppercase+dot (like B.02), or digit
    if [[ "$suffix" =~ ^[0-9] ]] || [[ "$suffix" =~ ^[A-Z]\.[0-9] ]] || [[ "$suffix" =~ ^[0-9]+\. ]]; then
        return 0
    fi
    
    return 1
}

if [[ "$FORCE_DOWNLOAD" == "false" ]] && [[ -d "${STAGING_DIR}" ]]; then
    echo "Checking for existing RPMs in staging directory..."
    for base_pkg in "${ESSENTIAL_PACKAGES[@]}"; do
        found=false
        # Check all RPMs that might match this package
        for rpm_file in "${STAGING_DIR}/${base_pkg}"-*.rpm; do
            [[ -f "$rpm_file" ]] || continue
            if rpm_matches_package "$base_pkg" "$rpm_file"; then
                found=true
                break
            fi
        done
        
        if [[ "$found" == "true" ]]; then
            ALREADY_HAVE+=("$base_pkg")
        else
            NEED_TO_DOWNLOAD+=("$base_pkg")
        fi
    done
    echo "  Already have: ${#ALREADY_HAVE[@]} packages"
    echo "  Need to download: ${#NEED_TO_DOWNLOAD[@]} packages"
else
    NEED_TO_DOWNLOAD=("${ESSENTIAL_PACKAGES[@]}")
    echo "  Will download all ${#NEED_TO_DOWNLOAD[@]} packages"
fi

if [[ ${#NEED_TO_DOWNLOAD[@]} -eq 0 ]]; then
    echo
    echo "All required packages already present in staging directory."
    echo "Use --force to re-download everything."
    DOWNLOADED=$(ls -1 "${STAGING_DIR}"/*.rpm 2>/dev/null | wc -l)
    echo
    echo "=== Download Summary ==="
    echo "Already present: ${DOWNLOADED} RPMs"
    echo "Location:        ${STAGING_DIR}"
    echo
    exit 0
fi

echo "Resolving dependencies..."
echo

# Create temporary container to resolve dependencies
CONTAINER_ID=$(docker create mcr.microsoft.com/azurelinux/base/core:3.0)
TMP_CACHE="/tmp/rpm-cache-$$"
mkdir -p "${TMP_CACHE}"

# Track failed packages
FAILED_PACKAGES=()

# Use tdnf to download packages with dependencies
echo "Downloading packages with full dependency resolution..."
TOTAL_MOVED=0
for base_pkg in "${NEED_TO_DOWNLOAD[@]}"; do
    echo "  Resolving ${base_pkg}..."
    # Clean temp cache before each package
    find "${TMP_CACHE}" -name "*.rpm" -delete 2>/dev/null || true
    
    # Try to download package and dependencies
    # First try with install (gets dependencies)
    if timeout 120 docker run --rm \
        -v "${TMP_CACHE}":/cache \
        mcr.microsoft.com/azurelinux/base/core:3.0 \
        bash -c "mkdir -p /cache && tdnf install -y --downloadonly --downloaddir=/cache --nogpgcheck ${base_pkg}" \
        >/tmp/tdnf_output_$$.log 2>&1; then
        install_success=true
    else
        install_success=false
    fi
    
    # If nothing was downloaded (package already installed), try reinstall to get the base package
    rpm_count=$(find "${TMP_CACHE}" -name "*.rpm" 2>/dev/null | wc -l)
    if [[ "$rpm_count" -eq 0 ]]; then
        if timeout 120 docker run --rm \
            -v "${TMP_CACHE}":/cache \
            mcr.microsoft.com/azurelinux/base/core:3.0 \
            bash -c "mkdir -p /cache && tdnf reinstall -y --downloadonly --downloaddir=/cache --nogpgcheck ${base_pkg}" \
            >/tmp/tdnf_output_$$.log 2>&1; then
            install_success=true
        else
            install_success=false
        fi
    fi
    
    # Move downloaded RPMs to staging immediately
    rpm_count=$(find "${TMP_CACHE}" -name "*.rpm" 2>/dev/null | wc -l)
    if [[ "$rpm_count" -gt 0 ]]; then
        for rpm_file in "${TMP_CACHE}"/*.rpm; do
            if [[ -f "$rpm_file" ]]; then
                rpm_name=$(basename "$rpm_file")
                # Only move if not already in staging
                if [[ ! -f "${STAGING_DIR}/${rpm_name}" ]]; then
                    mv "$rpm_file" "${STAGING_DIR}/"
                    echo "    → Moved: ${rpm_name}"
                    TOTAL_MOVED=$((TOTAL_MOVED + 1))
                else
                    rm -f "$rpm_file"
                fi
            fi
        done
    else
        echo "    ERROR: Could not resolve ${base_pkg}"
        FAILED_PACKAGES+=("$base_pkg")
    fi
    
    rm -f /tmp/tdnf_output_$$.log
done

# Clean up
rm -rf "${TMP_CACHE}"
docker rm "${CONTAINER_ID}" >/dev/null 2>&1

# Check for failures
if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
    echo
    echo "=== ERROR: Failed to resolve ${#FAILED_PACKAGES[@]} package(s) ==="
    for failed_pkg in "${FAILED_PACKAGES[@]}"; do
        echo "  - ${failed_pkg}"
    done
    echo
    echo "Please check that these packages exist in Azure Linux 3.0 repositories."
    echo "You may need to update the package catalog if the package name has changed."
    exit 1
fi

# Count what we got
DOWNLOADED=$(ls -1 "${STAGING_DIR}"/*.rpm 2>/dev/null | wc -l)

echo
echo "=== Download Summary ==="
echo "Newly moved:      ${TOTAL_MOVED} RPMs"
echo "Already had:      ${#ALREADY_HAVE[@]} packages"
echo "Total available:  ${DOWNLOADED} RPMs (including dependencies)"
echo "Location:         ${STAGING_DIR}"
echo

# List unique packages
echo "Package inventory:"
ls -1 "${STAGING_DIR}"/*.rpm 2>/dev/null | xargs -n1 basename | sort || echo "  (none)"
echo

# Create repository metadata for local cache
echo "=== Creating repository metadata ==="
if command -v createrepo_c &>/dev/null; then
    echo "Running createrepo_c to generate repository metadata..."
    createrepo_c "${STAGING_DIR}" >/dev/null 2>&1
    if [[ -f "${STAGING_DIR}/repodata/repomd.xml" ]]; then
        echo "✓ Repository metadata created successfully"
        echo "  This directory can now be used as a local dnf repository cache"
    else
        echo "⚠ Warning: createrepo_c completed but metadata not found"
        exit 1
    fi
else
    echo "⚠ Warning: createrepo_c not found - repository metadata not created"
    echo "  To use this as a local dnf repository cache, install createrepo_c:"
    echo "    - Fedora/RHEL: sudo dnf install createrepo_c"
    echo "    - Debian/Ubuntu: sudo apt install createrepo-c"
    echo "  Then run: createrepo_c ${STAGING_DIR}"
    exit 1
fi
echo

echo "All required RPM packages are ready in: ${STAGING_DIR}"
echo
echo "To use these RPMs in a build, set:"
echo "  export RPM_STAGING_DIR='${STAGING_DIR}'"
echo "  export PACKAGE_SOURCE_MODE=RPM"
echo
echo "To use as a local dnf repository cache:"
echo "  export RPM_LOCAL_CACHE='${STAGING_DIR}'"
