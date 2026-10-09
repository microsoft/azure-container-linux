#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Offline validation exit-status contracts; no VM, network, or Azure access.

set -euo pipefail
TEST_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

run_case() {
    local scenario="$1"
    _VALIDATE_MODULE_DIR="${SCRIPT_DIR}/acl/validate"
    source "${_VALIDATE_MODULE_DIR}/validate_common.sh"
    source "${SCRIPT_DIR}/acl/tests/ipe/offline/function-extraction.sh"
    # Keep real argument parsing and orchestration; replace only host/VM I/O.
    _VALIDATE_AZURE_LOADED=1
    _VALIDATE_QEMU_LOADED=1
    resolve_azure_defaults() { :; }
    check_vm_prerequisites() { :; }
    resolve_vm_image_path() { echo "${TEST_SCRIPT}"; }
    read_vm_state() { VM_IP=192.0.2.1; VM_RG=test-rg; }
    start_vm() { VM_IP=192.0.2.1; VM_RG=test-rg; return "${START_STATUS:-0}"; }
    wait_for_vm_boot_qemu() { return "${BOOT_STATUS:-0}"; }
    wait_for_vm_ip_qemu() { return "${IP_STATUS:-0}"; }
    print_size_summary() { echo "SIZE_SUMMARY_REACHED"; }
    run_command_via_console_qemu() { return "${SCRIPT_STATUS:-0}"; }
    run_command_vm_azure() { return "${SCRIPT_STATUS:-0}"; }
    VM_SSH_KEY=test-key
    ssh() {
        echo "SSH_CALLED" >> "${TEST_LOG}"
        echo "sensitive-auth-banner" >&2
        local previous="" argument
        for argument; do
            if [[ "$previous" == "-i" && "$argument" != "$VM_SSH_KEY" ]]; then
                echo "KEY_SPLIT" >> "${TEST_LOG}"
                return 2
            fi
            previous="$argument"
        done
        if [[ "${!#}" == "echo 'SSH ready'" ]]; then
            return "${SSH_STATUS:-0}"
        fi
        return "${SCRIPT_STATUS:-0}"
    }
    scp() { return "${COPY_STATUS:-0}"; }
    # Advance a deterministic clock; no real timeout delays or extra probes.
    clock=0
    date() { echo "$clock"; }
    sleep() { clock=$((clock + $1)); }

    local args=(--vm-type=azure --reuse-vm --run-script="true" --ssh-timeout=6)
    case "$scenario" in
        ssh-timeout|build-ssh-timeout) SSH_STATUS=255 ;;
        script-error|build-script-error) SCRIPT_STATUS=42 ;;
        transport-error) SCRIPT_STATUS=255 ;;
        file-error|file-success)
            args+=(--run-script="${TEST_SCRIPT}")
            [[ "$scenario" != file-error ]] || SCRIPT_STATUS=42
            ;;
        copy-error) COPY_STATUS=1; args+=(--run-script="${TEST_SCRIPT}") ;;
        missing-script) args+=(--run-script="./missing-script.sh") ;;
        vm-start-error)
            args=(--vm-type=qemu --start-vm --run-script="true")
            START_STATUS=23
            ;;
        qemu-boot-error|serial-boot-error|build-boot-error)
            args=(--vm-type=qemu --start-vm --run-script="true")
            BOOT_STATUS=1
            [[ "$scenario" != serial-boot-error ]] || args+=(--use-serial)
            ;;
        qemu-ip-error)
            args=(--vm-type=qemu --start-vm --run-script="true")
            IP_STATUS=1
            ;;
        serial-error|serial-success)
            args+=(--use-serial)
            [[ "$scenario" != serial-error ]] || SCRIPT_STATUS=1
            ;;
        probe-success|probe-timeout|probe-no-key|probe-zero-timeout)
            VM_SSH_KEY="key with spaces"
            [[ "$scenario" != probe-timeout ]] || SSH_STATUS=255
            [[ "$scenario" != probe-no-key ]] || VM_SSH_KEY=""
            local seconds=6
            [[ "$scenario" != probe-zero-timeout ]] || seconds=0
            wait_for_ssh 192.0.2.1 "$seconds"
            return
            ;;
        success|build-success) ;;
        *) echo "Unknown scenario: $scenario" >&2; exit 2 ;;
    esac

    if [[ "$scenario" == build-* ]]; then
        source_test_functions "${SCRIPT_DIR}/acl/build_rpm_image.sh" main
        parse_args() { parse_validate_args "$@"; }
        check_prerequisites() { :; }
        print_summary() { :; }
        docker() { :; }
        cleanup_rpm_directories() { :; }
        BUILD_SDK_CONTAINER=false BUILD_RPMS=false BUILD_IMAGE=false
        BUILD_STANDALONE_SYSEXTS=false BUILD_TEST_IMAGE=false BUILD_VM_IMAGE=false
        ACL_IPE_MODE=audit ACL_IPE_SIGNING_MODE=ephemeral BUILD_ID=""
        RESOURCE_TAGS=()
        # Preserve the real build entrypoint's delegation and subprocess status.
        eval "$(printf '%q' "${SCRIPT_DIR}/acl/validate/validate_rpm_image.sh")"'() (
            RUN_SCRIPTS=()
            RUN_HOST_SCRIPTS=()
            START_VM=false
            REUSE_VM=false
            validate_main "$@"
        )'
        main "${args[@]}"
    else
        validate_main "${args[@]}"
    fi
}

if [[ "${1:-}" == "--case" ]]; then
    run_case "$2"
    exit $?
fi

TEST_WORK="${SCRIPT_DIR}/.validate-common-test.$$"
mkdir "${TEST_WORK}"
trap 'rm -rf "${TEST_WORK}"' EXIT
export TEST_LOG="${TEST_WORK}/calls"
passed=0
for spec in \
    ssh-timeout:1 script-error:1 transport-error:1 file-error:1 file-success:0 copy-error:1 missing-script:1 \
    vm-start-error:23 qemu-boot-error:1 serial-boot-error:1 qemu-ip-error:1 \
    serial-error:1 serial-success:0 success:0 \
    probe-success:0 probe-timeout:1 probe-no-key:0 probe-zero-timeout:1 \
    build-ssh-timeout:1 build-script-error:1 build-boot-error:1 build-success:0; do
    scenario="${spec%:*}" expected="${spec#*:}"
    : > "${TEST_LOG}"
    rc=0
    # A separate shell preserves production errexit semantics.
    bash "${TEST_SCRIPT}" --case "$scenario" > "${TEST_WORK}/output" 2>&1 || rc=$?
    if [[ "$rc" != "$expected" ]]; then
        cat "${TEST_WORK}/output"
        echo "FAIL: ${scenario}: got ${rc}, expected ${expected}" >&2
        exit 1
    fi
    if grep -Eq 'unbound variable|command not found|not a valid identifier' "${TEST_WORK}/output"; then
        cat "${TEST_WORK}/output"
        echo "FAIL: ${scenario}: test harness error" >&2
        exit 1
    fi
    if [[ "$scenario" == *ssh-timeout || "$scenario" == probe-timeout ]]; then
        grep -Fq "attempts=2, last exit status=255; guest scripts were not executed" "${TEST_WORK}/output"
        if grep -Eq 'sensitive-auth-banner|All scripts completed successfully|SIZE_SUMMARY_REACHED' "${TEST_WORK}/output"; then
            echo "FAIL: ${scenario}: leaked probe output or continued after timeout" >&2
            exit 1
        fi
        [[ "$(wc -l < "${TEST_LOG}")" -eq 2 ]]
    elif [[ "$scenario" == probe-zero-timeout ]]; then
        grep -Fq "attempts=0, last exit status=not attempted" "${TEST_WORK}/output"
        [[ ! -s "${TEST_LOG}" ]]
    elif [[ "$scenario" == *boot-error ]]; then
        grep -Fq "VM failed to boot within timeout" "${TEST_WORK}/output"
        [[ ! -s "${TEST_LOG}" ]]
    elif [[ "$scenario" == qemu-ip-error || "$scenario" == vm-start-error ]]; then
        [[ ! -s "${TEST_LOG}" ]]
    elif [[ "$scenario" == success || "$scenario" == build-success || "$scenario" == serial-success || "$scenario" == file-success ]]; then
        grep -Fq "All scripts completed successfully!" "${TEST_WORK}/output"
    fi
    if grep -Fq "KEY_SPLIT" "${TEST_LOG}"; then
        echo "FAIL: ${scenario}: SSH key argument was split" >&2
        exit 1
    fi
    echo "PASS: ${scenario}"
    passed=$((passed + 1))
done
echo "Validation exit-status tests passed (${passed} cases)"
