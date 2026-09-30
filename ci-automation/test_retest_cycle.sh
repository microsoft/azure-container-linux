#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Regression tests for grouped Kola retry-cycle stop signals.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=ci-automation/ci_automation_common.sh
source "${SCRIPT_DIR}/ci-automation/ci_automation_common.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

mkdir -p \
    "${TEST_TMPDIR}/__TESTS__/qemu_uefi" \
    "${TEST_TMPDIR}/__TESTS__/parallel/qemu_uefi" \
    "${TEST_TMPDIR}/unrelated/qemu_uefi"

(
    cd "${TEST_TMPDIR}/__TESTS__/qemu_uefi"
    TEST_WORK_DIR=__TESTS__ break_retest_cycle
)
if [[ -f "${TEST_TMPDIR}/__TESTS__/break_retests" ]]; then
    pass "legacy test work root emits the stop marker"
else
    fail "legacy test work root did not emit the stop marker"
fi
rm -f "${TEST_TMPDIR}/__TESTS__/break_retests"

if (
    cd "${TEST_TMPDIR}"
    MAX_RUNS=3
    ATTEMPTS=0
    TEST_WORK_DIR=__TESTS__/parallel
    for _ in $(seq "${MAX_RUNS}"); do
        ATTEMPTS=$((ATTEMPTS + 1))
        (
            cd __TESTS__/parallel/qemu_uefi
            TEST_WORK_DIR=__TESTS__ break_retest_cycle
        )
        if retest_cycle_broken; then
            break
        fi
    done
    [[ "${ATTEMPTS}" -eq 1 ]]
); then
    pass "nested test group stops a multi-attempt retry cycle"
else
    fail "nested test group did not stop after the first attempt"
fi

(
    cd "${TEST_TMPDIR}/unrelated/qemu_uefi"
    TEST_WORK_DIR=__TESTS__ break_retest_cycle
)
if [[ ! -e "${TEST_TMPDIR}/unrelated/break_retests" ]]; then
    pass "unrelated work directory cannot emit a stop marker"
else
    fail "unrelated work directory emitted a stop marker"
fi

echo
echo "Passed: ${PASS}   Failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
