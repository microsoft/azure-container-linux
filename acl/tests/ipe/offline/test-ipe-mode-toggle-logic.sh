#!/bin/bash
# Offline unit tests for the pure (non-VM) logic in
# run-ipe-mode-toggle-test.sh: the acl-node-security-profile tag -> expected
# runtime mode mapping, and the 'enforcing must never be observed' safety
# assertions. The reboot/IMDS orchestration itself requires a live Azure VM
# and is exercised by run-ipe-mode-toggle-test.sh directly in pipeline runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export SCRIPT_DIR

# Sourcing (rather than executing) skips main() — see the
# BASH_SOURCE-vs-$0 guard at the bottom of the toggle test script — while
# still loading the exact same helper functions it uses at runtime.
source "${SCRIPT_DIR}/acl/tests/ipe/run-ipe-mode-toggle-test.sh"

test_expected_mode_for_tag() {
    local case_spec input expected actual
    for case_spec in "disabled:off" "off:off" ":off" "audit:permissive" \
        "permissive:permissive" "enforcing:off" "bogus:off"; do
        input="${case_spec%%:*}"
        expected="${case_spec##*:}"
        actual="$(expected_mode_for_tag "${input}")"
        [[ "${actual}" == "${expected}" ]] ||
            { echo "expected_mode_for_tag('${input}') = '${actual}', want '${expected}'" >&2; return 1; }
    done
}

test_assert_ipe_mode_matches() {
    get_ipe_mode() { echo "off"; }
    assert_ipe_mode "off"
    get_ipe_mode() { echo "permissive"; }
    assert_ipe_mode "permissive"
}

test_assert_ipe_mode_mismatch_fails() {
    get_ipe_mode() { echo "off"; }
    if assert_ipe_mode "permissive" 2>/dev/null; then
        echo "assert_ipe_mode accepted a mismatched mode" >&2; return 1
    fi
}

# ---- Safety: 'enforcing' observed anywhere must fail loudly, regardless
# of what was expected, and must never be silently accepted. ----
test_assert_ipe_mode_rejects_enforcing() {
    get_ipe_mode() { echo "enforcing"; }
    local output
    if output="$(assert_ipe_mode "off" 2>&1)"; then
        echo "assert_ipe_mode accepted an observed 'enforcing' state" >&2; return 1
    fi
    grep -Fq "CRITICAL: IPE is ENFORCING at runtime" <<< "${output}" ||
        { echo "missing CRITICAL enforcing diagnostic" >&2; return 1; }
}

test_assert_ipe_not_enforcing() {
    get_ipe_mode() { echo "off"; }
    assert_ipe_not_enforcing
    get_ipe_mode() { echo "permissive"; }
    assert_ipe_not_enforcing

    get_ipe_mode() { echo "enforcing"; }
    local output
    if output="$(assert_ipe_not_enforcing 2>&1)"; then
        echo "assert_ipe_not_enforcing accepted an observed 'enforcing' state" >&2; return 1
    fi
    grep -Fq "CRITICAL: IPE is ENFORCING at runtime" <<< "${output}" ||
        { echo "missing CRITICAL enforcing diagnostic" >&2; return 1; }
}

test_acl_security_profile_value_reused() {
    # The toggle test reuses acl_security_profile_value() from the
    # production security-profile helper; confirm it parses the way the
    # in-guest loader expects.
    [[ "$(acl_security_profile_value 'ipe=audit,foo=bar' 'ipe')" == "audit" ]]
    [[ "$(acl_security_profile_value '' 'ipe')" == "" ]]
}

test_expected_mode_for_tag
test_assert_ipe_mode_matches
test_assert_ipe_mode_mismatch_fails
test_assert_ipe_mode_rejects_enforcing
test_assert_ipe_not_enforcing
test_acl_security_profile_value_reused

echo "IPE mode toggle logic tests passed"
