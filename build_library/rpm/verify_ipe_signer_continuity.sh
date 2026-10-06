#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Verify staged and ESP-installed IPE policies against the original per-build
# certificate before image conversion re-signs the UKI.

set -euo pipefail

CERT_DIR="${1:?usage: verify_ipe_signer_continuity.sh <cert-dir> <artifact-dir> <esp-dir>}"
ARTIFACT_DIR="${2:?usage: verify_ipe_signer_continuity.sh <cert-dir> <artifact-dir> <esp-dir>}"
ESP_DIR="${3:?usage: verify_ipe_signer_continuity.sh <cert-dir> <artifact-dir> <esp-dir>}"
CERT="${CERT_DIR}/uki-signing-ca.pem"
STAGED_POLICY="${ARTIFACT_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred"

verify_attached_cms() {
    local signature="$1"

    openssl smime -verify -inform der -binary \
        -in "${signature}" \
        -nointern -certfile "${CERT}" -noverify \
        -out /dev/null >/dev/null 2>&1
}

[[ -s "${CERT}" ]] || {
    echo "IPE signer certificate is missing: ${CERT}" >&2
    exit 1
}
[[ -s "${STAGED_POLICY}" ]] || {
    echo "Staged IPE policy credential is missing: ${STAGED_POLICY}" >&2
    exit 1
}
verify_attached_cms "${STAGED_POLICY}" || {
    echo "Staged IPE policy is not signed by ${CERT}" >&2
    exit 1
}

policy_count=0
while IFS= read -r -d '' policy_cred; do
    verify_attached_cms "${policy_cred}" || {
        echo "Installed IPE policy is not signed by ${CERT}: ${policy_cred}" >&2
        exit 1
    }
    policy_count=$((policy_count + 1))
done < <(find "${ESP_DIR}/EFI/Linux" -type f \
    -path '*.efi.extra.d/acl-ipe-policy.p7b.cred' -print0)
[[ "${policy_count}" -gt 0 ]] || {
    echo "No installed IPE policy credential found under ${ESP_DIR}/EFI/Linux" >&2
    exit 1
}
