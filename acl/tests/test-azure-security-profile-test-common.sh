#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMON_HELPER="${SCRIPT_DIR}/acl/tests/azure-security-profile-test-common.sh"

source "${COMMON_HELPER}"

VM_SSH_KEY="/tmp/test-vm-ssh-key"
setup_ssh_opts

contains_ssh_option() {
    local option="$1"
    local index

    for ((index = 0; index < ${#SSH_OPTS[@]} - 1; index++)); do
        if [[ "${SSH_OPTS[index]}" == "-o" && "${SSH_OPTS[index + 1]}" == "${option}" ]]; then
            return 0
        fi
    done

    return 1
}

contains_ssh_option "ServerAliveInterval=5"
contains_ssh_option "ServerAliveCountMax=2"

grep -Fq 'timeout --signal=TERM --kill-after=5s 15s \' "${COMMON_HELPER}"

echo "azure security profile helper timeout contract passed"
