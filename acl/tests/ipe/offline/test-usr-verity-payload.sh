#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "${ROOT}/build_library/rpm/additional_files/acl-usr-verity-payload.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
hash="$(printf 'a%.0s' {1..64})"

reject() {
    if "$@" > "${work}/unexpected.out" 2>&1; then
        echo "Unexpected success: $*" >&2
        exit 1
    fi
}
printf '%s' "${hash}" > "${work}/root"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${work}/key.pem" \
    -out "${work}/cert.pem" -days 1 -subj /CN=ACL-verity-test > /dev/null 2>&1
openssl cms -sign -binary -noattr -in "${work}/root" -signer "${work}/cert.pem" \
    -inkey "${work}/key.pem" -outform DER -out "${work}/sig.der"
acl_verity_encode_payload "${hash}" "${work}/sig.der" "${work}/payload" 1048576
acl_verity_decode_payload "${work}/payload" "${hash}" "${work}/decoded.der"
cmp "${work}/sig.der" "${work}/decoded.der"
acl_verity_check_cms "${hash}" "${work}/decoded.der"
reject acl_verity_decode_payload "${work}/payload" "$(printf 'b%.0s' {1..64})" "${work}/decoded.der"
reject acl_verity_encode_payload "${hash}" "${work}/sig.der" "${work}/bad" 1048577
reject acl_verity_encode_payload "${hash}" "${work}/sig.der" "${work}/bad" 4095
reject acl_verity_encode_payload "${hash^^}" "${work}/sig.der" "${work}/bad" 4096
cp "${work}/payload" "${work}/bad"
printf X | dd of="${work}/bad" bs=1 seek=1048575 conv=notrunc status=none
reject acl_verity_decode_payload "${work}/bad" "${hash}" "${work}/decoded.der"
for text in \
    "{\"rootHash\":\"${hash}\",\"rootHash\":\"${hash}\",\"signature\":\"AA==\"}" \
    "{\"rootHash\":\"${hash}\",\"signature\":\"AA==\",\"signature\":\"AA==\"}" \
    "{\"rootHash\":\"${hash}\",\"signature\":\"AB==\"}" \
    "{\"rootHash\":\"${hash}\",\"signature\":\"!bad!\"}" \
    "{\"rootHash\":\"${hash}\",\"signature\":\"AA==\"} {}" \
    "{\"rootHash\":\"${hash}\",\"signature\":\"AA==\",\"unexpected\":true}"; do
    printf '%s' "${text}" > "${work}/bad"
    truncate -s 4096 "${work}/bad"
    reject acl_verity_decode_payload "${work}/bad" "${hash}" "${work}/decoded.der"
done
head -c 4095 "${work}/payload" > "${work}/bad"
reject acl_verity_decode_payload "${work}/bad" "${hash}" "${work}/decoded.der"
reject acl_verity_check_cms "$(printf 'b%.0s' {1..64})" "${work}/sig.der"
openssl cms -sign -binary -noattr -nodetach -in "${work}/root" -signer "${work}/cert.pem" \
    -inkey "${work}/key.pem" -outform DER -out "${work}/attached.der"
reject acl_verity_check_cms "${hash}" "${work}/attached.der"
echo "Signed /usr payload: bounds, padding, duplicates, canonical encoding and CMS checks passed"
