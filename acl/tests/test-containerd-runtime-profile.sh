#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="${REPO_ROOT}/build_library/rpm/additional_files/containerd2-erofs"
SELECTOR="${PROFILE_DIR}/containerd-acl-select-profile"
MANGLE="${REPO_ROOT}/build_library/rpm/sysext_mangle_containerd-flatcar.sh"
SYSEXT_YAML="${REPO_ROOT}/acl/sysexts.yaml"
SPEC="${REPO_ROOT}/acl/SPECS/containerd2/containerd2.spec"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

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
    local expected="$3"
    local case_root="${TEST_ROOT}/${name}"
    local active_file="${case_root}/ipe-active"
    local config_path="${case_root}/run/containerd/acl-config.toml"

    mkdir -p "${case_root}"
    if [[ -n "${active}" ]]; then
        printf '%s\n' "${active}" > "${active_file}"
    fi

    ACL_IPE_ACTIVE_FILE="${active_file}" \
        ACL_CONTAINERD_CONFIG_PATH="${config_path}" \
        "${SELECTOR}" >/dev/null

    [[ "$(readlink "${config_path}")" == "${expected}" ]]
}

profile_root="${TEST_ROOT}/profile-mangle"
prepare_mangle_root "${profile_root}"
"${MANGLE}" "${profile_root}" >/dev/null
assert_profile_installed "${profile_root}"

test_selector inactive 0 /usr/share/containerd2/acl-config.toml
test_selector active 1 /usr/share/containerd2/acl-erofs-config.toml
test_selector no-policy-file "" /usr/share/containerd2/acl-config.toml

grep -Fq -- '- erofs-utils' "${SYSEXT_YAML}"
if grep -Fq 'feature: erofs' "${SYSEXT_YAML}"; then
    exit 1
fi
if grep -Fq 'containerd2-erofs' "${SYSEXT_YAML}"; then
    exit 1
fi
grep -Fq 'Obsoletes: containerd2-erofs < %{version}-%{release}' "${SPEC}"
if grep -Eq '^%package[[:space:]]+erofs$' "${SPEC}"; then
    exit 1
fi
[[ "$(grep -Fc 'platform = "linux/amd64"' "${PROFILE_DIR}/containerd-acl-erofs.toml")" -eq 2 ]]
[[ "$(grep -Fc 'platform = "linux/arm64"' "${PROFILE_DIR}/containerd-acl-erofs.toml")" -eq 2 ]]

echo "containerd runtime profile tests passed"
