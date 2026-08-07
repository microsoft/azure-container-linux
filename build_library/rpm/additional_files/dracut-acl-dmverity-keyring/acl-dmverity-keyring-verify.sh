#!/bin/bash
set -Eeuo pipefail

export LC_ALL=C

readonly KEYRING="%:.dm-verity"
readonly ASSET_DIR="/usr/lib/acl/dmverity-keyring"
readonly SIGNER_DESCRIPTION="acl-osguard-signer"
readonly PROBE_DESCRIPTION="acl-dmverity-seal-probe"

log() {
    echo "acl-dmverity-keyring-verify: $*" >&2
}

fail() {
    log "ERROR: $*"
    exit 1
}

[[ -d /sys/module/dm_verity ]] ||
    fail "dm_verity is not loaded"
keyctl list "${KEYRING}" >/dev/null ||
    fail "the .dm-verity keyring is unavailable after switch-root"

key_ids=$(keyctl rlist "${KEYRING}")
key_count=$(wc -w <<< "${key_ids}")
[[ "${key_count}" == "1" ]] ||
    fail "dm-verity keyring contains ${key_count} keys instead of 1"

# keyctl search requires search permission on the unpossessed child key.
# Description lookup only needs the owner-view permission granted at creation.
signer_id=$(awk 'NF { print $1; exit }' <<< "${key_ids}")
signer_description=$(keyctl describe "${signer_id}") ||
    fail "OS Guard Signer certificate could not be described"
grep -Fq "asymmetric: ${SIGNER_DESCRIPTION}" <<< "${signer_description}" ||
    fail "dm-verity keyring contains an unexpected key: ${signer_description}"

tmp_dir=$(mktemp -d /run/acl-dmverity-keyring-verify.XXXXXX)
trap 'rm -rf "${tmp_dir}"' EXIT
base64 --decode "${ASSET_DIR}/seal-probe.der.b64" > "${tmp_dir}/seal-probe.der"
expected_probe_sha=$(awk '$2 == "seal-probe.der" { print $1 }' "${ASSET_DIR}/certs.sha256")
actual_probe_sha=$(sha256sum "${tmp_dir}/seal-probe.der" | awk '{ print $1 }')
[[ -n "${expected_probe_sha}" && "${actual_probe_sha}" == "${expected_probe_sha}" ]] ||
    fail "seal probe certificate integrity check failed"

probe_error="${tmp_dir}/seal-probe.error"
if unexpected_probe_id=$(keyctl padd asymmetric "${PROBE_DESCRIPTION}" "${KEYRING}" \
        < "${tmp_dir}/seal-probe.der" 2> "${probe_error}"); then
    keyctl unlink "${unexpected_probe_id}" "${KEYRING}" >/dev/null 2>&1 || true
    fail "dm-verity keyring accepted a key after switch-root"
fi
grep -Eq "Operation not permitted|Permission denied" "${probe_error}" ||
    fail "post-switch insertion failed for an unexpected reason: $(<"${probe_error}")"

touch /run/acl-dmverity-keyring.verified
log "dm-verity keyring contains the expected signer and remains sealed"
