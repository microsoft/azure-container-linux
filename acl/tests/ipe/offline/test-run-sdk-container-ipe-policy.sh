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

test_untagged_checkout_version_fallback() {
    local repo="${TEST_DIR}/untagged"
    mkdir -p "${repo}/sdk_container/.repo/manifests"
    printf 'FLATCAR_VERSION="9999.0.0"\n' \
        > "${repo}/sdk_container/.repo/manifests/version.txt"
    git -C "${repo}" init -q
    git -C "${repo}" -c user.name=test -c user.email=test@example.com \
        -c commit.gpgsign=false commit --allow-empty -qm initial

    (
        cd "${repo}"
        source "${SCRIPT_DIR}/sdk_lib/sdk_container_common.sh"
        [[ "$(get_git_version)" == "9999.0.0" ]]
    )
}

test_mode_forwarded
test_invalid_mode_rejected
test_invalid_signing_mode_rejected
test_enforcing_mode_rejected
test_untagged_checkout_version_fallback

echo "run_sdk_container IPE mode tests passed"
