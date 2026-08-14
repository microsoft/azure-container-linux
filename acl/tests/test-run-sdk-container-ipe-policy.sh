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
    printf '%s' "$1" >> "${FAKE_DOCKER_LOG}"
    shift
    printf '\t%s' "$@" >> "${FAKE_DOCKER_LOG}"
    printf '\n' >> "${FAKE_DOCKER_LOG}"

    if [[ "${1:-}" == "--all" ]]; then
        printf 'Up 1 second\n'
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
    local mode="$1" policy="$2" log="$3"
    (
        cd "${TEST_DIR}"
        ACL_IPE_POLICY_MODE="${mode}" \
        ACL_IPE_POLICY_PATH="${policy}" \
        FAKE_DOCKER_LOG="${log}" \
            ./run_sdk_container -C fake-sdk -n reused-container -- true
    )
}

test_external_policy_refresh() {
    local log="${TEST_DIR}/external.log" policy

    for policy in "${TEST_DIR}/policy-a.p7b" "${TEST_DIR}/policy-b.p7b"; do
        run_container external "${policy}" "${log}"
        assert_docker_call "${log}" cp \
            "${policy}" "reused-container:/tmp/acl-ipe-policy.p7b"
    done
    [[ "$(grep -Fc $'exec\treused-container\tsh\t-c\tchmod 0644 "$1" && test -s "$1"\tsh\t/tmp/acl-ipe-policy.p7b' "${log}")" -eq 2 ]]
    ! grep -Fq $'create\t' "${log}"
}

test_ephemeral_mode_removes_stale_policy() {
    local log="${TEST_DIR}/ephemeral.log"
    run_container ephemeral "" "${log}"
    assert_docker_call "${log}" exec \
        reused-container rm -f /tmp/acl-ipe-policy.p7b
}

# Different inputs prove that a reused container receives the current policy.
test_external_policy_refresh
test_ephemeral_mode_removes_stale_policy

echo "run_sdk_container IPE policy reuse tests passed"
