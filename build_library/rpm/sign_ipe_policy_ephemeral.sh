#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Shared policy-only signing primitive; callers retain and verify source bytes.
set -euo pipefail
POLICY="${1:?usage: sign_ipe_policy_ephemeral.sh <policy> <credential> <cert-dir>}"
CREDENTIAL="${2:?credential required}"
CERT_DIR="${3:?certificate directory required}"
"$(dirname "${BASH_SOURCE[0]}")/ensure_ephemeral_cert.sh" "${CERT_DIR}"
openssl smime -sign -binary \
    -in "${POLICY}" \
    -signer "${CERT_DIR}/uki-signing-ca.pem" \
    -inkey "${CERT_DIR}/ca.key" \
    -noattr -nodetach -nosmimecap -outform der -out "${CREDENTIAL}"
[[ -s "${CREDENTIAL}" ]]
