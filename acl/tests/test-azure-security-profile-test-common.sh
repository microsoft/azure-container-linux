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
for ACL_SECURITY_PROFILE_DIAGNOSTICS in 0 1; do
    setup_ssh_opts
    for PROBE_MODE in success ssh http malformed; do
        status=0
        imds_security_profile_state >"${TEST_DIR}/${PROBE_MODE}.out" \
            2>"${TEST_DIR}/${PROBE_MODE}.err" || status=$?
        case "${PROBE_MODE}" in
            success)
                [[ "${status}" -eq 0 ]]
                [[ "$(<"${TEST_DIR}/success.out")" == '{"present":true,"value":"ipe=audit"}' ]]
                ;;
            ssh) [[ "${status}" -eq 255 ]]; grep -q 'SSH transport/session' "${TEST_DIR}/ssh.err" ;;
            http) [[ "${status}" -eq 69 ]]; grep -q 'Remote IMDS request failed' "${TEST_DIR}/http.err" ;;
            malformed) [[ "${status}" -eq 65 ]]; grep -q 'Invalid IMDS' "${TEST_DIR}/malformed.err" ;;
        esac
    done
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
    sleep() { [[ "$1" == 2 ]]; clock=$((clock + 30)); }
    az() {
        case "$1 $2" in
            "vm show") printf '/fixture/vm\n' ;;
            "tag update") : ;;
            *) return 99 ;;
        esac
    }
    capture_security_profile_diagnostics() { echo "$1" >>"${TEST_DIR}/captures"; return 73; }
    for PROBE_MODE in ssh http malformed success; do
        clock=0 status=0
        : >"${TEST_DIR}/captures"
        set_security_profile_tag_state '{"present":true,"value":"ipe=enforcing"}' \
            >"${TEST_DIR}/poll.stdout" 2>"${TEST_DIR}/poll.stderr" || status=$?
        [[ "${status}" -eq 1 ]]
        grep -q 'within 60s' "${TEST_DIR}/poll.stderr"
        case "$PROBE_MODE" in
            ssh) reason=ssh-failure; message='SSH failures=2' ;;
            http) reason=imds-read-failure; message='remote request failures=2' ;;
            malformed) reason=imds-read-failure; message='invalid responses=2' ;;
            success) reason=imds-timeout; message='IMDS did not converge' ;;
        esac
        [[ "$(<"${TEST_DIR}/captures")" == "$reason" ]]
        grep -q "$message" "${TEST_DIR}/poll.stderr"
        if [[ "$PROBE_MODE" != success ]]; then
            ! grep -q 'IMDS did not converge' "${TEST_DIR}/poll.stderr"
            grep -q 'last observed: unavailable' "${TEST_DIR}/poll.stderr"
        else
            grep -q 'last observed: {"present":true,"value":"ipe=audit"}' "${TEST_DIR}/poll.stderr"
        fi
    done

    ssh_cmd() {
        if [[ "$clock" -eq 0 ]]; then
            printf '[{"name":"acl-node-security-profile","value":"ipe=audit"}]\n'
        else
            return 255
        fi
    }
    clock=0 status=0
    set_security_profile_tag_state '{"present":true,"value":"ipe=enforcing"}' \
        >"${TEST_DIR}/poll.stdout" 2>"${TEST_DIR}/poll.stderr" || status=$?
    [[ "$status" -eq 1 ]]
    grep -q 'SSH failures=1.*successful reads=1' "${TEST_DIR}/poll.stderr"
    grep -q 'last observed: {"present":true,"value":"ipe=audit"}' "${TEST_DIR}/poll.stderr"
)
echo "transport, remote request, invalid response and stale IMDS failures stay distinct with unchanged timeout/status"

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

    VM_BOOT_TIMEOUT=0 VM_SSH_TIMEOUT=10
    boot_id() { printf 'original-boot\n'; }
    timeout() { :; }
    az() {
        printf '%s\n' "$1 $2" >>"${TEST_DIR}/fallback-reads"
        case "$1 $2" in
            "vm get-instance-view") printf '{"statuses":[]}\n' ;;
            "vm boot-diagnostics") printf '"restoration serial\\n"\n' ;;
            *) return 99 ;;
        esac
    }
    status=0
    reboot_and_wait >"${TEST_DIR}/reboot.stdout" 2>"${TEST_DIR}/reboot.stderr" || status=$?
    [[ "$status" -eq 1 ]]
    if [[ ! -f "${TEST_DIR}/fallback-reads" ]]; then
        echo "FAIL: consumed one-shot capture suppressed restoration reboot diagnostics" >&2
        exit 1
    fi
    [[ "$(<"${TEST_DIR}/fallback-reads")" == $'vm get-instance-view\nvm boot-diagnostics' ]]
    [[ "$(grep -c '^instance$' "${TEST_DIR}/snapshot-reads")" -eq 1 ]]
    [[ "$(<"${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-serial.log")" == 'raw serial text, not JSON' ]]
    fallback_serial=("${DIAGNOSTICS_DIR}"/*-fixture-serial.log)
    [[ "${#fallback_serial[@]}" -eq 1 && "$(<"${fallback_serial[0]}")" == 'restoration serial' ]]
)
echo "failure snapshot is single-shot; later reboot timeout preserves it and captures legacy diagnostics"

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
