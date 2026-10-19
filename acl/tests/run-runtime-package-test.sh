#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Run inside the finished image, after RPM/database and documentation cleanup.
# No services are started and no block devices are modified.
set -euo pipefail

for command in bzip2 bunzip2 bzcat bzip2recover bzcmp bzdiff bzegrep bzfgrep \
    bzgrep bzless bzmore zstd unzstd zstdcat zstdmt pzstd zstdgrep zstdless \
    tc machinectl systemd-nspawn integritysetup; do
    path="$(command -v "${command}")"
    test -x "${path}"
done
for helper in systemd-importd systemd-machined; do
    test -x "/usr/lib/systemd/${helper}"
    "/usr/lib/systemd/${helper}" --help >/dev/null
done

bzip2 --help
zstd --version
pzstd --version
tc -Version
machinectl --version
systemd-nspawn --version
integritysetup --version

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
printf 'runtime compression smoke test\n' > "${workdir}/payload"
tar -cjf "${workdir}/payload.tar.bz2" -C "${workdir}" payload
tar --zstd -cf "${workdir}/payload.tar.zst" -C "${workdir}" payload
mkdir "${workdir}/bzip2" "${workdir}/zstd"
tar -xjf "${workdir}/payload.tar.bz2" -C "${workdir}/bzip2"
tar --zstd -xf "${workdir}/payload.tar.zst" -C "${workdir}/zstd"
cmp "${workdir}/payload" "${workdir}/bzip2/payload"
cmp "${workdir}/payload" "${workdir}/zstd/payload"

echo "PASS: installed runtime tools and tar compression/decompression"
