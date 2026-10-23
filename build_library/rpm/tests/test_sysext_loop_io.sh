#!/bin/bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILD_LIBRARY_DIR="${SCRIPT_ROOT}/build_library"
source "${BUILD_LIBRARY_DIR}/rpm/build_image_util.sh"

die() { echo "$*" >&2; exit 1; }
sudo() { "$@"; }

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
root_fs="${work_dir}/root"
vendor="${root_fs}/usr/lib/systemd/system/systemd-sysext.service.d/60-loop-buffered-io.conf"
override="${root_fs}/etc/systemd/system/systemd-sysext.service.d/60-loop-buffered-io.conf"

mkdir -p "$(dirname "${override}")"
printf '[Service]\nEnvironment=SYSTEMD_LOOP_DIRECT_IO=1\n' > "${override}"
cp "${override}" "${work_dir}/admin-override"
printf '[Service]\nEnvironment=SYSTEMD_LOOP_DIRECT_IO=0\n' > "${work_dir}/expected"

_configure_sysext_rpm "${root_fs}"
cmp "${work_dir}/expected" "${vendor}" ||
    die "Image must install the buffered-loop vendor default"
[[ "$(stat -c '%a' "${vendor}")" == 644 ]] ||
    die "Vendor drop-in must be readable by systemd"

_configure_sysext_rpm "${root_fs}"
cmp "${work_dir}/expected" "${vendor}" ||
    die "Repeated image configuration must not duplicate the drop-in"
cmp "${work_dir}/admin-override" "${override}" ||
    die "Image configuration must preserve administrator overrides"
