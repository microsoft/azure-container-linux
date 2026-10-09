#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SIGN="${SCRIPT_DIR}/build_library/rpm/sign_ipe_policy_ephemeral.sh"
POLICY="${SCRIPT_DIR}/build_library/rpm/additional_files/ipe/acl-ipe-boot-policy.pol"

"${SIGN}" "${POLICY}" "${WORK}/first.cred" "${WORK}/cert"
"${SIGN}" "${POLICY}" "${WORK}/second.cred" "${WORK}/cert"
cmp "${WORK}/first.cred" "${WORK}/second.cred"
openssl smime -verify -binary -inform der -in "${WORK}/first.cred" \
    -nointern -certfile "${WORK}/cert/uki-signing-ca.pem" -noverify \
    -out "${WORK}/verified.pol"
cmp "${POLICY}" "${WORK}/verified.pol"

"${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" "${WORK}/other"
if openssl smime -verify -binary -inform der -in "${WORK}/first.cred" \
    -nointern -certfile "${WORK}/other/uki-signing-ca.pem" -noverify \
    -out "${WORK}/wrong.pol" 2>/dev/null; then
    echo "Wrong signer accepted" >&2
    exit 1
fi
cp "${WORK}/other/ca.key" "${WORK}/cert/ca.key"
if "${SIGN}" "${POLICY}" "${WORK}/bad.cred" "${WORK}/cert" 2>/dev/null; then
    echo "Mismatched certificate/key accepted" >&2
    exit 1
fi
echo "Shared IPE policy signer tests passed"
