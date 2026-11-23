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

# Persist attempts across the command substitution used to capture az diagnostics.
attempts="$(mktemp)"
trap 'rm -f "$attempts"' EXIT
info() { :; }
sleep() { :; }
az() {
    printf '%q ' "$@" >> "$attempts"
    printf '\n' >> "$attempts"
    if (( $(wc -l < "$attempts") <= failures )); then
        printf '%s\n' "$diagnostic" >&2
        return 17
    fi
}

check_tag_write() {
    local operation="$1" tag="$2" diagnostic="$3" failures="$4"
    local expected_attempts="$5" expected_rc="$6" rc=0
    : > "$attempts"
    update_security_profile_tag --resource-id test-vm --operation "$operation" --tags "$tag" || rc=$?
    [[ "$rc" == "$expected_rc" ]]
    [[ $(wc -l < "$attempts") -eq expected_attempts ]]
    [[ $(sort -u "$attempts" | wc -l) -eq 1 ]]
}

check_tag_write merge "acl-node-security-profile=ipe=audit" \
    "ERROR: ('Unable to connect to proxy', RemoteDisconnected('Remote end closed connection without response'))" 1 2 0
check_tag_write delete "acl-node-security-profile=" "Connection reset by peer" 2 3 0
check_tag_write merge "acl-node-security-profile=ipe=audit" "Connection reset by peer" 3 3 17
check_tag_write merge "acl-node-security-profile=ipe=audit" "AuthorizationFailed" 1 1 17
echo "azure security profile tag retry tests passed"
