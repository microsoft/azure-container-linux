#!/bin/bash
# Validate the dedicated dm-verity verification keyring on a booted ACL image.

set -euo pipefail

readonly KEYRING="%:.dm-verity"
readonly SIGNER_DESCRIPTION="acl-osguard-signer"

if ! grep -Fqw "dm_verity.keyring_unsealed=1" /proc/cmdline; then
    echo "SKIPPED: dm-verity keyring provisioning is disabled for this image"
    exit 0
fi

command -v keyctl >/dev/null
[[ -r /sys/module/dm_verity/parameters/keyring_unsealed ]]

keyring_unsealed=$(</sys/module/dm_verity/parameters/keyring_unsealed)
[[ "${keyring_unsealed}" == "Y" || "${keyring_unsealed}" == "1" ]]

keyctl list "${KEYRING}"
key_ids=$(keyctl rlist "${KEYRING}")
[[ "$(wc -w <<< "${key_ids}")" == "1" ]]
signer_id=$(awk 'NF { print $1; exit }' <<< "${key_ids}")
keyctl describe "${signer_id}" |
    grep -Fq "asymmetric: ${SIGNER_DESCRIPTION}"

# The static verifier checks that the signer survived switch-root and that a
# valid probe certificate is rejected after sealing.
systemctl start acl-dmverity-keyring-verify.service
[[ -f /run/acl-dmverity-keyring.verified ]]

echo "SUCCESS: dm-verity keyring contains the expected signer and is sealed"
