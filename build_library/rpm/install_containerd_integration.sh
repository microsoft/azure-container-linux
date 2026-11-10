#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Install ACL containerd integration in an RPM image or sysext staging tree.
# Run before filesystem hashing/signing, against the merged /etc for ACL images.
# Usage: install_containerd_integration.sh <rootfs> <sysext|image>

set -euo pipefail

rootfs="${1:?rootfs is required}"
layout="${2:?layout must be sysext or image}"
azl_config="${rootfs}/etc/containerd/config.toml"
case "${layout}" in
  sysext) config_path="/usr/share/containerd/config.toml" ;;
  image) config_path="/etc/containerd/config.toml" ;;
  *) echo "ERROR: unsupported containerd layout: ${layout}" >&2; exit 1 ;;
esac
acl_config="${rootfs}${config_path}"
acl_cgroupfs_config="${rootfs}/usr/share/containerd/config-cgroupfs.toml"
unit="${rootfs}/usr/lib/systemd/system/containerd.service"
dropin_dir="${rootfs}/usr/lib/systemd/system/containerd.service.d"
wants_dir="${rootfs}/usr/lib/systemd/system/multi-user.target.wants"
profile_dir="$(dirname "${BASH_SOURCE[0]}")/additional_files/containerd2"

if [[ ! -f "${unit}" ]]; then
  echo ">>> ERROR: $0: Azure Linux containerd unit not found at ${unit}" >&2
  exit 1
fi

if [[ ! -f "${azl_config}" ]]; then
  echo ">>> ERROR: $0: Azure Linux containerd config not found at ${azl_config}" >&2
  exit 1
fi

echo ">>> NOTICE: $0: installing Azure Linux containerd config with SELinux enabled"
if [[ "${azl_config}" != "${acl_config}" ]]; then
  install -Dpm 0644 "${azl_config}" "${acl_config}"
fi

if grep -Eq '^[[:space:]]*enable_selinux[[:space:]]*=' "${acl_config}"; then
  sed -i -E 's/^([[:space:]]*)enable_selinux[[:space:]]*=.*/\1enable_selinux = true/' "${acl_config}"
elif grep -Eq '^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\][[:space:]]*$' "${acl_config}"; then
  sed -i -E '/^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\][[:space:]]*$/a\    enable_selinux = true' "${acl_config}"
else
  echo ">>> ERROR: $0: CRI plugin section not found in ${azl_config}" >&2
  exit 1
fi

# Variant selected by tests that need the cgroupfs driver instead of systemd.
if ! grep -Eq '^[[:space:]]*SystemdCgroup[[:space:]]*=' "${acl_config}"; then
  echo ">>> ERROR: $0: SystemdCgroup setting not found in ${acl_config}" >&2
  exit 1
fi

echo ">>> NOTICE: $0: generating cgroupfs containerd config"
mkdir -p "$(dirname "${acl_cgroupfs_config}")"
sed -E 's/^([[:space:]]*)SystemdCgroup[[:space:]]*=.*/\1SystemdCgroup = false/' \
  "${acl_config}" > "${acl_cgroupfs_config}"
chmod 0644 "${acl_cgroupfs_config}"

# Add the EROFS containerd configuration. The IPE loader activates it at boot.
install -Dpm 0644 "${profile_dir}/containerd-acl-erofs.toml" \
  "${rootfs}/usr/share/containerd/acl-erofs.toml"
install -Dpm 0755 "${profile_dir}/containerd-acl-select-profile" \
  "${rootfs}/usr/libexec/containerd/acl-select-profile"

# The RPM enables the unit from %post, which does not run when the payload is
# unpacked into a sysext, so create the enablement symlink here.
echo ">>> NOTICE: $0: enabling containerd.service"
mkdir -p "${wants_dir}"
ln -fs ../containerd.service "${wants_dir}/containerd.service"

echo ">>> NOTICE: $0: installing ACL drop-in for containerd.service"
mkdir -p "${dropin_dir}"
cat > "${dropin_dir}/10-acl.conf" <<EOF
# ACL-specific overrides on top of the Azure Linux containerd.service.
[Service]
Environment=CONTAINERD_CONFIG=${config_path}
EOF
cat >> "${dropin_dir}/10-acl.conf" <<'EOF'
ExecStart=
ExecStart=/usr/bin/containerd --config ${CONTAINERD_CONFIG}

# containerd calls sd_notify once its socket is set up, so units ordered after
# it start against a ready daemon.
Type=notify
RestartSec=5

# docker.service expects containerd's socket at the legacy libcontainerd path.
ExecStartPre=/usr/bin/mkdir -p /run/docker/libcontainerd
ExecStartPre=/usr/bin/ln -fs /run/containerd/containerd.sock /run/docker/libcontainerd/docker-containerd.sock

# (lack of) limits from the upstream docker service unit
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
EOF
chmod 0644 "${dropin_dir}/10-acl.conf"

if [[ "${layout}" == sysext ]]; then
  # systemd-sysext only merges /usr and /opt.
  rm -rf "${rootfs}/etc/containerd"
fi
