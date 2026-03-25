#!/bin/bash
# sign_uki_ephemeral.sh — Sign UKI EFI files with an ephemeral (self-signed) key.
#
# This script generates a one-time RSA 2048-bit certificate and signs all
# UKI-related EFI binaries on the mounted ESP.  The public certificate
# (ca.pem) is written to the output directory so it can be enrolled in:
#   - OVMF Secure Boot db  (for QEMU testing via virt-fw-vars)
#   - Azure gallery image  (for Azure VM testing via securityProfile)
#
# The private key is deleted after signing.
#
# Usage:
#   sign_uki_ephemeral.sh <esp-mount-dir> <cert-output-dir>
#
# Requirements (all available in the SDK container):
#   - openssl   (key and certificate generation)
#   - sbsign    (EFI Authenticode signing — from app-crypt/sbsigntools)

set -euo pipefail

ESP_DIR="${1:?Usage: sign_uki_ephemeral.sh <esp-mount-dir> <cert-output-dir>}"
CERT_OUTPUT_DIR="${2:?Usage: sign_uki_ephemeral.sh <esp-mount-dir> <cert-output-dir>}"

CERT_NAME="uki-signing-ca.pem"

info()  { echo "[sign_uki_ephemeral] $*"; }
error() { echo "[sign_uki_ephemeral] ERROR: $*" >&2; }

if [[ ! -d "${ESP_DIR}" ]]; then
    error "ESP directory does not exist: ${ESP_DIR}"
    exit 1
fi

if [[ ! -d "${ESP_DIR}/EFI/Linux" ]]; then
    error "No EFI/Linux directory on ESP — is this a UKI image?"
    exit 1
fi

mkdir -p "${CERT_OUTPUT_DIR}"

# Generate ephemeral key + certificate
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

KEY_FILE="${WORK_DIR}/ca.key"
CERT_FILE="${CERT_OUTPUT_DIR}/${CERT_NAME}"

info "Generating ephemeral signing certificate..."
openssl req -x509 \
    -newkey rsa:2048 \
    -days 1 \
    -noenc \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -subj "/CN=ACL Ephemeral Signing $(date +%Y%m%d%H%M%S)" \
    -sha256 \
    -addext "basicConstraints=CA:FALSE" \
    -addext "extendedKeyUsage=codeSigning" \
    2>&1

info "Certificate: ${CERT_FILE}"

# Discover EFI files to sign
declare -a efi_files=()

# Main UKI
if [[ -f "${ESP_DIR}/EFI/Linux/acl.efi" ]]; then
    efi_files+=("${ESP_DIR}/EFI/Linux/acl.efi")
fi

# UKI addons (firstboot, oem, etc.)
if [[ -d "${ESP_DIR}/EFI/Linux/acl.efi.extra.d" ]]; then
    while IFS= read -r -d '' addon; do
        efi_files+=("${addon}")
    done < <(find "${ESP_DIR}/EFI/Linux/acl.efi.extra.d" -name '*.efi' -print0 2>/dev/null)
fi

if [[ ${#efi_files[@]} -eq 0 ]]; then
    error "No EFI files found to sign"
    exit 1
fi

info "Found ${#efi_files[@]} EFI file(s) to sign"

# Sign each EFI file
for efi_file in "${efi_files[@]}"; do
    local_name=$(basename "${efi_file}")
    info "  Signing: ${local_name}"

    signed_tmp="${WORK_DIR}/${local_name}.signed"

    sbsign \
        --key "${KEY_FILE}" \
        --cert "${CERT_FILE}" \
        --output "${signed_tmp}" \
        "${efi_file}"

    sudo mv "${signed_tmp}" "${efi_file}"
done

# Private key is in WORK_DIR which is cleaned up by the trap.
info "Signing complete. ${#efi_files[@]} file(s) signed."
info "Public certificate: ${CERT_FILE}"
