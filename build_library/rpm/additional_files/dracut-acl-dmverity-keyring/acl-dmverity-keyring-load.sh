#!/bin/bash
set -Eeuo pipefail

export LC_ALL=C

readonly KEYRING="%:.dm-verity"
readonly ASSET_DIR="/usr/lib/acl/dmverity-keyring"
# Phase one deliberately pins the exact AKV signer leaf used by the
# precomputed-container test. Production should replace it with its stable CA.
readonly SIGNER_DESCRIPTION="acl-osguard-signer"
readonly PROBE_DESCRIPTION="acl-dmverity-seal-probe"
# Retain search/view/read access while permanently dropping write and setattr.
readonly SEALED_KEYRING_PERMISSIONS="0x080b0000"

sealed=0
tmp_dir=""

log() {
    echo "acl-dmverity-keyring: $*" >&2
}

fail() {
    log "ERROR: $*"
    exit 1
}

key_count() {
    keyctl rlist "${KEYRING}" | wc -w
}

seal_on_exit() {
    local rc=$?
    trap - EXIT
    set +e

    if [[ "${sealed}" -eq 0 ]] && keyctl list "${KEYRING}" >/dev/null 2>&1; then
        if keyctl restrict_keyring "${KEYRING}" >/dev/null 2>&1; then
            log "sealed the dm-verity keyring while handling an error"
        else
            log "ERROR: failed to seal the dm-verity keyring while handling an error"
        fi
    fi

    if [[ -n "${tmp_dir}" ]]; then
        rm -rf "${tmp_dir}"
    fi

    exit "${rc}"
}
trap seal_on_exit EXIT

grep -Fqw "dm_verity.keyring_unsealed=1" /proc/cmdline ||
    fail "signed kernel command line is missing dm_verity.keyring_unsealed=1"

modprobe dm_verity

[[ -r /sys/module/dm_verity/parameters/keyring_unsealed ]] ||
    fail "kernel does not expose the dm-verity keyring backport"

keyring_unsealed=$(</sys/module/dm_verity/parameters/keyring_unsealed)
[[ "${keyring_unsealed}" == "Y" || "${keyring_unsealed}" == "1" ]] ||
    fail "dm-verity keyring was not initialized unsealed"

keyctl list "${KEYRING}" >/dev/null ||
    fail "kernel did not create the .dm-verity keyring"

[[ "$(key_count)" == "0" ]] ||
    fail "expected an empty dm-verity keyring before provisioning"

tmp_dir=$(mktemp -d /run/acl-dmverity-keyring.XXXXXX)
base64 --decode "${ASSET_DIR}/osguard-signer.der.b64" > "${tmp_dir}/osguard-signer.der"
base64 --decode "${ASSET_DIR}/seal-probe.der.b64" > "${tmp_dir}/seal-probe.der"
(
    cd "${tmp_dir}"
    sha256sum --check "${ASSET_DIR}/certs.sha256"
) || fail "embedded certificate integrity check failed"

# Parse the probe before sealing so a later insertion failure proves the
# restriction rejected a valid asymmetric key rather than malformed DER.
probe_id=$(keyctl padd asymmetric "${PROBE_DESCRIPTION}" "${KEYRING}" < "${tmp_dir}/seal-probe.der") ||
    fail "seal probe certificate could not be added before restriction"
keyctl unlink "${probe_id}" "${KEYRING}" ||
    fail "seal probe certificate could not be removed before provisioning"

signer_id=$(keyctl padd asymmetric "${SIGNER_DESCRIPTION}" "${KEYRING}" < "${tmp_dir}/osguard-signer.der") ||
    fail "OS Guard Signer certificate could not be added"
# The kernel-owned ring is not linked into this service's credential keyrings,
# so the new key is not possessed and keyctl search returns EACCES. The key's
# owner-view permission still allows validating the returned serial directly.
signer_description=$(keyctl describe "${signer_id}") ||
    fail "OS Guard Signer certificate could not be described after insertion"
grep -Fq "asymmetric: ${SIGNER_DESCRIPTION}" <<< "${signer_description}" ||
    fail "OS Guard Signer certificate has an unexpected key description: ${signer_description}"

[[ "$(key_count)" == "1" ]] ||
    fail "dm-verity keyring contains an unexpected number of keys"

keyctl restrict_keyring "${KEYRING}" ||
    fail "failed to seal the dm-verity keyring"
sealed=1

probe_error="${tmp_dir}/seal-probe.error"
if unexpected_probe_id=$(keyctl padd asymmetric "${PROBE_DESCRIPTION}" "${KEYRING}" \
        < "${tmp_dir}/seal-probe.der" 2> "${probe_error}"); then
    keyctl unlink "${unexpected_probe_id}" "${KEYRING}" >/dev/null 2>&1 || true
    fail "dm-verity keyring accepted a key after sealing"
fi
grep -Eq "Operation not permitted|Permission denied" "${probe_error}" ||
    fail "post-seal insertion failed for an unexpected reason: $(<"${probe_error}")"

keyctl setperm "${KEYRING}" "${SEALED_KEYRING_PERMISSIONS}" ||
    fail "failed to remove mutation permissions from the sealed dm-verity keyring"

touch /run/acl-dmverity-keyring.sealed
log "loaded key ${signer_id}, sealed the dm-verity keyring, and removed mutation permissions"
