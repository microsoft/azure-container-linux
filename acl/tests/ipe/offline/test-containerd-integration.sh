#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
INSTALLER="${SCRIPT_DIR}/build_library/rpm/install_containerd_integration.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

seed() {
    mkdir -p "$1/etc/containerd" "$1/usr/lib/systemd/system"
    cp "${SCRIPT_DIR}/acl/SPECS/containerd2/containerd.service" "$1/usr/lib/systemd/system/"
    cat > "$1/etc/containerd/config.toml" <<'EOF'
version = 4
[plugins."io.containerd.cri.v1.runtime"]
enable_selinux = false
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
SystemdCgroup = true
EOF
}

for layout in sysext image; do
    root="${TMP_DIR}/${layout}"
    seed "${root}"
    if [[ "${layout}" == sysext ]]; then
        bash "${SCRIPT_DIR}/build_library/rpm/sysext_mangle_containerd-flatcar.sh" "${root}"
        config="/usr/share/containerd/config.toml"
        [[ ! -e "${root}/etc/containerd" ]]
    else
        bash "${INSTALLER}" "${root}" image
        config="/etc/containerd/config.toml"
        [[ -s "${root}${config}" ]]
    fi
    grep -Fxq 'enable_selinux = true' "${root}${config}"
    grep -Fxq 'SystemdCgroup = true' "${root}${config}"
    grep -Fxq 'SystemdCgroup = false' "${root}/usr/share/containerd/config-cgroupfs.toml"
    dropin="${root}/usr/lib/systemd/system/containerd.service.d/10-acl.conf"
    grep -Fxq "Environment=CONTAINERD_CONFIG=${config}" "${dropin}"
    grep -Fxq "ExecStart=/usr/bin/containerd --config \${CONTAINERD_CONFIG}" "${dropin}"
    grep -Fxq 'Type=notify' "${dropin}"
    grep -Fxq 'TasksMax=infinity' "${dropin}"
    cmp "${SCRIPT_DIR}/build_library/rpm/additional_files/containerd2/containerd-acl-select-profile" \
        "${root}/usr/libexec/containerd/acl-select-profile"
    cmp "${SCRIPT_DIR}/build_library/rpm/additional_files/containerd2/containerd-acl-erofs.toml" \
        "${root}/usr/share/containerd/acl-erofs.toml"
done

# A second image customization must preserve the RPM layout and remain idempotent.
bash "${INSTALLER}" "${TMP_DIR}/image" image
cmp "${TMP_DIR}/image/etc/containerd/config.toml" \
    "${TMP_DIR}/sysext/usr/share/containerd/config.toml"

seed "${TMP_DIR}/missing-unit"
rm "${TMP_DIR}/missing-unit/usr/lib/systemd/system/containerd.service"
if bash "${INSTALLER}" "${TMP_DIR}/missing-unit" image >"${TMP_DIR}/error" 2>&1; then
    echo "Expected missing RPM unit to fail" >&2
    exit 1
fi
grep -q 'containerd unit not found' "${TMP_DIR}/error"
echo "Containerd image/sysext integration tests passed"
