#!/bin/bash
# Download Azure Linux RPMs for Azure Container Linux (ACL) build
# Run this on the host (outside SDK) before building
#
# Usage: download_azure_linux_rpms.sh [staging_dir] [--force]
#   staging_dir: Target directory for RPMs (default: ./__build__/rpm-staging)
#   --force:     Re-download all packages even if already present

set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
STAGING_DIR=""
FORCE_DOWNLOAD=false

# Parse arguments
for arg in "$@"; do
    if [[ "$arg" == "--force" ]]; then
        FORCE_DOWNLOAD=true
    elif [[ "$arg" != --* ]]; then
        STAGING_DIR="$arg"
    fi
done

# Default staging dir if not specified
STAGING_DIR="${STAGING_DIR:-${SCRIPT_DIR}/__build__/rpm-staging}"

ESSENTIAL_PACKAGES=(
    "grub2"
    "grub2-efi"
    "grub2-efi-binary"
    "shim"
    "systemd-boot"
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

echo "Downloading packages (no dependency resolution)..."
echo

TMP_CACHE="/tmp/rpm-cache-$$"
mkdir -p "${TMP_CACHE}"

# Get list of all available package URLs from Azure Linux repos
echo "Fetching package URLs from Azure Linux repositories..."
ALL_URLS=$(docker run --rm mcr.microsoft.com/azurelinux/base/core:3.0 \
    bash -c "tdnf reposync --urls 2>/dev/null" 2>/dev/null | grep '\.rpm$' || true)

if [[ -z "$ALL_URLS" ]]; then
    echo "ERROR: Could not fetch package URLs from Azure Linux repositories"
    exit 1
fi

# Track failed packages
FAILED_PACKAGES=()

TOTAL_MOVED=0
for base_pkg in "${NEED_TO_DOWNLOAD[@]}"; do
    echo "  Downloading ${base_pkg}..."
    
    # Find the latest version URL for this package
    # Match package name followed by version (e.g., grub2-2.06-26.azl3.x86_64.rpm)
    # but not subpackages (e.g., grub2-tools-2.06-26.azl3.x86_64.rpm)
    pkg_url=$(echo "$ALL_URLS" | grep -E "/${base_pkg}-[0-9][^/]*\.rpm$" | sort -V | tail -1)
    
    if [[ -z "$pkg_url" ]]; then
        echo "    ERROR: Could not find package ${base_pkg} in repository"
        FAILED_PACKAGES+=("$base_pkg")
        continue
    fi
    
    rpm_name=$(basename "$pkg_url")
    
    # Download the package directly
    if curl -sL -o "${TMP_CACHE}/${rpm_name}" "$pkg_url"; then
        # Move to staging
        if [[ ! -f "${STAGING_DIR}/${rpm_name}" ]]; then
            mv "${TMP_CACHE}/${rpm_name}" "${STAGING_DIR}/"
            echo "    → Downloaded: ${rpm_name}"
            TOTAL_MOVED=$((TOTAL_MOVED + 1))
        else
            rm -f "${TMP_CACHE}/${rpm_name}"
            echo "    → Already exists: ${rpm_name}"
        fi
    else
        echo "    ERROR: Could not download ${base_pkg} from ${pkg_url}"
        FAILED_PACKAGES+=("$base_pkg")
    fi
done

# Clean up
rm -rf "${TMP_CACHE}"

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
echo "Downloaded:       ${TOTAL_MOVED} RPMs"
echo "Already had:      ${#ALREADY_HAVE[@]} packages"
echo "Total available:  ${DOWNLOADED} RPMs"
echo "Location:         ${STAGING_DIR}"
echo

# List unique packages
echo "Package inventory:"
ls -1 "${STAGING_DIR}"/*.rpm 2>/dev/null | xargs -n1 basename | sort || echo "  (none)"
echo

echo "All required RPM packages are ready in: ${STAGING_DIR}"
echo
echo "To use these RPMs in a build, set:"
echo "  export RPM_STAGING_DIR='${STAGING_DIR}'"
echo "  export PACKAGE_SOURCE_MODE=RPM"
echo
echo "To use as a local dnf repository cache:"
echo "  export RPM_LOCAL_CACHE='${STAGING_DIR}'"
