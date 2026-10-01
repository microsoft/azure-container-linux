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

containerd_bin="$(command -v "${CONTAINERD_BIN:-containerd}")"
mkdir "${TEST_ROOT}/bin"
ln -s "${containerd_bin}" "${TEST_ROOT}/bin/containerd"
export PATH="${TEST_ROOT}/bin:${PATH}"

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
    "${PROFILE_DIR}/containerd-acl-erofs.toml" "${SELECTOR}" "${TEST_ROOT}" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tomllib

config_path, base, profile_path, selector, test_root = map(Path, sys.argv[1:])
config = tomllib.loads(config_path.read_text())
assert config["version"] == 4, "Set CONTAINERD_BIN to the target containerd 2.3.4 binary"
assert config["imports"] == ["/usr/share/containerd2/acl-erofs.toml"]

with profile_path.open("rb") as profile_file:
    profile = tomllib.load(profile_file)
assert profile["version"] == 3
plugins = profile["plugins"]
assert set(plugins) == {
    "io.containerd.snapshotter.v1.erofs",
    "io.containerd.cri.v1.images",
    "io.containerd.service.v1.diff-service",
}
snapshotter = plugins["io.containerd.snapshotter.v1.erofs"]
assert snapshotter["enable_dmverity_referrers"] is True
assert set(snapshotter) == {"enable_dmverity_referrers"}
assert plugins["io.containerd.cri.v1.images"]["snapshotter"] == "erofs"
assert set(plugins["io.containerd.cri.v1.images"]) == {"snapshotter"}
assert plugins["io.containerd.service.v1.diff-service"]["default"] == ["erofs", "walking"]

def generate(base_path, *, cwd=None, success=True):
    result = subprocess.run(
        [str(selector), str(base_path)],
        env=dict(os.environ, ACL_CONTAINERD_CONFIG_PATH=str(config_path)),
        cwd=cwd, text=True, capture_output=True,
    )
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    assert not list(config_path.parent.glob(config_path.name + ".tmp.*"))
    return result

def effective():
    # Resolve the installed profile path to the checkout without modifying /usr.
    text = config_path.read_text()
    assert text.count('imports = ["/usr/share/containerd2/acl-erofs.toml"]') == 1
    probe = test_root / "effective.toml"
    probe.write_text(text.replace(
        'imports = ["/usr/share/containerd2/acl-erofs.toml"]',
        f"imports = [{json.dumps(str(profile_path))}]",
    ))
    result = subprocess.run(
        ["containerd", "--config", str(probe), "config", "dump"],
        text=True, capture_output=True, check=True,
    )
    return tomllib.loads(result.stdout)

def assert_profile(config):
    plugins = config["plugins"]
    assert plugins["io.containerd.snapshotter.v1.erofs"]["enable_dmverity_referrers"]
    assert plugins["io.containerd.cri.v1.images"]["snapshotter"] == "erofs"
    assert plugins["io.containerd.cri.v1.images"]["use_local_image_pull"] is False
    assert plugins["io.containerd.service.v1.diff-service"]["default"] == ["erofs", "walking"]
    assert not plugins["io.containerd.transfer.v1.local"].get("unpack_config")

assert_profile(effective())
assert effective()["plugins"]["io.containerd.cri.v1.runtime"]["containerd"]["runtimes"]["runc"]["options"]["SystemdCgroup"] is False

for version in (2, 3, 4):
    directory = test_root / f'version-{version} "quoted" path'
    directory.mkdir()
    (directory / "conf.d").mkdir()
    runtime = directory / "runtime.toml"
    cri = ('plugins."io.containerd.grpc.v1.cri".containerd' if version == 2
           else 'plugins."io.containerd.cri.v1.images"')
    registry = ('plugins."io.containerd.grpc.v1.cri".registry' if version == 2
                else 'plugins."io.containerd.cri.v1.images".registry')
    snapshotter = 'plugins."io.containerd.snapshotter.v1.erofs"'
    runtime.write_text(f'''version = {version}
[{cri}]
snapshotter = "overlayfs"
[{registry}]
config_path = "/etc/containerd/custom-certs.d"
[{snapshotter}]
enable_dmverity_referrers = false
dmverity_mode = "auto"
[plugins."io.containerd.service.v1.diff-service"]
default = ["walking"]
[plugins."io.containerd.transfer.v1.local"]
max_concurrent_downloads = 7
''')
    (directory / "conf.d/10-runtime.toml").write_text(
        f'version = {version}\nimports = ["../runtime.toml"]\n'
    )
    source = directory / "base.toml"
    source.write_text(
        f'version = {version}\nroot = "/var/lib/containerd-custom"\n'
        'imports = ["conf.d/*.toml"]\n'
    )
    original = source.read_bytes()
    generate("base.toml", cwd=directory)
    assert source.read_bytes() == original
    merged = effective()
    assert_profile(merged)
    assert merged["root"] == "/var/lib/containerd-custom"
    assert merged["plugins"]["io.containerd.cri.v1.images"]["registry"]["config_path"] == "/etc/containerd/custom-certs.d"
    assert merged["plugins"]["io.containerd.transfer.v1.local"]["max_concurrent_downloads"] == 7

    # Re-resolve imports on every start; do not reuse a stale flattened base.
    runtime.write_text(runtime.read_text().replace("= 7", "= 9").replace('"auto"', '"off"'))
    generate(source)
    merged = effective()
    assert_profile(merged)
    assert merged["plugins"]["io.containerd.transfer.v1.local"]["max_concurrent_downloads"] == 9
    # The snapshotter, not this helper, rejects explicitly disabled dm-verity.
    assert merged["plugins"]["io.containerd.snapshotter.v1.erofs"]["dmverity_mode"] == "off"

escaped_base = test_root / 'flat "quoted" \\base.toml'
escaped_base.write_text('version = 4\nroot = "/var/lib/containerd-escaped"\n')
generate(escaped_base)
assert effective()["root"] == "/var/lib/containerd-escaped"
assert_profile(effective())

escaped_base.write_text('''version = 4
[plugins."io.containerd.cri.v1.images"]
use_local_image_pull = true
''')
generate(escaped_base)
# Preserve incompatible operator choices; the signed consumer rejects local pulls.
assert effective()["plugins"]["io.containerd.cri.v1.images"]["use_local_image_pull"] is True

previous = config_path.read_bytes()
invalid = test_root / "invalid.toml"
invalid.write_text("not valid TOML !\n")
result = generate(invalid, success=False)
assert "failed to resolve containerd base config" in result.stderr
assert config_path.read_bytes() == previous
generate(test_root / "missing.toml", success=False)
assert config_path.read_bytes() == previous
PY

mkdir "${TEST_ROOT}/failure-bin"
cat > "${TEST_ROOT}/failure-bin/containerd" <<'EOF'
#!/bin/bash
echo 'version = 4'
if [[ "${FAILURE_MODE}" == "partial" ]]; then
    echo 'imports = []'
    exit 1
fi
EOF
chmod +x "${TEST_ROOT}/failure-bin/containerd"
cp "${config_path}" "${TEST_ROOT}/previous.toml"
for failure in partial missing-imports; do
    if FAILURE_MODE="${failure}" PATH="${TEST_ROOT}/failure-bin:${PATH}" \
        ACL_CONTAINERD_CONFIG_PATH="${config_path}" \
        "${SELECTOR}" "${base}" >"${TEST_ROOT}/failure.log" 2>&1; then
        echo "Selector accepted ${failure} dump output" >&2
        exit 1
    fi
    grep -q 'ERROR: failed to resolve containerd base config' "${TEST_ROOT}/failure.log"
    cmp "${config_path}" "${TEST_ROOT}/previous.toml"
    [[ -z "$(find "$(dirname "${config_path}")" -name '*.tmp.*' -print)" ]]
done

echo "containerd runtime profile tests passed"
