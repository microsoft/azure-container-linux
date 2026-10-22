#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Verify the staged IPE signer and selected UKI's credential binding before
# image conversion re-signs the UKI.

set -euo pipefail

CERT_DIR="${1:?usage: verify_ipe_signer_continuity.sh <cert-dir> <artifact-dir> <esp-dir>}"
ARTIFACT_DIR="${2:?usage: verify_ipe_signer_continuity.sh <cert-dir> <artifact-dir> <esp-dir>}"
ESP_DIR="${3:?usage: verify_ipe_signer_continuity.sh <cert-dir> <artifact-dir> <esp-dir>}"
CERT="${CERT_DIR}/uki-signing-ca.pem"
STAGED_POLICY="${ARTIFACT_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred"

verify_attached_cms() {
    local signature="$1"

    openssl smime -verify -inform der -binary \
        -in "${signature}" \
        -nointern -certfile "${CERT}" -noverify \
        -out /dev/null >/dev/null 2>&1
}

[[ -s "${CERT}" ]] || {
    echo "IPE signer certificate is missing: ${CERT}" >&2
    exit 1
}
[[ -s "${STAGED_POLICY}" ]] || {
    echo "Staged IPE policy credential is missing: ${STAGED_POLICY}" >&2
    exit 1
}
verify_attached_cms "${STAGED_POLICY}" || {
    echo "Staged IPE policy is not signed by ${CERT}" >&2
    exit 1
}

config="${ESP_DIR}/loader/loader.conf"
[[ -r "${config}" ]] || {
    echo "IPE UKI loader configuration is missing: ${config}" >&2
    exit 1
}
uki_name=""
while read -r key value extra; do
    [[ "${key}" == "default" ]] || continue
    if [[ -n "${uki_name}" || -n "${extra:-}" ||
        ! "${value:-}" =~ ^[A-Za-z0-9_.+-]+[.]efi$ ]]; then
        echo "IPE verification requires exactly one literal UKI default in ${config}" >&2
        exit 1
    fi
    uki_name="${value}"
done < "${config}"
[[ -n "${uki_name}" ]] || {
    echo "No UKI default found in ${config}" >&2
    exit 1
}

uki="${ESP_DIR}/EFI/Linux/${uki_name}"
installed="${uki}.extra.d/acl-ipe-policy.p7b.cred"
[[ -f "${installed}" && ! -L "${installed}" ]] &&
    cmp -s -- "${STAGED_POLICY}" "${installed}" || {
        echo "Selected UKI credential differs from staged policy: ${installed}" >&2
        exit 1
    }

cmdline="$(ukify inspect "${uki}" --json=short --section=.cmdline:text |
    jq -er '.[".cmdline"].text | select(type == "string" and (contains("\u0000") | not))')" || {
        echo "Cannot read the selected UKI command line: ${uki}" >&2
        exit 1
    }
read -r -a tokens <<< "${cmdline//$'\n'/ }"
expected_hash="$(sha256sum "${STAGED_POLICY}" | cut -d' ' -f1)"
hashes=()
for token in "${tokens[@]}"; do
    if [[ "${token}" == acl.ipe.policy_sha256=* ]]; then
        hashes+=("${token#*=}")
    fi
done
if [[ "${#hashes[@]}" -ne 1 || "${hashes[0]:-}" != "${expected_hash}" ]]; then
    echo "Selected UKI must bind exactly one matching IPE policy SHA-256: ${uki}" >&2
    exit 1
fi

shopt -s nullglob nocaseglob
for addon in "${uki}.extra.d"/*.addon.efi "${ESP_DIR}/loader/addons"/*.addon.efi; do
    [[ -f "${addon}" && ! -L "${addon}" ]] || {
        echo "IPE UKI addon must be a regular file: ${addon}" >&2
        exit 1
    }
    addon_json="$(ukify inspect "${addon}" --json=short --section=.cmdline:text)" || {
        echo "Cannot inspect IPE UKI addon: ${addon}" >&2
        exit 1
    }
    addon_cmdline="$(jq -er '
        if type != "object" then error("invalid addon inspection")
        elif has(".cmdline") then
            .[".cmdline"].text | select(type == "string" and (contains("\u0000") | not))
        else "" end
    ' <<< "${addon_json}")" || {
        echo "Cannot read IPE UKI addon command line: ${addon}" >&2
        exit 1
    }
    read -r -a addon_tokens <<< "${addon_cmdline//$'\n'/ }"
    for token in "${addon_tokens[@]}"; do
        if [[ "${token}" == acl.ipe.policy_sha256=* ]]; then
            echo "IPE UKI addon must not set acl.ipe.policy_sha256: ${addon}" >&2
            exit 1
        fi
    done
done
