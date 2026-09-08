#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMON_HELPER="${SCRIPT_DIR}/acl/tests/azure-security-profile-test-common.sh"
VALIDATE_COMMON="${SCRIPT_DIR}/acl/validate/validate_common.sh"

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
grep -Fq 'reboot_timeout="${VM_BOOT_TIMEOUT:-$VM_SSH_TIMEOUT}"' "${COMMON_HELPER}"
grep -Fq '"--ssh-timeout=${VM_SSH_TIMEOUT}"' "${VALIDATE_COMMON}"
grep -Fq '"--boot-timeout=${VM_BOOT_TIMEOUT}"' "${VALIDATE_COMMON}"

echo "azure security profile helper timeout contract passed"
