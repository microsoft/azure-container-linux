#!/bin/bash
# Build Azure Container Linux (ACL) Image - Complete workflow
#
# This script builds an Azure Container Linux (ACL) image using Azure Linux RPMs where available,
# falling back to Portage packages for Flatcar-specific components.
#
# Usage:
#   ./build_rpm_image.sh [options]
#
# Options:
#   --az-storage-account=NAME            Azure storage account name to override default (for start-vm --vm-type=azure)
#   --az-sub-id=ID                       Azure subscription ID to override default (for start-vm --vm-type=azure)
#   --az-region=REGION                   Azure region to override default (for start-vm --vm-type=azure)
#   --board=BOARD                        Target board (default: amd64-usr)
#   --boot-timeout=SECS                  Timeout waiting for VM boot (default: 180)
#   --build-rpms                         Build custom RPM packages using Azure Linux toolkit (runs acl/build.sh)
#   --build-sdk-container                Update/rebuild SDK container with RPM tools (can run standalone)
#   --build-vm-image                     Build VM images after creating base image
#   --clean                              Clean staging directory before download
#   --console-password=PASS              Serial console login password (empty for passwordless)
#   --console-user=USER                  Serial console login user (default: root)
#   --download-rpms                      Download Azure Linux RPMs to staging directory
#   --download-unofficial-kernel         Download unofficial kernel RPMs from Azure DevOps build
#   --group=GROUP                        Image group: developer|production|prod (default: production)
#   --help                               Show this help message
#   --img-name=NAME                      Base image name prefix (default: acl_production)
#                                        Final image will be NAME_image.bin, VM image will be NAME_qemu_uefi_image.img
#   --no-cleanup                         Skip cleanup of existing VM resource groups (for start-vm --vm-type=azure)
#   --output=DIR                         Output directory for images
#   --rebuild                            Force rebuild even if image exists
#   --parity[=DIR]                       Run parity data collection and comparison report.
#                                        Requires os-diff repo (default DIR: ../os-diff)
#   --rebuild-and-test                   Rebuild image and run container tests (equivalent to
#                                        --rebuild --build-vm-image --start-vm --run-script ./run-container-test.sh)
#   --run-script=PATH                    Run script on VM after boot (can specify multiple times)
#                                        Can be a file path or inline command. Implies --start-vm
#   --run-kola-tests                     Run kola tests using run_local_tests.sh after building
#   --ssh-authorized-keys=KEYS           SSH public keys for VM access (file path or key string)
#   --ssh-key=PATH                       SSH private key for VM access
#   --ssh-timeout=SECS                   Timeout waiting for SSH (default: 120)
#   --ssh-user=USER                      SSH user for VM scripts (default: core)
#   --start-vm                           Start the VM after building (implies --build-vm-image)
#   --unofficial-kernel-build-id=ID      Specify Azure DevOps build ID for kernel (default: 1028516)
#   --use-serial                         Use serial console for script execution (default, no SSH/ignition needed)
#   --use-ssh                            Use SSH for script execution (requires working ignition/SSH keys)
#   --vm-name=NAME                       Name for the VM (default: acl)
#   --vm-type=TYPE                       VM type when building VM images: azure|qemu (default: qemu)
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
#   ACL_SDK_IMAGE           Override SDK container image (e.g., acldevel.azurecr.io/sdk:4459.0.0-rpm)
#                           Bypasses auto-detection from version.txt when set
#   NO_TTY                  Set to "true" to disable TTY allocation (for CI pipelines)
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
# Copyright (c) 2026, Microsoft Corporation.

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
USE_UNOFFICIAL_KERNEL=false
UNOFFICIAL_KERNEL_BUILD_ID="1037837"
CLEAN_STAGING=false
FORCE_REBUILD=false
BUILD_IMAGE=false
IMG_NAME="${IMG_NAME:-acl_production}"
BUILD_VM_IMAGE=false
VM_TYPE="${VM_TYPE:-qemu}"
START_VM=false
VM_NAME="${VM_NAME:-acl}"
OUTPUT_ROOT="${OUTPUT_ROOT:-__build__}"
STAGING_DIR="${SCRIPT_DIR}/__build__/rpm-staging"
DISK_LAYOUT="${DISK_LAYOUT:-vm}"  # Use 'vm' layout for larger ROOT partition (needed for RPM mode)
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
PARITY=""  # Path to os-diff directory for parity data collection and reporting
SECURE_BOOT_ENABLED="${SECURE_BOOT_ENABLED:-false}"  # Enable secure boot (disable for unsigned kernels)
RUN_KOLA_TESTS=false  # Run kola tests via run_local_tests.sh on a QEMU VM

# Set envi var-s required for RPM mode
export PACKAGE_SOURCE_MODE=RPM
export RPM_STAGING_DIR="${STAGING_DIR}"

# Var-s for Azure VM testing:
# - Subscription ID
AZ_SUB_ID="${AZ_SUB_ID_OVERRIDE:-b99b2264-54e6-408e-812b-2ec280c0ce7a}"
# - Region
AZ_REGION="${AZ_REGION_OVERRIDE:-eastus2}"
# - Storage RG
AZ_STORAGE_RG="acl-test-storage-rg"
# - Storage account
AZ_STORAGE_ACC="${AZ_STORAGE_ACC_OVERRIDE:-aclteststorageacc}"
# - Storage container
AZ_STORAGE_CONTAINER="acl-test-vm-img"
# - Gallery RG
AZ_GALLERY_RG="acl-test-gallery-rg"
# - Compute gallery
AZ_ACG="acltestacg"
# - VM image definition (user-specific to prevent race conditions when multiple users test concurrently)
AZ_VM_IMAGE_DEF="$(whoami)-acl-test-vm-img"
# - Prefix for VM RG name (user-specific to avoid conflicts)
VM_RG_PREFIX="$(whoami)-acl-test-vm-rg"
# - By default, set to false and clean up pre-existing VM RGs for the user
NO_CLEANUP="${NO_CLEANUP:-false}"

# Global variable to store the actual VM resource group name
# - For QEMU VMs: empty string (not used)
# - For Azure VMs: set by start_vm_azure() to actual RG name
VM_RG=""

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

# Get SDK container image to use for builds
# If ACL_SDK_IMAGE is set, use it directly (allows CI to specify pre-built SDK)
# Otherwise, auto-detect from version.txt
get_sdk_image() {
    if [[ -n "${ACL_SDK_IMAGE:-}" ]]; then
        echo "${ACL_SDK_IMAGE}"
        return
    fi

    # Auto-detect from version.txt
    source "${SCRIPT_DIR}/sdk_lib/sdk_container_common.sh"
    local sdk_version
    sdk_version=$(get_sdk_version_from_versionfile)
    local docker_sdk_vernum
    docker_sdk_vernum=$(vernum_to_docker_image_version "$sdk_version")
    echo "${sdk_container_common_registry}/flatcar-sdk-all:${docker_sdk_vernum}"
}

# Get TTY flag for run_sdk_container
# Returns "-t" for local dev (TTY available), empty for CI pipelines
get_tty_flag() {
    if [[ "${NO_TTY:-false}" == "true" ]]; then
        echo ""
    else
        echo "-t"
    fi
}

# Returns the path to the private SSH key that should be used for all flows. If VM_SSH_KEY is set,
# then returns it. Otherwise, searches for default SSH keys in priority order.
get_ssh_private_key() {
    # If VM_SSH_KEY is already set, return it
    if [[ -n "$VM_SSH_KEY" ]]; then
        echo "$VM_SSH_KEY"
        return 0
    fi
    
    # Search for default SSH keys in priority order
    for keyfile in ~/.ssh/id_rsa.pub ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub; do
        if [[ -f "$keyfile" ]]; then
            local private_key="${keyfile%.pub}"
            if [[ -f "$private_key" ]]; then
                echo "$private_key"
                return 0
            fi
        fi
    done
    
    echo ""
    return 1
}

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
            --img-name=*)
                IMG_NAME="${1#*=}"
                shift
                ;;
            --img-name)
                IMG_NAME="$2"
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
            --download-unofficial-kernel)
                USE_UNOFFICIAL_KERNEL=true
                shift
                ;;
            --unofficial-kernel-build-id=*)
                UNOFFICIAL_KERNEL_BUILD_ID="${1#*=}"
                USE_UNOFFICIAL_KERNEL=true
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
                # Disabled while we are running on the buddy built kernel
                # RUN_SCRIPTS+=("./acl/tests/run-secureboot-test.sh")
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
            --vm-type=*)
                VM_TYPE="${1#*=}"
                shift
                ;;
            --vm-type)
                VM_TYPE="$2"
                shift 2
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
            --parity=*)
                PARITY="${1#*=}"
                shift
                ;;
            --parity)
                # Use default sibling os-diff directory
                PARITY="${SCRIPT_DIR}/../os-diff"
                shift
                ;;
            --no-secure-boot)
                SECURE_BOOT_ENABLED=false
                shift
                ;;
            --az-sub-id=*)
                AZ_SUB_ID_OVERRIDE="${1#*=}"
                shift
                ;;
            --az-sub-id)
                AZ_SUB_ID_OVERRIDE="$2"
                shift 2
                ;;
            --az-region=*)
                AZ_REGION_OVERRIDE="${1#*=}"
                shift
                ;;
            --az-region)
                AZ_REGION_OVERRIDE="$2"
                shift 2
                ;;
            --az-storage-account=*)
                AZ_STORAGE_ACC_OVERRIDE="${1#*=}"
                shift
                ;;
            --az-storage-account)
                AZ_STORAGE_ACC_OVERRIDE="$2"
                shift 2
                ;;
            --no-cleanup)
                NO_CLEANUP=true
                shift
                ;;
            --run-kola-tests)
                RUN_KOLA_TESTS=true
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

    # Validate VM type if building VM images
    if [[ "$BUILD_VM_IMAGE" == "true" ]] || [[ "$START_VM" == "true" ]]; then
        case "$VM_TYPE" in
            azure|qemu)
                # Valid VM type
                ;;
            *)
                error "Invalid VM type: $VM_TYPE"
                error "Valid options: azure, qemu"
                exit 1
                ;;
        esac
    fi
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

    # Check swtpm on Azure Linux 3 if VM operations are planned
    if [[ "$START_VM" == "true" ]] || [[ "$BUILD_VM_IMAGE" == "true" ]]; then
        check_swtpm_azure_linux
    fi

    # Check libvirt/virsh when starting a QEMU VM or running kola tests
    if [[ "$VM_TYPE" == "qemu" ]] && ([[ "$START_VM" == "true" ]] || [[ "$RUN_KOLA_TESTS" == "true" ]]); then
        if ! command -v virsh &>/dev/null; then
            error "virsh not found - required for VM operations and kola tests"
            if is_azure_linux_3; then
                error "Install with: sudo tdnf install -y libvirt libvirt-client qemu-kvm"
            else
                error "Install with: sudo apt-get install -y libvirt-clients libvirt-daemon-system qemu-kvm"
            fi
            exit 1
        fi
        info "✓ virsh found"

        if ! ensure_libvirt_network; then
            warnings=$((warnings + 1))
        fi
    fi

    # Check Azure CLI when starting an Azure VM
    if [[ "$START_VM" == "true" ]] && [[ "$VM_TYPE" == "azure" ]]; then
        if ! check_azure_prereqs; then
            error "Azure prerequisites not met"
            exit 1
        fi
        
        # Check for serial-console extension if using serial console
        if [[ "$USE_SERIAL_CONSOLE" == "true" ]]; then
            if ! az extension show --name serial-console &>/dev/null 2>&1; then
                info "Installing Azure CLI serial-console extension..."
                if ! az extension add --name serial-console; then
                    error "Failed to install serial-console extension"
                    error "Install manually with: az extension add --name serial-console"
                    exit 1
                fi
                info "✓ Azure CLI serial-console extension installed"
            else
                info "✓ Azure CLI serial-console extension found"
            fi
        fi
    fi

    # Check expect when starting a QEMU VM (needed for serial console automation)
    if [[ "$START_VM" == "true" ]] && [[ "$VM_TYPE" == "qemu" ]]; then
        if ! command -v expect &>/dev/null; then
            error "expect not found - required for VM serial console automation"
            if is_azure_linux_3; then
                error "Install with: sudo tdnf install -y expect"
            else
                error "Install with: sudo apt-get install -y expect"
            fi
            exit 1
        fi
        info "✓ expect found"
    fi

    # Check SSH key when running kola tests or using SSH for scripts
    if [[ "$RUN_KOLA_TESTS" == "true" ]] || [[ "$USE_SERIAL_CONSOLE" == "false" ]]; then
        local ssh_key_path
        ssh_key_path=$(get_ssh_private_key)
        if [[ -z "$ssh_key_path" || ! -f "$ssh_key_path" ]]; then
            error "SSH private key not found"
            error "SSH key is required for kola tests and SSH-based VM access"
            error "Generate one with: ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa"
            error "Or specify with: --ssh-key=PATH"
            exit 1
        fi
        # Check corresponding public key exists
        if [[ ! -f "${ssh_key_path}.pub" ]]; then
            error "SSH public key not found at: ${ssh_key_path}.pub"
            error "The public key is needed for VM provisioning"
            exit 1
        fi
        # Update VM_SSH_KEY for global access
        VM_SSH_KEY="$ssh_key_path"
        info "✓ SSH key found at $ssh_key_path"
    fi

    if [[ $warnings -gt 0 ]]; then
        warn "$warnings warning(s) detected - some operations may fail"
        echo
    fi

    info "✓ All prerequisites met"
}

# Checks prerequisites for Azure CLI operations.
check_azure_prereqs() {
    info "Checking Azure prerequisites..."
    if ! command -v az &>/dev/null; then
        error "Azure CLI (az) not found - required for Azure VM operations"
        if is_azure_linux_3; then
            error "Install with: sudo tdnf install -y azure-cli"
        else
            error "Install with: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
        fi
        return 1
    fi
    
    # Check if logged into Azure with a valid token
    if ! az account show &>/dev/null; then
        error "Not logged into Azure. Please run: az login"
        return 1
    fi
    
    # Test that the token is actually valid by attempting a simple operation
    if ! az group list --query "[]" -o tsv &>/dev/null; then
        error "Azure authentication token has expired or is invalid"
        error "Please re-authenticate with Azure:"
        error "  az logout"
        error "  az login"
        return 1
    fi

    info "✓ Azure prerequisites met"
}

# Downloads Azure Linux RPMs.
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

# Downloads unofficial kernel RPMs from Azure DevOps build artifacts.
download_unofficial_kernel() {
    section "Downloading Unofficial Kernel from Azure DevOps"

    local build_id="${UNOFFICIAL_KERNEL_BUILD_ID}"
    local org="https://dev.azure.com/mariner-org"
    local project="mariner"
    # Artifact name for AMD64 kernel build
    local artifact_name="drop_buddy_build_amd64_build_amd64"
    local temp_dir="${STAGING_DIR}/.unofficial-kernel-temp"

    info "Build ID: ${build_id}"
    info "Organization: ${org}"
    info "Project: ${project}"
    info "Artifact: ${artifact_name}"

    # Check for az CLI
    if ! command -v az &>/dev/null; then
        error "Azure CLI (az) not found - required to download unofficial kernel"
        if is_azure_linux_3; then
            error "Install with: sudo tdnf install -y azure-cli"
        else
            error "Install with: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
        fi
        exit 1
    fi

    # Check for azure-devops extension
    if ! az extension show --name azure-devops &>/dev/null 2>&1; then
        info "Installing azure-devops extension..."
        az extension add --name azure-devops
    fi

    # Create temp directory
    rm -rf "${temp_dir}"
    mkdir -p "${temp_dir}"

    info "Downloading artifacts from build ${build_id}..."
    
    if ! az pipelines runs artifact download \
        --artifact-name "${artifact_name}" \
        --path "${temp_dir}" \
        --run-id "${build_id}" \
        --org "${org}" \
        --project "${project}"; then
        error "Failed to download artifacts from Azure DevOps"
        error "Ensure you are logged in with: az login"
        error "And have access to ${org}/${project}"
        error "Available artifacts can be listed with:"
        error "  az pipelines runs artifact list --run-id ${build_id} --org ${org} --project ${project}"
        rm -rf "${temp_dir}"
        exit 1
    fi

    # Look for rpms.tar.gz in the downloaded artifacts
    local rpms_tarball
    rpms_tarball=$(find "${temp_dir}" -name "rpms.tar.gz" -type f | head -1)
    
    if [[ -z "${rpms_tarball}" || ! -f "${rpms_tarball}" ]]; then
        # List what was downloaded for debugging
        warn "Contents of downloaded artifacts:"
        find "${temp_dir}" -type f 2>/dev/null | head -30 || true
        error "rpms.tar.gz not found in downloaded artifacts"
        rm -rf "${temp_dir}"
        exit 1
    fi

    info "Found: ${rpms_tarball}"
    info "Extracting kernel RPMs..."
    
    # Detect file type and extract accordingly
    local file_type
    file_type=$(file -b "${rpms_tarball}" 2>/dev/null || echo "unknown")
    info "File type: ${file_type}"
    
    # Extract RPMs to staging directory
    # The Azure DevOps artifact is a plain tar archive (despite .tar.gz extension)
    local extract_failed=false
    if ! tar -xf "${rpms_tarball}" -C "${temp_dir}"; then
        extract_failed=true
    fi
    
    if [[ "${extract_failed}" == "true" ]]; then
        error "Failed to extract rpms.tar.gz (type: ${file_type})"
        error "Temp directory preserved for debugging: ${temp_dir}"
        exit 1
    fi

    # Find and copy RPM files to staging
    local rpm_count=0
    while IFS= read -r -d '' rpm_file; do
        cp "${rpm_file}" "${STAGING_DIR}/"
        ((rpm_count++)) || true
    done < <(find "${temp_dir}" -name "*.rpm" -type f -print0)

    if [[ "${rpm_count}" -eq 0 ]]; then
        error "No RPM files found in the extracted artifacts"
        error "Temp directory preserved for debugging: ${temp_dir}"
        exit 1
    fi

    info "✓ Extracted ${rpm_count} RPM packages from unofficial kernel build"

    # Clean up temp directory
    rm -rf "${temp_dir}"

    # Update repository metadata
    create_repo
}

# Verifies critical packages are in staging.
verify_critical_packages() {
    info "Verifying critical packages..."

    local critical_packages=(
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

# Creates or updates repository metadata for the staging directory.
create_repo() {
    info "Creating repository metadata..."
    
    if ! command -v createrepo_c &>/dev/null; then
        error "createrepo_c not found - required to create repository metadata"
        error "  Install with: sudo dnf install createrepo_c or sudo apt install createrepo-c"
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

# Cleans up old Docker containers matching a filter pattern.
cleanup_containers() {
    local filter="${1:-name=flatcar-sdk-}"

    info "Cleaning up old containers..."
    docker ps -a --filter "${filter}" --format "{{.ID}} {{.Names}}" | while read -r id name; do
        info "  Removing container: $name ($id)"
        docker rm -f "$id" 2>/dev/null || true
    done
}

# Updates/rebuilds the SDK container with RPM tools.
update_sdk_container() {
    section "Updating SDK Container"

    info "Rebuilding SDK container with RPM/dnf5 tools..."

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
    ./run_sdk_container $(get_tty_flag) hostname

    # Update SDK container with RPM tools
    info "Installing RPM/dnf5 tools in SDK container..."
    ./update_sdk_container_image "${rpm_sdk_version}"

    # Clean up old SDK containers
    cleanup_containers "name=flatcar-sdk-"

    # Get updated SDK version
    local sdk_version=$(get_sdk_version_from_versionfile)
    local docker_sdk_vernum=$(vernum_to_docker_image_version "$sdk_version")
    local sdk_image="${sdk_container_common_registry}/flatcar-sdk-all:${docker_sdk_vernum}"

    info "✓ SDK container updated successfully"
    info "  Image: ${sdk_image}"
    echo
}

# Builds custom RPM packages using Azure Linux toolkit.
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

# Builds the Azure Container Linux (ACL) image using SDK container.
build_image() {
    section "Building Azure Container Linux Image"

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
        "--image_name=${IMG_NAME}_image.bin"
    )

    if [[ "$FORCE_REBUILD" == "true" ]]; then
        build_args+=("--replace")
    fi

    # Run the build inside SDK container
    info "Starting SDK container and build process..."

    local sdk_image
    sdk_image=$(get_sdk_image)

    info "Using SDK image: ${sdk_image}"
    # Use -C to specify the custom image (skips registry download)
    # Use --rm to remove old container and ensure environment variables are set correctly
    "${SCRIPT_DIR}/run_sdk_container" \
        --rm \
        $(get_tty_flag) \
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

# Shows build output location.
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

# Suggests troubleshooting steps.
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

# Generates Ignition config file for VM user provisioning.
# Writes the JSON config to the specified path for use with fw_cfg file parameter.
generate_ignition_config() {
    local config_path="$1"
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
        # Use the helper to get the private key, then derive the public key
        private_key=$(get_ssh_private_key)
        public_key="${private_key}.pub"
        ssh_keys+=("$(cat "$public_key")")
        info "Using default SSH key: $public_key"
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

    # Generate Ignition config (spec 3.3.0) - write to file
    cat > "${config_path}" <<EOF
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
    # Make world-readable so QEMU can access it
    chmod 644 "${config_path}"

    info "Generated Ignition config: $config_path"
    debug "SSH keys configured: ${#ssh_keys[@]}"
    debug "Password configured: $(if [[ -n "$password_hash" ]]; then echo 'yes'; else echo 'no'; fi)"
}

# Gets IP address of a QEMU VM from libvirt.
get_vm_ip_qemu() {
    local vm_name="$1"
    local ip=""

    # Try to get IP from virsh domifaddr (most reliable, queries VM directly)
    ip=$(virsh domifaddr "$vm_name" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | head -1)

    # Validate the IP is not empty and looks like an IP
    if [[ -n "$ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
        return 0
    fi

    echo ""
}

# Waits for SSH to become available.
wait_for_ssh() {
    local ip="$1"
    local timeout="$2"
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes"

    ssh_opts+=" -i $VM_SSH_KEY"

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

# Waits for a QEMU VM to obtain an IP address.
# Returns: Sets VM_IP global variable, returns 0 on success, 1 on timeout.
wait_for_vm_ip_qemu() {
    local vm_name="$1"
    local timeout="${2:-60}"

    info "Waiting for VM to obtain IP address (timeout: ${timeout}s)..."

    local start_time=$(date +%s)
    local end_time=$((start_time + timeout))
    VM_IP=""

    while [[ -z "$VM_IP" ]] && [[ $(date +%s) -lt $end_time ]]; do
        sleep 2
        VM_IP=$(get_vm_ip_qemu "$vm_name")
    done

    if [[ -z "$VM_IP" ]]; then
        error "Failed to get VM IP address after ${timeout}s"
        return 1
    fi

    info "VM IP address: $VM_IP"
    return 0
}

# Connects to VM interactively via SSH.
connect_vm_ssh() {
    local ip="$1"
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ssh_opts="$ssh_opts -i $VM_SSH_KEY"
    
    info "Connecting to ${VM_SSH_USER}@${ip}..."
    ssh $ssh_opts "${VM_SSH_USER}@${ip}"
}

# Connects to a QEMU VM interactively via serial console.
connect_vm_console_qemu() {
    local vm_name="$1"
    info "Connecting to console..."
    info "Press Ctrl+] to disconnect from console"
    sleep 1
    virsh console "$vm_name"
}

# Connects to an Azure VM interactively via serial console.
connect_vm_console_azure() {
    local vm_rg_name="$1"
    local vm_name="$2"
    
    info "Connecting to Azure VM serial console..."
    info "Press Ctrl+] followed by 'q' to disconnect from console"
    sleep 1
    
    # Use Azure serial console for true interactive experience
    az serial-console connect \
        --resource-group "$vm_rg_name" \
        --name "$vm_name"
}

# Executes scripts on VM via SSH.
run_scripts_on_vm() {
    local ip="$1"
    shift
    local scripts=("$@")
    local failed=0

    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
    ssh_opts+=" -i $VM_SSH_KEY"

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

# Waits for a QEMU VM to boot and show login prompt via serial console.
wait_for_vm_boot_qemu() {
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
    -re {(emergency|Emergency mode|Give root password|Press Enter for maintenance|Entering emergency mode|You are in emergency mode)} {
        # Emergency shell detected - switch to interactive mode
        puts "\n═══════════════════════════════════════════════════════════════════════════════"
        puts "⚠ EMERGENCY SHELL DETECTED - Switching to interactive console"
        puts "  Press Ctrl+] to disconnect"
        puts "═══════════════════════════════════════════════════════════════════════════════"
        # Enter interactive mode - pass control to user
        interact
        exit 2
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
    local exit_code
    "$expect_script" "$timeout" "$vm_name"
    exit_code=$?
    rm -f "$expect_script"
    
    case $exit_code in
        0) return 0 ;;                    # Normal boot completed
        2) warn "Emergency shell was detected - user exited interactive console"
           return 2 ;;                    # Emergency shell detected
        *) return 1 ;;                    # Timeout or other error
    esac
}

# Executes a command on a QEMU VM via serial console using expect.
run_command_via_console_qemu() {
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

# Executes a command on an Azure VM using Azure CLI.
run_command_vm_azure() {
    local vm_rg_name="$1"
    local vm_name="$2"
    local command="$3"
    local timeout="${4:-60}"

    info "Running command on Azure VM: $command"

    # Escape command for JSON
    local escaped_command
    escaped_command=$(printf '%s' "$command" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Create a script that runs the command and captures exit code
    local script_content="#!/bin/bash\nset -e\n$command\necho \"SCRIPT_EXIT_CODE:\$?\""

    # Execute command using Azure CLI run-command
    local result=0
    local output
    if output=$(az vm run-command invoke \
        --resource-group "$vm_rg_name" \
        --name "$vm_name" \
        --command-id RunShellScript \
        --scripts "$script_content" \
        --query 'value[0].message' \
        --output tsv 2>&1); then
        
        # Display the output
        echo "$output"
        
        # Check if command succeeded by looking for SCRIPT_EXIT_CODE:0
        if echo "$output" | grep -q "SCRIPT_EXIT_CODE:0"; then
            info "✓ Command completed successfully"
        else
            error "Command failed or returned non-zero exit code"
            result=1
        fi
    else
        error "Failed to execute command on Azure VM: $output"
        result=1
    fi

    return $result
}

# Runs scripts via serial console (QEMU) or run-command (Azure).
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

            if [[ "$VM_TYPE" == "azure" ]]; then
                # For Azure VMs, use run-command directly with script content
                if ! run_command_vm_azure "$VM_RG" "$vm_name" "$script_content"; then
                    error "Script failed: $script"
                    failed=1
                else
                    info "✓ Script completed successfully: $script"
                fi
            else
                # For QEMU VMs, use base64 encoding approach via serial console
                local encoded
                encoded=$(base64 -w0 "$script")
                local remote_cmd="echo '$encoded' | base64 -d > /tmp/script.sh && chmod +x /tmp/script.sh && /tmp/script.sh; echo \"SCRIPT_EXIT_CODE:\$?\""

                if ! run_command_via_console_qemu "$vm_name" "$remote_cmd" "$VM_CONSOLE_USER" "$VM_CONSOLE_PASSWORD"; then
                    error "Script failed: $script"
                    failed=1
                else
                    info "✓ Script completed successfully: $script"
                fi
            fi
        elif [[ "$script" == *";"* ]] || [[ "$script" == *"&&"* ]] || [[ "$script" =~ ^[a-zA-Z] ]]; then
            # Treat as inline command
            if [[ "$VM_TYPE" == "azure" ]]; then
                info "Running command on Azure VM: $script"
                if ! run_command_vm_azure "$VM_RG" "$vm_name" "$script"; then
                    error "Command failed: $script"
                    failed=1
                else
                    info "Command completed"
                fi
            else
                info "Running command via console: $script"
                if ! run_command_via_console_qemu "$vm_name" "$script" "$VM_CONSOLE_USER" "$VM_CONSOLE_PASSWORD"; then
                    error "Command failed: $script"
                    failed=1
                else
                    info "Command completed"
                fi
            fi
        else
            warn "Script not found and not a valid command: $script"
            failed=1
        fi
    done

    return $failed
}

# Starts a QEMU VM using libvirt.
# Sets global: booted_image_path, abs_disk_path.
start_vm_qemu() {
    local vm_image_path="$1"

    booted_image_path="${vm_image_path}.booted"
    cp "${vm_image_path}" "${booted_image_path}"
    
    # Get absolute path for disk image
    abs_disk_path="$(cd "$(dirname "${booted_image_path}")" && pwd)/$(basename "${booted_image_path}")"
    
    # Get paths to OVMF firmware files
    local ovmf_code="" ovmf_vars_template="" secure_attr="" smm_feature=""
    
    if [[ "${SECURE_BOOT_ENABLED}" != "true" ]]; then
        info "Secure boot DISABLED - using unsigned kernel"
        # Use non-secure boot OVMF firmware
        # Try Azure Linux paths first, then Ubuntu/Debian paths
        for code_file in \
            "/usr/share/edk2/ovmf/OVMF_CODE.fd" \
            "/usr/share/OVMF/OVMF_CODE_4M.fd" \
            "/usr/share/OVMF/OVMF_CODE.fd"; do
            if [[ -f "$code_file" ]]; then
                ovmf_code="$code_file"
                break
            fi
        done
        for vars_file in \
            "/usr/share/edk2/ovmf/OVMF_VARS.fd" \
            "/usr/share/OVMF/OVMF_VARS_4M.fd" \
            "/usr/share/OVMF/OVMF_VARS.fd"; do
            if [[ -f "$vars_file" ]]; then
                ovmf_vars_template="$vars_file"
                break
            fi
        done
        secure_attr=""
        smm_feature=""
    else
        # Use secure boot OVMF firmware
        # Try Azure Linux paths first, then Ubuntu/Debian paths
        for code_file in \
            "/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd" \
            "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd" \
            "/usr/share/OVMF/OVMF_CODE.secboot.fd" \
            "/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd" \
            "/usr/share/OVMF/OVMF_CODE_4M.fd" \
            "/usr/share/OVMF/OVMF_CODE.fd"; do
            if [[ -f "$code_file" ]]; then
                ovmf_code="$code_file"
                break
            fi
        done
        for vars_file in \
            "/usr/share/edk2/x64/OVMF_VARS.ms.4m.fd" \
            "/usr/share/OVMF/OVMF_VARS_4M.ms.fd" \
            "/usr/share/OVMF/OVMF_VARS.ms.fd" \
            "/usr/share/edk2/x64/OVMF_VARS.secboot.fd" \
            "/usr/share/OVMF/OVMF_VARS_4M.fd" \
            "/usr/share/OVMF/OVMF_VARS.fd" \
            "/usr/share/edk2/x64/OVMF_VARS.4m.fd"; do
            if [[ -f "$vars_file" ]]; then
                ovmf_vars_template="$vars_file"
                break
            fi
        done
        secure_attr=" secure='yes'"
        smm_feature="    <smm state='on'/>"
    fi
    
    if [[ -z "$ovmf_code" ]] || [[ -z "$ovmf_vars_template" ]]; then
        error "OVMF firmware files not found"
        error "Install with: sudo apt-get install -y ovmf"
        exit 1
    fi
    
    info "Using OVMF firmware:"
    info "  Code: $ovmf_code"
    info "  Vars: $ovmf_vars_template"
    
    # Create a writable copy of OVMF_VARS for this VM
    local vm_vars_path="${abs_disk_path}.vars"
    cp "$ovmf_vars_template" "$vm_vars_path"
    
    # Generate Ignition config file in /tmp (accessible to QEMU without AppArmor issues)
    local ignition_config="/tmp/${VM_NAME}-ignition.ign"
    generate_ignition_config "$ignition_config"
    
    # Create VM XML definition
    if [[ "${SECURE_BOOT_ENABLED}" != "true" ]]; then
        info "Creating VM definition WITHOUT secure boot..."
    else
        info "Creating VM definition with secure boot..."
    fi
    cat > /tmp/${VM_NAME}.xml <<EOF
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>${VM_NAME}</name>
  <memory unit='KiB'>2097152</memory>
  <currentMemory unit='KiB'>2097152</currentMemory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes'${secure_attr} type='pflash'>${ovmf_code}</loader>
    <nvram>${vm_vars_path}</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
${smm_feature}
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
  <seclabel type='none'/>
  <qemu:commandline>
    <qemu:arg value='-fw_cfg'/>
    <qemu:arg value='name=opt/org.flatcar-linux/config,file=${ignition_config}'/>
  </qemu:commandline>
</domain>
EOF

    # Define and start the VM with virsh
    info "Defining VM with virsh..."
    virsh define /tmp/${VM_NAME}.xml
    
    info "Starting VM..."
    virsh start "${VM_NAME}"
    
    rm -f /tmp/${VM_NAME}.xml
    info "VM '${VM_NAME}' started successfully!"
}

# Checks that required Azure infrastructure exists.
check_azure_infra() {
    info "Checking that required Azure infrastructure exists..."
    
    # Check storage RG
    if [[ "$(az group exists -n "$AZ_STORAGE_RG")" == "false" ]]; then
        info "Creating storage resource group: $AZ_STORAGE_RG"
        az group create --name "$AZ_STORAGE_RG" --location "$AZ_REGION"
    fi
    
    # Check gallery RG
    if [[ "$(az group exists -n "$AZ_GALLERY_RG")" == "false" ]]; then
        info "Creating gallery resource group: $AZ_GALLERY_RG"
        az group create --name "$AZ_GALLERY_RG" --location "$AZ_REGION"
    fi
    
    # Check storage account
    local storage_account_resource_id="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$AZ_STORAGE_RG/providers/Microsoft.Storage/storageAccounts/$AZ_STORAGE_ACC"
    if ! az storage account show --ids "$storage_account_resource_id" &>/dev/null; then
        info "Creating storage account: $AZ_STORAGE_ACC"
        if [[ "$(az storage account check-name --name "$AZ_STORAGE_ACC" --query nameAvailable)" == "false" ]]; then
            error "Storage account name $AZ_STORAGE_ACC is not available"
            exit 1
        fi
        az storage account create \
            --resource-group "$AZ_STORAGE_RG" \
            --name "$AZ_STORAGE_ACC" \
            --location "$AZ_REGION" \
            --allow-shared-key-access false \
            --sku Standard_LRS
    fi
    
    # Check storage container
    local container_exists
    container_exists=$(az storage container exists --account-name "$AZ_STORAGE_ACC" --name "$AZ_STORAGE_CONTAINER" --auth-mode login --query exists -o tsv)
    if [[ "$container_exists" != "true" ]]; then
        info "Creating storage container: $AZ_STORAGE_CONTAINER"
        az storage container create \
            --account-name "$AZ_STORAGE_ACC" \
            --name "$AZ_STORAGE_CONTAINER" \
            --auth-mode login
    fi
    
    # Check shared image gallery
    if ! az sig show -r "$AZ_ACG" -g "$AZ_GALLERY_RG" &>/dev/null; then
        info "Creating shared image gallery: $AZ_ACG"
        az sig create \
            --resource-group "$AZ_GALLERY_RG" \
            --gallery-name "$AZ_ACG" \
            --location "$AZ_REGION"
    fi
    
    # Check image definition
    local image_def_exists
    local publisher="$(whoami)-ACL"
    local offer="$AZ_VM_IMAGE_DEF"
    local sku="$(whoami)-TestBase"
    
    image_def_exists=$(az sig image-definition list -r "$AZ_ACG" -g "$AZ_GALLERY_RG" --query "[?name=='$AZ_VM_IMAGE_DEF' && identifier.publisher=='$publisher' && identifier.offer=='$offer' && identifier.sku=='$sku'] | length(@)" -o tsv)
    if [[ "$image_def_exists" -eq 0 ]]; then
        info "Creating image definition: $AZ_VM_IMAGE_DEF"
        az sig image-definition create \
            --gallery-image-definition "$AZ_VM_IMAGE_DEF" \
            --publisher "$publisher" \
            --offer "$offer" \
            --sku "$sku" \
            --gallery-name "$AZ_ACG" \
            --resource-group "$AZ_GALLERY_RG" \
            --os-type Linux \
            --features SecurityType=TrustedLaunchSupported \
            --hyper-v-generation V2
    else
        info "Image definition already exists: $AZ_VM_IMAGE_DEF"
    fi
    
    info "Azure infrastructure ready"
}

# Uploads VHD to Azure Storage.
upload_vhd_to_storage() {
    local vhd_path="$1"
    local blob_name="$2"
    
    info "Uploading VHD to Azure storage..."
    info "  Local file:  $vhd_path"
    info "  Blob name:   $blob_name"
    info "  Storage account: $AZ_STORAGE_ACC"
    info "  Container:       $AZ_STORAGE_CONTAINER"
    
    az storage blob upload \
        --account-name "$AZ_STORAGE_ACC" \
        --container-name "$AZ_STORAGE_CONTAINER" \
        --name "$blob_name" \
        --file "$vhd_path" \
        --auth-mode login \
        --overwrite
    
    info "✓ VHD uploaded successfully"
}

# Returns next available image version.
get_next_image_version() {
    # Get latest version and increment
    local latest_version
    latest_version=$(az sig image-version list \
        --resource-group "$AZ_GALLERY_RG" \
        --gallery-name "$AZ_ACG" \
        --gallery-image-name "$AZ_VM_IMAGE_DEF" \
        --query '[].name' -o tsv | \
        sort -t "." -k1,1n -k2,2n -k3,3n | \
        tail -1)
    
    if [[ -z "$latest_version" ]]; then
        echo "1.0.0"
    else
        echo "$latest_version" | awk -F. '{print $1"."$2"."$3+1}'
    fi
}

# Creates gallery image version from uploaded VHD.
create_gallery_image_version() {
    local image_version="$1"
    local blob_name="$2"
    
    info "Creating gallery image version: $image_version"
    
    local storage_account_resource_id="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$AZ_STORAGE_RG/providers/Microsoft.Storage/storageAccounts/$AZ_STORAGE_ACC"
    local blob_url="https://$AZ_STORAGE_ACC.blob.core.windows.net/$AZ_STORAGE_CONTAINER/$blob_name"
    
    # Create image version using Azure CLI
    az sig image-version create \
        --resource-group "$AZ_GALLERY_RG" \
        --gallery-name "$AZ_ACG" \
        --gallery-image-definition "$AZ_VM_IMAGE_DEF" \
        --gallery-image-version "$image_version" \
        --os-vhd-uri "$blob_url" \
        --os-vhd-storage-account "$storage_account_resource_id" \
        --target-regions "$AZ_REGION" \
        --replica-count 1 \
        --storage-account-type Standard_LRS \
        --replication-mode Shallow
    
    info "✓ Gallery image version created: $image_version"
}

# Creates Azure VM.
create_vm_azure() {
    local vm_rg_name="$1"
    local image_version="$2"
    
    # Create VM RG
    if [[ "$(az group exists -n "$vm_rg_name")" == "false" ]]; then
        info "Creating VM RG: $vm_rg_name"
        az group create \
            --name "$vm_rg_name" \
            --location "$AZ_REGION" \
            --tags "createdBy=$(whoami)" "purpose=VM-testing" "creationTime=$(date +%s)"
    fi
    
    # Compose image ID inside the gallery
    local image_id="/subscriptions/$AZ_SUB_ID/resourceGroups/$AZ_GALLERY_RG/providers/Microsoft.Compute/galleries/$AZ_ACG/images/$AZ_VM_IMAGE_DEF/versions/$image_version"
    
    # Create public IP first with required IP policy compliance tags
    local public_ip_name="${VM_NAME}PublicIP"
    info "Creating public IP with policy-compliant tags: $public_ip_name"
    az network public-ip create \
        --name "$public_ip_name" \
        --resource-group "$vm_rg_name" \
        --location "$AZ_REGION" \
        --allocation-method Static \
        --sku Standard \
        --ip-tags FirstPartyUsage=/NonProd \
        --tags "createdBy=$(whoami)" "purpose=VM-testing"
    
    info "Creating an Azure VM ${VM_NAME} in RG ${vm_rg_name}..."
    
    # Build base Azure CLI command
    local vm_create_args=(
        --resource-group "$vm_rg_name"
        --name "$VM_NAME"
        --size "Standard_D2s_v5"
        --os-disk-size-gb 60
        --admin-username "$VM_SSH_USER"
        --ssh-key-values "@${VM_SSH_KEY}.pub"
        --security-type TrustedLaunch
        --enable-vtpm true
        --image "$image_id"
        --location "$AZ_REGION"
        --public-ip-address "$public_ip_name"
        --tags "createdBy=$(whoami)" "purpose=VM-testing"
    )
    
    # Add security features based on SECURE_BOOT_ENABLED variable
    if [[ "$SECURE_BOOT_ENABLED" == "true" ]]; then
        vm_create_args+=(--enable-secure-boot true)
    else
        vm_create_args+=(--enable-secure-boot false)
    fi
    az vm create "${vm_create_args[@]}"
    
    # Enable boot diagnostics
    info "Enabling boot diagnostics..."
    az vm boot-diagnostics enable \
        --name "$VM_NAME" \
        --resource-group "$vm_rg_name"
}

# Generates a unique VM RG name.
get_vm_rg_name() {
  local suffix
  suffix=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)
  printf '%s-%s\n' "$VM_RG_PREFIX" "$suffix"
}

# Starts an Azure VM.
start_vm_azure() {
    local vm_image_path="$1"
    
    section "Starting Azure VM"

    # Get VM RG name for this build
    local vm_rg_name=$(get_vm_rg_name)
    
    # Set global VM_RG variable for use by console functions
    VM_RG="$vm_rg_name"
    
    info "Azure VM Configuration:"
    info "  Subscription:      ${AZ_SUB_ID}"
    info "  Storage RG:        ${AZ_STORAGE_RG}"
    info "  Location:          ${AZ_REGION}"
    info "  VM Resource Group: ${vm_rg_name}"
    info "  VM Name:           ${VM_NAME}"
    info "  Gallery:           ${AZ_ACG}"
    info "  Image Definition:  ${AZ_VM_IMAGE_DEF}"
    echo
    
    # Set subscription
    info "Setting Azure subscription..."
    az account set --subscription "$AZ_SUB_ID"
    
    # Step 1: Check/Create Azure infrastructure
    check_azure_infra
    
    # Step 2: Upload VHD to storage
    local blob_name="$(date +%y%m%d.%H%M%S)-${IMG_NAME}.vhd"
    upload_vhd_to_storage "$vm_image_path" "$blob_name"
    
    # Step 3: Create gallery image version
    local image_version
    image_version=$(get_next_image_version)
    create_gallery_image_version "$image_version" "$blob_name"
    
    # Step 4: Create VM RG and VM
    create_vm_azure "$vm_rg_name" "$image_version"
    
    # Step 5: Get VM IP and validate that VM deployment succeeded
    export VM_IP=$(az vm show -d -g "$vm_rg_name" -n "$VM_NAME" --query "publicIps" -o tsv)
    # Use az cli to confirm the VM deployment status is successful
    while [ "$(az vm show -d -g "$vm_rg_name" -n "$VM_NAME" --query provisioningState -o tsv)" != "Succeeded" ]; do sleep 1; done
    
    info "✓ Azure VM '${VM_NAME}' started successfully!"
    info " IP Address:     ${VM_IP}"
}

# Removes any existing VM of the specified type and name.
remove_old_vm() {
    # Remove VM based on type
    case "$VM_TYPE" in
        qemu)
            info "Removing qemu VM '${VM_NAME}' if present..."
            virsh destroy "${VM_NAME}" 2>/dev/null || true
            virsh undefine --nvram "${VM_NAME}" 2>/dev/null || true
            ;;
        azure)
            remove_vm_azure
            ;;
        *)
            error "Unsupported VM type: $VM_TYPE"
            exit 1
            ;;
    esac
}

# Schedules cleanup of VM RGs.
remove_vm_azure() {
    if [[ "$NO_CLEANUP" == "true" ]]; then
        info "--no-cleanup specified, so skipping cleanup of VM resources"
        return 0
    fi
    
    info "Scheduling deletion of VM resources for user: $(whoami)"
    
    # Get all resource groups that match the user-specific tag
    local user_tag="createdBy=$(whoami)"
    local matching_rgs
    matching_rgs=$(az group list --tag "$user_tag" --query "[].name" -o tsv)
    
    if [[ -z "$matching_rgs" ]]; then
        info "No resource groups found with tag: $user_tag"
        return 0
    fi

    # Schedule deletion of all matching resource groups without waiting
    local rg_count=0
    local failed_count=0
    while IFS= read -r rg_name; do
        [[ -z "$rg_name" ]] && continue
        info "Scheduling deletion of RG: $rg_name"
        local err
        # Disable errexit temporarily b/c az group delete issues a non-0 error code, and the script fails?
        # Even though deletion is scheduled successfully
        set +e
        if err=$(az group delete -n "$rg_name" -y --no-wait 2>&1 >/dev/null); then
            ((rg_count++))
        else
            warn "Failed to schedule deletion of RG: $rg_name"
            warn "  az error: $err"
            ((failed_count++))
        fi
        set -e
    done <<< "$matching_rgs"
    
    info "Scheduled deletion of $rg_count resource group(s)"
    if [[ $failed_count -gt 0 ]]; then
        info "$failed_count resource group(s) couldn't be scheduled (likely already deleting)"
    fi
    return 0
}

# Builds VM image at vm_image_path based on VM type.
build_vm_image() {
    local vm_type="$1"
    local vm_image_path="$2"
    local format
    
    # Set format string based on VM type
    case "$vm_type" in
        qemu)
            format="qemu_uefi"
            ;;
        azure)
            format="azure"
            ;;
        *)
            error "Unsupported VM type: $VM_TYPE"
            exit 1
            ;;
    esac

    local sdk_image
    sdk_image=$(get_sdk_image)

    # Build args for image_to_vm.sh
    local build_args=(
        "--image_compression_formats=none"
        "--from=../build/images/${BOARD}/latest"
        "--board=${BOARD}"
        "--format=${format}"
        "--image_name=${IMG_NAME}_image.bin"
    )
    
    # Use -C to specify custom SDK image (avoids trying to download non-existent version-specific image)
    # Use --rm to remove old container and ensure environment variables are set correctly
    info "Building ${vm_type} VM image using SDK container..."
    "${SCRIPT_DIR}/run_sdk_container" \
        --rm \
        $(get_tty_flag) \
        -C "${sdk_image}" \
        -- \
        ./image_to_vm.sh "${build_args[@]}"
    
    if ! [[ -f "$vm_image_path" ]]; then
        error "${vm_type} VM image generation failed"
        exit 1
    fi
    info "${vm_type} VM image ready at: ${vm_image_path}"
}

# Starts a VM.
start_vm() {
    local vm_image_path="$1"
    
    remove_old_vm

    section "Starting a ${VM_TYPE} VM '${VM_NAME}'"

    # Start VM based on type
    case "$VM_TYPE" in
        qemu)
            start_vm_qemu "$vm_image_path"
            ;;
        azure)
            start_vm_azure "$vm_image_path"
            ;;
        *)
            error "Unsupported VM type: $VM_TYPE"
            exit 1
            ;;
    esac
}

# Print size summary of built images
print_size_summary() {
    section "Image Size Summary"

    # Find the latest build directory
    local build_dir="${OUTPUT_ROOT}"
    BUILD_IMAGE_DIR="${build_dir}/images/images/${BOARD}/latest"
    if [[ -d "${BUILD_IMAGE_DIR}" ]]; then
        info "Build directory: ${BUILD_IMAGE_DIR}"
        echo

        # USR partition image
        if [[ -f "${BUILD_IMAGE_DIR}/${IMG_NAME}_image.bin" ]]; then
            usr_size=$(du -h "${BUILD_IMAGE_DIR}/${IMG_NAME}_image.bin" | cut -f1)
            info "USR Image:    ${usr_size}  (${BUILD_IMAGE_DIR}/${IMG_NAME}_image.bin)"
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
        if [[ -f "${BUILD_IMAGE_DIR}/${IMG_NAME}_image.bin" ]]; then
            echo
            full_size=$(du -h "${BUILD_IMAGE_DIR}/${IMG_NAME}_image.bin" | cut -f1)
            info "Full Image:   ${full_size}  (total disk image)"
        fi
    else
        warn "Build directory not found: ${BUILD_IMAGE_DIR}"
    fi
    echo
}

# Print summary of what will be done
print_summary() {
    section "Azure Container Linux Image Build Summary"

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

    if [[ "$USE_UNOFFICIAL_KERNEL" == "true" ]]; then
        echo "  2.6. Use unofficial kernel from Azure DevOps"
        echo "     Build ID: ${UNOFFICIAL_KERNEL_BUILD_ID}"
        echo "     Output: ${STAGING_DIR}"
        echo
    fi

    if [[ "$BUILD_IMAGE" == "true" ]]; then
        echo "  3. Build Azure Container Linux image using SDK container"
        echo "     Board: ${BOARD}"
        echo "     Group: ${GROUP}"
        echo "     Mode: RPM (Azure Linux RPMs + Portage)"
        echo
    fi

    if [[ "$BUILD_VM_IMAGE" == "true" ]]; then
        echo "  4. Build Azure Container Linux VM image"
        echo "     VM Type: ${VM_TYPE}"
        echo "     Base Image: ${IMG_NAME}_${VM_TYPE}_uefi_image.img"
        echo "     Start VM after build: ${START_VM}"
        echo "     VM Name: ${VM_NAME}"
        echo
    fi

    echo
}

# Collects parity data from running VM and generates comparison report.
collect_parity_data() {
    local vm_image_path="$1"
    
    if [[ ! -d "$PARITY" ]]; then
        error "os-diff directory not found: $PARITY"
        error "Specify a valid path with --parity=/path/to/os-diff"
        exit 1
    fi
    
    local os_diff_dir="$PARITY"
    local collector_bin="${os_diff_dir}/os-data-collector"
    [[ ! -x "$collector_bin" ]] && collector_bin="${os_diff_dir}/os-data-collector-static"
    if [[ ! -x "$collector_bin" ]]; then
        error "os-data-collector not found in $os_diff_dir"
        error "Build it with: cd $os_diff_dir && make build static"
        exit 1
    fi
    
    if ! wait_for_ssh "$VM_IP" "$VM_SSH_TIMEOUT"; then
        error "SSH not available for data collection"
        exit 1
    fi
    
    local collect_output_dir="${SCRIPT_DIR}/__build__/data-collection"
    mkdir -p "$collect_output_dir"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local collected_file="${collect_output_dir}/${timestamp}-comparison-data.json"
    
    # Compress VM image with bzip2 -9 to get compressed size
    info "Compressing image with bzip2 -9 for size measurement..."
    rm -f "${vm_image_path}.bz2"
    bzip2 -9 -k "$vm_image_path"
    local compressed_size
    compressed_size=$(stat -c%s "${vm_image_path}.bz2")
    info "Compressed image size: $(numfmt --to=iec-i --suffix=B $compressed_size) ($compressed_size bytes)"
    
    info "Running data collection..."
    "${SCRIPT_DIR}/acl/collect_vm_data.sh" --host="$VM_IP" --collector="$collector_bin" --user="$VM_SSH_USER" --output="$collected_file" >/dev/null 2>&1
    
    # Inject compressed_image_size into the collected JSON
    info "Adding compressed_image_size to collected data..."
    local tmp_file
    tmp_file=$(mktemp)
    jq --argjson size "$compressed_size" '.os_info.compressed_image_size = $size' "$collected_file" > "$tmp_file" && mv "$tmp_file" "$collected_file"
    
    # Run comparison report
    local upstream_data="${SCRIPT_DIR}/acl/upstream-fc-comparison-data.json"
    local reporter="${os_diff_dir}/os-comparison-reporter"
    [[ ! -x "$reporter" ]] && reporter="${os_diff_dir}/os-comparison-reporter-static"
    if [[ ! -x "$reporter" ]]; then
        error "os-comparison-reporter not found in $os_diff_dir"
        exit 1
    fi
    if [[ ! -f "$upstream_data" ]]; then
        error "Upstream comparison data not found: $upstream_data"
        exit 1
    fi
    local report_file="${collect_output_dir}/${timestamp}-report.md"
    info "Running comparison report..."
    "$reporter" -s -o "$report_file" "$upstream_data" "$collected_file"
    info "Report generated: $report_file"
}

# Main entry point
main() {
    parse_args "$@"

    section "Azure Container Linux Image Builder"
    info "Building ${BOARD} ${GROUP} image using Azure Linux RPMs"

    check_prerequisites
    print_summary

    # Use gzip compression for sysexts when NOT using unofficial kernel or on Azure Linux 3
    # (ACL kernel doesn't support squashfs-zstd yet, Once unofficial kernel is accepted upstream we can standardize to zstd)
    if [[ "$USE_UNOFFICIAL_KERNEL" != "true" ]] || is_azure_linux_3; then
        export SYSEXT_COMPRESSION=gzip
        info "Using gzip compression for sysexts (official kernel compatibility)"
    fi

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

    # Step 1.5: Use unofficial kernel from Azure DevOps (if requested or previously downloaded)
    if [[ "$USE_UNOFFICIAL_KERNEL" == "true" ]]; then
        # Flag was passed - download unofficial kernel
        download_unofficial_kernel
    elif ls "${STAGING_DIR}"/kernel-[0-9]*.rpm &>/dev/null 2>&1; then
        # Kernel RPMs found in staging - use unofficial kernel settings
        USE_UNOFFICIAL_KERNEL=true
        info "Detected kernel RPMs in staging directory, using unofficial kernel settings"
    fi

    # Automatically disable secure boot when using unofficial (unsigned) kernel
    if [[ "$USE_UNOFFICIAL_KERNEL" == "true" ]] && [[ "$SECURE_BOOT_ENABLED" == "true" ]]; then
        warn "Disabling secure boot (unofficial kernel is unsigned)"
        SECURE_BOOT_ENABLED=false
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

    # Step 3: Build VM image (if requested)
    local vm_image_path
    
    # Set expected VM image path based on VM type
    case "$VM_TYPE" in
        qemu)
            vm_image_path="__build__/images/images/${BOARD}/latest/${IMG_NAME}_qemu_uefi_image.img"
            ;;
        azure)
            vm_image_path="__build__/images/images/${BOARD}/latest/${IMG_NAME}_azure_image.vhd"
            ;;
    esac
    
    if [[ "$BUILD_VM_IMAGE" == "true" ]]; then
        section "Building VM Image at ${vm_image_path}"
        info "Converting base image to ${VM_TYPE} VM format..."
        
        build_vm_image "$VM_TYPE" "$vm_image_path"
    fi

    # Step 4: Start VM (if requested)
    if [[ "$START_VM" == "true" ]]; then
        # Validate that VM image exists
        if ! [[ -f "$vm_image_path" ]]; then
            error "VM image not found at expected path: $vm_image_path"
            error "Build a VM image first with '--build-vm-image'"
            exit 1
        fi

        start_vm "${vm_image_path}"

        # If scripts are specified, run them via serial console or SSH
        if [[ ${#RUN_SCRIPTS[@]} -gt 0 ]] ; then
            section "Running Scripts on VM"

            if [[ "$USE_SERIAL_CONSOLE" == "true" ]]; then
                # Use serial console execution
                info "Using serial console for script execution"
                
                # If this is a QEMU VM, wait for boot first
                if [[ "$VM_TYPE" == "qemu" ]]; then
                    info "Waiting for QEMU VM to boot..."
                    if ! wait_for_vm_boot_qemu "${VM_NAME}" "$VM_BOOT_TIMEOUT"; then
                        error "VM failed to boot within timeout"
                        exit 1
                    fi
                fi
                # For an Azure VM, we assume boot is done after start_vm_azure completes

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

                # If this is a QEMU VM, wait for VM IP first
                if [[ "$VM_TYPE" == "qemu" ]]; then
                    if ! wait_for_vm_ip_qemu "${VM_NAME}" 60; then
                        warn "You can still connect manually: virsh console ${VM_NAME}"
                        exit 1
                    fi
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
                    warn "You can still connect manually:"
                    if [[ "$VM_TYPE" == "qemu" ]]; then
                        warn "  virsh console ${VM_NAME}"
                    else
                        warn "  az vm run-command invoke --command-id RunShellScript --name ${VM_NAME} --resource-group ${VM_RG} --scripts 'echo Hello'"
                    fi
                fi
            fi
            # Only run nginx curl test if we executed the container test
            if [[ ${#RUN_SCRIPTS[@]} -gt 0 ]] && [[ "${RUN_SCRIPTS[-1]}" == *"run-container-test.sh" ]]; then
                # If this is a QEMU VM, IP might not be yet set, so get it
                if [[ -z "${VM_IP:-}" ]]; then
                    VM_IP=$(get_vm_ip_qemu "${VM_NAME}")
                fi
                curl --connect-timeout 10 --max-time 30 http://$VM_IP | grep "Thank you for using nginx."
            fi
            print_size_summary
        else
            if [[ "$VM_TYPE" == "qemu" ]]; then
                # No scripts - wait for boot, then either collect data or connect interactively
                echo
                info "Waiting for VM to boot (showing console output)..."
                
                # Wait for boot and show progress
                if ! wait_for_vm_boot_qemu "${VM_NAME}" "$VM_BOOT_TIMEOUT"; then
                    warn "Boot detection timed out"
                fi
                if ! wait_for_vm_ip_qemu "${VM_NAME}" 60; then
                    error "Could not get VM IP for data collection"
                    exit 1
                fi
            fi
            
            # Run parity data collection if requested
            if [[ -n "$PARITY" ]]; then
                collect_parity_data "$vm_image_path"
            elif [[ "$USE_SERIAL_CONSOLE" == "true" ]]; then
                if [[ "$VM_TYPE" == "qemu" ]]; then
                    connect_vm_console_qemu "${VM_NAME}"
                elif [[ "$VM_TYPE" == "azure" ]]; then
                    connect_vm_console_azure "$VM_RG" "${VM_NAME}"
                fi
            else
                # Connect via SSH
                info "VM is ready! Connecting via SSH..."
                
                if [[ "$VM_TYPE" == "qemu" ]]; then
                    if wait_for_vm_ip_qemu "${VM_NAME}" 60 && wait_for_ssh "$VM_IP" "$VM_SSH_TIMEOUT"; then
                        connect_vm_ssh "$VM_IP"
                    else
                        warn "SSH not available, falling back to console"
                        connect_vm_console_qemu "${VM_NAME}"
                    fi
                elif [[ "$VM_TYPE" == "azure" ]]; then
                    if [[ -n "${VM_IP:-}" ]] && wait_for_ssh "$VM_IP" "$VM_SSH_TIMEOUT"; then
                        connect_vm_ssh "$VM_IP"
                    else
                        warn "SSH not available, falling back to console"
                        connect_vm_console_azure "$VM_RG" "${VM_NAME}"
                    fi
                fi
            fi
        fi

    elif [[ "$VM_TYPE" == "qemu" ]]; then
        # Print instructions for manual libvirt deployment
        echo
        info "To deploy to libvirt, run:"
        echo "  virsh destroy ${VM_NAME} || true"
        echo "  virsh undefine --nvram ${VM_NAME} || true"
        echo "  virt-install --name ${VM_NAME} --memory 2048 --vcpus 2 --os-variant generic --import --disk ${vm_image_path} --network default --machine q35 --boot uefi --noautoconsole"
        echo "  virsh console ${VM_NAME}"
    else
        # Print instructions for manual Azure deployment
        echo
        info "To deploy to Azure, run:"
        echo "  az vm create --resource-group <rg-name> --name <vm-name> --image <image-id> --admin-username <username> --ssh-key-values <ssh-key-file> --size Standard_D2s_v5 --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true"
        echo "  az vm boot-diagnostics enable --name <vm-name> --resource-group <rg-name>"
        echo "  az vm show -d -g <rg-name> -n <vm-name> --query publicIps -o tsv"
    fi

    # Run kola tests if requested
    if [[ "$RUN_KOLA_TESTS" == "true" ]]; then
        if [[ "$VM_TYPE" == "azure" ]]; then
            error "Running kola tests not yet supported on Azure VMs"
            exit 1
        fi
        section "Running Kola Tests"
        cleanup_containers "name=flatcar-tests-"
        info "Running kola tests via run_local_tests.sh..."
        export PACKAGE_SOURCE_MODE=RPM
        if "${SCRIPT_DIR}/run_local_tests.sh"; then
            info "Kola tests completed successfully!"
        else
            error "Kola tests failed"
            exit 1
        fi
    fi
}

# Run main function
main "$@"
