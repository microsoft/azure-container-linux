#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Shared candidate signer for the stock builder and post-customization images.
# Usage: sign_ipe_artifact.sh <policy|usr> <input> <output> <cert-dir>
set -euo pipefail

kind="${1:?artifact kind is required}"
input="${2:?input is required}"
output="${3:?output is required}"
cert_dir="${4:?certificate directory is required}"
case "${kind}" in
    policy) cert_mode=create ;;
    usr) cert_mode=require ;;
    *) echo "ERROR: unsupported IPE artifact kind: ${kind}" >&2; exit 1 ;;
esac
[[ -f "${input}" && ! -L "${input}" && -s "${input}" ]] || {
    echo "ERROR: IPE signing input must be a nonempty regular file: ${input}" >&2
    exit 1
}
if [[ "${kind}" == usr ]]; then
    [[ "$(wc -c < "${input}")" -eq 64 && "$(<"${input}")" =~ ^[0-9a-f]{64}$ ]] || {
        echo "ERROR: /usr signing input must be exactly 64 lowercase ASCII hex bytes" >&2
        exit 1
    }
fi
bash "$(dirname "${BASH_SOURCE[0]}")/ensure_ephemeral_cert.sh" "${cert_dir}" "${cert_mode}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
if [[ "${kind}" == policy ]]; then
    openssl smime -sign -binary -in "${input}" \
        -signer "${cert_dir}/uki-signing-ca.pem" -inkey "${cert_dir}/ca.key" \
        -noattr -nodetach -nosmimecap -outform DER -out "${work}/signed"
    openssl smime -verify -inform DER -binary -in "${work}/signed" \
        -nointern -certfile "${cert_dir}/uki-signing-ca.pem" -noverify \
        -out "${work}/verified"
else
    openssl cms -sign -binary -noattr -md sha256 -in "${input}" \
        -signer "${cert_dir}/uki-signing-ca.pem" -inkey "${cert_dir}/ca.key" \
        -outform DER -out "${work}/signed"
    openssl cms -verify -binary -inform DER -in "${work}/signed" \
        -content "${input}" -nointern -certfile "${cert_dir}/uki-signing-ca.pem" \
        -noverify -out "${work}/verified"
fi
cmp "${input}" "${work}/verified"
install -m 0644 "${work}/signed" "${output}"
