#!/bin/bash
# SPDX-License-Identifier: MIT
# Diagnostic only: production signing remains owned by the publishing pipeline.
set -euo pipefail
hash_file=${1:?Root hash file required}
cert_dir=${2:?Shared ephemeral certificate directory required}
output=${3:?Signature output required}
hash=$(cat "$hash_file")
[[ "$hash" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid SHA-256 root hash" >&2; exit 1; }
bash "$(dirname "$0")/ensure_ephemeral_cert.sh" "$cert_dir" require
work=$(mktemp -d)
trap 'rm -f "$work/hash" "$work/signature"; rmdir "$work"' EXIT
printf '%s' "$hash" > "$work/hash"
openssl cms -sign -binary -noattr -md sha256 -in "$work/hash" \
    -signer "$cert_dir/uki-signing-ca.pem" -inkey "$cert_dir/ca.key" \
    -outform DER -out "$work/signature"
openssl cms -verify -binary -inform DER -in "$work/signature" \
    -content "$work/hash" -noverify -out /dev/null
install -m 0644 "$work/signature" "$output"
