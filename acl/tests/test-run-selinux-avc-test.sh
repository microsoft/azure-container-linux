#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT=$(mktemp)
trap 'rm -f -- "$OUTPUT"' EXIT

dmesg() { printf '%s\n' "${DMESG_LOG:-boot completed}"; }
journalctl() { printf '%s\n' "${JOURNAL_LOG:-}"; }
getenforce() { printf '%s\n' "${MODE:-Enforcing}"; }
chcon() { :; }
stat() { printf '%s\n' 'system_u:object_r:shadow_t:s0'; }
runcon() {
    while [[ "$1" != -- ]]; do shift; done
    shift
    if [[ "$1" == id ]]; then
        printf '%s\n' "${PROCESS_CONTEXT:-system_u:system_r:container_t:s0}"
    elif [[ "${READ_RESULT:-denied}" == denied ]]; then
        printf 'cat: %s: Permission denied\n' "$2" >&2
        return 1
    else
        cat "$2"
    fi
}
export -f dmesg journalctl getenforce chcon stat runcon

check_case() {
    local name="$1" expected_status="$2" expected_output="$3" status=0
    bash "$SCRIPT_DIR/run-selinux-avc-test.sh" > "$OUTPUT" 2>&1 || status=$?
    if [[ "$status" -ne "$expected_status" ]] || ! grep -Fq "$expected_output" "$OUTPUT"; then
        printf 'FAIL: %s (status %s, expected %s)\n' "$name" "$status" "$expected_status" >&2
        cat "$OUTPUT" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$name"
}

check_case 'confined read is denied' 0 'Enforcing SELinux denied container_t read of shadow_t'
READ_RESULT=allowed
export READ_RESULT
check_case 'unexpectedly allowed read fails' 1 'Confined read was not denied as expected'
READ_RESULT=denied
MODE=Permissive
export READ_RESULT MODE
check_case 'permissive mode fails' 1 'SELinux is not enforcing'
MODE=Enforcing
PROCESS_CONTEXT=system_u:system_r:unconfined_t:s0
export MODE PROCESS_CONTEXT
check_case 'wrong process domain fails' 1 'Probe process has unexpected context'
PROCESS_CONTEXT=system_u:system_r:container_t:s0
DMESG_LOG='audit: avc: denied { read } comm="cat" name="other" scontext=system_u:system_r:container_t:s0 tcontext=system_u:object_r:shadow_t:s0 tclass=file permissive=0'
export PROCESS_CONTEXT DMESG_LOG
check_case 'unrelated AVC still fails' 1 'AVC denials found in dmesg: 1'
DMESG_LOG='audit: avc: denied { read } comm="cat" name="acl-selinux-denial.abcdef" scontext=system_u:system_r:container_t:s0 tcontext=system_u:object_r:shadow_t:s0 tclass=file permissive=0'
export DMESG_LOG
check_case 'prior probe AVC is excluded' 0 'Enforcing SELinux denied container_t read of shadow_t'
DMESG_LOG='audit: avc: denied { write } comm="cat" name="acl-selinux-denial.abcdef" scontext=system_u:system_r:container_t:s0 tcontext=system_u:object_r:shadow_t:s0 tclass=file permissive=0'
export DMESG_LOG
check_case 'other access to probe is not excluded' 1 'AVC denials found in dmesg: 1'
DMESG_LOG='boot completed'
JOURNAL_LOG='audit: avc: denied { read } comm="cat" name="other" scontext=system_u:system_r:container_t:s0 tcontext=system_u:object_r:shadow_t:s0 tclass=file permissive=0'
export DMESG_LOG JOURNAL_LOG
check_case 'unrelated journal AVC still fails' 1 'AVC denials found in journal: 1'
