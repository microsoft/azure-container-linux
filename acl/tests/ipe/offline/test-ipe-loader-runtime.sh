#!/bin/bash
# Verify best-effort initramfs IPE policy loading and validation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LOADER="${SCRIPT_DIR}/build_library/rpm/additional_files/dracut-acl-ipe-load/acl-ipe-load.sh"
PROFILE_HELPER="${SCRIPT_DIR}/build_library/rpm/additional_files/acl-node-security-profile.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ZERO_HASH="0000000000000000000000000000000000000000000000000000000000000000"

make_credential() {
    local path="$1"
    printf 'test-credential-content\n' > "${path}"
}

prepare_case() {
    local name="$1"
    CASE_DIR="${TMP_DIR}/${name}"
    IPE_DIR="${CASE_DIR}/ipe"

    mkdir -p "${IPE_DIR}"
    : > "${IPE_DIR}/new_policy"
    printf '9\n' > "${IPE_DIR}/enforce"

    cat > "${CASE_DIR}/security-profile.sh" <<'EOF'
acl_security_profile() {
    printf '%s\n' 'ipe=permissive'
}
acl_security_profile_value() {
    printf '%s\n' 'permissive'
}
EOF
}

run_loader() {
    local credential="${1:-${CASE_DIR}/credential.p7b.cred}"
    ACL_IPE_DIR="${IPE_DIR}" \
    ACL_IPE_CMDLINE_FILE="${CASE_DIR}/cmdline" \
    ACL_IPE_CREDENTIAL_PATH="${credential}" \
    ACL_IPE_SECURITY_PROFILE_HELPER="${CASE_DIR}/security-profile.sh" \
        bash "${LOADER}" 2>&1
}

assert_best_effort_skip() {
    local expected="$1"
    local output
    shift

    output="$(run_loader "$@")"
    grep -Fq "WARNING: ${expected}" <<< "${output}" ||
        { echo "missing best-effort warning: ${expected}" >&2; return 1; }
    grep -Fq 'continuing boot without activating IPE' <<< "${output}" ||
        { echo "loader did not report that boot would continue" >&2; return 1; }
}

# ---- Test: absent token → succeed as disabled ----
test_absent_token() {
    prepare_case absent-token
    printf 'root=/dev/sda1\n' > "${CASE_DIR}/cmdline"
    run_loader
}

# ---- Test: unreadable/missing cmdline → skip IPE and continue boot ----
test_missing_cmdline() {
    prepare_case missing-cmdline
    rm -f "${CASE_DIR}/cmdline"
    assert_best_effort_skip "could not read kernel command line"
}

# ---- Test: valid load + inactive (IMDS off) ----
test_valid_inactive_load() {
    run_inactive_case valid-inactive off
}

# ---- Test: 'disabled' is accepted as an alias for 'off' ----
test_valid_disabled_alias_inactive() {
    run_inactive_case valid-disabled-alias disabled
}

run_inactive_case() {
    local name="$1" imds_mode="$2"
    prepare_case "${name}"
    make_credential "${CASE_DIR}/credential.p7b.cred"
    local h
    h="$(sha256sum "${CASE_DIR}/credential.p7b.cred" | cut -d' ' -f1)"
    printf 'flatcar.oem.id=azure acl.ipe.policy_sha256=%s\n' "${h}" > "${CASE_DIR}/cmdline"

    # Override IMDS to return the requested inactive-style mode
    cat > "${CASE_DIR}/security-profile.sh" <<EOF
acl_security_profile() { printf '%s\n' 'ipe=${imds_mode}'; }
acl_security_profile_value() { printf '%s\n' '${imds_mode}'; }
EOF

    # The policy is loaded into new_policy but not activated
    run_loader "${CASE_DIR}/credential.p7b.cred"
    # Verify policy was loaded
    [[ -s "${IPE_DIR}/new_policy" ]]
    # enforce should remain unchanged (not set to 0)
    [[ "$(<"${IPE_DIR}/enforce")" == "9" ]]
}

# ---- Test: valid permissive activation ----
# In a real kernel, loading a policy into new_policy creates policies/<name>/.
# We simulate this by using a named pipe so the policies directory appears
# only after the loader writes to new_policy (passing the preexisting check).
test_valid_permissive() {
    run_active_case valid-permissive permissive
}

# ---- Test: 'audit' is accepted as an alias for 'permissive' ----
test_valid_audit_alias_active() {
    run_active_case valid-audit-alias audit
}

run_active_case() {
    local name="$1" imds_mode="$2"
    prepare_case "${name}"
    make_credential "${CASE_DIR}/credential.p7b.cred"
    # Keep the writer blocked while the simulated kernel creates the policy
    # directory after accepting the first byte.
    dd if=/dev/zero bs=65536 count=64 >> "${CASE_DIR}/credential.p7b.cred" 2>/dev/null
    local h
    h="$(sha256sum "${CASE_DIR}/credential.p7b.cred" | cut -d' ' -f1)"
    printf 'flatcar.oem.id=azure acl.ipe.policy_sha256=%s\n' "${h}" > "${CASE_DIR}/cmdline"

    cat > "${CASE_DIR}/security-profile.sh" <<EOF
acl_security_profile() { printf '%s\n' 'ipe=${imds_mode}'; }
acl_security_profile_value() { printf '%s\n' '${imds_mode}'; }
EOF

    # Replace new_policy with a named pipe; a background reader simulates the
    # kernel creating the policy directory after the write.
    rm -f "${IPE_DIR}/new_policy"
    mkfifo "${IPE_DIR}/new_policy" 2>/dev/null || {
        # mkfifo unavailable (e.g. Windows) — skip this test
        echo "skipping run_active_case (mkfifo not available)"
        return 0
    }
    (
        exec 3< "${IPE_DIR}/new_policy"
        IFS= read -r -n 1 <&3 || true
        mkdir -p "${IPE_DIR}/policies/acl_ipe_boot_policy"
        printf '0\n' > "${IPE_DIR}/policies/acl_ipe_boot_policy/active"
        cat <&3 > /dev/null
        exec 3<&-
    ) &

    local output
    output="$(run_loader "${CASE_DIR}/credential.p7b.cred")"
    wait
    grep -Fq "Using IPE mode '${imds_mode}'." <<< "${output}" ||
        { echo "loader did not report requested mode '${imds_mode}'" >&2; return 1; }
    [[ "$(<"${IPE_DIR}/enforce")" == "0" ]]
    [[ "$(<"${IPE_DIR}/policies/acl_ipe_boot_policy/active")" == "1" ]]
}

# ---- Test: 'enforcing' is reserved; loader logs an explicit unsupported
# diagnostic and falls back safely to inactive without failing boot ----
test_enforcing_mode_safe_fallback() {
    prepare_case enforcing-fallback
    make_credential "${CASE_DIR}/credential.p7b.cred"
    local h
    h="$(sha256sum "${CASE_DIR}/credential.p7b.cred" | cut -d' ' -f1)"
    printf 'flatcar.oem.id=azure acl.ipe.policy_sha256=%s\n' "${h}" > "${CASE_DIR}/cmdline"

    cat > "${CASE_DIR}/security-profile.sh" <<'EOF'
acl_security_profile() { printf '%s\n' 'ipe=enforcing'; }
acl_security_profile_value() { printf '%s\n' 'enforcing'; }
EOF

    local output
    output="$(run_loader "${CASE_DIR}/credential.p7b.cred")"
    grep -Fq "IPE mode 'enforcing' is not supported at runtime; leaving IPE inactive." <<< "${output}" ||
        { echo "missing explicit unsupported-mode diagnostic" >&2; return 1; }
    grep -Fq "Using IPE mode 'off'." <<< "${output}" ||
        { echo "loader did not fall back to inactive mode" >&2; return 1; }
    # Verify policy was loaded but not activated, and boot was not blocked.
    [[ -s "${IPE_DIR}/new_policy" ]]
    [[ "$(<"${IPE_DIR}/enforce")" == "9" ]]
}


# ---- Test: duplicate token → skip IPE and continue boot ----
test_duplicate_token() {
    prepare_case dup-token
    local h="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    printf 'acl.ipe.policy_sha256=%s acl.ipe.policy_sha256=%s\n' "${h}" "${h}" > "${CASE_DIR}/cmdline"
    assert_best_effort_skip "duplicate acl.ipe.policy_sha256 tokens"
}

# ---- Test: malformed hash → skip IPE and continue boot ----
test_malformed_hash() {
    prepare_case malformed
    printf 'acl.ipe.policy_sha256=GHIJ0123\n' > "${CASE_DIR}/cmdline"
    assert_best_effort_skip "malformed acl.ipe.policy_sha256 value"
}

# ---- Test: zero hash → skip IPE and continue boot ----
test_zero_hash() {
    prepare_case zero-hash
    printf 'acl.ipe.policy_sha256=%s\n' "${ZERO_HASH}" > "${CASE_DIR}/cmdline"
    assert_best_effort_skip "acl.ipe.policy_sha256 is all zeros"
}

# ---- Test: missing credential → skip IPE and continue boot ----
test_missing_credential() {
    prepare_case missing-cred
    printf 'acl.ipe.policy_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "${CASE_DIR}/cmdline"
    assert_best_effort_skip "policy credential missing" "${CASE_DIR}/nonexistent.cred"
}

# ---- Test: symlink credential → skip IPE and continue boot ----
test_symlink_credential() {
    prepare_case symlink-cred
    make_credential "${CASE_DIR}/real.cred"
    ln -sf "${CASE_DIR}/real.cred" "${CASE_DIR}/credential.p7b.cred"
    # Verify the symlink was created (some platforms, e.g. Windows, may copy instead)
    if [[ ! -L "${CASE_DIR}/credential.p7b.cred" ]]; then
        echo "skipping test_symlink_credential (symlinks not supported)"
        return 0
    fi
    local h
    h="$(sha256sum "${CASE_DIR}/real.cred" | cut -d' ' -f1)"
    printf 'acl.ipe.policy_sha256=%s\n' "${h}" > "${CASE_DIR}/cmdline"
    assert_best_effort_skip "credential must not be a symlink" \
        "${CASE_DIR}/credential.p7b.cred"
}

# ---- Test: mismatched credential → skip IPE and continue boot ----
test_mismatched_credential() {
    prepare_case mismatch-cred
    make_credential "${CASE_DIR}/credential.p7b.cred"
    # Use a hash that won't match
    printf 'acl.ipe.policy_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "${CASE_DIR}/cmdline"
    assert_best_effort_skip "credential SHA-256 mismatch" \
        "${CASE_DIR}/credential.p7b.cred"
}

# ---- Test: missing IPE interface → skip IPE and continue boot ----
test_missing_ipe_interface() {
    prepare_case no-ipe
    make_credential "${CASE_DIR}/credential.p7b.cred"
    local h
    h="$(sha256sum "${CASE_DIR}/credential.p7b.cred" | cut -d' ' -f1)"
    printf 'acl.ipe.policy_sha256=%s\n' "${h}" > "${CASE_DIR}/cmdline"
    # Remove the IPE directory to simulate missing kernel support
    rm -rf "${IPE_DIR}"
    mkdir "${IPE_DIR}"
    assert_best_effort_skip "IPE securityfs interface missing" \
        "${CASE_DIR}/credential.p7b.cred"
}

# ---- Test: rejected kernel write → skip IPE and continue boot ----
test_rejected_write() {
    prepare_case rejected-write
    make_credential "${CASE_DIR}/credential.p7b.cred"
    local h
    h="$(sha256sum "${CASE_DIR}/credential.p7b.cred" | cut -d' ' -f1)"
    printf 'acl.ipe.policy_sha256=%s\n' "${h}" > "${CASE_DIR}/cmdline"
    # Make new_policy a directory to simulate write rejection
    rm "${IPE_DIR}/new_policy"
    mkdir "${IPE_DIR}/new_policy"
    assert_best_effort_skip "kernel rejected policy load" \
        "${CASE_DIR}/credential.p7b.cred"
}

# ---- Test: preexisting policy → skip IPE and continue boot ----
test_preexisting_ambiguity() {
    prepare_case preexisting
    make_credential "${CASE_DIR}/credential.p7b.cred"
    local h
    h="$(sha256sum "${CASE_DIR}/credential.p7b.cred" | cut -d' ' -f1)"
    printf 'acl.ipe.policy_sha256=%s\n' "${h}" > "${CASE_DIR}/cmdline"
    mkdir -p "${IPE_DIR}/policies/acl_ipe_boot_policy"
    assert_best_effort_skip "IPE already has a loaded policy" \
        "${CASE_DIR}/credential.p7b.cred"
}

# ---- Test: any differently named preexisting policy is also skipped ----
test_other_preexisting_ambiguity() {
    prepare_case other-preexisting
    make_credential "${CASE_DIR}/credential.p7b.cred"
    local h
    h="$(sha256sum "${CASE_DIR}/credential.p7b.cred" | cut -d' ' -f1)"
    printf 'acl.ipe.policy_sha256=%s\n' "${h}" > "${CASE_DIR}/cmdline"
    mkdir -p "${IPE_DIR}/policies/another_policy"
    assert_best_effort_skip "IPE already has a loaded policy" \
        "${CASE_DIR}/credential.p7b.cred"
}

# ---- Test: missing runtime mode helper → skip IPE and continue boot ----
test_missing_security_profile_helper() {
    prepare_case missing-profile-helper
    make_credential "${CASE_DIR}/credential.p7b.cred"
    local h
    h="$(sha256sum "${CASE_DIR}/credential.p7b.cred" | cut -d' ' -f1)"
    printf 'acl.ipe.policy_sha256=%s\n' "${h}" > "${CASE_DIR}/cmdline"
    rm "${CASE_DIR}/security-profile.sh"
    assert_best_effort_skip "security profile helper is missing or unreadable" \
        "${CASE_DIR}/credential.p7b.cred"
}

# ---- Test: incomplete runtime mode helper → skip IPE and continue boot ----
test_incomplete_security_profile_helper() {
    prepare_case incomplete-profile-helper
    make_credential "${CASE_DIR}/credential.p7b.cred"
    local h
    h="$(sha256sum "${CASE_DIR}/credential.p7b.cred" | cut -d' ' -f1)"
    printf 'acl.ipe.policy_sha256=%s\n' "${h}" > "${CASE_DIR}/cmdline"
    cat > "${CASE_DIR}/security-profile.sh" <<'EOF'
acl_security_profile() { printf '%s\n' 'ipe=off'; }
EOF
    assert_best_effort_skip "security profile helper is missing required functions" \
        "${CASE_DIR}/credential.p7b.cred"
}

# ---- Test: IMDS failure after validation ----
test_imds_failure_after_validation() {
    (
        source "${PROFILE_HELPER}"
        ACL_SECURITY_PROFILE_CACHE="${TMP_DIR}/node-security-profile"
        ACL_SECURITY_PROFILE_FAILURE_CACHE="${ACL_SECURITY_PROFILE_CACHE}.failed"
        attempts="${TMP_DIR}/imds-attempts"

        systemctl() { :; }
        sleep() { :; }
        acl_usrbin() {
            printf x >> "${attempts}"
            return 1
        }

        ! acl_security_profile >/dev/null 2>&1
        [[ "$(wc -c < "${attempts}")" -eq 30 ]]
        [[ -e "${ACL_SECURITY_PROFILE_FAILURE_CACHE}" ]]
        ! acl_security_profile >/dev/null 2>&1
        [[ "$(wc -c < "${attempts}")" -eq 30 ]]
    )
}

# ---- Static assertions: Azure-scoped, best-effort service wiring ----
test_best_effort_service_wiring() {
    local module_setup="${SCRIPT_DIR}/build_library/rpm/additional_files/dracut-acl-ipe-load/module-setup.sh"
    local service="${SCRIPT_DIR}/build_library/rpm/additional_files/dracut-acl-ipe-load/acl-ipe-load.service"

    ! grep -Fq 'initrd-switch-root.service' "${module_setup}" ||
        { echo "module-setup.sh installs a switch-root dependency" >&2; return 1; }
    # sha256sum must be installed in initramfs
    grep -Fq 'sha256sum' "${module_setup}" ||
        { echo "module-setup.sh missing sha256sum binary install" >&2; return 1; }

    grep -Fxq 'Before=initrd-parse-etc.service' "${service}" ||
        { echo "service has unexpected initrd ordering" >&2; return 1; }
    ! grep -Fq 'initrd-switch-root.service' "${service}" ||
        { echo "service gates initrd-switch-root.service" >&2; return 1; }
    grep -Fxq 'ConditionVirtualization=microsoft' "${service}" ||
        { echo "service missing Microsoft virtualization condition" >&2; return 1; }
    grep -Fxq 'ConditionKernelCommandLine=flatcar.oem.id=azure' "${service}" ||
        { echo "service missing Azure kernel command-line condition" >&2; return 1; }
    ! grep -Fq 'OnFailure=' "${service}" ||
        { echo "service has fail-closed OnFailure behavior" >&2; return 1; }
    # No RequiresMountsFor
    ! grep -Fq 'RequiresMountsFor' "${service}" ||
        { echo "service has RequiresMountsFor" >&2; return 1; }
    # StandardError for explicit console/journal failure output
    grep -Fq 'StandardError=journal+console' "${service}" ||
        { echo "service missing StandardError=journal+console" >&2; return 1; }
}

test_absent_token
test_missing_cmdline
test_valid_inactive_load
test_valid_disabled_alias_inactive
test_valid_permissive
test_valid_audit_alias_active
test_enforcing_mode_safe_fallback
test_duplicate_token
test_malformed_hash
test_zero_hash
test_missing_credential
test_symlink_credential
test_mismatched_credential
test_missing_ipe_interface
test_rejected_write
test_preexisting_ambiguity
test_other_preexisting_ambiguity
test_missing_security_profile_helper
test_incomplete_security_profile_helper
test_imds_failure_after_validation
test_best_effort_service_wiring

echo "IPE loader runtime mode tests passed"
