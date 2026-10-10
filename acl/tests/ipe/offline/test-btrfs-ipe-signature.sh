#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
signer="$root/build_library/rpm/sign_btrfs_ipe_test_root.sh"
cert="$work/cert"
bash "$root/build_library/rpm/ensure_ephemeral_cert.sh" "$cert"
printf '%064d' 0 > "$work/hash"
bash "$signer" "$work/hash" "$cert" "$work/root.p7b"
openssl cms -verify -binary -inform DER -in "$work/root.p7b" \
    -content "$work/hash" -CAfile "$cert/uki-signing-ca.pem" -purpose any -out /dev/null
printf '%064d' 1 > "$work/other"
if openssl cms -verify -binary -inform DER -in "$work/root.p7b" \
    -content "$work/other" -noverify -out /dev/null 2>/dev/null; then
    echo "Incorrect root hash was accepted" >&2
    exit 1
fi
printf 'not-a-hash' > "$work/invalid"
if bash "$signer" "$work/invalid" "$cert" "$work/invalid.p7b" 2>/dev/null; then
    echo "Invalid hash was signed" >&2
    exit 1
fi
if bash "$signer" "$work/hash" "$work/missing" "$work/missing.p7b" 2>/dev/null; then
    echo "Signing succeeded without the shared certificate" >&2
    exit 1
fi
echo "Btrfs diagnostic root-signature tests passed"
