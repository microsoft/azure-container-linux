#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMON_HELPER="${SCRIPT_DIR}/acl/tests/azure-security-profile-test-common.sh"
VALIDATE_COMMON="${SCRIPT_DIR}/acl/validate/validate_common.sh"

source "${COMMON_HELPER}"

VM_SSH_KEY="${SCRIPT_DIR}/unused-test-vm-ssh-key"
ACL_SECURITY_PROFILE_DIAGNOSTICS=0
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

TEST_DIR="${SCRIPT_DIR}/.security-profile-test-${BASHPID}"
mkdir "${TEST_DIR}"
trap 'rm -rf -- "${TEST_DIR}"' EXIT
! security_profile_diagnostics_enabled
DIAGNOSTICS_DIR="${TEST_DIR}/diagnostics"
ACL_SECURITY_PROFILE_DIAGNOSTICS=1
setup_ssh_opts
security_profile_diagnostics_enabled
[[ " ${SSH_OPTS[*]} " == *" -vv -E "* ]]
VM_RG=fixture VM_NAME=fixture VM_IP=192.0.2.1 VM_SSH_USER=fixture
info() { :; }
warn() { printf '%s\n' "$*" >&2; }
error() { printf '%s\n' "$*" >&2; }

ssh_cmd() {
    case "${PROBE_MODE}" in
        success) printf '[{"name":"acl-node-security-profile","value":"ipe=audit"}]\n' ;;
        ssh) echo "Connection timed out" >&2; return 255 ;;
        http) echo "ACL_IMDS_HTTP_STATUS=410" >&2; return 22 ;;
        malformed) printf '{}\n' ;;
    esac
}
for PROBE_MODE in success ssh http malformed; do
    status=0
    imds_security_profile_state >"${TEST_DIR}/${PROBE_MODE}.out" || status=$?
    if [[ "${PROBE_MODE}" == success ]]; then
        [[ "${status}" -eq 0 ]]
        [[ "$(<"${TEST_DIR}/success.out")" == '{"present":true,"value":"ipe=audit"}' ]]
    else
        [[ "${status}" -ne 0 ]]
    fi
done
grep -q 'probe-ssh-or-remote-exit=255' "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-events.log"
grep -q 'probe-ssh-or-remote-exit=22' "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-events.log"
grep -q 'probe-parser-exit=5' "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-events.log"
grep -q 'Connection timed out' "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-imds.stderr"
grep -q 'ACL_IMDS_HTTP_STATUS=410' "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-imds.stderr"
echo "IMDS transport, HTTP, parser status and normalized stdout preserved"

(
    security_profile_diagnostic_read failing-command \
        bash -c 'echo fixture-output; echo fixture-error >&2; exit 7'
    [[ "$(<"${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-failing-command.stdout")" == fixture-output ]]
    [[ "$(<"${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-failing-command.stderr")" == fixture-error ]]
    grep -q 'snapshot=failing-command status=7' "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-events.log"
)

(
    clock=0
    date() {
        if [[ "$1" == +%s ]]; then printf '%s\n' "${clock}"; else command date "$@"; fi
    }
    sleep() { clock=60; }
    az() {
        case "$1 $2" in
            "vm show") printf '/fixture/vm\n' ;;
            "tag update") : ;;
            *) return 99 ;;
        esac
    }
    capture_security_profile_diagnostics() { echo "$1" >>"${TEST_DIR}/captures"; return 73; }
    PROBE_MODE=ssh
    status=0
    set_security_profile_tag_state '{"present":true,"value":"ipe=audit"}' \
        >"${TEST_DIR}/poll.stdout" 2>"${TEST_DIR}/poll.stderr" || status=$?
    [[ "${status}" -eq 1 ]]
    [[ "$(<"${TEST_DIR}/captures")" == imds-timeout ]]
    grep -q 'within 60s' "${TEST_DIR}/poll.stderr"
)
echo "terminal IMDS failure captures diagnostics without changing its status"

(
    security_profile_diagnostic_read() {
        printf '%s\n' "$1" >>"${TEST_DIR}/snapshot-reads"
        [[ "$1" != vm ]] || printf '{}\n' >"${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-vm.stdout"
        return 0
    }
    timeout() { printf 'https://example.invalid/serial?sig=fixture-secret\n'; }
    curl() { printf 'raw serial text, not JSON\n'; }
    capture_security_profile_diagnostics fixture
    capture_security_profile_diagnostics duplicate
    [[ "$(grep -c '^instance$' "${TEST_DIR}/snapshot-reads")" -eq 1 ]]
    [[ "$(<"${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-serial.log")" == 'raw serial text, not JSON' ]]
    ! grep -r -q 'fixture-secret' "${DIAGNOSTICS_DIR}"
)
echo "failure snapshot is single-shot and preserves raw serial without its SAS URL"

status=0
(
    info() { :; }
    warn() { :; }
    section() { :; }
    capture_security_profile_diagnostics() { echo capture >>"${TEST_DIR}/order"; return 73; }
    set_security_profile_tag_state() { echo restore >>"${TEST_DIR}/order"; }
    reboot_and_wait() { echo reboot >>"${TEST_DIR}/order"; }
    SECURITY_PROFILE_MUTATED=true
    ORIGINAL_SECURITY_PROFILE_STATE='{"present":true,"value":"ipe=audit"}'
    trap restore_security_profile_on_exit EXIT
    exit 7
) || status=$?
[[ "${status}" -eq 7 ]]
[[ "$(<"${TEST_DIR}/order")" == $'capture\nrestore\nreboot' ]]
echo "failed diagnostics preserve primary exit status and precede restoration"
