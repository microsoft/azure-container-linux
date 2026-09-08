#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Generate the per-build test certificate shared by the IPE policy, /usr
# root-hash signature, and UKI. Enrolling this certificate in UEFI db makes it
# available to the kernel through the .platform keyring.

set -euo pipefail

CERT_DIR="${1:?usage: ensure_ephemeral_cert.sh <dir>}"
KEY="${CERT_DIR}/ca.key"
CERT="${CERT_DIR}/uki-signing-ca.pem"

if [[ -s "${KEY}" && -s "${CERT}" ]]; then
    exit 0
fi

mkdir -p "${CERT_DIR}"
openssl req -x509 \
    -newkey rsa:2048 \
    -days 1 \
    -noenc \
    -keyout "${KEY}" \
    -out "${CERT}" \
    -subj "/CN=ACL Ephemeral Signing $(date +%Y%m%d%H%M%S)" \
    -sha256 \
    -addext "basicConstraints=CA:FALSE" \
    -addext "extendedKeyUsage=codeSigning"
chmod 600 "${KEY}"
