#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
    if [[ "${command}" == "exec" &&
        "${1:-}" == "-i" &&
        "${2:-}" == "reused-container" &&
        "${3:-}" == "sh" &&
        "${4:-}" == "-c" ]]; then
        cat > "${FAKE_DOCKER_POLICY_CAPTURE}"
    fi
}
EOF

printf 'policy-a\n' > "${TEST_DIR}/policy-a.p7b"
printf 'policy-b\n' > "${TEST_DIR}/policy-b.p7b"

assert_docker_call() {
    local log="$1" expected="$2" arg
    shift 2
    for arg in "$@"; do
        expected+=$'\t'"${arg}"
    done
    grep -Fqx "${expected}" "${log}"
}

run_container() {
    local mode="$1" policy="$2" log="$3" status="${4:-up}"
    (
        cd "${TEST_DIR}"
        ACL_IPE_POLICY_MODE="${mode}" \
        ACL_IPE_POLICY_PATH="${policy}" \
        FAKE_DOCKER_LOG="${log}" \
        FAKE_DOCKER_POLICY_CAPTURE="${log}.policy" \
        FAKE_DOCKER_STATUS="${status}" \
            ./run_sdk_container -C fake-sdk -n reused-container -- true
    )
}

test_external_policy_refresh() {
    local log="${TEST_DIR}/external.log" policy

    for policy in "${TEST_DIR}/policy-a.p7b" "${TEST_DIR}/policy-b.p7b"; do
        run_container external "${policy}" "${log}"
        cmp -s "${policy}" "${log}.policy"
    done
    [[ "$(grep -Fc $'exec\t-i\treused-container\tsh\t-c\tcat > "$1" && chmod 0644 "$1" && test -s "$1"\tsh\t/tmp/acl-ipe-policy.p7b' "${log}")" -eq 2 ]]
    ! grep -Fq $'cp\t' "${log}"
    ! grep -Fq $'create\t' "${log}"
}

test_external_policy_fresh_container() {
    local log="${TEST_DIR}/fresh.log"
    local create_line start_line stream_line

    run_container external "${TEST_DIR}/policy-a.p7b" "${log}" missing
    cmp -s "${TEST_DIR}/policy-a.p7b" "${log}.policy"

    create_line="$(grep -nF $'create\t' "${log}" | cut -d: -f1)"
    start_line="$(grep -nF $'start\treused-container' "${log}" | cut -d: -f1)"
    stream_line="$(grep -nF $'exec\t-i\treused-container\tsh\t-c\tcat > "$1" && chmod 0644 "$1" && test -s "$1"\tsh\t/tmp/acl-ipe-policy.p7b' "${log}" | cut -d: -f1)"
    [[ -n "${create_line}" && -n "${start_line}" && -n "${stream_line}" ]]
    [[ "${create_line}" -lt "${start_line}" ]]
    [[ "${start_line}" -lt "${stream_line}" ]]
}

test_ephemeral_mode_removes_stale_policy() {
    local log="${TEST_DIR}/ephemeral.log"
    run_container ephemeral "" "${log}"
    assert_docker_call "${log}" exec \
        reused-container rm -f /tmp/acl-ipe-policy.p7b
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

# Different inputs prove that a reused container receives the current policy.
test_external_policy_refresh
test_external_policy_fresh_container
test_ephemeral_mode_removes_stale_policy
test_untagged_checkout_version_fallback

echo "run_sdk_container IPE policy reuse tests passed"
