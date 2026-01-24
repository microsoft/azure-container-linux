#!/bin/bash
# Collect OS comparison data from any VM via SSH
#
# Usage: ./collect_vm_data.sh --host=IP --collector=PATH [options]
#
# Options:
#   --host=IP|HOSTNAME  Target host to connect to (required)
#   --collector=PATH    Path to os-data-collector binary (required)
#   --user=USER         SSH user (default: core)
#   --output=DIR        Output directory for results (default: current dir)
#   --help              Show this help
#
# Examples:
#   ./collect_vm_data.sh --host=192.168.122.100 --collector=./os-data-collector
#   ./collect_vm_data.sh --host=20.10.30.40 --user=core --collector=./bin/collector

set -euo pipefail

# Configuration
TARGET_HOST=""
SSH_USER="${SSH_USER:-core}"
COLLECTOR_BINARY=""
OUTPUT_DIR="${OUTPUT_DIR:-.}"
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
            --output=*) OUTPUT_DIR="${1#*=}"; shift ;;
            --output) OUTPUT_DIR="$2"; shift 2 ;;
            --help|-h) show_help ;;
            *) error "Unknown option: $1" ;;
        esac
    done
}

validate_inputs() {
    [[ -z "$TARGET_HOST" ]] && error "--host is required"
    [[ -z "$COLLECTOR_BINARY" ]] && error "--collector is required"
    [[ ! -f "$COLLECTOR_BINARY" ]] && error "Collector binary not found: $COLLECTOR_BINARY"
    mkdir -p "$OUTPUT_DIR"
}

# SSH/SCP with standard options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"
ssh_cmd() { ssh $SSH_OPTS "${SSH_USER}@${TARGET_HOST}" "$@"; }
scp_cmd() { scp $SSH_OPTS "$@"; }

collect_data() {
    info "Collecting data from ${SSH_USER}@${TARGET_HOST}"

    # Copy and run collector
    local remote_collector="/tmp/os-data-collector"
    scp_cmd "$COLLECTOR_BINARY" "${SSH_USER}@${TARGET_HOST}:${remote_collector}"
    ssh_cmd "chmod +x $remote_collector && sudo $remote_collector"

    # Find and download results
    local remote_dir
    remote_dir=$(ssh_cmd "ls -td /tmp/os-comparison-* 2>/dev/null | head -1")
    [[ -z "$remote_dir" ]] && error "No results found on VM"

    local output_file="${OUTPUT_DIR}/${TARGET_HOST//[.:]/-}-${TIMESTAMP}-comparison-data.json"
    scp_cmd "${SSH_USER}@${TARGET_HOST}:${remote_dir}/comparison-data.json" "$output_file"

    # Cleanup
    ssh_cmd "rm -rf $remote_collector $remote_dir" || true

    echo
    info "✓ Data collection complete!"
    info "  Output: $output_file"
    info "  SSH: ssh ${SSH_USER}@${TARGET_HOST}"
}

main() {
    parse_args "$@"
    validate_inputs
    collect_data
}

main "$@"
