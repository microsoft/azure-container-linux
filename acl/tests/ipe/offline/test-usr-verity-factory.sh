#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export MOCK_DISK_DIR="${work}"
root_hash="$(printf 'a%.0s' {1..64})"
source "${ROOT}/build_library/rpm/additional_files/acl-usr-verity-payload.sh"
reject() {
    if "$@" > "${work}/rejected.log" 2>&1; then
        echo "Unexpected success: $*" >&2
        exit 1
    fi
}
for partition in USR-A USR-B HASH-A HASH-B; do
    truncate -s 4096 "${work}/${partition}"
done
for partition in HASH-SIG-A HASH-SIG-B; do
    truncate -s 1048576 "${work}/${partition}"
done
printf 'active data fixture' > "${work}/USR-A"
printf 'active tree fixture' > "${work}/HASH-A"
truncate -s 4096 "${work}/USR-A" "${work}/HASH-A"
active_before="$(sha256sum "${work}/USR-A" "${work}/HASH-A")"
lsblk() {
    [[ "${*: -1}" == /dev/mock-image ]] || return 1
    jq -n --arg work "${MOCK_DISK_DIR}" '{blockdevices:
        (["USR-A","HASH-A","HASH-SIG-A","USR-B","HASH-B","HASH-SIG-B"] |
        map({path:($work+"/"+.),partlabel:.}))}'
}
blockdev() { stat -c %s "${2}"; }
veritysetup() { [[ "$1" == verify && "$2" == */USR-A && "$3" == */HASH-A && "$4" == "${root_hash}" ]]; }
export -f lsblk blockdev veritysetup
mkdir "${work}/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=acl-factory-test' \
    -keyout "${work}/certs/ca.key" -out "${work}/certs/uki-signing-ca.pem" \
    > "${work}/openssl.log" 2>&1
builder="${ROOT}/build_library/rpm/sign-usr-root-hash.sh"
bash "${builder}" /dev/mock-image "${root_hash}" "${work}/certs"
[[ "$(sha256sum "${work}/USR-A" "${work}/HASH-A")" == "${active_before}" ]]
acl_verity_decode_payload "${work}/HASH-SIG-A" "${root_hash}" "${work}/decoded.p7s"
acl_verity_check_cms "${root_hash}" "${work}/decoded.p7s"
signature_before="$(sha256sum "${work}/HASH-SIG-A")"
for partition in USR-B HASH-B HASH-SIG-B; do
    capacity="$(stat -c %s "${work}/${partition}")"
    cmp -n "${capacity}" "${work}/${partition}" /dev/zero
    printf x | dd of="${work}/${partition}" conv=notrunc status=none
    reject bash "${builder}" /dev/mock-image "${root_hash}" "${work}/certs"
    [[ "$(sha256sum "${work}/HASH-SIG-A")" == "${signature_before}" ]]
    truncate -s 0 "${work}/${partition}"
    truncate -s "${capacity}" "${work}/${partition}"
done
truncate -s 8192 "${work}/HASH-B"
reject bash "${builder}" /dev/mock-image "${root_hash}" "${work}/certs"
[[ "$(sha256sum "${work}/HASH-SIG-A")" == "${signature_before}" ]]

reject acl_verity_decode_payload "${work}/HASH-SIG-A" "$(printf 'b%.0s' {1..64})" "${work}/decoded.p7s"
reject acl_verity_check_cms "$(printf 'b%.0s' {1..64})" "${work}/decoded.p7s"
cp "${work}/HASH-SIG-A" "${work}/bad"
printf x | dd of="${work}/bad" bs=1 seek=1048575 conv=notrunc status=none
reject acl_verity_decode_payload "${work}/bad" "${root_hash}" "${work}/decoded.p7s"
for fields in \
    "\"rootHash\":\"${root_hash}\",\"signature\":\"AA==\"" \
    '"signature":"AA==","signature":"AA=="' \
    '"signature":"AB=="' \
    '"signature":"AA==","unexpected":true'; do
    printf '{"rootHash":"%s",%s}' "${root_hash}" "${fields}" > "${work}/bad"
    truncate -s 4096 "${work}/bad"
    reject acl_verity_decode_payload "${work}/bad" "${root_hash}" "${work}/decoded.p7s"
done
echo "Signed /usr factory and payload tests passed"
