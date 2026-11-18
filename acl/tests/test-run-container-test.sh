#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$(mktemp)"
trap 'rm -f -- "${OUTPUT}"' EXIT

iptables() {
    echo "FAIL: sourcing the container test must not execute it" >&2
    exit 1
}

# shellcheck source=acl/tests/run-container-test.sh
source "${SCRIPT_DIR}/run-container-test.sh"

IMAGE=mcr.microsoft.com/azurelinux/base/nginx:1
EROFS_IMAGE=mcr.microsoft.com/oss/v2/ingress-nginx/controller:v1.14.1-1

assert_equal() {
    local expected="$1" actual="$2" label="$3"
    if [[ "${expected}" != "${actual}" ]]; then
        printf 'FAIL: %s\nExpected: %s\nActual: %s\n' "${label}" "${expected}" "${actual}" >&2
        cat "${OUTPUT}" >&2
        exit 1
    fi
}

reset_mocks() {
    PULL_RESULTS=("$@")
    PULL_ATTEMPTS=0
    PULL_ERROR="ctr: registry request failed"
    COMMANDS=()
}

timeout() {
    assert_equal "--signal=TERM --kill-after=5s 300s" "${*:1:3}" "per-attempt timeout and kill grace"
    shift 3
    assert_equal "ctr images pull" "${*:1:3}" "only image pulls are retried"
    "$@"
}

ctr() {
    COMMANDS+=("ctr $*")
    if [[ "$1" == images ]]; then
        if [[ "${PULL_ATTEMPTS}" -ge "${#PULL_RESULTS[@]}" ]]; then
            echo "FAIL: unexpected extra image pull" >&2
            exit 1
        fi
        local status="${PULL_RESULTS[PULL_ATTEMPTS]}"
        PULL_ATTEMPTS=$((PULL_ATTEMPTS + 1))
        echo "mock pull progress"
        if [[ "${status}" -ne 0 ]]; then
            echo "${PULL_ERROR}" >&2
        fi
        return "${status}"
    fi
    assert_equal run "$1" "container runtime command"
}

iptables() {
    COMMANDS+=("iptables $*")
}

sleep() {
    COMMANDS+=("sleep $*")
}

capture_status() {
    STATUS=0
    "$@" > "${OUTPUT}" 2>&1 || STATUS=$?
}

assert_commands() {
    local expected actual
    printf -v expected '%s\n' "$@"
    printf -v actual '%s\n' "${COMMANDS[@]}"
    assert_equal "${expected}" "${actual}" "command ordering and backoff"
}

assert_pull_case() (
    local label="$1" expected_status="$2" error="$3"
    shift 3
    reset_mocks "$@"
    PULL_ERROR="${error}"
    capture_status pull_image_with_retry "${IMAGE}"
    assert_equal "${expected_status}" "${STATUS}" "${label} exit status"
    assert_equal "${#PULL_RESULTS[@]}" "${PULL_ATTEMPTS}" "${label} attempt count"

    case "${PULL_ATTEMPTS}" in
        1) assert_commands "ctr images pull ${IMAGE}" ;;
        2) assert_commands "ctr images pull ${IMAGE}" "sleep 15" "ctr images pull ${IMAGE}" ;;
        3) assert_commands "ctr images pull ${IMAGE}" "sleep 15" "ctr images pull ${IMAGE}" \
               "sleep 30" "ctr images pull ${IMAGE}" ;;
    esac
    grep -Fq "attempt ${PULL_ATTEMPTS}/3" "${OUTPUT}"
    if [[ -n "${error}" ]]; then
        grep -Fq "${error}" "${OUTPUT}"
    fi
    if [[ "${expected_status}" -ne 0 ]]; then
        grep -Fq "FAILED: Image pull failed after 3 attempts (exit ${expected_status})" "${OUTPUT}"
    fi
    if grep -Fq "mock pull progress" "${OUTPUT}"; then
        echo "FAIL: image pull progress should remain suppressed" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "${label}"
)

assert_overlayfs_recovery() (
    reset_mocks 1 0
    capture_status run_overlayfs_smoke_test
    assert_equal 0 "${STATUS}" "overlayfs recovery"
    assert_commands \
        "iptables -I INPUT -p tcp --dport 80 -j ACCEPT" \
        "ctr images pull ${IMAGE}" "sleep 15" "ctr images pull ${IMAGE}" \
        "ctr run --detach --net-host ${IMAGE} nginx" "sleep 2"
    echo "PASS: overlayfs startup runs once, after a successful pull"
)

assert_overlayfs_failure() (
    reset_mocks 42 42 42
    capture_status run_overlayfs_smoke_test
    assert_equal 42 "${STATUS}" "overlayfs pull exhaustion"
    assert_commands \
        "iptables -I INPUT -p tcp --dport 80 -j ACCEPT" \
        "ctr images pull ${IMAGE}" "sleep 15" "ctr images pull ${IMAGE}" \
        "sleep 30" "ctr images pull ${IMAGE}"
    echo "PASS: overlayfs startup is not reached after pull exhaustion"
)

# These overrides are called indirectly by the sourced EROFS test.
# shellcheck disable=SC2329
assert_erofs_case() (
    local expected_status="$1"
    shift
    reset_mocks "$@"
    getenforce() { echo Enforcing; }
    latest_nginx_image() { echo "${EROFS_IMAGE}"; }
    mktemp() { echo /unused/erofs-test; }
    cleanup_erofs_nginx() { exit "$1"; }
    start_erofs_nginx() {
        assert_equal "${EROFS_IMAGE} erofs-test /unused/erofs-test" "$*" "EROFS startup arguments"
        assert_commands \
            "ctr images pull --snapshotter erofs ${EROFS_IMAGE}" "sleep 15" \
            "ctr images pull --snapshotter erofs ${EROFS_IMAGE}"
        exit 23
    }

    capture_status run_erofs_selinux_test
    assert_equal "${expected_status}" "${STATUS}" "EROFS pull propagation and cleanup"
    grep -Fq "attempt ${#PULL_RESULTS[@]}/3" "${OUTPUT}"
    printf 'PASS: EROFS pull returns %s through cleanup\n' "${expected_status}"
)

# These mocks run in the smoke script's child shell.
# shellcheck disable=SC2329
assert_startup_failure() (
    ctr() {
        echo "MOCK ctr $*" >&2
        if [[ "$1" == images ]]; then
            return 0
        fi
        return 7
    }
    timeout() { shift 3; "$@"; }
    iptables() { :; }
    sleep() {
        echo "FAIL: container startup failure must stop the script" >&2
        exit 1
    }
    export -f ctr timeout iptables sleep

    capture_status bash "${SCRIPT_DIR}/run-container-test.sh"
    assert_equal 7 "${STATUS}" "direct execution preserves container startup failure"
    assert_equal 1 "$(grep -Fc "MOCK ctr images pull ${IMAGE}" "${OUTPUT}")" "single successful pull"
    assert_equal 1 "$(grep -Fc "MOCK ctr run --detach --net-host ${IMAGE} nginx" "${OUTPUT}")" "startup is not retried"
    echo "PASS: direct execution fails on container startup without retrying it"
)

assert_pull_case "immediate success" 0 "" 0
assert_pull_case "TLS handshake timeout recovery" 0 "ctr: net/http: TLS handshake timeout" 1 0
assert_pull_case "TCP connection timeout recovery" 0 "ctr: dial tcp: i/o timeout: context deadline exceeded" 1 0
assert_pull_case "HTTP 429 recovery" 0 "ctr: 429 Too Many Requests" 1 0
assert_pull_case "third-attempt recovery" 0 "ctr: connection reset by peer" 1 1 0
assert_pull_case "persistent failure" 42 "ctr: unauthorized" 42 42 42
assert_pull_case "per-attempt timeout exhaustion" 124 "timeout: command timed out" 124 124 124
assert_pull_case "forced termination exhaustion" 137 "timeout: command killed" 137 137 137
assert_overlayfs_recovery
assert_overlayfs_failure
assert_erofs_case 23 1 0
assert_erofs_case 42 42 42 42
assert_startup_failure
