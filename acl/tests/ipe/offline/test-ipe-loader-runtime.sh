#!/bin/bash
# Verify best-effort initramfs IPE policy loading and validation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LOADER="${SCRIPT_DIR}/build_library/rpm/additional_files/dracut-acl-ipe-load/acl-ipe-load.sh"
PROFILE_HELPER="${SCRIPT_DIR}/build_library/rpm/additional_files/acl-node-security-profile.sh"
CONTAINERD_EROFS_PROFILE="${SCRIPT_DIR}/build_library/rpm/additional_files/containerd2/containerd-acl-erofs-profile.conf"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ZERO_HASH="0000000000000000000000000000000000000000000000000000000000000000"

make_credential() {
    local path="$1"
    printf 'test-credential-content\n' > "${path}"
}

write_hashed_cmdline() {
    local credential="$1" prefix="${2:-}" hash
    hash="$(sha256sum "${credential}" | cut -d' ' -f1)" || return 1
    printf '%sacl.ipe.policy_sha256=%s\n' \
        "${prefix:+${prefix} }" "${hash}" > "${CASE_DIR}/cmdline"
}

prepare_case() {
    local name="$1"
    CASE_DIR="${TMP_DIR}/${name}"
    IPE_DIR="${CASE_DIR}/ipe"

    mkdir -p "${IPE_DIR}"
    : > "${IPE_DIR}/new_policy"
    printf '9\n' > "${IPE_DIR}/enforce"
    cp "${CONTAINERD_EROFS_PROFILE}" "${CASE_DIR}/containerd-acl-erofs-profile.conf"

    command cat > "${CASE_DIR}/security-profile.sh" <<EOF
source "${PROFILE_HELPER}"
acl_security_profile() {
    printf '%s\n' 'ipe=audit'
}
EOF
}

run_loader() {
    local credential="${1:-${CASE_DIR}/credential.p7b.cred}"
    ACL_IPE_DIR="${IPE_DIR}" \
    ACL_IPE_CMDLINE_FILE="${CASE_DIR}/cmdline" \
    ACL_IPE_CREDENTIAL_PATH="${credential}" \
    ACL_IPE_SECURITY_PROFILE_HELPER="${CASE_DIR}/security-profile.sh" \
    ACL_IPE_CONTAINERD_PROFILE="${CASE_DIR}/containerd-acl-erofs-profile.conf" \
    ACL_IPE_CONTAINERD_DROPIN="${CASE_DIR}/dropins/90-acl-profile.conf" \
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
    write_hashed_cmdline "${CASE_DIR}/credential.p7b.cred" "flatcar.oem.id=azure"

    # Override IMDS to return the requested inactive-style mode
    command cat > "${CASE_DIR}/security-profile.sh" <<EOF
source "${PROFILE_HELPER}"
acl_security_profile() { printf '%s\n' 'ipe=${imds_mode}'; }
EOF

    # The policy is loaded into new_policy but not activated
    run_loader "${CASE_DIR}/credential.p7b.cred"
    # Verify policy was loaded
    [[ -s "${IPE_DIR}/new_policy" ]]
    # enforce should remain unchanged (not set to 0)
    [[ "$(<"${IPE_DIR}/enforce")" == "9" ]]
    [[ ! -e "${CASE_DIR}/dropins/90-acl-profile.conf" ]]
}

# ---- Test: the removed runtime alias must not activate IPE ----
test_removed_alias_inactive() {
    local output
    output="$(run_inactive_case removed-alias permissive)"
    grep -Fq "Ignoring unrecognized IPE mode 'permissive' from IMDS." <<< "${output}"
    grep -Fq "Using IPE mode 'off'." <<< "${output}"
}

# ---- Test: audit activates the policy without enforcement ----
test_valid_audit_active() {
    run_active_case valid-audit audit
}

run_active_case() (
    local name="$1" imds_mode="$2"
    prepare_case "${name}"
    make_credential "${CASE_DIR}/credential.p7b.cred"
    write_hashed_cmdline "${CASE_DIR}/credential.p7b.cred" "flatcar.oem.id=azure"

    command cat > "${CASE_DIR}/security-profile.sh" <<EOF
source "${PROFILE_HELPER}"
acl_security_profile() { printf '%s\n' 'ipe=${imds_mode}'; }
EOF

    # Simulate the kernel creating the policy interface when the credential
    # is written, after the loader's preexisting-policy check.
    # shellcheck disable=SC2329 # Exported to the loader subprocess.
    cat() {
        command cat "$@" || return 1
        if [[ "$#" -eq 1 && "$1" == "${ACL_IPE_CREDENTIAL_PATH:-}" ]]; then
            mkdir -p "${ACL_IPE_DIR}/policies/acl_ipe_boot_policy"
            printf '0\n' > "${ACL_IPE_DIR}/policies/acl_ipe_boot_policy/active"
        fi
    }
    export -f cat

    local output
    output="$(run_loader "${CASE_DIR}/credential.p7b.cred")"
    grep -Fq "Using IPE mode '${imds_mode}'." <<< "${output}" ||
        { echo "loader did not report requested mode '${imds_mode}'" >&2; return 1; }
    [[ "$(<"${IPE_DIR}/enforce")" == "0" ]]
    [[ "$(<"${IPE_DIR}/policies/acl_ipe_boot_policy/active")" == "1" ]]
    cmp "${CASE_DIR}/containerd-acl-erofs-profile.conf" "${CASE_DIR}/dropins/90-acl-profile.conf"
)

# ---- Test: 'enforcing' is reserved; loader logs an explicit unsupported
# diagnostic and falls back safely to inactive without failing boot ----
test_enforcing_mode_safe_fallback() {
    prepare_case enforcing-fallback
    make_credential "${CASE_DIR}/credential.p7b.cred"
    write_hashed_cmdline "${CASE_DIR}/credential.p7b.cred" "flatcar.oem.id=azure"

    command cat > "${CASE_DIR}/security-profile.sh" <<EOF
source "${PROFILE_HELPER}"
acl_security_profile() { printf '%s\n' 'ipe=enforcing'; }
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
    [[ ! -e "${CASE_DIR}/dropins/90-acl-profile.conf" ]]
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
    make_credential "${CASE_DIR}/credential.p7b.cred"
    printf 'acl.ipe.policy_sha256=%s\n' "${ZERO_HASH}" > "${CASE_DIR}/cmdline"
    assert_best_effort_skip "credential SHA-256 mismatch: expected=${ZERO_HASH}"
    [[ ! -s "${IPE_DIR}/new_policy" ]]
    [[ "$(<"${IPE_DIR}/enforce")" == "9" ]]
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
    write_hashed_cmdline "${CASE_DIR}/real.cred"
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
    write_hashed_cmdline "${CASE_DIR}/credential.p7b.cred"
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
    write_hashed_cmdline "${CASE_DIR}/credential.p7b.cred"
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
    write_hashed_cmdline "${CASE_DIR}/credential.p7b.cred"
    mkdir -p "${IPE_DIR}/policies/acl_ipe_boot_policy"
    assert_best_effort_skip "IPE already has a loaded policy" \
        "${CASE_DIR}/credential.p7b.cred"
}

# ---- Test: any differently named preexisting policy is also skipped ----
test_other_preexisting_ambiguity() {
    prepare_case other-preexisting
    make_credential "${CASE_DIR}/credential.p7b.cred"
    write_hashed_cmdline "${CASE_DIR}/credential.p7b.cred"
    mkdir -p "${IPE_DIR}/policies/another_policy"
    assert_best_effort_skip "IPE already has a loaded policy" \
        "${CASE_DIR}/credential.p7b.cred"
}

# ---- Test: missing runtime mode helper → skip IPE and continue boot ----
test_missing_security_profile_helper() {
    prepare_case missing-profile-helper
    make_credential "${CASE_DIR}/credential.p7b.cred"
    write_hashed_cmdline "${CASE_DIR}/credential.p7b.cred"
    rm "${CASE_DIR}/security-profile.sh"
    assert_best_effort_skip "security profile helper is missing or unreadable" \
        "${CASE_DIR}/credential.p7b.cred"
}

# ---- Test: incomplete runtime mode helper → skip IPE and continue boot ----
test_incomplete_security_profile_helper() {
    prepare_case incomplete-profile-helper
    make_credential "${CASE_DIR}/credential.p7b.cred"
    write_hashed_cmdline "${CASE_DIR}/credential.p7b.cred"
    command cat > "${CASE_DIR}/security-profile.sh" <<'EOF'
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

test_early_failure_keeps_loader_inactive() {
    prepare_case early-profile-failure
    make_credential "${CASE_DIR}/credential.p7b.cred"
    write_hashed_cmdline "${CASE_DIR}/credential.p7b.cred" "flatcar.oem.id=azure"
    : > "${CASE_DIR}/profile.failed"
    command cat > "${CASE_DIR}/security-profile.sh" <<EOF
source "${PROFILE_HELPER}"
acl_usrbin() { echo unexpected-network-call >> "${CASE_DIR}/calls"; return 99; }
EOF
    local output
    output="$(ACL_SECURITY_PROFILE_CACHE="${CASE_DIR}/profile" run_loader)"
    grep -Fq "IMDS unavailable; leaving IPE inactive" <<< "${output}"
    [[ "$(<"${IPE_DIR}/enforce")" == 9 ]]
    [[ ! -e "${CASE_DIR}/dropins/90-acl-profile.conf" ]]
    [[ ! -e "${CASE_DIR}/calls" ]]
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

test_hashed_cmdline_helper() {
    prepare_case hashed-cmdline
    make_credential "${CASE_DIR}/credential.p7b.cred"
    local expected_hash
    expected_hash="$(sha256sum "${CASE_DIR}/credential.p7b.cred" | cut -d' ' -f1)"

    write_hashed_cmdline "${CASE_DIR}/credential.p7b.cred" "flatcar.oem.id=azure"
    [[ "$(<"${CASE_DIR}/cmdline")" == "flatcar.oem.id=azure acl.ipe.policy_sha256=${expected_hash}" ]]

    write_hashed_cmdline "${CASE_DIR}/credential.p7b.cred"
    [[ "$(<"${CASE_DIR}/cmdline")" == "acl.ipe.policy_sha256=${expected_hash}" ]]
}

test_containerd_profile_selection() (
    prepare_case containerd-profile

    local selector="${SCRIPT_DIR}/build_library/rpm/additional_files/containerd2/containerd-acl-select-profile"
    local erofs="${SCRIPT_DIR}/build_library/rpm/additional_files/containerd2/containerd-acl-erofs.toml"
    local base="${CASE_DIR}/base \"quoted\" config.toml"
    local original="${CASE_DIR}/original.toml"
    local final="${CASE_DIR}/run/acl-config.toml"
    local scenario local_pull fallback extra unpack_differ overlay_differ
    local host_arch foreign_arch unpack_arch check_platform
    case "$(uname -m)" in
        x86_64) host_arch=amd64; foreign_arch=arm64 ;;
        aarch64) host_arch=arm64; foreign_arch=amd64 ;;
        *) echo "Unsupported test architecture" >&2; return 1 ;;
    esac

    mkdir -p "${CASE_DIR}/bin"
    printf '0\n' > "${IPE_DIR}/enforce"

    if [[ -n "${CONTAINERD_BIN:-}" ]]; then
        ln -s "$(command -v "${CONTAINERD_BIN}")" "${CASE_DIR}/bin/containerd"
    else
        command cat > "${CASE_DIR}/bin/containerd" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "$#" == 2 && "$1" == config && "$2" == default ]]; then
    printf '[plugins."io.containerd.snapshotter.v1.erofs"]\nenable_dmverity_referrers = false\n'
    printf '[plugins."io.containerd.cri.v1.images"]\nmax_concurrent_downloads = 7\n'
    exit 0
fi

[[ "$#" == 4 && "$1" == --config && "$3" == config && "$4" == dump ]]
grep -Fq "${ACL_CONTAINERD_EROFS_CONFIG}" "$2" || {
    echo "Unexpected base-only config dump" >&2
    exit 1
}

cat <<TOML
[plugins."io.containerd.snapshotter.v1.erofs"]
enable_dmverity_referrers = true
dmverity_mode = "${TEST_DMVERITY_MODE}"
[plugins."io.containerd.cri.v1.images"]
snapshotter = "erofs"
max_concurrent_downloads = ${TEST_CRI_DOWNLOADS}
use_local_image_pull = ${TEST_LOCAL_PULL}
[plugins."io.containerd.service.v1.diff-service"]
default = ["erofs", "walking"]
${TEST_UNPACK_CONFIG}
TOML
EOF
        chmod +x "${CASE_DIR}/bin/containerd"
    fi

    export PATH="${CASE_DIR}/bin:${PATH}"
    export ACL_IPE_DIR="${IPE_DIR}"
    export ACL_CONTAINERD_CONFIG_PATH="${final}"
    export ACL_CONTAINERD_EROFS_CONFIG="${erofs}"

    printf 'version = 2\nroot = "/var/lib/containerd-provider"\n' > "${CASE_DIR}/relative.toml"
    for scenario in compatible transfer-concurrency cri-concurrency local-pull dmverity-off \
        unpack-compatible unpack-overlayfs unpack-wrong-arch unpack-platform-unchecked \
        unpack-mixed-arch unpack-split-entries; do
        local_pull=false
        fallback=false
        extra=""
        export TEST_CRI_DOWNLOADS=7
        export TEST_DMVERITY_MODE=auto
        export TEST_UNPACK_CONFIG=""

        case "${scenario}" in
            transfer-concurrency)
                extra=$'[plugins."io.containerd.transfer.v1.local"]\nmax_concurrent_downloads = 4'
                ;;
            cri-concurrency)
                extra='max_concurrent_downloads = 4'
                TEST_CRI_DOWNLOADS=4
                fallback=true
                ;;
            local-pull)
                local_pull=true
                fallback=true
                ;;
            dmverity-off)
                TEST_DMVERITY_MODE=off
                extra=$'[plugins."io.containerd.snapshotter.v1.erofs"]\ndmverity_mode = "off"'
                fallback=true
                ;;
            unpack-*)
                unpack_differ=erofs
                overlay_differ=walking
                unpack_arch="${host_arch}"
                check_platform=true
                case "${scenario}" in
                    unpack-wrong-arch|unpack-platform-unchecked|unpack-mixed-arch)
                        unpack_arch="${foreign_arch}"
                        ;;
                esac
                [[ "${scenario}" != unpack-platform-unchecked ]] || check_platform=false
                extra="[plugins.\"io.containerd.transfer.v1.local\"]
check_platform_supported = ${check_platform}"
                if [[ "${scenario}" == unpack-split-entries ]]; then
                    unpack_differ=walking
                    overlay_differ=erofs
                fi
                if [[ "${scenario}" != unpack-overlayfs ]]; then
                    extra+="
[[plugins.\"io.containerd.transfer.v1.local\".unpack_config]]
platform = \"linux(+erofs)/${unpack_arch}\"
snapshotter = \"erofs\"
differ = \"${unpack_differ}\""
                fi
                if [[ "${scenario}" == unpack-mixed-arch ]]; then
                    extra+="
[[plugins.\"io.containerd.transfer.v1.local\".unpack_config]]
platform = \"linux/${host_arch}\"
snapshotter = \"erofs\"
differ = \"erofs\""
                fi
                extra+="
[[plugins.\"io.containerd.transfer.v1.local\".unpack_config]]
platform = \"linux/${host_arch}\"
snapshotter = \"overlayfs\"
differ = \"${overlay_differ}\""
                case "${scenario}" in
                    unpack-compatible|unpack-platform-unchecked|unpack-mixed-arch) ;;
                    *) fallback=true ;;
                esac
                TEST_UNPACK_CONFIG="${extra}"
                ;;
        esac

        export TEST_LOCAL_PULL="${local_pull}"
        command cat > "${base}" <<EOF
version = 2
imports = ["relative.toml"]
[plugins."io.containerd.cri.v1.images"]
use_local_image_pull = ${local_pull}
${extra}
EOF

        cp "${base}" "${original}"
        bash "${selector}" "${base}"

        python3 - "${final}" "${base}" "${erofs}" "${fallback}" <<'PY'
import sys, tomllib
path, base, erofs, fallback = sys.argv[1:]
with open(path, "rb") as config:
    wrapper = tomllib.load(config)
assert wrapper == {"version": 4, "imports": [base] if fallback == "true" else [base, erofs]}
PY

        cmp "${base}" "${original}"
        [[ ! -e "${CASE_DIR}/run/acl-config.env" ]]
        [[ -z "$(find "${CASE_DIR}/run" -name '*.tmp.*' -print)" ]]

        if [[ -n "${CONTAINERD_BIN:-}" ]]; then
            containerd --config "${final}" config dump |
                python3 -c 'import sys, tomllib; assert tomllib.loads(sys.stdin.read())["root"] == "/var/lib/containerd-provider"'
        fi
    done

    cp "${final}" "${CASE_DIR}/selected.toml"
    printf '1\n' > "${IPE_DIR}/enforce"
    if bash "${selector}" "${base}" > "${CASE_DIR}/failure.log" 2>&1; then
        echo "Selector allowed unsigned fallback with enforcement enabled" >&2
        return 1
    fi
    grep -Fq 'IPE enforcement is not in audit mode' "${CASE_DIR}/failure.log" ||
        { echo "missing IPE enforcement rejection diagnostic" >&2; return 1; }

    rm "${IPE_DIR}/enforce"
    if bash "${selector}" "${base}" > "${CASE_DIR}/failure.log" 2>&1; then
        echo "Selector allowed unsigned fallback without enforcement state" >&2
        return 1
    fi
    grep -Fq 'IPE enforcement is not in audit mode' "${CASE_DIR}/failure.log" ||
        { echo "missing IPE enforcement rejection diagnostic" >&2; return 1; }

    cmp "${final}" "${CASE_DIR}/selected.toml"
    [[ -z "$(find "${CASE_DIR}/run" -name '*.tmp.*' -print)" ]]
    cmp "${base}" "${original}"
    echo "containerd audit profile wrapper tests passed"
)

test_hashed_cmdline_helper
test_absent_token
test_missing_cmdline
test_valid_inactive_load
test_valid_disabled_alias_inactive
test_removed_alias_inactive
test_valid_audit_active
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
test_early_failure_keeps_loader_inactive
test_best_effort_service_wiring
test_containerd_profile_selection

echo "IPE loader runtime mode tests passed"
