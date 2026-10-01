#!/bin/bash
# Verify that shipping the EROFS profile leaves the ordinary containerd unit intact.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MANGLE="${ROOT}/build_library/rpm/sysext_mangle_containerd-flatcar.sh"
PROFILE_DIR="${ROOT}/build_library/rpm/additional_files/containerd2"
SELECTOR="${PROFILE_DIR}/containerd-acl-select-profile"
PROFILE="${PROFILE_DIR}/containerd-acl-profile.conf"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

prepare_root() {
    local root="$1"
    mkdir -p "${root}/etc/containerd" "${root}/usr/lib/systemd/system" \
        "${root}/usr/share/containerd2"
    cat > "${root}/etc/containerd/config.toml" <<'EOF'
version = 2
[plugins."io.containerd.grpc.v1.cri"]
  enable_selinux = false
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true
EOF
    printf '[Unit]\n' > "${root}/usr/lib/systemd/system/containerd.service"
}

plain_root="${TEST_ROOT}/plain"
prepare_root "${plain_root}"
"${MANGLE}" "${plain_root}" >/dev/null
cmp "${PROFILE_DIR}/containerd-acl-erofs.toml" "${plain_root}/usr/share/containerd2/acl-erofs.toml"
cmp "${SELECTOR}" "${plain_root}/usr/libexec/containerd2/acl-select-profile"
[[ -x "${plain_root}/usr/libexec/containerd2/acl-select-profile" ]]
[[ ! -e "${plain_root}/usr/lib/systemd/system/containerd.service.d/90-acl-profile.conf" ]]
[[ ! -e "${plain_root}/usr/share/containerd2/force-erofs" ]]
grep -Fq 'ExecStart=/usr/bin/containerd --config ${CONTAINERD_CONFIG}' \
    "${plain_root}/usr/lib/systemd/system/containerd.service.d/10-acl.conf"
grep -Fq 'ExecStartPre=/usr/libexec/containerd2/acl-select-profile ${CONTAINERD_CONFIG}' \
    "${PROFILE}"
if grep -Fq 'Environment=CONTAINERD_CONFIG=' "${PROFILE}"; then
    echo "EROFS profile overrides the node's base containerd config" >&2
    exit 1
fi

base="${plain_root}/usr/share/containerd/config-cgroupfs.toml"
config_path="${TEST_ROOT}/run/containerd/acl-config.toml"
ACL_CONTAINERD_CONFIG_PATH="${config_path}" "${SELECTOR}" "${base}" >/dev/null

python3 - "${config_path}" "${base}" \
    "${PROFILE_DIR}/containerd-acl-erofs.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as config_file:
    config = tomllib.load(config_file)
assert config["version"] == 3
assert config["imports"] == [
    sys.argv[2],
    "/usr/share/containerd2/acl-erofs.toml",
]

with open(sys.argv[3], "rb") as profile_file:
    profile = tomllib.load(profile_file)
assert profile["version"] == 3
plugins = profile["plugins"]
assert set(plugins) == {
    "io.containerd.snapshotter.v1.erofs",
    "io.containerd.differ.v1.erofs",
    "io.containerd.cri.v1.images",
    "io.containerd.service.v1.diff-service",
}
snapshotter = plugins["io.containerd.snapshotter.v1.erofs"]
differ = plugins["io.containerd.differ.v1.erofs"]
assert snapshotter["enable_dmverity_referrers"] is True
assert snapshotter["dmverity_mode"] in ("auto", "on")
assert "enable_dmverity_referrers" not in differ
assert differ["enable_dmverity"] is True
assert differ["enable_tar_index"] is True
assert differ["mkfs_options"] == ["--sort=none", "-T", "0", "--mkfs-time"]
assert plugins["io.containerd.cri.v1.images"]["snapshotter"] == "erofs"
assert plugins["io.containerd.service.v1.diff-service"]["default"] == ["erofs", "walking"]
PY

version3_base="${TEST_ROOT}/version3.toml"
printf 'version = 3\n' > "${version3_base}"
ACL_CONTAINERD_CONFIG_PATH="${config_path}" "${SELECTOR}" "${version3_base}" >/dev/null
python3 - "${config_path}" "${version3_base}" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as stream:
    config = tomllib.load(stream)
with open(sys.argv[2], "rb") as stream:
    base = tomllib.load(stream)
assert config["version"] >= base["version"]
assert config["imports"][0] == sys.argv[2]
PY

if ACL_CONTAINERD_CONFIG_PATH="${config_path}" \
    "${SELECTOR}" "${TEST_ROOT}/missing.toml" >/dev/null 2>&1; then
    echo "Selector accepted an unreadable base config" >&2
    exit 1
fi

echo "containerd runtime profile tests passed"
