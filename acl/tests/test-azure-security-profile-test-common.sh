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

TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_DIR}"' EXIT
mkdir -p "${TEST_DIR}/bin"
export PATH="${TEST_DIR}/bin:${PATH}"
export MOCK_STATE MOCK_MODE
VM_NAME=test
VM_RG=test-rg
VM_IP=192.0.2.1
VM_SSH_USER=core
VM_SSH_TIMEOUT=120

info() { printf 'INFO: %s\n' "$*" >>"${MOCK_STATE}/messages"; }
warn() { printf 'WARN: %s\n' "$*" >>"${MOCK_STATE}/messages"; }
error() { printf 'ERROR: %s\n' "$*" >>"${MOCK_STATE}/messages"; }
section() { info "$@"; }

cat >"${TEST_DIR}/bin/ssh" <<'MOCK'
#!/bin/bash
set -eu
command="${*: -1}"
printf 'ssh: %s\n' "${command}" >>"${MOCK_STATE}/calls"
case "${command}" in
    'cat /proc/sys/kernel/random/boot_id')
        echo "boot probe stderr" >&2
        if [[ "${MOCK_MODE}" == "unreachable" ||
              ( "${MOCK_MODE}" == "timeout" && -f "${MOCK_STATE}/generation" ) ]]; then
            echo "Connection timed out" >&2
            exit 255
        fi
        generation=0
        [[ ! -f "${MOCK_STATE}/generation" ]] || generation="$(cat "${MOCK_STATE}/generation")"
        printf 'boot-%s\n' "${generation}"
        ;;
    'sudo reboot')
        generation=0
        [[ ! -f "${MOCK_STATE}/generation" ]] || generation="$(cat "${MOCK_STATE}/generation")"
        echo "$((generation + 1))" >"${MOCK_STATE}/generation"
        echo "Connection closed by remote host" >&2
        exit 255
        ;;
    'sudo -n sh -s')
        cat >"${MOCK_STATE}/guest-script"
        if [[ "${MOCK_MODE}" == "unreachable" ||
              "${MOCK_MODE}" == "capture-failure" ||
              ( "${MOCK_MODE}" == "timeout" && -f "${MOCK_STATE}/generation" ) ]]; then
            echo "Permission denied (publickey)" >&2
            exit 255
        fi
        echo "guest snapshot: SELinux enforcing, IPE enforce=0"
        ;;
    *)
        echo "Unexpected SSH command: ${command}" >&2
        exit 90
        ;;
esac
MOCK

cat >"${TEST_DIR}/bin/az" <<'MOCK'
#!/bin/bash
set -eu
printf 'az: %s\n' "$*" >>"${MOCK_STATE}/calls"
case "$*" in
    'vm get-instance-view '*)
        echo '{"statuses":[{"code":"PowerState/running"}]}'
        ;;
    'vm boot-diagnostics get-boot-log '*)
        printf '[    0.000000] Linux boot log\nsshd: listening\n'
        echo "serial collection stderr" >&2
        ;;
    'vm run-command invoke '*)
        echo '{"value":[{"code":"ComponentStatus/StdOut/succeeded","message":"guest-agent snapshot"}]}'
        ;;
    *)
        echo "Unexpected Azure operation" >&2
        exit 90
        ;;
esac
MOCK
chmod +x "${TEST_DIR}/bin/ssh" "${TEST_DIR}/bin/az"

new_case() {
    MOCK_STATE="${TEST_DIR}/$1"
    MOCK_MODE="${2:-success}"
    DIAGNOSTICS_DIR="${MOCK_STATE}/diagnostics"
    mkdir -p "${DIAGNOSTICS_DIR}"
    VM_BOOT_TIMEOUT=10
}

new_case capture-status
status=0
capture_security_profile_diagnostic "${MOCK_STATE}/output" 5s \
    bash -c 'echo stdout; echo stderr >&2; exit 7' || status=$?
[[ "${status}" -eq 7 ]]
[[ "$(<"${MOCK_STATE}/output")" == "stdout" ]]
[[ "$(<"${MOCK_STATE}/output.stderr")" == "stderr" ]]
[[ "$(<"${MOCK_STATE}/output.exit-code")" == "7" ]]
grep -q 'WARN:.*exit=7' "${MOCK_STATE}/messages"
echo "diagnostic stdout, stderr, and exit status preserved"

new_case bounded-command
status=0
capture_security_profile_diagnostic "${MOCK_STATE}/output" 0.1s sleep 5 || status=$?
[[ "${status}" -eq 124 ]]
[[ "$(<"${MOCK_STATE}/output.exit-code")" == "124" ]]
echo "diagnostic command timeout enforced"

new_case successful-reboot
reboot_and_wait
prefixes=("${DIAGNOSTICS_DIR}"/security-profile-test.*)
prefix="${prefixes[0]}"
grep -q 'guest snapshot' "${prefix}/guest-before.log"
grep -q 'guest snapshot' "${prefix}/guest-after.log"
grep -q 'boot probe stderr' "${prefix}/ssh-poll.log"
grep -q 'old_boot_id=boot-0' "${prefix}/reboot.log"
grep -q 'boot_id=boot-1' "${prefix}/reboot.log"
grep -q 'reboot_command_exit=255' "${prefix}/reboot.log"
grep -q 'Connection closed' "${prefix}/reboot-command.log"
grep -q 'journalctl' "${MOCK_STATE}/guest-script"
! grep -q '^az:' "${MOCK_STATE}/calls"
reboot_and_wait
prefixes=("${DIAGNOSTICS_DIR}"/security-profile-test.*)
[[ "${#prefixes[@]}" -eq 2 ]]
echo "successful reboots collect separate snapshots without Azure fallback"

new_case failed-reboot timeout
VM_BOOT_TIMEOUT=1
status=0
reboot_and_wait || status=$?
[[ "${status}" -eq 1 ]]
prefixes=("${DIAGNOSTICS_DIR}"/security-profile-test.*)
prefix="${prefixes[0]}"
grep -q 'Linux boot log' "${prefix}/serial.log"
grep -q 'serial collection stderr' "${prefix}/serial.log.stderr"
grep -q 'PowerState/running' "${prefix}/instance-view.json"
grep -q 'Permission denied' "${prefix}/guest-timeout.log.stderr"
grep -q 'Connection timed out' "${prefix}/ssh-poll.log"
grep -q 'exit=255 boot_id=' "${prefix}/reboot.log"
grep -q 'guest-agent snapshot' "${prefix}/run-command.json"
grep -q 'timeout --signal=TERM --kill-after=5s 45s sh' "${MOCK_STATE}/calls"
! grep -q '^az:.*\(tag update\|group delete\)' "${MOCK_STATE}/calls"
[[ ! -e "${prefix}/guest-after.log" ]]
echo "failed reboot preserves raw serial data, falls back to agent, and remains failed"

new_case reachable-failure
collect_security_profile_failure_diagnostics "${DIAGNOSTICS_DIR}"
[[ -s "${DIAGNOSTICS_DIR}/guest-timeout.log" ]]
[[ ! -e "${DIAGNOSTICS_DIR}/run-command.json" ]]
echo "failure collection skips Run Command when SSH succeeds"

new_case failed-snapshots capture-failure
reboot_and_wait
prefixes=("${DIAGNOSTICS_DIR}"/security-profile-test.*)
prefix="${prefixes[0]}"
[[ "$(<"${prefix}/guest-before.log.exit-code")" == "255" ]]
[[ "$(<"${prefix}/guest-after.log.exit-code")" == "255" ]]
grep -q 'Pre-reboot guest snapshot incomplete' "${MOCK_STATE}/messages"
grep -q 'Post-reboot guest snapshot incomplete' "${MOCK_STATE}/messages"
echo "snapshot failures are visible without changing a successful reboot result"

new_case initially-unreachable unreachable
status=0
reboot_and_wait || status=$?
[[ "${status}" -eq 1 ]]
prefixes=("${DIAGNOSTICS_DIR}"/security-profile-test.*)
grep -q 'Connection timed out' "${prefixes[0]}/ssh-poll.log"
[[ -s "${prefixes[0]}/run-command.json" ]]
! grep -q '^ssh: sudo reboot' "${MOCK_STATE}/calls"
echo "initial SSH failure collects diagnostics without attempting a reboot"

new_case restoration
status=0
(
    SECURITY_PROFILE_MUTATED=true
    ORIGINAL_SECURITY_PROFILE_STATE='{"present":true,"value":"ipe=audit"}'
    set_security_profile_tag_state() { echo restored >>"${MOCK_STATE}/calls"; }
    reboot_and_wait() { echo restore-reboot >>"${MOCK_STATE}/calls"; }
    trap restore_security_profile_on_exit EXIT
    collect_security_profile_failure_diagnostics "${DIAGNOSTICS_DIR}"
    exit 7
) || status=$?
[[ "${status}" -eq 7 ]]
[[ "$(tail -2 "${MOCK_STATE}/calls")" == $'restored\nrestore-reboot' ]]
echo "diagnostics finish before restoration and preserve the original failure status"

sh -n "${SCRIPT_DIR}/acl/tests/collect-security-profile-diagnostics.sh"
echo "azure security profile diagnostic tests passed"
