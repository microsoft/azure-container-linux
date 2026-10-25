#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

mkdir -p "${TEST_DIR}/sdk_lib"
cp "${SCRIPT_DIR}/run_sdk_container" "${TEST_DIR}/run_sdk_container"

cat > "${TEST_DIR}/sdk_lib/sdk_container_common.sh" <<'EOF'
docker_a=(docker)
is_podman=false

get_git_version() { echo "1.0.0"; }
get_sdk_version_from_versionfile() { echo "1.0.0"; }
get_version_from_versionfile() { echo "1.0.0"; }
vernum_to_docker_image_version() { echo "$1"; }
create_versionfile() { :; }
setup_sdk_env() { :; }
setup_gsutil() { :; }
gnupg_ssh_gcloud_mount_opts() { :; }
yell() { :; }

call_docker() {
    local command="$1"

    printf '%s' "${command}" >> "${FAKE_DOCKER_LOG}"
    shift
    printf '\t%s' "$@" >> "${FAKE_DOCKER_LOG}"
    printf '\n' >> "${FAKE_DOCKER_LOG}"

    if [[ "${command}" == "ps" &&
        "${FAKE_DOCKER_STATUS:-up}" == "up" ]]; then
        printf 'Up 1 second\n'
    fi
}
EOF

assert_docker_call() {
    local log="$1" expected="$2" arg
    shift 2
    for arg in "$@"; do
        expected+=$'\t'"${arg}"
    done
    grep -Fqx "${expected}" "${log}"
}

run_container() {
    local mode="$1" signing_mode="$2" log="$3" status="${4:-up}"
    (
        cd "${TEST_DIR}"
        ACL_IPE_MODE="${mode}" \
        ACL_IPE_SIGNING_MODE="${signing_mode}" \
        FAKE_DOCKER_LOG="${log}" \
        FAKE_DOCKER_STATUS="${status}" \
            ./run_sdk_container -C fake-sdk -n reused-container -- true
    )
}

test_mode_forwarded() {
    local log="${TEST_DIR}/mode.log"
    local mode signing
    for mode in disabled audit; do
        for signing in ephemeral esrp; do
            : > "${log}"
            run_container "${mode}" "${signing}" "${log}"
            grep -Fq $'\t-e\tACL_IPE_MODE='"${mode}"$'\t' "${log}" ||
                { echo "IPE mode ${mode} was not forwarded" >&2; return 1; }
            grep -Fq $'\t-e\tACL_IPE_SIGNING_MODE='"${signing}"$'\t' "${log}" ||
                { echo "IPE signing mode ${signing} was not forwarded" >&2; return 1; }
        done
    done
    ACL_ROOT_HASH_SIGNING_ENABLED=true run_container audit ephemeral "${log}"
    grep -Fq $'\t-e\tACL_ROOT_HASH_SIGNING_ENABLED=true\t' "${log}" ||
        { echo "Root-hash signing setting was not forwarded" >&2; return 1; }
}

test_invalid_mode_rejected() {
    local log="${TEST_DIR}/invalid.log"
    if run_container "invalid" "ephemeral" "${log}" 2>/dev/null; then
        echo "invalid mode was accepted" >&2; return 1
    fi
}

test_invalid_signing_mode_rejected() {
    local log="${TEST_DIR}/invalid-signing.log"
    if run_container "audit" "invalid" "${log}" 2>/dev/null; then
        echo "invalid signing mode was accepted" >&2; return 1
    fi
}

test_enforcing_mode_rejected() {
    local log="${TEST_DIR}/enforcing.log"
    if run_container "enforcing" "ephemeral" "${log}" 2>/dev/null; then
        echo "reserved 'enforcing' mode was accepted" >&2; return 1
    fi
}

test_sdk_entry_root_signing_validation() (
    local entry value mode bootloader output
    export SDK_TEST_BASHRC="${TEST_DIR}/sdk.bashrc"
    # Exercise the entrypoint's validation and exports without SDK setup or su.
    entry="$(awk '
        /^ACL_IPE_MODE=/ { copying=1 }
        /^if \[ \$# -gt 0 \]/ { exit }
        copying { print }
    ' "${SCRIPT_DIR}/sdk_lib/sdk_entry.sh")"
    [[ "${entry}" == *'export ACL_ROOT_HASH_SIGNING_ENABLED='* ]]
    entry="${entry//\/home\/sdk\/.bashrc/\"\$SDK_TEST_BASHRC\"}"

    for value in false true; do
        for mode in disabled audit; do
            for bootloader in grub uki; do
                : > "${SDK_TEST_BASHRC}"
                if output="$(ACL_ROOT_HASH_SIGNING_ENABLED="${value}" ACL_IPE_MODE="${mode}" \
                    BOOTLOADER_MODE="${bootloader}" bash -c "${entry}" 2>&1)"; then
                    [[ "${value}" == false || ( "${mode}" == audit && "${bootloader}" == uki ) ]]
                    grep -Fxq "export ACL_ROOT_HASH_SIGNING_ENABLED='${value}'" "${SDK_TEST_BASHRC}"
                else
                    [[ "${value}" == true && ( "${mode}" != audit || "${bootloader}" != uki ) ]]
                    [[ "${output}" == *"true on an IPE-capable UKI build"* ]]
                    [[ ! -s "${SDK_TEST_BASHRC}" ]]
                fi
            done
        done
    done
    for value in false:garbage "false:'quoted'" garbage true:garbage; do
        printf 'unchanged\n' > "${SDK_TEST_BASHRC}"
        if output="$(ACL_ROOT_HASH_SIGNING_ENABLED="${value}" ACL_IPE_MODE=audit \
            BOOTLOADER_MODE=uki bash -c "${entry}" 2>&1)"; then
            echo "SDK entrypoint accepted invalid boolean: ${value}" >&2
            return 1
        fi
        [[ "${output}" == *"ACL_ROOT_HASH_SIGNING_ENABLED must be true or false"* ]]
        [[ "$(<"${SDK_TEST_BASHRC}")" == unchanged ]]
    done
)

test_mode_forwarded
test_invalid_mode_rejected
test_invalid_signing_mode_rejected
test_enforcing_mode_rejected
test_sdk_entry_root_signing_validation

echo "run_sdk_container IPE mode tests passed"
