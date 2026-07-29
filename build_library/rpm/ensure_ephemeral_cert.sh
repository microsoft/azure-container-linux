#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# ensure_ephemeral_cert.sh <dir>
#
# Idempotently generate the per-build, throwaway RSA-2048 signing key +
# certificate used in permissive/enforcing IPE modes to sign, with ONE cert:
#   - the UKI Secure Boot chain and addons   (sign_uki_ephemeral.sh)
#   - the ACL IPE policy, including the exact /usr dm-verity root hash
#     (uki_install.sh)
#
# Both MUST share the same cert: a single public cert is enrolled in the
# test VM's UEFI db (→ .platform keyring), and that is what the kernel verifies
# the UKI and IPE policy signatures against.
#
# uki_install.sh (build_image phase) calls this first to sign the policy and
# bind the /usr verity root hash into it; sign_uki_ephemeral.sh (image_to_vm
# phase) then finds the cert here and reuses it. Both run in the same SDK chroot
# and address the build output directory by the same absolute path.
#
# Idempotent: if the key + cert already exist, this is a no-op.

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
