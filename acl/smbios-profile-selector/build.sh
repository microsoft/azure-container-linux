#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -euo pipefail

SELECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EFITREELOADER_DIR="${1:?Usage: build.sh <efitreeloader-repository>}"
TARGET="aarch64-unknown-uefi"
OUTPUT_DIR="${SELECTOR_DIR}/target/boot"
mkdir -p "${OUTPUT_DIR}"
WORK_DIR="$(mktemp -d "${SELECTOR_DIR}/target/efitreeloader.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Configure a clean dependency snapshot without modifying the caller's checkout.
git -C "${EFITREELOADER_DIR}" archive HEAD | tar -x -C "${WORK_DIR}"
cp "${SELECTOR_DIR}/boot/load_entries.arm64.json" "${WORK_DIR}/efitreeloader/load_entries.json"
(
    cd "${SELECTOR_DIR}"
    export CARGO_TARGET_DIR="${SELECTOR_DIR}/target"
    cargo build --locked --release --target "${TARGET}"
)
(
    cd "${WORK_DIR}"
    CARGO_TARGET_DIR="${SELECTOR_DIR}/target/efitreeloader" \
        cargo build --locked --release --target "${TARGET}" -p efitreeloader
)

install -m 0644 "${SELECTOR_DIR}/target/${TARGET}/release/smbios-profile-selector.efi" "${OUTPUT_DIR}/"
install -m 0644 "${SELECTOR_DIR}/target/efitreeloader/${TARGET}/release/efitreeloader.efi" "${OUTPUT_DIR}/"
git -C "${EFITREELOADER_DIR}" rev-parse HEAD > "${OUTPUT_DIR}/EFITREELOADER_COMMIT.txt"
(
    cd "${OUTPUT_DIR}"
    sha256sum smbios-profile-selector.efi efitreeloader.efi > SHA256SUMS
)
