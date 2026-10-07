#!/bin/bash
# Populate a fresh signed-root image, after the final /usr hash is generated.
set -euo pipefail

disk="${1:?disk}" root_hash="${2:?root hash}" cert_dir="${3:?certificate directory}"
metadata="${4:?metadata output}"
source "$(dirname "${BASH_SOURCE[0]}")/additional_files/acl-usr-verity-payload.sh"
[[ "${root_hash}" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid /usr root hash" >&2; exit 1; }
[[ -s "${cert_dir}/ca.key" && -s "${cert_dir}/uki-signing-ca.pem" ]] ||
    { echo "Missing shared IPE signing material" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
lsblk --json --paths --output PATH,PARTLABEL,PARTUUID,SIZE --bytes "${disk}" > "${work}/disk.json"
partition() {
    jq -er --arg label "$1" '
        [.. | objects | select(.partlabel? == $label)] |
        if length == 1 then .[0].path else error("ambiguous/missing partition") end
    ' "${work}/disk.json"
}
data_a="$(partition USR-A)" data_b="$(partition USR-B)"
hash_a="$(partition HASH-A)" hash_b="$(partition HASH-B)"
for pair in "${data_a}:${data_b}" "${hash_a}:${hash_b}"; do
    [[ "$(blockdev --getsize64 "${pair%:*}")" == "$(blockdev --getsize64 "${pair#*:}")" ]] ||
        { echo "A/B partition capacity mismatch" >&2; exit 1; }
done
veritysetup verify "${data_a}" "${hash_a}" "${root_hash}"
# Only this fresh-image builder initializes B. Servicing must never do this.
dd if="${data_a}" of="${data_b}" bs=4M conv=fsync status=none
dd if="${hash_a}" of="${hash_b}" bs=1M conv=fsync status=none
veritysetup verify "${data_b}" "${hash_b}" "${root_hash}"
printf '%s' "${root_hash}" > "${work}/root.hash"
openssl cms -sign -binary -noattr -md sha256 -in "${work}/root.hash" \
    -signer "${cert_dir}/uki-signing-ca.pem" -inkey "${cert_dir}/ca.key" \
    -outform DER -out "${work}/root.p7s"
acl_verity_check_cms "${root_hash}" "${work}/root.p7s"
for slot in A B; do
    device="$(partition "HASH-SIG-${slot}")"
    capacity="$(blockdev --getsize64 "${device}")"
    acl_verity_encode_payload "${root_hash}" "${work}/root.p7s" "${work}/payload" "${capacity}"
    dd if="${work}/payload" of="${device}" bs=4096 conv=fsync status=none
    cmp -n "${capacity}" "${work}/payload" "${device}"
    jq -cn --arg slot "${slot,,}" --arg hash "${root_hash}" --arg sig_hash "$(sha256sum "${work}/root.p7s" | cut -d' ' -f1)" \
        --arg data "$(blkid -s PARTUUID -o value "$(partition "USR-${slot}")")" \
        --arg tree "$(blkid -s PARTUUID -o value "$(partition "HASH-${slot}")")" \
        --arg signature "$(blkid -s PARTUUID -o value "${device}")" \
        '{slot:$slot,rootHash:$hash,dataPartUuid:$data,hashPartUuid:$tree,signaturePartUuid:$signature,signatureSha256:$sig_hash}' \
        >> "${work}/slots.jsonl"
done
jq -s '{version:1,signingMode:"ephemeral",slots:.}' "${work}/slots.jsonl" > "${metadata}.tmp"
mv -f "${metadata}.tmp" "${metadata}"
