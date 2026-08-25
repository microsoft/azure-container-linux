#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELECTOR="${REPO_ROOT}/acl/SPECS/containerd2/containerd-acl-select-profile"
MANGLE="${REPO_ROOT}/build_library/rpm/sysext_mangle_containerd-flatcar.sh"
BUILD_SCRIPT="${REPO_ROOT}/acl/build_rpm_image.sh"
SYSEXT_PROD_BUILDER="${REPO_ROOT}/build_library/sysext_prod_builder"
STANDALONE_SYSEXT_UTIL="${REPO_ROOT}/build_library/standalone_sysext_util.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

test_selector() {
    local name="$1"
    local active="$2"
    local force="$3"
    local expected="$4"
    local case_root="${TEST_ROOT}/${name}"
    local active_file="${case_root}/ipe-active"
    local force_file="${case_root}/force-erofs"
    local config_path="${case_root}/run/containerd/acl-config.toml"

    mkdir -p "${case_root}"
    if [[ -n "${active}" ]]; then
        printf '%s\n' "${active}" > "${active_file}"
    fi
    if [[ "${force}" == "true" ]]; then
        touch "${force_file}"
    fi

    ACL_IPE_ACTIVE_FILE="${active_file}" \
        ACL_FORCE_EROFS_FILE="${force_file}" \
        ACL_CONTAINERD_CONFIG_PATH="${config_path}" \
        "${SELECTOR}" >/dev/null

    [[ "$(readlink "${config_path}")" == "${expected}" ]]
}

prepare_mangle_root() {
    local root="$1"
    mkdir -p "${root}/etc/containerd" "${root}/usr/lib/systemd/system"
    cat > "${root}/etc/containerd/config.toml" <<'EOF'
version = 2
[plugins."io.containerd.grpc.v1.cri"]
  enable_selinux = false
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true
EOF
    printf '%s\n' '[Unit]' > "${root}/usr/lib/systemd/system/containerd.service"
}

feature_functions="${TEST_ROOT}/feature-functions.sh"
sed -n \
    -e '/^append_acl_feature() {/,/^}/p' \
    -e '/^configure_acl_features() {/,/^}/p' \
    "${BUILD_SCRIPT}" > "${feature_functions}"
# shellcheck source=/dev/null
source "${feature_functions}"

test_features() {
    local erofs_override="$1"
    local ipe_mode="$2"
    local initial="$3"
    local expected="$4"

    ACL_EROFS_ENABLE="${erofs_override}"
    ACL_IPE_ASSET_MODE="${ipe_mode}"
    ACL_FEATURES="${initial}"
    configure_acl_features
    [[ "${ACL_FEATURES}" == "${expected}" ]]
}

grep -Fq 'ACL_EROFS_ENABLE="${ACL_EROFS_ENABLE:-0}"' "${BUILD_SCRIPT}"
grep -Fq '"ACL_FEATURES=${ACL_FEATURES:-}"' "${SYSEXT_PROD_BUILDER}"
grep -Fq '"ACL_FEATURES=${ACL_FEATURES:-}"' "${STANDALONE_SYSEXT_UTIL}"
test_features 0 disabled "" ""
test_features 0 ephemeral "" erofs
test_features 0 external base "base,erofs"
test_features 1 disabled "" "erofs,erofs-static"
test_features 1 ephemeral erofs "erofs,erofs-static"

test_selector inactive 0 false /usr/share/containerd2/acl-config.toml
test_selector active 1 false /usr/share/containerd2/acl-erofs-config.toml
test_selector forced 0 true /usr/share/containerd2/acl-erofs-config.toml
test_selector no-ipe-file "" false /usr/share/containerd2/acl-config.toml

static_root="${TEST_ROOT}/static-mangle"
prepare_mangle_root "${static_root}"
ACL_FEATURES="erofs,erofs-static" "${MANGLE}" "${static_root}" >/dev/null
[[ -f "${static_root}/usr/share/containerd2/force-erofs" ]]

dynamic_root="${TEST_ROOT}/dynamic-mangle"
prepare_mangle_root "${dynamic_root}"
ACL_FEATURES="erofs" "${MANGLE}" "${dynamic_root}" >/dev/null
[[ ! -e "${dynamic_root}/usr/share/containerd2/force-erofs" ]]

echo "containerd runtime profile tests passed"
