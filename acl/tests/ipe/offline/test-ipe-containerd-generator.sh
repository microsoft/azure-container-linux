#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PROFILE_DIR="${ROOT}/build_library/rpm/additional_files/containerd2"
GENERATOR="${PROFILE_DIR}/containerd-acl-profile-generator"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

export ACL_IPE_DIR="${TMP_DIR}/ipe"
export ACL_IPE_CONTAINERD_PROFILE="${PROFILE_DIR}/containerd-acl-erofs-profile.conf"
export ACL_IPE_CONTAINERD_SELECTOR="${PROFILE_DIR}/containerd-acl-select-profile"
active="${ACL_IPE_DIR}/policies/acl_ipe_boot_policy/active"
output="${TMP_DIR}/generated"
dropin="${output}/containerd.service.d/90-acl-profile.conf"

run_generator() {
    bash "${GENERATOR}" "${output}" "${TMP_DIR}/early" "${TMP_DIR}/late"
}

run_generator
[[ ! -e "${dropin}" ]]
mkdir -p "${active%/*}"
printf '0\n' > "${active}"
run_generator
[[ ! -e "${dropin}" ]]

printf '1\n' > "${active}"
printf '0\n' > "${ACL_IPE_DIR}/enforce"
run_generator
cmp "${ACL_IPE_CONTAINERD_PROFILE}" "${dropin}"
[[ "$(<"${ACL_IPE_DIR}/enforce")" == 0 ]]

# systemd clears generated output before invoking the current generators again.
rm -f "${dropin}"
printf '0\n' > "${active}"
run_generator
[[ ! -e "${dropin}" ]]

printf '1\n' > "${active}"
if ACL_IPE_CONTAINERD_SELECTOR="${TMP_DIR}/missing-selector" run_generator > "${TMP_DIR}/error" 2>&1; then
    echo "Missing runtime selector was accepted" >&2
    exit 1
fi
grep -Fq 'missing its IPE profile assets' "${TMP_DIR}/error"
[[ ! -e "${dropin}" ]]

if ACL_IPE_CONTAINERD_PROFILE="${TMP_DIR}/missing-profile" run_generator > "${TMP_DIR}/error" 2>&1; then
    echo "Missing profile was accepted" >&2
    exit 1
fi
grep -Fq 'missing its IPE profile assets' "${TMP_DIR}/error"

printf 'invalid\n' > "${active}"
if run_generator > "${TMP_DIR}/error" 2>&1; then
    echo "Invalid policy activation state was accepted" >&2
    exit 1
fi
grep -Fq 'invalid ACL IPE policy activation state' "${TMP_DIR}/error"

rootfs="${TMP_DIR}/runtime"
mkdir -p "${rootfs}/etc/containerd" "${rootfs}/usr/lib/systemd/system"
printf '[Service]\nExecStart=/usr/bin/containerd\n' > "${rootfs}/usr/lib/systemd/system/containerd.service"
cat > "${rootfs}/etc/containerd/config.toml" <<'EOF'
version = 2
[plugins."io.containerd.grpc.v1.cri"]
  enable_selinux = false
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF
bash "${ROOT}/build_library/rpm/sysext_mangle_containerd-flatcar.sh" "${rootfs}"
[[ -x "${rootfs}/usr/lib/systemd/system-generators/acl-containerd-profile-generator" ]]
cmp "${GENERATOR}" "${rootfs}/usr/lib/systemd/system-generators/acl-containerd-profile-generator"
cmp "${ACL_IPE_CONTAINERD_PROFILE}" "${rootfs}/usr/share/containerd/acl-erofs-profile.conf"
[[ -x "${rootfs}/usr/libexec/containerd/acl-select-profile" ]]

echo "IPE containerd generator and runtime packaging tests passed"
