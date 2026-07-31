#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# RPM-specific mangle logic for the containerd-flatcar sysext.
# Called from build_library/sysext_mangle_containerd-flatcar when PACKAGE_SOURCE_MODE=RPM.

set -euo pipefail

rootfs="${1}"
azl_config="${rootfs}/etc/containerd/config.toml"
acl_config="${rootfs}/usr/share/containerd/config.toml"

if [[ ! -f "${azl_config}" ]]; then
  echo ">>> ERROR: $0: Azure Linux containerd config not found at ${azl_config}" >&2
  exit 1
fi

echo ">>> NOTICE: $0: installing Azure Linux containerd config with SELinux enabled"
install -Dpm 0644 "${azl_config}" "${acl_config}"

if grep -Eq '^[[:space:]]*enable_selinux[[:space:]]*=' "${acl_config}"; then
  sed -i -E 's/^([[:space:]]*)enable_selinux[[:space:]]*=.*/\1enable_selinux = true/' "${acl_config}"
elif grep -Eq '^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\][[:space:]]*$' "${acl_config}"; then
  sed -i -E '/^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\][[:space:]]*$/a\    enable_selinux = true' "${acl_config}"
else
  echo ">>> ERROR: $0: CRI plugin section not found in ${azl_config}" >&2
  exit 1
fi
