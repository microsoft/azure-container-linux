#!/bin/bash
# Populate a fresh signed-root image, after the final /usr hash is generated.
set -euo pipefail

disk="${1:?disk}" root_hash="${2:?root hash}" cert_dir="${3:?certificate directory}"
source "$(dirname "${BASH_SOURCE[0]}")/additional_files/acl-usr-verity-payload.sh"
[[ "${root_hash}" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid /usr root hash" >&2; exit 1; }
[[ -s "${cert_dir}/ca.key" && -s "${cert_dir}/uki-signing-ca.pem" ]] ||
    { echo "Missing shared IPE signing material" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
lsblk --json --paths --output PATH,PARTLABEL "${disk}" > "${work}/disk.json"
partition() {
    jq -er --arg label "$1" '
        [.. | objects | select(.partlabel? == $label)] |
        if length == 1 then .[0].path else error("ambiguous/missing partition") end
    ' "${work}/disk.json"
}
data_a="$(partition USR-A)" data_b="$(partition USR-B)"
hash_a="$(partition HASH-A)" hash_b="$(partition HASH-B)"
signature_a="$(partition HASH-SIG-A)" signature_b="$(partition HASH-SIG-B)"
for label in USR HASH; do
    capacity_a="$(blockdev --getsize64 "$(partition "${label}-A")")"
    capacity_b="$(blockdev --getsize64 "$(partition "${label}-B")")"
    [[ "${capacity_a}" =~ ^[1-9][0-9]*$ && "${capacity_a}" == "${capacity_b}" ]] ||
        { echo "A/B partition capacity mismatch" >&2; exit 1; }
done
for device in "${signature_a}" "${signature_b}"; do
    [[ "$(blockdev --getsize64 "${device}")" == 1048576 ]] ||
        { echo "HASH-SIG partitions must be exactly 1 MiB" >&2; exit 1; }
done
veritysetup verify "${data_a}" "${hash_a}" "${root_hash}"
# Keep the factory B slot uninitialized. Copying /usr also duplicates the
# Image Customizer discovery fstab, making COSI conversion ambiguous.
for device in "${data_b}" "${hash_b}" "${signature_b}"; do
    capacity="$(blockdev --getsize64 "${device}")"
    cmp -n "${capacity}" "${device}" /dev/zero ||
        { echo "Fresh signed images require an empty B slot: ${device}" >&2; exit 1; }
done
printf '%s' "${root_hash}" > "${work}/root.hash"
openssl cms -sign -binary -noattr -md sha256 -in "${work}/root.hash" \
    -signer "${cert_dir}/uki-signing-ca.pem" -inkey "${cert_dir}/ca.key" \
    -outform DER -out "${work}/root.p7s"
acl_verity_check_cms "${root_hash}" "${work}/root.p7s"
acl_verity_encode_payload "${root_hash}" "${work}/root.p7s" "${work}/payload" 1048576
dd if="${work}/payload" of="${signature_a}" bs=4096 conv=fsync status=none
cmp -n 1048576 "${work}/payload" "${signature_a}"
