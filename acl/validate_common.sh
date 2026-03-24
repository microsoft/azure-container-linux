#!/bin/bash
# Common validation library for Azure Container Linux (ACL) images.
#
# Provides shared globals, logging, SSH helpers, script execution,
# VM lifecycle dispatchers, argument parsing, and the main entry point.
#
# Sourced by validate_rpm_image.sh alongside validate_qemu.sh and validate_azure.sh.
#
# Copyright (c) 2026, Microsoft Corporation.

# Guard against double-sourcing
[[ -n "${_VALIDATE_COMMON_LOADED:-}" ]] && return 0
_VALIDATE_COMMON_LOADED=1

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"
cd "${SCRIPT_DIR}"

# ── Default configuration ──────────────────────────────────────────

BOARD="${BOARD:-amd64-usr}"
GROUP="${GROUP:-production}"
IMG_NAME="${IMG_NAME:-acl_production}"
VM_TYPE="${VM_TYPE:-qemu}"
START_VM=false
VM_NAME="${VM_NAME:-acl}"
OUTPUT_ROOT="${OUTPUT_ROOT:-__build__}"
RUN_SCRIPTS=()  # Scripts to run on VM after boot
SCRIPT_RESULTS_NAMES=()   # Names of scripts that were executed
SCRIPT_RESULTS_STATUS=()  # Exit status per script: 0=pass, non-zero=fail
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
SECURE_BOOT_ENABLED="${SECURE_BOOT_ENABLED:-true}"  # Enable secure boot
RUN_KOLA_TESTS=false  # Run kola tests via run_local_tests.sh on a QEMU VM
ACG_IMAGE_VERSION_ID=""  # Pre-existing Azure Compute Gallery image version resource ID
KEEP_VM=false  # Keep VM running after scripts complete (write state file)
REUSE_VM=false  # Reuse an already-running VM (read state file)
VM_STATE_FILE="${SCRIPT_DIR}/.vm-state.env"  # State file for VM reuse between invocations
VM_IMAGE_PATH=""  # Explicit VM image path (auto-detected if empty)
AZ_VM_ARGS="${AZ_VM_ARGS:-}"  # Additional arguments to pass when starting Azure VMs (e.g., for user-data)
export BOOTLOADER_MODE="${BOOTLOADER_MODE:-grub}"

VM_IP=""

# ── Colors / logging ───────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
debug()   { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" || true; }
section() { echo -e "\n${GREEN}=========================================${NC}"; echo -e "${GREEN}$*${NC}"; echo -e "${GREEN}=========================================${NC}\n"; }

# ── Script results summary ─────────────────────────────────────────

print_script_results_summary() {
    if [[ ${#SCRIPT_RESULTS_NAMES[@]} -eq 0 ]]; then
        return
    fi

    local passed=0 failed=0 total=${#SCRIPT_RESULTS_NAMES[@]}

    for status in "${SCRIPT_RESULTS_STATUS[@]}"; do
        if [[ "$status" -eq 0 ]]; then
            ((passed++)) || true
        else
            ((failed++)) || true
        fi
    done

    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN} Script Execution Summary${NC}"
    echo -e "${GREEN}=========================================${NC}"
    printf "  %-50s %s\n" "SCRIPT" "RESULT"
    printf "  %-50s %s\n" "------" "------"

    for i in "${!SCRIPT_RESULTS_NAMES[@]}"; do
        local name="${SCRIPT_RESULTS_NAMES[$i]}"
        local status="${SCRIPT_RESULTS_STATUS[$i]}"
        if [[ "$status" -eq 0 ]]; then
            printf "  %-50s ${GREEN}%s${NC}\n" "$name" "PASSED"
        else
            printf "  %-50s ${RED}%s${NC}\n" "$name" "FAILED"
        fi
    done

    echo -e "  ${GREEN}-----------------------------------------${NC}"
    printf "  Total: %d  |  " "$total"
    if [[ $passed -gt 0 ]]; then
        printf "${GREEN}Passed: %d${NC}  |  " "$passed"
    else
        printf "Passed: %d  |  " "$passed"
    fi
    if [[ $failed -gt 0 ]]; then
        printf "${RED}Failed: %d${NC}\n" "$failed"
    else
        printf "Failed: %d\n" "$failed"
    fi
    echo -e "${GREEN}=========================================${NC}"
    echo ""
}

# ── SDK / TTY helpers ──────────────────────────────────────────────

get_sdk_image() {
    if [[ -n "${ACL_SDK_IMAGE:-}" ]]; then
        echo "${ACL_SDK_IMAGE}"
        return
    fi
    source "${SCRIPT_DIR}/sdk_lib/sdk_container_common.sh"
    local sdk_version
    sdk_version=$(get_sdk_version_from_versionfile)
    local docker_sdk_vernum
    docker_sdk_vernum=$(vernum_to_docker_image_version "$sdk_version")
    echo "${sdk_container_common_registry}/flatcar-sdk-all:${docker_sdk_vernum}"
}

get_tty_flag() {
    if [[ "${NO_TTY:-false}" == "true" ]]; then
        echo ""
    else
        echo "-t"
    fi
}

# ── SSH key helpers ────────────────────────────────────────────────

get_ssh_private_key() {
    if [[ -n "$VM_SSH_KEY" ]]; then
        echo "$VM_SSH_KEY"
        return 0
    fi
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

# ── Platform detection ─────────────────────────────────────────────

is_azure_linux_3() {
    [[ -f /etc/os-release ]] && grep -q 'ID=azurelinux' /etc/os-release && grep -q 'VERSION_ID="3' /etc/os-release
}

# ── SSH / connect helpers ──────────────────────────────────────────

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

connect_vm_ssh() {
    local ip="$1"
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ssh_opts="$ssh_opts -i $VM_SSH_KEY"
    info "Connecting to ${VM_SSH_USER}@${ip}..."
    ssh $ssh_opts "${VM_SSH_USER}@${ip}"
}

# ── Script execution (SSH) ─────────────────────────────────────────

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
            local remote_script="/tmp/$(basename "$script")"
            if ! scp $ssh_opts "$script" "${VM_SSH_USER}@${ip}:${remote_script}"; then
                error "Failed to copy script: $script"
                SCRIPT_RESULTS_NAMES+=("$script")
                SCRIPT_RESULTS_STATUS+=(1)
                failed=1
                continue
            fi
            if ! ssh $ssh_opts "${VM_SSH_USER}@${ip}" "chmod +x ${remote_script} && sudo ${remote_script}"; then
                error "Script failed: $script"
                SCRIPT_RESULTS_NAMES+=("$script")
                SCRIPT_RESULTS_STATUS+=(1)
                failed=1
            else
                info "Script completed: $script"
                SCRIPT_RESULTS_NAMES+=("$script")
                SCRIPT_RESULTS_STATUS+=(0)
            fi
        elif [[ "$script" == *";"* ]] || [[ "$script" == *"&&"* ]] || [[ "$script" =~ ^[a-zA-Z] ]]; then
            info "Running command: $script"
            if ! ssh $ssh_opts "${VM_SSH_USER}@${ip}" "sudo bash -c '$script'"; then
                error "Command failed: $script"
                SCRIPT_RESULTS_NAMES+=("$script")
                SCRIPT_RESULTS_STATUS+=(1)
                failed=1
            else
                info "Command completed"
                SCRIPT_RESULTS_NAMES+=("$script")
                SCRIPT_RESULTS_STATUS+=(0)
            fi
        else
            warn "Script not found and not a valid command: $script"
            SCRIPT_RESULTS_NAMES+=("$script")
            SCRIPT_RESULTS_STATUS+=(1)
            failed=1
        fi
    done

    return $failed
}

# ── Script execution (serial console — dispatches to platform) ─────

run_scripts_via_console() {
    local vm_name="$1"
    shift
    local scripts=("$@")
    local failed=0

    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            info "Running script via console: $script"
            local script_content
            script_content=$(cat "$script")

            if [[ "$VM_TYPE" == "azure" ]]; then
                if ! run_command_vm_azure "$VM_RG" "$vm_name" "$script_content"; then
                    error "Script failed: $script"
                    SCRIPT_RESULTS_NAMES+=("$script")
                    SCRIPT_RESULTS_STATUS+=(1)
                    failed=1
                else
                    info "✓ Script completed successfully: $script"
                    SCRIPT_RESULTS_NAMES+=("$script")
                    SCRIPT_RESULTS_STATUS+=(0)
                fi
            else
                local encoded
                encoded=$(base64 -w0 "$script")
                local remote_cmd="echo '$encoded' | base64 -d > /tmp/script.sh && chmod +x /tmp/script.sh && /tmp/script.sh; echo \"SCRIPT_EXIT_CODE:\$?\""

                if ! run_command_via_console_qemu "$vm_name" "$remote_cmd" "$VM_CONSOLE_USER" "$VM_CONSOLE_PASSWORD"; then
                    error "Script failed: $script"
                    SCRIPT_RESULTS_NAMES+=("$script")
                    SCRIPT_RESULTS_STATUS+=(1)
                    failed=1
                else
                    info "✓ Script completed successfully: $script"
                    SCRIPT_RESULTS_NAMES+=("$script")
                    SCRIPT_RESULTS_STATUS+=(0)
                fi
            fi
        elif [[ "$script" == *";"* ]] || [[ "$script" == *"&&"* ]] || [[ "$script" =~ ^[a-zA-Z] ]]; then
            if [[ "$VM_TYPE" == "azure" ]]; then
                info "Running command on Azure VM: $script"
                if ! run_command_vm_azure "$VM_RG" "$vm_name" "$script"; then
                    error "Command failed: $script"
                    SCRIPT_RESULTS_NAMES+=("$script")
                    SCRIPT_RESULTS_STATUS+=(1)
                    failed=1
                else
                    info "Command completed"
                    SCRIPT_RESULTS_NAMES+=("$script")
                    SCRIPT_RESULTS_STATUS+=(0)
                fi
            else
                info "Running command via console: $script"
                if ! run_command_via_console_qemu "$vm_name" "$script" "$VM_CONSOLE_USER" "$VM_CONSOLE_PASSWORD"; then
                    error "Command failed: $script"
                    SCRIPT_RESULTS_NAMES+=("$script")
                    SCRIPT_RESULTS_STATUS+=(1)
                    failed=1
                else
                    info "Command completed"
                    SCRIPT_RESULTS_NAMES+=("$script")
                    SCRIPT_RESULTS_STATUS+=(0)
                fi
            fi
        else
            warn "Script not found and not a valid command: $script"
            SCRIPT_RESULTS_NAMES+=("$script")
            SCRIPT_RESULTS_STATUS+=(1)
            failed=1
        fi
    done

    return $failed
}

# ── VM lifecycle dispatchers ───────────────────────────────────────

start_vm() {
    local vm_image_path="$1"
    local board="$2"
    remove_old_vm
    section "Starting a ${VM_TYPE} VM '${VM_NAME}' Board: '${BOARD}'"
    case "$VM_TYPE" in
        qemu)
            start_vm_qemu "$vm_image_path" "$board"
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

remove_old_vm() {
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

# ── VM state persistence ──────────────────────────────────────────

write_vm_state() {
    cat > "$VM_STATE_FILE" <<EOF
VM_IP=${VM_IP}
VM_RG=${VM_RG}
VM_NAME=${VM_NAME}
VM_TYPE=${VM_TYPE}
EOF
    info "VM state written to ${VM_STATE_FILE}"
}

read_vm_state() {
    if [[ ! -f "$VM_STATE_FILE" ]]; then
        error "--reuse-vm requires a running VM, but no state file found at ${VM_STATE_FILE}"
        error "Provision a VM first with --keep-vm"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$VM_STATE_FILE"
    info "Loaded VM state from ${VM_STATE_FILE}"
    info "  IP:   ${VM_IP}"
    info "  RG:   ${VM_RG}"
    info "  Name: ${VM_NAME}"
    info "  Type: ${VM_TYPE}"
}

remove_vm_state() {
    if [[ -f "$VM_STATE_FILE" ]]; then
        rm -f "$VM_STATE_FILE"
        info "Removed VM state file"
    fi
}

# ── Image size summary ────────────────────────────────────────────

print_size_summary() {
    section "Image Size Summary"

    local BUILD_IMAGE_DIR="${OUTPUT_ROOT}/images/images/${BOARD}/latest"
    if [[ -d "${BUILD_IMAGE_DIR}" ]]; then
        info "Build directory: ${BUILD_IMAGE_DIR}"
        echo

        if [[ -f "${BUILD_IMAGE_DIR}/${IMG_NAME}_image.bin" ]]; then
            local usr_size
            usr_size=$(du -h "${BUILD_IMAGE_DIR}/${IMG_NAME}_image.bin" | cut -f1)
            info "USR Image:    ${usr_size}  (${BUILD_IMAGE_DIR}/${IMG_NAME}_image.bin)"
        fi

        if ls "${BUILD_IMAGE_DIR}"/rootfs-included-sysexts/*.raw &>/dev/null; then
            echo
            info "Sysext Images:"
            for sysext in "${BUILD_IMAGE_DIR}"/rootfs-included-sysexts/*.raw; do
                if [[ -f "$sysext" ]]; then
                    local sysext_size sysext_name
                    sysext_size=$(du -h "$sysext" | cut -f1)
                    sysext_name=$(basename "$sysext")
                    info "  - ${sysext_name}: ${sysext_size}"
                fi
            done
        fi

        if [[ -f "${BUILD_IMAGE_DIR}/${IMG_NAME}_image.bin" ]]; then
            echo
            local full_size
            full_size=$(du -h "${BUILD_IMAGE_DIR}/${IMG_NAME}_image.bin" | cut -f1)
            info "Full Image:   ${full_size}  (total disk image)"
        fi
    else
        warn "Build directory not found: ${BUILD_IMAGE_DIR}"
    fi
    echo
}

# ── Parity data collection ────────────────────────────────────────

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

    info "Running data collection..."
    "${SCRIPT_DIR}/acl/collect_vm_data.sh" --host="$VM_IP" --collector="$collector_bin" --user="$VM_SSH_USER" --output="$collected_file" >/dev/null 2>&1

    info "Compressing image with bzip2 -9 for size measurement..."
    rm -f "${vm_image_path}.bz2"
    bzip2 -9 -k "$vm_image_path"
    local compressed_size
    compressed_size=$(stat -c%s "${vm_image_path}.bz2")
    info "Compressed image size: $(numfmt --to=iec-i --suffix=B $compressed_size) ($compressed_size bytes)"

    info "Adding compressed_image_size to collected data..."
    local tmp_file
    tmp_file=$(mktemp)
    jq --argjson size "$compressed_size" '.os_info.compressed_image_size = $size' "$collected_file" > "$tmp_file" && mv "$tmp_file" "$collected_file"

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

# ── Cleanup helpers ────────────────────────────────────────────────

cleanup_containers() {
    local filter="${1:-name=flatcar-sdk-}"
    info "Cleaning up old containers..."
    docker ps -a --filter "${filter}" --format "{{.ID}} {{.Names}}" | while read -r id name; do
        info "  Removing container: $name ($id)"
        docker rm -f "$id" 2>/dev/null || true
    done
}

# ── Prerequisites check ───────────────────────────────────────────

check_vm_prerequisites() {
    section "Checking VM Prerequisites"

    local warnings=0

    # Check swtpm on Azure Linux 3 if VM operations are planned
    if [[ "$START_VM" == "true" ]]; then
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
        if [[ "$USE_SERIAL_CONSOLE" == "true" ]]; then
            if ! az extension show --name serial-console &>/dev/null 2>&1; then
                info "Installing Azure CLI serial-console extension..."
                if ! az extension add --name serial-console; then
                    error "Failed to install serial-console extension"
                    exit 1
                fi
                info "✓ Azure CLI serial-console extension installed"
            else
                info "✓ Azure CLI serial-console extension found"
            fi
        fi
    fi

    # Check expect when starting a QEMU VM
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
            error "Generate one with: ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa"
            error "Or specify with: --ssh-key=PATH"
            exit 1
        fi
        if [[ ! -f "${ssh_key_path}.pub" ]]; then
            error "SSH public key not found at: ${ssh_key_path}.pub"
            exit 1
        fi
        VM_SSH_KEY="$ssh_key_path"
        info "✓ SSH key found at $ssh_key_path"
    fi

    if [[ $warnings -gt 0 ]]; then
        warn "$warnings warning(s) detected - some operations may fail"
        echo
    fi

    info "✓ VM prerequisites met"
}

# ── Argument parsing ──────────────────────────────────────────────

parse_validate_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --board=*)
                BOARD="${1#*=}"
                shift ;;
            --img-name=*)
                IMG_NAME="${1#*=}"
                shift ;;
            --vm-type=*)
                VM_TYPE="${1#*=}"
                if [[ "$VM_TYPE" != "azure" ]] && [[ "$VM_TYPE" != "qemu" ]]; then
                    error "Invalid VM type: $VM_TYPE (must be 'azure' or 'qemu')"
                    exit 1
                fi
                shift ;;
            --start-vm)
                START_VM=true
                shift ;;
            --vm-name=*)
                VM_NAME="${1#*=}"
                shift ;;
            --vm-image-path=*)
                VM_IMAGE_PATH="${1#*=}"
                shift ;;
            --run-script=*)
                RUN_SCRIPTS+=("${1#*=}")
                START_VM=true
                shift ;;
            --run-script)
                RUN_SCRIPTS+=("$2")
                START_VM=true
                shift 2 ;;
            --ssh-user=*)
                VM_SSH_USER="${1#*=}"
                shift ;;
            --ssh-key=*)
                VM_SSH_KEY="${1#*=}"
                shift ;;
            --ssh-timeout=*)
                VM_SSH_TIMEOUT="${1#*=}"
                shift ;;
            --ssh-authorized-keys=*)
                VM_SSH_AUTHORIZED_KEYS="${1#*=}"
                shift ;;
            --use-serial)
                USE_SERIAL_CONSOLE=true
                shift ;;
            --use-ssh)
                USE_SERIAL_CONSOLE=false
                shift ;;
            --console-user=*)
                VM_CONSOLE_USER="${1#*=}"
                shift ;;
            --console-password=*)
                VM_CONSOLE_PASSWORD="${1#*=}"
                shift ;;
            --boot-timeout=*)
                VM_BOOT_TIMEOUT="${1#*=}"
                shift ;;
            --keep-vm)
                KEEP_VM=true
                NO_CLEANUP=true
                shift ;;
            --reuse-vm)
                REUSE_VM=true
                START_VM=true
                NO_CLEANUP=true
                shift ;;
            --no-cleanup)
                NO_CLEANUP=true
                shift ;;
            --parity=*)
                PARITY="${1#*=}"
                START_VM=true
                shift ;;
            --parity)
                PARITY="${SCRIPT_DIR}/../os-diff"
                START_VM=true
                shift ;;
            --run-kola-tests)
                RUN_KOLA_TESTS=true
                shift ;;
            --tag=*)
                RESOURCE_TAGS+=("${1#*=}")
                shift ;;
            --acg-gallery-name=*)
                AZ_ACG="${1#*=}"
                shift ;;
            --acg-image-version-id=*)
                ACG_IMAGE_VERSION_ID="${1#*=}"
                START_VM=true
                shift ;;
            --az-storage-account=*)
                AZ_STORAGE_ACC="${1#*=}"
                shift ;;
            --az-sub-id=*)
                AZ_SUB_ID="${1#*=}"
                shift ;;
            --az-region=*)
                AZ_REGION="${1#*=}"
                shift ;;
            --az-vm-size=*)
                AZ_VM_SIZE="${1#*=}"
                shift ;;
            --az-storage-rg=*)
                AZ_STORAGE_RG="${1#*=}"
                shift ;;
            --az-gallery-rg=*)
                AZ_GALLERY_RG="${1#*=}"
                shift ;;
            --az-vm-image-def=*)
                AZ_VM_IMAGE_DEF="${1#*=}"
                shift ;;
            --az-storage-container=*)
                AZ_STORAGE_CONTAINER="${1#*=}"
                shift ;;
            --build-id=*)
                BUILD_ID="${1#*=}"
                shift ;;
            --az-vm-args=*)
                AZ_VM_ARGS="${1#*=}"
                shift ;;
            --help)
                echo "Usage: $0 [options]"
                echo ""
                echo "Validate an ACL image by starting a VM and running test scripts."
                echo ""
                echo "Options:"
                echo "  --board=BOARD              Target board (default: amd64-usr)"
                echo "  --boot-timeout=SECS        Timeout waiting for VM boot (default: 180)"

                echo "  --console-password=PASS    Serial console login password"
                echo "  --console-user=USER        Serial console login user (default: root)"
                echo "  --help                     Show this help message"
                echo "  --img-name=NAME            Image name prefix (default: acl_production)"
                echo "  --keep-vm                  Keep VM running after scripts complete"
                echo "  --no-cleanup               Skip cleanup of existing VM resource groups"
                echo "  --parity[=DIR]             Run parity data collection"
                echo "  --reuse-vm                 Reuse an already-running VM"
                echo "  --run-kola-tests           Run kola tests"
                echo "  --run-script=PATH          Run script on VM (can specify multiple)"
                echo "  --ssh-key=PATH             SSH private key for VM access"
                echo "  --ssh-timeout=SECS         Timeout waiting for SSH (default: 120)"
                echo "  --ssh-user=USER            SSH user (default: core)"
                echo "  --start-vm                 Start the VM"
                echo "  --tag=KEY=VALUE            Add a resource tag"
                echo "  --use-serial               Use serial console"
                echo "  --use-ssh                  Use SSH"
                echo "  --vm-image-path=PATH       Path to VM image"
                echo "  --az-vm-args=ARGS          Additional arguments to pass when starting Azure VMs"
                echo "  --vm-name=NAME             VM name (default: acl)"
                echo "  --vm-type=TYPE             VM type: azure|qemu (default: qemu)"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    if [[ "$START_VM" == "true" ]] && [[ "$REUSE_VM" != "true" ]]; then
        local auto_vm_path="${VM_IMAGE_PATH}"
        if [[ -z "$auto_vm_path" ]]; then
            case "$VM_TYPE" in
                qemu)  auto_vm_path="__build__/images/images/${BOARD}/latest/${IMG_NAME}_qemu_uefi_image.img" ;;
                azure) auto_vm_path="__build__/images/images/${BOARD}/latest/${IMG_NAME}_azure_image.vhd" ;;
            esac
        fi
        # Don't auto-build if image already exists or using ACG image
        if [[ -n "${ACG_IMAGE_VERSION_ID}" ]] || [[ -f "$auto_vm_path" ]]; then
            : # Image exists or using gallery image, no need to build
        fi
    fi
}

# ── Main entry point ──────────────────────────────────────────────

validate_main() {
    parse_validate_args "$@"
    resolve_azure_defaults

    section "Azure Container Linux Image Validator"

    check_vm_prerequisites

    # Resolve VM image path
    local vm_image_path="${VM_IMAGE_PATH}"
    if [[ -z "$vm_image_path" ]]; then
        case "$VM_TYPE" in
            qemu)  vm_image_path="__build__/images/images/${BOARD}/latest/${IMG_NAME}_qemu_uefi_image.img" ;;
            azure) vm_image_path="__build__/images/images/${BOARD}/latest/${IMG_NAME}_azure_image.vhd" ;;
        esac
    fi

    # Start VM and run scripts / connect interactively
    if [[ "$START_VM" == "true" ]]; then

        if [[ "$REUSE_VM" == "true" ]]; then
            read_vm_state
        else
            if [[ -n "${ACG_IMAGE_VERSION_ID}" ]] && [[ "$VM_TYPE" == "azure" ]]; then
                info "Using pre-existing ACG image version — skipping local image check"
            elif ! [[ -f "$vm_image_path" ]]; then
                error "VM image not found at expected path: $vm_image_path"
                error "Build a VM image first with '--build-vm-image'"
                exit 1
            fi

            start_vm "${vm_image_path}" "${BOARD}"

            if [[ "$KEEP_VM" == "true" ]]; then
                write_vm_state
            fi
        fi

        # Run scripts on VM
        if [[ ${#RUN_SCRIPTS[@]} -gt 0 ]]; then
            section "Running Scripts on VM"

            if [[ "$USE_SERIAL_CONSOLE" == "true" ]]; then
                info "Using serial console for script execution"

                if [[ "$VM_TYPE" == "qemu" ]]; then
                    info "Waiting for QEMU VM to boot..."
                    if ! wait_for_vm_boot_qemu "${VM_NAME}" "$VM_BOOT_TIMEOUT"; then
                        error "VM failed to boot within timeout"
                        exit 1
                    fi
                fi

                if run_scripts_via_console "${VM_NAME}" "${RUN_SCRIPTS[@]}"; then
                    print_script_results_summary
                    info "All scripts completed successfully!"
                else
                    print_script_results_summary
                    error "One or more scripts failed"
                    exit 1
                fi
            else
                info "Using SSH for script execution"

                if [[ "$VM_TYPE" == "qemu" ]]; then
                    info "Waiting for QEMU VM to boot..."
                    if ! wait_for_vm_boot_qemu "${VM_NAME}" "$VM_BOOT_TIMEOUT"; then
                        error "VM failed to boot within timeout"
                        exit 1
                    fi
                    if ! wait_for_vm_ip_qemu "${VM_NAME}" 60; then
                        warn "You can still connect manually: virsh console ${VM_NAME}"
                        exit 1
                    fi
                fi

                if wait_for_ssh "$VM_IP" "$VM_SSH_TIMEOUT"; then
                    if run_scripts_on_vm "$VM_IP" "${RUN_SCRIPTS[@]}"; then
                        print_script_results_summary
                        info "All scripts completed successfully!"
                    else
                        print_script_results_summary
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
            # Nginx curl test for container test (QEMU only)
            if [[ "$VM_TYPE" != "azure" ]] && [[ ${#RUN_SCRIPTS[@]} -gt 0 ]] && [[ "${RUN_SCRIPTS[-1]}" == *"run-container-test.sh" ]]; then
                if [[ -z "${VM_IP:-}" ]]; then
                    VM_IP=$(get_vm_ip_qemu "${VM_NAME}")
                fi
                curl --connect-timeout 10 --max-time 30 http://$VM_IP | grep "Thank you for using nginx."
            fi
            print_size_summary
        else
            # No scripts — interactive mode or parity
            if [[ "$VM_TYPE" == "qemu" ]]; then
                echo
                info "Waiting for VM to boot (showing console output)..."
                if ! wait_for_vm_boot_qemu "${VM_NAME}" "$VM_BOOT_TIMEOUT"; then
                    warn "Boot detection timed out"
                fi
                if ! wait_for_vm_ip_qemu "${VM_NAME}" 60; then
                    error "Could not get VM IP for data collection"
                    exit 1
                fi
            fi

            if [[ -n "$PARITY" ]]; then
                collect_parity_data "$vm_image_path"
            elif [[ "$USE_SERIAL_CONSOLE" == "true" ]]; then
                if [[ "$VM_TYPE" == "qemu" ]]; then
                    connect_vm_console_qemu "${VM_NAME}"
                elif [[ "$VM_TYPE" == "azure" ]]; then
                    connect_vm_console_azure "$VM_RG" "${VM_NAME}"
                fi
            else
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
        echo
        info "To deploy to libvirt, run:"
        echo "  virsh destroy ${VM_NAME} || true"
        echo "  virsh undefine --nvram ${VM_NAME} || true"
        echo "  virt-install --name ${VM_NAME} --memory 2048 --vcpus 2 --os-variant generic --import --disk ${vm_image_path} --network default --machine q35 --boot uefi --noautoconsole"
        echo "  virsh console ${VM_NAME}"
    else
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
        local kola_arch="${BOARD%%-*}"  # arm64-usr → arm64, amd64-usr → amd64
        info "Running kola tests via run_local_tests.sh (arch=${kola_arch})..."
        if "${SCRIPT_DIR}/run_local_tests.sh" "${kola_arch}"; then
            info "Kola tests completed successfully!"
        else
            error "Kola tests failed"
            exit 1
        fi
    fi
}
