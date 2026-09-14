#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="${REPO_ROOT}/build_library/rpm/additional_files/containerd2-erofs"
SELECTOR="${PROFILE_DIR}/containerd-acl-select-profile"
MANGLE="${REPO_ROOT}/build_library/rpm/sysext_mangle_containerd-flatcar.sh"
BUILD_SCRIPT="${REPO_ROOT}/acl/build_rpm_image.sh"
SYSEXT_YAML="${REPO_ROOT}/acl/sysexts.yaml"
SPEC="${REPO_ROOT}/acl/SPECS/containerd2/containerd2.spec"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

MOCK_RPM="${TEST_ROOT}/rpm"
cat > "${MOCK_RPM}" <<'EOF'
#!/bin/bash
if [[ "${MOCK_RPM_HAS_CAPABILITY:-1}" == "1" ]]; then
    printf '%s\n' 'containerd2-dmverity-referrers-api 1'
    exit 0
fi
exit 1
EOF
chmod 0755 "${MOCK_RPM}"

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

assert_profile_absent() {
    local root="$1"
    [[ ! -e "${root}/usr/share/containerd2/acl-erofs.toml" ]]
    [[ ! -e "${root}/usr/share/containerd2/acl-config.toml" ]]
    [[ ! -e "${root}/usr/share/containerd2/acl-erofs-config.toml" ]]
    [[ ! -e "${root}/usr/share/containerd2/acl-erofs-runtime.toml" ]]
    [[ ! -e "${root}/usr/libexec/containerd2/acl-select-profile" ]]
    [[ ! -e "${root}/usr/lib/systemd/system/containerd.service.d/90-acl-profile.conf" ]]
    [[ ! -e "${root}/usr/lib/tmpfiles.d/10-containerd-acl.conf" ]]
}

assert_profile_installed() {
    local root="$1"
    cmp "${PROFILE_DIR}/containerd-acl-erofs.toml" \
        "${root}/usr/share/containerd2/acl-erofs.toml"
    cmp "${PROFILE_DIR}/containerd-acl-config.toml" \
        "${root}/usr/share/containerd2/acl-config.toml"
    cmp "${PROFILE_DIR}/containerd-acl-erofs-config.toml" \
        "${root}/usr/share/containerd2/acl-erofs-config.toml"
    cmp "${PROFILE_DIR}/containerd-acl-erofs-runtime.toml" \
        "${root}/usr/share/containerd2/acl-erofs-runtime.toml"
    cmp "${PROFILE_DIR}/containerd-acl-select-profile" \
        "${root}/usr/libexec/containerd2/acl-select-profile"
    cmp "${PROFILE_DIR}/containerd-acl-profile.conf" \
        "${root}/usr/lib/systemd/system/containerd.service.d/90-acl-profile.conf"
    cmp "${PROFILE_DIR}/containerd-acl-tmpfiles.conf" \
        "${root}/usr/lib/tmpfiles.d/10-containerd-acl.conf"
    [[ "$(stat -c '%a' "${root}/usr/libexec/containerd2/acl-select-profile")" == "755" ]]
}

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

feature_functions="${TEST_ROOT}/feature-functions.sh"
sed -n \
    -e '/^append_acl_feature() {/,/^}/p' \
    -e '/^configure_acl_features() {/,/^}/p' \
    "${BUILD_SCRIPT}" > "${feature_functions}"
# shellcheck source=/dev/null
source "${feature_functions}"

export ACL_EROFS_ENABLE=0
export ACL_IPE_ASSET_MODE=disabled
export ACL_FEATURES=""
configure_acl_features
[[ -z "${ACL_FEATURES}" ]]

export ACL_EROFS_ENABLE=0
export ACL_IPE_ASSET_MODE=ephemeral
export ACL_FEATURES=""
configure_acl_features
[[ "${ACL_FEATURES}" == "erofs" ]]

export ACL_EROFS_ENABLE=1
export ACL_IPE_ASSET_MODE=disabled
export ACL_FEATURES=""
configure_acl_features
[[ "${ACL_FEATURES}" == "erofs,erofs-static" ]]

plain_root="${TEST_ROOT}/plain-mangle"
prepare_mangle_root "${plain_root}"
ACL_RPM_QUERY="${MOCK_RPM}" MOCK_RPM_HAS_CAPABILITY=0 \
    ACL_FEATURES="" "${MANGLE}" "${plain_root}" >/dev/null
assert_profile_absent "${plain_root}"

dynamic_root="${TEST_ROOT}/dynamic-mangle"
prepare_mangle_root "${dynamic_root}"
ACL_RPM_QUERY="${MOCK_RPM}" ACL_FEATURES="erofs" "${MANGLE}" "${dynamic_root}" >/dev/null
assert_profile_installed "${dynamic_root}"
[[ ! -e "${dynamic_root}/usr/share/containerd2/force-erofs" ]]

static_root="${TEST_ROOT}/static-mangle"
prepare_mangle_root "${static_root}"
ACL_RPM_QUERY="${MOCK_RPM}" ACL_FEATURES="erofs,erofs-static" \
    "${MANGLE}" "${static_root}" >/dev/null
assert_profile_installed "${static_root}"
[[ -f "${static_root}/usr/share/containerd2/force-erofs" ]]

unsupported_root="${TEST_ROOT}/unsupported-mangle"
prepare_mangle_root "${unsupported_root}"
if ACL_RPM_QUERY="${MOCK_RPM}" MOCK_RPM_HAS_CAPABILITY=0 \
    ACL_FEATURES="erofs" "${MANGLE}" "${unsupported_root}" >/dev/null 2>&1; then
    exit 1
fi
assert_profile_absent "${unsupported_root}"

test_selector inactive 0 false /usr/share/containerd2/acl-config.toml
test_selector active 1 false /usr/share/containerd2/acl-erofs-config.toml
test_selector forced 0 true /usr/share/containerd2/acl-erofs-config.toml
test_selector no-ipe-file "" false /usr/share/containerd2/acl-config.toml

grep -Fq 'name: erofs-utils' "${SYSEXT_YAML}"
if grep -Fq 'containerd2-erofs' "${SYSEXT_YAML}"; then
    exit 1
fi
grep -Fq 'Provides: containerd2-dmverity-referrers-api = 1' "${SPEC}"
grep -Fq 'Obsoletes: containerd2-erofs < %{version}-%{release}' "${SPEC}"
if grep -Eq '^%package[[:space:]]+erofs$' "${SPEC}"; then
    exit 1
fi
[[ "$(grep -Fc 'platform = "linux/amd64"' "${PROFILE_DIR}/containerd-acl-erofs.toml")" -eq 2 ]]
[[ "$(grep -Fc 'platform = "linux/arm64"' "${PROFILE_DIR}/containerd-acl-erofs.toml")" -eq 2 ]]

echo "containerd runtime profile tests passed"
