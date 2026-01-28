#!/bin/bash
# Collect OS comparison data from any VM via SSH
#
# Usage: ./collect_vm_data.sh --host=IP --collector=PATH [options]
#
# Options:
#   --host=IP|HOSTNAME  Target host to connect to (required)
#   --collector=PATH    Path to os-data-collector binary (required)
#   --user=USER         SSH user (default: core)
#   --output=FILE       Output file path (default: ./<timestamp>-comparison-data.json)
#   --help              Show this help
#
# Examples:
#   ./collect_vm_data.sh --host=192.168.122.100 --collector=./os-data-collector
#   ./collect_vm_data.sh --host=20.10.30.40 --collector=./bin/collector --output=/tmp/data.json

set -euo pipefail

# Configuration
TARGET_HOST=""
SSH_USER="${SSH_USER:-core}"
COLLECTOR_BINARY=""
OUTPUT_FILE=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

show_help() {
    head -15 "$0" | grep -E "^#" | sed 's/^# *//'
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --host=*) TARGET_HOST="${1#*=}"; shift ;;
            --host) TARGET_HOST="$2"; shift 2 ;;
            --user=*) SSH_USER="${1#*=}"; shift ;;
            --user) SSH_USER="$2"; shift 2 ;;
            --collector=*) COLLECTOR_BINARY="${1#*=}"; shift ;;
            --collector) COLLECTOR_BINARY="$2"; shift 2 ;;
            --output=*) OUTPUT_FILE="${1#*=}"; shift ;;
            --output) OUTPUT_FILE="$2"; shift 2 ;;
            --help|-h) show_help ;;
            *) error "Unknown option: $1" ;;
        esac
    done
}

validate_inputs() {
    [[ -z "$TARGET_HOST" ]] && error "--host is required"
    [[ -z "$COLLECTOR_BINARY" ]] && error "--collector is required"
    [[ ! -f "$COLLECTOR_BINARY" ]] && error "Collector binary not found: $COLLECTOR_BINARY"
    [[ -z "$OUTPUT_FILE" ]] && OUTPUT_FILE="./${TIMESTAMP}-comparison-data.json"
    mkdir -p "$(dirname "$OUTPUT_FILE")"
}

# SSH/SCP with standard options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"
ssh_cmd() { ssh $SSH_OPTS "${SSH_USER}@${TARGET_HOST}" "$@"; }
scp_cmd() { scp $SSH_OPTS "$@"; }

collect_data() {
    info "Collecting data from ${SSH_USER}@${TARGET_HOST}"

    # Copy collector and helper script
    local remote_collector="/tmp/os-data-collector"
    local script_dir
    script_dir=$(dirname "$(realpath "$0")")
    local extract_script="${script_dir}/../build_library/extract-initramfs-from-vmlinuz.sh"
    
    scp_cmd "$COLLECTOR_BINARY" "${SSH_USER}@${TARGET_HOST}:${remote_collector}"
    [[ -f "$extract_script" ]] && scp_cmd "$extract_script" "${SSH_USER}@${TARGET_HOST}:/tmp/"
    ssh_cmd "chmod +x $remote_collector && sudo $remote_collector"

    # Find and download results
    local remote_dir
    remote_dir=$(ssh_cmd "ls -td /tmp/os-comparison-* 2>/dev/null | head -1")
    [[ -z "$remote_dir" ]] && error "No results found on VM"

    scp_cmd "${SSH_USER}@${TARGET_HOST}:${remote_dir}/comparison-data.json" "$OUTPUT_FILE"

    # Cleanup
    ssh_cmd "rm -rf $remote_collector /tmp/extract_initramfs_from_vmlinuz.sh $remote_dir" || true

    echo
    info "✓ Data collection complete!"
    info "  Output: $OUTPUT_FILE"
    info "  SSH: ssh ${SSH_USER}@${TARGET_HOST}"
}

main() {
    parse_args "$@"
    validate_inputs
    collect_data
}

main "$@"
