#!/bin/bash
# Build Flatcar RPM Image - Complete workflow
#
# This script builds a Flatcar Linux image using Azure Linux RPMs where available,
# falling back to Portage packages for Flatcar-specific components.
#
# Usage:
#   ./build_rpm_image.sh [options]
#
# Options:
#   --board=BOARD       Target board (default: amd64-usr)
#   --group=GROUP       Image group: developer|production|prod (default: production)
#   --build-sdk-container   Update/rebuild SDK container with RPM tools (can run standalone)
#   --build-rpms        Build custom RPM packages using Azure Linux toolkit (runs acl/build.sh)
#   --download-rpms     Download Azure Linux RPMs to staging directory
#   --clean             Clean staging directory before download
#   --rebuild           Force rebuild even if image exists
#   --rebuild-and-test    Rebuild image and run container tests (equivalent to
#                       --rebuild --build-vm-image --start-vm --run-script ./run-container-test.sh)
#   --build-vm-image    Build VM images after creating base image
#   --start-vm          Start the VM after building (implies --build-vm-image)
#   --vm-name=NAME      Name for the VM (default: flatcar-hybrid)
#   --run-script=PATH   Run script on VM after boot (can specify multiple times)
#                       Can be a file path or inline command. Implies --start-vm.
#   --use-serial        Use serial console for script execution (default, no SSH/ignition needed)
#   --use-ssh           Use SSH for script execution (requires working ignition/SSH keys)
#   --console-user=USER Serial console login user (default: root)
#   --console-password=PASS  Serial console login password (empty for passwordless)
#   --boot-timeout=SECS Timeout waiting for VM boot (default: 180)
#   --ssh-user=USER     SSH user for VM scripts (default: core)
#   --ssh-key=PATH      SSH private key for VM access
#   --ssh-timeout=SECS  Timeout waiting for SSH (default: 120)
#   --output=DIR        Output directory for images
#   --help              Show this help message
#
# Examples:
#   # Build and run a test script on the VM via serial console
#   ./build_rpm_image.sh --run-script=./tests/smoke_test.sh
#
#   # Run inline command via serial console
#   ./build_rpm_image.sh --run-script="cat /etc/os-release"
#
#   # Run multiple scripts
#   ./build_rpm_image.sh --run-script=./setup.sh --run-script=./test.sh
#
#   # Use SSH instead of serial console (requires ignition/SSH setup)
#   ./build_rpm_image.sh --use-ssh --run-script="systemctl status docker"
#
#   # Run with specific console user
#   ./build_rpm_image.sh --console-user=core --run-script="whoami"
#
# Environment Variables:
#   RPM_REPO_URL            Azure Linux repository URL
#   RPM_ARCH                Target architecture (default: x86_64)
#   BUILD_ID                Build identifier for versioning
#   USE_SERIAL_CONSOLE      Use serial console (true) or SSH (false) - default: true
#   VM_CONSOLE_USER         Serial console login user (default: root)
#   VM_CONSOLE_PASSWORD     Serial console login password
#   VM_BOOT_TIMEOUT         Boot timeout in seconds (default: 180)
#   VM_SSH_USER             SSH user for VM (default: core)
#   VM_SSH_KEY              SSH private key path
#   VM_SSH_TIMEOUT          SSH connection timeout in seconds (default: 120)
#
# Copyright (c) 2025 The Flatcar Maintainers.
# Use of this source code is governed by the Apache 2.0 license.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
cd "${SCRIPT_DIR}"

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

# Default configuration
BOARD="${BOARD:-amd64-usr}"
GROUP="${GROUP:-production}"
BUILD_SDK_CONTAINER=false
BUILD_RPMS=false
DOWNLOAD_RPMS=false
CLEAN_STAGING=false
FORCE_REBUILD=false
BUILD_IMAGE=false
BUILD_VM_IMAGE=false
START_VM=false
VM_NAME="${VM_NAME:-flatcar-hybrid}"
OUTPUT_ROOT="${OUTPUT_ROOT:-__build__}"
STAGING_DIR="${SCRIPT_DIR}/__build__/rpm-staging"
DISK_LAYOUT="${DISK_LAYOUT:-vm}"  # Use 'vm' layout for larger ROOT partition (needed for hybrid mode)
RUN_SCRIPTS=()  # Scripts to run on VM after boot
VM_SSH_USER="${VM_SSH_USER:-core}"
VM_SSH_KEY="${VM_SSH_KEY:-}"
VM_SSH_TIMEOUT="${VM_SSH_TIMEOUT:-120}"  # Seconds to wait for SSH
VM_SSH_AUTHORIZED_KEYS="${VM_SSH_AUTHORIZED_KEYS:-}"  # SSH public keys to inject (file or string)
VM_PASSWORD="${VM_PASSWORD:-}"  # Password for VM user (optional)
USE_SERIAL_CONSOLE="${USE_SERIAL_CONSOLE:-false}"  # Use serial console instead of SSH
VM_CONSOLE_USER="${VM_CONSOLE_USER:-root}"  # Console login user
VM_CONSOLE_PASSWORD="${VM_CONSOLE_PASSWORD:-}"  # Console login password (empty for no password)
VM_BOOT_TIMEOUT="${VM_BOOT_TIMEOUT:-180}"  # Seconds to wait for VM boot

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
debug()   { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" || true; }
section() { echo -e "\n${GREEN}=========================================${NC}"; echo -e "${GREEN}$*${NC}"; echo -e "${GREEN}=========================================${NC}\n"; }

# Detect if running on Azure Linux 3
is_azure_linux_3() {
    [[ -f /etc/os-release ]] && grep -q 'ID=azurelinux' /etc/os-release && grep -q 'VERSION_ID="3' /etc/os-release
}

# Ensure libvirt default network exists and is active
ensure_libvirt_network() {
    if ! command -v virsh &>/dev/null; then
        error "virsh not found - required for VM operations"
        if is_azure_linux_3; then
            error "Install with: sudo tdnf install -y libvirt libvirt-client"
        else
            error "Install with: sudo apt-get install -y libvirt-clients"
        fi
        return 1
    fi
    
    # Check if default network exists
    if ! virsh net-info default &>/dev/null 2>&1; then
        warn "libvirt default network not found"
        if [[ -f /usr/share/libvirt/networks/default.xml ]]; then
            info "Attempting to define default network from template..."
            if sudo virsh net-define /usr/share/libvirt/networks/default.xml; then
                info "Default network defined successfully"
            else
                error "Failed to define default network. Please run manually:"
                error "  sudo virsh net-define /usr/share/libvirt/networks/default.xml"
                return 1
            fi
        else
            error "Default network template not found at /usr/share/libvirt/networks/default.xml"
            error "Please install libvirt or create the default network manually"
            return 1
        fi
    fi
    
    # Check if default network is active
    if ! virsh net-info default 2>/dev/null | grep -q 'Active:.*yes'; then
        info "Starting libvirt default network..."
        if sudo virsh net-start default; then
            sudo virsh net-autostart default 2>/dev/null || true
            info "Default network started successfully"
        else
            error "Failed to start default network. Please run manually:"
            error "  sudo virsh net-start default"
            return 1
        fi
    fi
    
    return 0
}

# Check for swtpm SECCOMP issue on Azure Linux 3
# Note: Not all Azure Linux 3 builds encounter this issue, so we only log at debug level.
# The fix is documented in BUILD_RPM_IMAGE_README.md for users who encounter it.
check_swtpm_azure_linux() {
    if ! is_azure_linux_3; then
        return 0
    fi
    
    # Check if swtpm exists and if wrapper is installed
    if [[ -x /usr/bin/swtpm ]]; then
        if [[ -L /usr/bin/swtpm ]] && [[ -f /usr/bin/swtpm.orig ]]; then
            debug "swtpm wrapper already installed"
            return 0
        fi
        
        debug "swtpm found without wrapper - if VM startup fails with 'tpm-emulator: could not send INIT', see BUILD_RPM_IMAGE_README.md for fix"
    fi
    return 0
}

# Show usage information
show_help() {
    head -30 "$0" | grep -E "^#" | sed 's/^# *//'
    exit 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --board=*)
                BOARD="${1#*=}"
                shift
                ;;
            --board)
                BOARD="$2"
                shift 2
                ;;
            --group=*)
                GROUP="${1#*=}"
                shift
                ;;
            --group)
                GROUP="$2"
                shift 2
                ;;
            --build-sdk-container)
                BUILD_SDK_CONTAINER=true
                shift
                ;;
            --build-rpms)
                BUILD_RPMS=true
                shift
                ;;
            --download-rpms|--download)
                DOWNLOAD_RPMS=true
                shift
                ;;
            --clean)
                CLEAN_STAGING=true
                shift
                ;;
            --rebuild)
                FORCE_REBUILD=true
                BUILD_IMAGE=true
                shift
                ;;
            --rebuild-and-test)
                FORCE_REBUILD=true
                BUILD_IMAGE=true
                BUILD_VM_IMAGE=true
                START_VM=true
                RUN_SCRIPTS+=("./acl/tests/run-secureboot-test.sh")
                RUN_SCRIPTS+=("./acl/tests/run-container-test.sh")
                shift
                ;;
            --build-image)
                BUILD_IMAGE=true
                shift
                ;;
            --build-vm-image)
                BUILD_VM_IMAGE=true
                shift
                ;;
            --start-vm)
                START_VM=true
                shift
                ;;
            --vm-name=*)
                VM_NAME="${1#*=}"
                shift
                ;;
            --vm-name)
                VM_NAME="$2"
                shift 2
                ;;
            --output=*)
                OUTPUT_ROOT="${1#*=}"
                shift
                ;;
            --output)
                OUTPUT_ROOT="$2"
                shift 2
                ;;
            --disk-layout=*)
                DISK_LAYOUT="${1#*=}"
                shift
                ;;
            --disk-layout)
                DISK_LAYOUT="$2"
                shift 2
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --run-script=*)
                RUN_SCRIPTS+=("${1#*=}")
                START_VM=true
                shift
                ;;
            --run-script)
                RUN_SCRIPTS+=("$2")
                START_VM=true
                shift 2
                ;;
            --ssh-user=*)
                VM_SSH_USER="${1#*=}"
                shift
                ;;
            --ssh-key=*)
                VM_SSH_KEY="${1#*=}"
                shift
                ;;
            --ssh-timeout=*)
                VM_SSH_TIMEOUT="${1#*=}"
                shift
                ;;
            --ssh-authorized-keys=*)
                VM_SSH_AUTHORIZED_KEYS="${1#*=}"
                shift
                ;;
            --ssh-authorized-keys)
                VM_SSH_AUTHORIZED_KEYS="$2"
                shift 2
                ;;
            --vm-password=*)
                VM_PASSWORD="${1#*=}"
                shift
                ;;
            --vm-password)
                VM_PASSWORD="$2"
                shift 2
                ;;
            --use-serial|--serial)
                USE_SERIAL_CONSOLE=true
                shift
                ;;
            --use-ssh|--no-serial)
                USE_SERIAL_CONSOLE=false
                shift
                ;;
            --console-user=*)
                VM_CONSOLE_USER="${1#*=}"
                shift
                ;;
            --console-user)
                VM_CONSOLE_USER="$2"
                shift 2
                ;;
            --console-password=*)
                VM_CONSOLE_PASSWORD="${1#*=}"
                shift
                ;;
            --console-password)
                VM_CONSOLE_PASSWORD="$2"
                shift 2
                ;;
            --boot-timeout=*)
                VM_BOOT_TIMEOUT="${1#*=}"
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                error "Unknown option: $1"
                show_help
                ;;
        esac
    done

    # Normalize group name
    case "$GROUP" in
        prod|production)
            GROUP="production"
            ;;
        dev|developer)
            GROUP="developer"
            ;;
    esac
}

# Check prerequisites
check_prerequisites() {
    section "Checking Prerequisites"

    local missing=()
    local warnings=0

    # Check for required commands
    for cmd in docker; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    # Azure Linux specific: check for docker-cli
    if is_azure_linux_3 && ! command -v docker &>/dev/null; then
        error "Docker CLI not found. On Azure Linux, install with:"
        error "  sudo tdnf install -y moby-engine docker-cli"
        exit 1
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required commands: ${missing[*]}"
        error "Please install them and try again."
        exit 1
    fi

    # Check Docker is running
    if ! docker info &>/dev/null; then
        error "Docker is not running. Please start Docker and try again."
        exit 1
    fi

    # Check for SDK container script
    if [[ ! -f "${SCRIPT_DIR}/run_sdk_container" ]]; then
        error "run_sdk_container script not found"
        exit 1
    fi

    # Check for build_image script
    if [[ ! -f "${SCRIPT_DIR}/build_image" ]]; then
        error "build_image script not found"
        exit 1
    fi

    # Check for genisoimage/mkisofs if VM operations are planned
    if [[ "$START_VM" == "true" ]] || [[ "$BUILD_VM_IMAGE" == "true" ]]; then
        if ! command -v genisoimage &>/dev/null && ! command -v mkisofs &>/dev/null; then
            warn "Neither genisoimage nor mkisofs found - required for ignition ISO creation"
            if is_azure_linux_3; then
                warn "Install with: sudo tdnf install -y cdrkit"
            else
                warn "Install with: sudo apt-get install -y genisoimage"
            fi
            warnings=$((warnings + 1))
        fi
        
        # Check swtpm on Azure Linux 3
        check_swtpm_azure_linux
    fi

    # Check libvirt network only when starting a VM
    if [[ "$START_VM" == "true" ]]; then
        if ! ensure_libvirt_network; then
            warnings=$((warnings + 1))
        fi
    fi

    if [[ $warnings -gt 0 ]]; then
        warn "$warnings warning(s) detected - some operations may fail"
        echo
    fi

    info "✓ All prerequisites met"
}

# Download Azure Linux RPMs
download_rpms() {
    section "Downloading Azure Linux RPMs"

    if [[ "$CLEAN_STAGING" == "true" ]]; then
        warn "Cleaning staging directory: ${STAGING_DIR}"
        rm -rf "${STAGING_DIR}"
    fi

    mkdir -p "${STAGING_DIR}"

    info "Using download_azure_linux_rpms.sh"
    "${SCRIPT_DIR}/acl/download_azure_linux_rpms.sh" "${STAGING_DIR}"

    # Verify downloads
    local rpm_count=$(ls -1 "${STAGING_DIR}"/*.rpm 2>/dev/null | wc -l)
    if [[ "$rpm_count" -eq 0 ]]; then
        error "No RPMs were downloaded. Check network connectivity and repository access."
        exit 1
    fi

    info "✓ Downloaded ${rpm_count} RPM packages"

    # Verify critical packages are present
    verify_critical_packages

    # Create repository metadata
    create_repo
}

# Verify critical packages are in staging
verify_critical_packages() {
    info "Verifying critical packages..."

    local critical_packages=(
        "filesystem"
        "grub2-efi-binary"
        "shim"
    )

    local missing=()
    for pkg in "${critical_packages[@]}"; do
        if ! ls "${STAGING_DIR}/${pkg}"-[0-9]*.rpm &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing critical packages: ${missing[*]}"
        exit 1
    fi

    info "✓ All critical packages present"
}

# Create/update repository metadata for the staging directory
create_repo() {
    info "Creating repository metadata..."
    
    if ! command -v createrepo_c &>/dev/null; then
        error "createrepo_c not found - required to create repository metadata"
        error "  Install with: sudo dnf install createrepo_c"
        exit 1
    fi

    if ! createrepo_c --update "${STAGING_DIR}" >/dev/null 2>&1; then
        error "Failed to create repository metadata"
        exit 1
    fi

    if [[ -f "${STAGING_DIR}/repodata/repomd.xml" ]]; then
        info "✓ Repository metadata created/updated successfully"
    else
        error "Repository metadata not found after createrepo_c"
        exit 1
    fi
}

# Update/rebuild the SDK container with RPM tools
update_sdk_container() {
    section "Updating SDK Container"

    info "Rebuilding SDK container with RPM/dnf tools..."

    # Source SDK common functions to get version info
    source "${SCRIPT_DIR}/sdk_lib/sdk_container_common.sh"

    # Restore original version file and read base SDK version
    git restore sdk_container/.repo/manifests/version.txt 2>/dev/null || true
    source sdk_container/.repo/manifests/version.txt
    local base_sdk_version="${FLATCAR_SDK_VERSION}"
    local rpm_sdk_version="${base_sdk_version}-rpm"

    info "Base SDK version: ${base_sdk_version}"
    info "RPM SDK version:  ${rpm_sdk_version}"

    # Ensure base SDK container exists
    info "Ensuring base SDK container is available..."
    ./run_sdk_container -t hostname

    # Update SDK container with RPM tools
    info "Installing RPM/dnf tools in SDK container..."
    ./update_sdk_container_image "${rpm_sdk_version}"

    # Clean up old SDK containers
    info "Cleaning up old SDK containers..."
    docker ps -a --filter "name=flatcar-sdk-" --format "{{.ID}} {{.Names}}" | while read -r id name; do
        info "  Removing container: $name ($id)"
        docker rm -f "$id" 2>/dev/null || true
    done

    # Get updated SDK version
    local sdk_version=$(get_sdk_version_from_versionfile)
    local docker_sdk_vernum=$(vernum_to_docker_image_version "$sdk_version")
    local sdk_image="${sdk_container_common_registry}/flatcar-sdk-all:${docker_sdk_vernum}"

    info "✓ SDK container updated successfully"
    info "  Image: ${sdk_image}"
    echo
}

# Build custom RPM packages using Azure Linux toolkit
build_rpms() {
    section "Building Custom RPM Packages"

    local build_script="${SCRIPT_DIR}/acl/build.sh"
    
    if [[ ! -f "$build_script" ]]; then
        error "RPM build script not found: $build_script"
        exit 1
    fi

    info "Running RPM build script..."
    info "  Build script: $build_script"
    info "  Output dir:   ${STAGING_DIR}"
    echo

    # Run the build script
    if ! "$build_script"; then
        error "RPM build failed"
        exit 1
    fi

    # Count built RPMs
    local rpm_count=$(ls -1 "${STAGING_DIR}"/*.rpm 2>/dev/null | wc -l)
    info "✓ RPM build complete"
    info "  Total RPMs in staging: ${rpm_count}"

    # Update repository metadata with new RPMs
    create_repo
}

# Build the hybrid image using SDK container
build_image() {
    section "Building Hybrid Flatcar Image"

    info "Configuration:"
    info "  Board:           ${BOARD}"
    info "  Group:           ${GROUP}"
    info "  Output:          ${OUTPUT_ROOT}"
    info "  Staging Dir:     ${STAGING_DIR}"
    info "  Force Rebuild:   ${FORCE_REBUILD}"
    echo

    # Count RPMs
    local rpm_count=$(ls -1 "${STAGING_DIR}"/*.rpm 2>/dev/null | wc -l)
    info "Using ${rpm_count} pre-downloaded RPM packages"

    # Build arguments for build_image
    local build_args=(
        "--board=${BOARD}"
        "--group=${GROUP}"
        "--disk_layout=${DISK_LAYOUT}"
    )

    if [[ "$FORCE_REBUILD" == "true" ]]; then
        build_args+=("--replace")
    fi

    # Run the build inside SDK container
    info "Starting SDK container and build process..."

    # Set environment variables for hybrid mode
    export PACKAGE_SOURCE_MODE=RPM
    export RPM_STAGING_DIR="${STAGING_DIR}"

    # Source SDK common functions to get version info
    source "${SCRIPT_DIR}/sdk_lib/sdk_container_common.sh"
    local sdk_version=$(get_sdk_version_from_versionfile)
    local docker_sdk_vernum=$(vernum_to_docker_image_version "$sdk_version")
    local sdk_image="${sdk_container_common_registry}/flatcar-sdk-all:${docker_sdk_vernum}"

    info "Using SDK image: ${sdk_image}"
    # Use -C to specify the custom image (skips registry download)
    # Use --rm to remove old container and ensure environment variables are set correctly
    "${SCRIPT_DIR}/run_sdk_container" \
        --rm \
        -t \
        -C "${sdk_image}" \
        -- \
        ./build_image "${build_args[@]}"

    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        section "Build Completed Successfully"
        show_build_output
    else
        error "Build failed with exit code: $exit_code"
        suggest_troubleshooting
        exit $exit_code
    fi
}

# Show build output location
show_build_output() {
    info "Build artifacts location:"

    local image_dir="${SCRIPT_DIR}/__build__/images/images/${BOARD}"
    if [[ -d "$image_dir" ]]; then
        # Find latest build
        local latest=$(ls -td "${image_dir}"/*/ 2>/dev/null | head -1)
        if [[ -n "$latest" ]]; then
            info "  Latest build: ${latest}"
            ls -lh "${latest}"/*.{bin,img,vmdk,qcow2,raw,gz,xz} 2>/dev/null | head -10 || true
        fi
    else
        warn "No image output directory found at: ${image_dir}"
    fi
}

# Suggest troubleshooting steps
suggest_troubleshooting() {
    echo
    warn "Troubleshooting suggestions:"
    echo "  1. Check the build log for specific errors"
    echo "  2. Verify RPM staging directory has all required packages:"
    echo "     ls ${STAGING_DIR}/*.rpm | wc -l"
    echo "  3. Try rebuilding with clean staging:"
    echo "     $0 --clean"
    echo "  4. Check for missing critical packages:"
    echo "     ls ${STAGING_DIR}/{filesystem,glibc,bash,readline,ncurses}*.rpm"
    echo "  5. Enable debug mode:"
    echo "     DEBUG=true $0"
    echo
}

# Generate Ignition config ISO for VM user provisioning
# Creates a CDROM ISO with label "ignition" containing the config at /ignition/config.ign
generate_ignition_iso() {
    local iso_path="$1"
    local ssh_keys=()
    local password_hash=""

    # Collect SSH public keys
    if [[ -n "$VM_SSH_AUTHORIZED_KEYS" ]]; then
        if [[ -f "$VM_SSH_AUTHORIZED_KEYS" ]]; then
            # Read keys from file
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" || "$line" == \#* ]] && continue
                ssh_keys+=("$line")
            done < "$VM_SSH_AUTHORIZED_KEYS"
        else
            # Treat as a single key string
            ssh_keys+=("$VM_SSH_AUTHORIZED_KEYS")
        fi
    fi

    # Try to use default SSH public key if none specified
    if [[ ${#ssh_keys[@]} -eq 0 ]]; then
        for keyfile in ~/.ssh/id_rsa.pub ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub; do
            if [[ -f "$keyfile" ]]; then
                ssh_keys+=("$(cat "$keyfile")")
                info "Using default SSH key: $keyfile"
                # Also set VM_SSH_KEY to the private key if not set
                if [[ -z "$VM_SSH_KEY" ]]; then
                    VM_SSH_KEY="${keyfile%.pub}"
                fi
                break
            fi
        done
    fi

    # Generate password hash if password provided
    if [[ -n "$VM_PASSWORD" ]]; then
        if command -v openssl &>/dev/null; then
            password_hash=$(openssl passwd -6 "$VM_PASSWORD")
        elif command -v mkpasswd &>/dev/null; then
            password_hash=$(mkpasswd -m sha-512 "$VM_PASSWORD")
        else
            warn "Cannot hash password - openssl or mkpasswd not found"
        fi
    fi

    # Build SSH keys JSON array
    local ssh_keys_json="[]"
    if [[ ${#ssh_keys[@]} -gt 0 ]]; then
        ssh_keys_json="["
        for i in "${!ssh_keys[@]}"; do
            [[ $i -gt 0 ]] && ssh_keys_json+=","
            # Escape the key for JSON
            local escaped_key=$(printf '%s' "${ssh_keys[$i]}" | sed 's/\\/\\\\/g; s/"/\\"/g')
            ssh_keys_json+="\"${escaped_key}\""
        done
        ssh_keys_json+="]"
    fi

    # Create temp directory for ISO contents
    local iso_tmp=$(mktemp -d)
    mkdir -p "${iso_tmp}/ignition"

    # Generate Ignition config (spec 3.3.0)
    cat > "${iso_tmp}/ignition/config.ign" <<EOF
{
  "ignition": {
    "version": "3.3.0"
  },
  "passwd": {
    "users": [
      {
        "name": "${VM_SSH_USER}",
        "sshAuthorizedKeys": ${ssh_keys_json}$(if [[ -n "$password_hash" ]]; then echo ",
        \"passwordHash\": \"${password_hash}\""; fi),
        "groups": ["wheel"]
      }
    ]
  },
  "storage": {
    "files": [
      {
        "path": "/etc/hostname",
        "mode": 420,
        "overwrite": true,
        "contents": {
          "source": "data:,${VM_NAME}"
        }
      }
    ]
  }
}
EOF

    # Create ISO with label "ignition"
    local iso_tmp_file=$(mktemp)
    if command -v genisoimage &>/dev/null; then
        genisoimage -o "$iso_tmp_file" -V "ignition" -r -J "${iso_tmp}" 2>/dev/null
    elif command -v mkisofs &>/dev/null; then
        mkisofs -o "$iso_tmp_file" -V "ignition" -r -J "${iso_tmp}" 2>/dev/null
    else
        error "Neither genisoimage nor mkisofs found - cannot create ignition ISO"
        rm -rf "${iso_tmp}" "$iso_tmp_file"
        return 1
    fi
    rm -rf "${iso_tmp}"

    # Move to final location with sudo for libvirt paths
    sudo mv "$iso_tmp_file" "$iso_path"
    sudo chmod 644 "$iso_path"

    info "Generated Ignition ISO: $iso_path"
    debug "SSH keys configured: ${#ssh_keys[@]}"
    debug "Password configured: $(if [[ -n "$password_hash" ]]; then echo 'yes'; else echo 'no'; fi)"
}

# Get VM IP address from libvirt
get_vm_ip() {
    local vm_name="$1"
    local ip=""

    # Try to get IP from libvirt's DHCP leases
    ip=$(virsh domifaddr "$vm_name" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | head -1)

    if [[ -z "$ip" ]]; then
        # Fallback: try to get from arp based on MAC address
        local mac=$(virsh domiflist "$vm_name" 2>/dev/null | awk '/network|bridge/ {print $5}' | head -1)
        if [[ -n "$mac" ]]; then
            ip=$(arp -an 2>/dev/null | grep -i "$mac" | awk '{print $2}' | tr -d '()')
        fi
    fi

    echo "$ip"
}

# Wait for SSH to become available
wait_for_ssh() {
    local ip="$1"
    local timeout="$2"
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes"

    if [[ -n "$VM_SSH_KEY" ]]; then
        ssh_opts+=" -i $VM_SSH_KEY"
    fi

    info "Waiting for SSH to become available on $ip (timeout: ${timeout}s)..."

    local start_time=$(date +%s)
    local end_time=$((start_time + timeout))

    while [[ $(date +%s) -lt $end_time ]]; do
        if ssh $ssh_opts "${VM_SSH_USER}@${ip}" "echo 'SSH ready'" &>/dev/null; then
            info "SSH connection established!"
            return 0
        fi
        sleep 5
    done

    error "Timeout waiting for SSH on $ip"
    return 1
}

# Wait for VM to obtain an IP address
# Returns: Sets VM_IP global variable, returns 0 on success, 1 on timeout
wait_for_vm_ip() {
    local vm_name="$1"
    local timeout="${2:-60}"

    info "Waiting for VM to obtain IP address (timeout: ${timeout}s)..."

    local start_time=$(date +%s)
    local end_time=$((start_time + timeout))
    VM_IP=""

    while [[ -z "$VM_IP" ]] && [[ $(date +%s) -lt $end_time ]]; do
        sleep 2
        VM_IP=$(get_vm_ip "$vm_name")
    done

    if [[ -z "$VM_IP" ]]; then
        error "Failed to get VM IP address after ${timeout}s"
        return 1
    fi

    info "VM IP address: $VM_IP"
    return 0
}

# Connect to VM interactively via SSH
connect_vm_ssh() {
    local ip="$1"
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    
    if [[ -n "$VM_SSH_KEY" ]]; then
        ssh_opts="$ssh_opts -i $VM_SSH_KEY"
    fi
    
    info "Connecting to ${VM_SSH_USER}@${ip}..."
    ssh $ssh_opts "${VM_SSH_USER}@${ip}"
}

# Connect to VM interactively via serial console
connect_vm_console() {
    local vm_name="$1"
    info "Connecting to console..."
    info "Press Ctrl+] to disconnect from console"
    sleep 1
    virsh console "$vm_name"
}

# Execute scripts on VM via SSH
run_scripts_on_vm() {
    local ip="$1"
    shift
    local scripts=("$@")
    local failed=0

    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
    if [[ -n "$VM_SSH_KEY" ]]; then
        ssh_opts+=" -i $VM_SSH_KEY"
    fi

    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            info "Running script: $script"
            # Copy script to VM and execute
            local remote_script="/tmp/$(basename "$script")"
            if ! scp $ssh_opts "$script" "${VM_SSH_USER}@${ip}:${remote_script}"; then
                error "Failed to copy script: $script"
                failed=1
                continue
            fi
            if ! ssh $ssh_opts "${VM_SSH_USER}@${ip}" "chmod +x ${remote_script} && sudo ${remote_script}"; then
                error "Script failed: $script"
                failed=1
            else
                info "Script completed: $script"
            fi
        elif [[ "$script" == *";"* ]] || [[ "$script" == *"&&"* ]] || [[ "$script" =~ ^[a-zA-Z] ]]; then
            # Treat as inline command
            info "Running command: $script"
            if ! ssh $ssh_opts "${VM_SSH_USER}@${ip}" "sudo bash -c '$script'"; then
                error "Command failed: $script"
                failed=1
            else
                info "Command completed"
            fi
        else
            warn "Script not found and not a valid command: $script"
            failed=1
        fi
    done

    return $failed
}

# Wait for VM to boot and show login prompt via serial console
wait_for_vm_boot() {
    local vm_name="$1"
    local timeout="${2:-300}"

    info "Connecting to VM console (will disconnect on login prompt, timeout: ${timeout}s)..."
    echo "═══════════════════════════════════════════════════════════════════════════════"

    # Check if expect is available
    if ! command -v expect &>/dev/null; then
        error "'expect' is required for console monitoring. Install with: apt-get install expect"
        return 1
    fi

    # Create expect script that monitors console and disconnects on login prompt
    local expect_script=$(mktemp)
    cat > "$expect_script" <<'EXPECT_EOF'
#!/usr/bin/expect -f
set timeout [lindex $argv 0]
set vm_name [lindex $argv 1]

log_user 1

# Connect to VM console
spawn virsh console $vm_name

# Wait for console connection, then monitor for login prompt
expect {
    "Escape character" {
        # Send Enter to trigger any pending output
        send "\r"
        exp_continue
    }
    -re {(login:|Login:)} {
        # Login prompt detected - VM has booted
        puts "\n═══════════════════════════════════════════════════════════════════════════════"
        puts "✓ Login prompt detected - VM boot complete"
        # Send escape sequence to disconnect from console
        send "\x1d"
        expect eof
        exit 0
    }
    timeout {
        puts "\n═══════════════════════════════════════════════════════════════════════════════"
        puts "✗ Timeout waiting for login prompt"
        send "\x1d"
        expect eof
        exit 1
    }
    eof {
        puts "\n═══════════════════════════════════════════════════════════════════════════════"
        puts "✗ Console connection lost"
        exit 1
    }
}
EXPECT_EOF

    chmod +x "$expect_script"

    # Run expect script - output goes directly to terminal
    if "$expect_script" "$timeout" "$vm_name"; then
        rm -f "$expect_script"
        return 0
    else
        rm -f "$expect_script"
        return 1
    fi
}

# Execute a command via serial console using expect
run_command_via_console() {
    local vm_name="$1"
    local command="$2"
    local user="${3:-root}"
    local password="${4:-}"
    local timeout="${5:-60}"

    # Check if expect is available
    if ! command -v expect &>/dev/null; then
        error "'expect' is required for serial console execution. Install with: apt-get install expect"
        return 1
    fi

    info "Running command via serial console: $command"

    # Escape the command for TCL - replace backslashes, quotes, and dollars
    local tcl_safe_command="${command//\\/\\\\}"  # Escape backslashes first
    tcl_safe_command="${tcl_safe_command//\"/\\\"}"  # Escape double quotes
    tcl_safe_command="${tcl_safe_command//\$/\\\$}"  # Escape dollar signs
    tcl_safe_command="${tcl_safe_command//\[/\\\[}"  # Escape square brackets
    tcl_safe_command="${tcl_safe_command//\]/\\\]}"  # Escape square brackets

    # Create expect script
    local expect_script=$(mktemp)
    cat > "$expect_script" <<EXPECT_EOF
#!/usr/bin/expect -f
set timeout $timeout
log_user 1

# Connect to VM console
spawn virsh console $vm_name

# Wait for console connection
expect {
    "Escape character" {
        send "\r"
    }
    timeout {
        puts "ERROR: Failed to connect to console"
        exit 1
    }
}

# Wait for login prompt or shell prompt
expect {
    -re "login:|Login:" {
        send "$user\r"
        # Handle password if needed
        expect {
            -re "[Pp]assword:" {
                send "$password\r"
                expect -re "\\$|#"
            }
            -re "\\$|#" {
                # No password needed
            }
            timeout {
                puts "ERROR: Timeout after login"
                exit 1
            }
        }
    }
    -re "\\$|#" {
        # Already logged in at shell prompt
    }
    timeout {
        puts "ERROR: Timeout waiting for login prompt"
        exit 1
    }
}

# Send command
send "$tcl_safe_command\r"

# Wait for command completion and capture exit code
expect {
    -re "SCRIPT_EXIT_CODE:(\[0-9\]+)" {
        set exit_code \$expect_out(1,string)
        # Wait a moment for any remaining output
        sleep 0.5
        if {\$exit_code != "0"} {
            puts "Command failed with exit code: \$exit_code"
            exit 1
        }
    }
    timeout {
        puts "ERROR: Command timeout"
        exit 1
    }
}

# Exit cleanly - send Ctrl+] to disconnect from console
send "\035"
expect eof
exit 0
EXPECT_EOF

    chmod +x "$expect_script"

    # Run expect script
    local result=0
    "$expect_script" || result=$?

    rm -f "$expect_script"

    return $result
}

# Run scripts via serial console
run_scripts_via_console() {
    local vm_name="$1"
    shift
    local scripts=("$@")
    local failed=0

    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            info "Running script via console: $script"
            # Read script and execute line by line (simple approach)
            # For complex scripts, we'd need to base64 encode and decode
            local script_content
            script_content=$(cat "$script")

            # Base64 encode the script and decode+execute on VM
            local encoded
            encoded=$(base64 -w0 "$script")
            local remote_cmd="echo '$encoded' | base64 -d > /tmp/script.sh && chmod +x /tmp/script.sh && /tmp/script.sh; echo \"SCRIPT_EXIT_CODE:\$?\""

            if ! run_command_via_console "$vm_name" "$remote_cmd" "$VM_CONSOLE_USER" "$VM_CONSOLE_PASSWORD"; then
                error "Script failed: $script"
                failed=1
            else
                info "✓ Script completed successfully: $script"
            fi
        elif [[ "$script" == *";"* ]] || [[ "$script" == *"&&"* ]] || [[ "$script" =~ ^[a-zA-Z] ]]; then
            # Treat as inline command
            info "Running command via console: $script"
            if ! run_command_via_console "$vm_name" "$script" "$VM_CONSOLE_USER" "$VM_CONSOLE_PASSWORD"; then
                error "Command failed: $script"
                failed=1
            else
                info "Command completed"
            fi
        else
            warn "Script not found and not a valid command: $script"
            failed=1
        fi
    done

    return $failed
}

# Print summary of what will be done
print_summary() {
    section "Hybrid Image Build Summary"

    echo "This script will:"
    echo

    if [[ "$DOWNLOAD_RPMS" == "true" ]]; then
        echo "  1. Download Azure Linux RPM packages"
        echo "     Target: ${STAGING_DIR}"
        if [[ "$CLEAN_STAGING" == "true" ]]; then
            echo "     Mode: Clean download (remove existing)"
        else
            echo "     Mode: Incremental (skip existing)"
        fi
        echo
    fi

    if [[ "$BUILD_RPMS" == "true" ]]; then
        echo "  2. Build custom RPM packages"
        echo "     Output: ${STAGING_DIR}"
        echo
    fi

    if [[ "$BUILD_IMAGE" == "true" ]]; then
        echo "  3. Build Flatcar image using SDK container"
        echo "     Board: ${BOARD}"
        echo "     Group: ${GROUP}"
        echo "     Mode: HYBRID (Azure Linux RPMs + Portage)"
        echo
    fi

    echo
}

remove_old_vm() {
    # clean up existing vm if it exists
    info "cleaning up existing vm '${VM_NAME}' if present..."
    virsh destroy "${VM_NAME}" 2>/dev/null || true
    virsh undefine --nvram "${VM_NAME}" 2>/dev/null || true
}

print_size_summary() {
    section "Image Size Summary"

    # Find the latest build directory
    local build_dir="${OUTPUT_ROOT}"
    BUILD_IMAGE_DIR="${build_dir}/images/images/${BOARD}/latest"
    if [[ -d "${BUILD_IMAGE_DIR}" ]]; then
        info "Build directory: ${BUILD_IMAGE_DIR}"
        echo

        # USR partition image
        if [[ -f "${BUILD_IMAGE_DIR}/flatcar_production_image.bin" ]]; then
            usr_size=$(du -h "${BUILD_IMAGE_DIR}/flatcar_production_image.bin" | cut -f1)
            info "USR Image:    ${usr_size}  (${BUILD_IMAGE_DIR}/flatcar_production_image.bin)"
        fi

        # Sysext images
        if ls "${BUILD_IMAGE_DIR}"/rootfs-included-sysexts/*.raw &>/dev/null; then
            echo
            info "Sysext Images:"
            for sysext in "${BUILD_IMAGE_DIR}"/rootfs-included-sysexts/*.raw; do
                if [[ -f "$sysext" ]]; then
                    sysext_size=$(du -h "$sysext" | cut -f1)
                    sysext_name=$(basename "$sysext")
                    info "  - ${sysext_name}: ${sysext_size}"
                fi
            done
        fi

        # Full disk image
        if [[ -f "${BUILD_IMAGE_DIR}/flatcar_production_image.bin" ]]; then
            echo
            full_size=$(du -h "${BUILD_IMAGE_DIR}/flatcar_production_image.bin" | cut -f1)
            info "Full Image:   ${full_size}  (total disk image)"
        fi
    else
        warn "Build directory not found: ${BUILD_IMAGE_DIR}"
    fi
    echo
}

# Main entry point
main() {
    parse_args "$@"

    section "Flatcar Hybrid Image Builder"
    info "Building ${BOARD} ${GROUP} image using Azure Linux RPMs"

    check_prerequisites
    print_summary

    # Step 0: Update SDK container if requested (before download/build)
    if [[ "$BUILD_SDK_CONTAINER" == "true" ]]; then
        update_sdk_container
        info "Updated SDK container. Existing SDK containers removed. For subsequent runs, remove the --build-sdk-container flag to speed up."
    else 
        info "Skipping SDK container update"
        info "Found the following SDK containers:"
        docker ps -a --filter "name=flatcar-sdk-" --format "{{.ID}} {{.Names}}"
    fi

    # Step 1: Download RPMs (if requested)
    if [[ "$DOWNLOAD_RPMS" == "true" ]]; then
        download_rpms
    fi

    # Step 2: Build custom RPM packages (if requested)
    if [[ "$BUILD_RPMS" == "true" ]]; then
        build_rpms
    fi

    # Step 3: Build image (if requested)
    if [[ "$BUILD_IMAGE" == "true" ]]; then
        build_image
        print_size_summary
    fi

    # Step 3: Build VM images (if requested)
    local vm_image_path="__build__/images/images/${BOARD}/latest/flatcar_production_qemu_uefi_image.img"
    if [[ "$BUILD_VM_IMAGE" == "true" ]]; then
        section "Building VM Images"
        remove_old_vm
        info "Converting base image to VM formats..."
        
        # Get SDK image to use
        source "${SCRIPT_DIR}/sdk_lib/sdk_container_common.sh"
        local sdk_version=$(get_sdk_version_from_versionfile)
        local docker_sdk_vernum=$(vernum_to_docker_image_version "$sdk_version")
        local sdk_image="${sdk_container_common_registry}/flatcar-sdk-all:${docker_sdk_vernum}"
        
        # Use -C to specify custom SDK image (avoids trying to download non-existent version-specific image)
        # Use --rm to remove old container and ensure environment variables are set correctly
        ./run_sdk_container --rm -C "${sdk_image}" ./image_to_vm.sh --image_compression_formats=none --from=../build/images/${BOARD}/latest --board=${BOARD}
        
        if ! [[ -f $vm_image_path ]]; then
            error "Image generation failed"
            exit 1
        fi
        info "VM image ready at: ${vm_image_path}"
    fi

    if [[ "$START_VM" == "true" ]]; then
        if ! command -v virsh &>/dev/null; then
            error "Cannot start VM: virsh not found"
            exit 1
        fi

        section "Starting VM: ${VM_NAME}"

        remove_old_vm

        booted_image_path="${vm_image_path}.booted"
        cp "${vm_image_path}" "${booted_image_path}"
        
        # Get absolute path for disk image
        local abs_disk_path="$(cd "$(dirname "${booted_image_path}")" && pwd)/$(basename "${booted_image_path}")"
        
        # Get paths to OVMF firmware files with secure boot
        local ovmf_code="/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd"
        local ovmf_vars_template="/usr/share/edk2/x64/OVMF_VARS.ms.4m.fd"
        
        # Fallback paths if the above don't exist
        if [[ ! -f "$ovmf_code" ]]; then
            ovmf_code="/usr/share/OVMF/OVMF_CODE.secboot.fd"
        fi
        if [[ ! -f "$ovmf_vars_template" ]]; then
            # Try ms.fd (Microsoft keys enrolled) first, then secboot, then regular
            for vars_file in "/usr/share/edk2/x64/OVMF_VARS.ms.fd" "/usr/share/OVMF/OVMF_VARS.ms.fd" "/usr/share/edk2/x64/OVMF_VARS.secboot.fd" "/usr/share/OVMF/OVMF_VARS.secboot.fd" "/usr/share/edk2/x64/OVMF_VARS.4m.fd" "/usr/share/OVMF/OVMF_VARS.fd"; do
                if [[ -f "$vars_file" ]]; then
                    ovmf_vars_template="$vars_file"
                    break
                fi
            done
        fi
        
        if [[ ! -f "$ovmf_code" ]] || [[ ! -f "$ovmf_vars_template" ]]; then
            error "OVMF firmware files not found"
            error "Searched for: $ovmf_code and $ovmf_vars_template"
            exit 1
        fi
        
        info "Using OVMF firmware:"
        info "  Code: $ovmf_code"
        info "  Vars: $ovmf_vars_template"
        
        # Create a writable copy of OVMF_VARS for this VM
        local vm_vars_path="${abs_disk_path}.vars"
        cp "$ovmf_vars_template" "$vm_vars_path"
        
        # Generate Ignition config ISO for user provisioning (colocated with disk image)
        local ignition_iso="${abs_disk_path%.qcow2}-ignition.iso"
        generate_ignition_iso "$ignition_iso"
        
        # Create VM XML definition with secure boot enabled
        info "Creating VM definition with secure boot..."
        cat > /tmp/${VM_NAME}.xml <<EOF
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>${VM_NAME}</name>
  <memory unit='KiB'>2097152</memory>
  <currentMemory unit='KiB'>2097152</currentMemory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' secure='yes' type='pflash'>${ovmf_code}</loader>
    <nvram>${vm_vars_path}</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <smm state='on'/>
  </features>
  <cpu mode='host-passthrough'/>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${abs_disk_path}'/>
      <target dev='sda' bus='sata'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${ignition_iso}'/>
      <target dev='sdb' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='e1000'/>
    </interface>
    <console type='pty'>
      <target type='serial'/>
    </console>
    <tpm model='tpm-crb'>
      <backend type='emulator' version='2.0'/>
    </tpm>
  </devices>
</domain>
EOF

        # Define and start the VM with virsh
        info "Defining VM with virsh..."
        virsh define /tmp/${VM_NAME}.xml
        
        info "Starting VM..."
        virsh start "${VM_NAME}"
        
        rm -f /tmp/${VM_NAME}.xml
        info "VM '${VM_NAME}' started successfully!"

        # If scripts are specified, run them via serial console or SSH
        if [[ ${#RUN_SCRIPTS[@]} -gt 0 ]]; then
            section "Running Scripts on VM"

            if [[ "$USE_SERIAL_CONSOLE" == "true" ]]; then
                # Use serial console execution
                info "Using serial console for script execution"
                
                # Wait for VM to boot by monitoring console
                if ! wait_for_vm_boot "${VM_NAME}" "$VM_BOOT_TIMEOUT"; then
                    error "VM failed to boot within timeout"
                    exit 1
                fi

                # Run scripts via console
                if run_scripts_via_console "${VM_NAME}" "${RUN_SCRIPTS[@]}"; then
                    info "All scripts completed successfully!"
                else
                    error "One or more scripts failed"
                    exit 1
                fi
            else
                # Use SSH execution
                info "Using SSH for script execution"

                # Wait for VM IP and SSH
                if ! wait_for_vm_ip "${VM_NAME}" 60; then
                    warn "You can still connect manually: virsh console ${VM_NAME}"
                    exit 1
                fi

                if wait_for_ssh "$VM_IP" "$VM_SSH_TIMEOUT"; then
                    if run_scripts_on_vm "$VM_IP" "${RUN_SCRIPTS[@]}"; then
                        info "All scripts completed successfully!"
                    else
                        error "One or more scripts failed"
                        exit 1
                    fi
                else
                    error "SSH not available - cannot run scripts"
                    warn "Try using --use-serial for serial console execution"
                    warn "You can still connect manually: virsh console ${VM_NAME}"
                fi
            fi
            # Only run nginx curl test if we executed the container test
            if [[ ${#RUN_SCRIPTS[@]} -gt 0 ]] && [[ "${RUN_SCRIPTS[-1]}" == *"run-container-test.sh" ]]; then
                if [[ -z "${VM_IP:-}" ]]; then
                    VM_IP=$(get_vm_ip "${VM_NAME}")
                fi
                curl --connect-timeout 10 --max-time 30 http://$VM_IP | grep "Thank you for using nginx."
            fi
            print_size_summary
        else
            # No scripts - wait for boot, then connect via console or SSH based on setting
            echo
            info "Waiting for VM to boot (showing console output)..."
            
            # Wait for boot and show progress
            if ! wait_for_vm_boot "${VM_NAME}" "$VM_BOOT_TIMEOUT"; then
                warn "Boot detection timed out"
            fi
            
            if [[ "$USE_SERIAL_CONSOLE" == "true" ]]; then
                connect_vm_console "${VM_NAME}"
            else
                # Connect via SSH
                info "VM is ready! Connecting via SSH..."
                
                if wait_for_vm_ip "${VM_NAME}" 60 && wait_for_ssh "$VM_IP" "$VM_SSH_TIMEOUT"; then
                    connect_vm_ssh "$VM_IP"
                else
                    warn "SSH not available, falling back to console"
                    connect_vm_console "${VM_NAME}"
                fi
            fi
        fi

    else
        echo
        info "To deploy to libvirt, run:"
        echo "  virsh destroy ${VM_NAME} || true"
        echo "  virsh undefine --nvram ${VM_NAME} || true"
        echo "  virt-install --name ${VM_NAME} --memory 2048 --vcpus 2 --os-variant generic --import --disk ${vm_image_path} --network default --machine q35 --boot uefi --noautoconsole"
        echo "  virsh console ${VM_NAME}"
    fi
}

# Run main function
main "$@"
