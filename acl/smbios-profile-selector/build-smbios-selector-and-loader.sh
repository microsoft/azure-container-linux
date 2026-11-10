#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Build the ARM64 SMBIOS profile selector and efitreeloader.
# The loader runs the SMBIOS profile selector before systemd-boot.
# Stage both unsigned EFI applications for image installation and later signing.

set -euo pipefail

SELECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EFITREELOADER_DIR="${1:?Usage: build-smbios-selector-and-loader.sh <efitreeloader-repository>}"
TARGET="aarch64-unknown-uefi"
OUTPUT_DIR="${SELECTOR_DIR}/target/boot"
mkdir -p "${OUTPUT_DIR}"
WORK_DIR="$(mktemp -d "${SELECTOR_DIR}/target/efitreeloader.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Embed our boot sequence without modifying the efitreeloader checkout.
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
