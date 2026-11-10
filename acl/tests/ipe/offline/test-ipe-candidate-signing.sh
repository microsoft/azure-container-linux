#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SIGNER="${SCRIPT_DIR}/build_library/rpm/sign_ipe_artifact.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
policy="${SCRIPT_DIR}/build_library/rpm/additional_files/ipe/acl-ipe-boot-policy.pol"
bash "${SIGNER}" policy "${policy}" "${work}/policy.cred" "${work}/cert"
openssl smime -verify -binary -inform DER -in "${work}/policy.cred" \
    -nointern -certfile "${work}/cert/uki-signing-ca.pem" -noverify \
    -out "${work}/policy"
cmp "${policy}" "${work}/policy"
printf '%064d' 1 > "${work}/hash"
bash "${SIGNER}" usr "${work}/hash" "${work}/root.cred" "${work}/cert"
openssl cms -verify -binary -inform DER -in "${work}/root.cred" \
    -content "${work}/hash" -nointern -certfile "${work}/cert/uki-signing-ca.pem" \
    -noverify -out "${work}/verified"
cmp "${work}/hash" "${work}/verified"
printf '%064d' 2 > "${work}/changed-hash"
if openssl cms -verify -binary -inform DER -in "${work}/root.cred" \
    -content "${work}/changed-hash" -noverify -out "${work}/verified" 2>/dev/null; then
    echo "ERROR: accepted a signature for the old filesystem hash" >&2
    exit 1
fi
printf '\n' >> "${work}/hash"
if bash "${SIGNER}" usr "${work}/hash" "${work}/invalid" "${work}/cert" 2>"${work}/error"; then
    echo "ERROR: signed a noncanonical root hash" >&2
    exit 1
fi
grep -q 'exactly 64 lowercase ASCII hex bytes' "${work}/error"
[[ ! -e "${work}/invalid" ]]
echo "IPE candidate policy and root-hash signing tests passed"
