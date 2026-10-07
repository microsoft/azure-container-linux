#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin" "${work}/certs"
export MOCK_DISK_JSON="${work}/disk.json" MOCK_BUILD_ROOT
MOCK_BUILD_ROOT="$(printf 'a%.0s' {1..64})"
export MOCK_REAL_DD MOCK_DD_LOG="${work}/dd.calls"
MOCK_REAL_DD="$(command -v dd)"
jq -n --arg work "${work}" '{blockdevices:[
    {path:($work+"/USR-A"),partlabel:"USR-A",partuuid:"7130c94a-213a-4e5a-8e26-6cce9662f132"},
    {path:($work+"/HASH-A"),partlabel:"HASH-A",partuuid:"b736baf1-cdb4-4535-beba-ddaaa30ad7b7"},
    {path:($work+"/HASH-SIG-A"),partlabel:"HASH-SIG-A",partuuid:"3514648f-e3da-44ae-89ba-8d0552418f88"},
    {path:($work+"/USR-B"),partlabel:"USR-B",partuuid:"e03dd35c-7c2d-4a47-b3fe-27f15780a57c"},
    {path:($work+"/HASH-B"),partlabel:"HASH-B",partuuid:"35bdf78b-c453-4661-98e6-f834f534ef5b"},
    {path:($work+"/HASH-SIG-B"),partlabel:"HASH-SIG-B",partuuid:"d8941eb2-f713-4bb6-b4ae-bd8350ca27d4"}
]}' > "${MOCK_DISK_JSON}"
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
cat > "${work}/bin/lsblk" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "${*: -1}" == /dev/mock-image ]]
cat "${MOCK_DISK_JSON}"
EOF
cat > "${work}/bin/blockdev" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$1" == --getsize64 ]]
[[ "${MOCK_SIZE_FAILURE:-}" != "$(basename "$2")" ]] || exit 1
stat -c %s "$2"
EOF
cat > "${work}/bin/veritysetup" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$1" == verify && "$2" == */USR-A && "$3" == */HASH-A && "$4" == "${MOCK_BUILD_ROOT}" ]]
EOF
cat > "${work}/bin/dd" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_DD_LOG}"
exec "${MOCK_REAL_DD}" "$@"
EOF
chmod +x "${work}/bin/"*
export PATH="${work}/bin:${PATH}"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=acl-factory-test' \
    -keyout "${work}/certs/ca.key" -out "${work}/certs/uki-signing-ca.pem" \
    > "${work}/openssl.log" 2>&1
builder="${ROOT}/build_library/rpm/sign-usr-root-hash.sh"
bash "${builder}" /dev/mock-image "${MOCK_BUILD_ROOT}" "${work}/certs"
[[ "$(sha256sum "${work}/USR-A" "${work}/HASH-A")" == "${active_before}" ]]
source "${ROOT}/build_library/rpm/additional_files/acl-usr-verity-payload.sh"
acl_verity_decode_payload "${work}/HASH-SIG-A" "${MOCK_BUILD_ROOT}" "${work}/decoded.p7s"
acl_verity_check_cms "${MOCK_BUILD_ROOT}" "${work}/decoded.p7s"
[[ "$(wc -l < "${MOCK_DD_LOG}")" == 1 ]]
for partition in USR-B HASH-B HASH-SIG-B; do
    capacity="$(stat -c %s "${work}/${partition}")"
    cmp -n "${capacity}" "${work}/${partition}" /dev/zero
    printf x | "${MOCK_REAL_DD}" of="${work}/${partition}" conv=notrunc status=none
    if bash "${builder}" /dev/mock-image "${MOCK_BUILD_ROOT}" "${work}/certs" \
        > "${work}/rejected.log" 2>&1; then
        echo "Nonempty factory ${partition} accepted" >&2
        exit 1
    fi
    [[ "$(wc -l < "${MOCK_DD_LOG}")" == 1 ]]
    truncate -s 0 "${work}/${partition}"
    truncate -s "${capacity}" "${work}/${partition}"
done
for partition in USR-A USR-B HASH-A HASH-B HASH-SIG-A HASH-SIG-B; do
    if MOCK_SIZE_FAILURE="${partition}" bash "${builder}" /dev/mock-image \
        "${MOCK_BUILD_ROOT}" "${work}/certs" \
        > "${work}/rejected.log" 2>&1; then
        echo "Failed size lookup for ${partition} accepted" >&2
        exit 1
    fi
    [[ "$(wc -l < "${MOCK_DD_LOG}")" == 1 ]]
done
echo "Signed /usr factory tests passed: A signed, B empty, stale B and size errors rejected before writes"
