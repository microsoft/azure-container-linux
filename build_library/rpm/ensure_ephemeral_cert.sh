#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Create or validate the per-build test certificate shared by the IPE policy,
# /usr root-hash signature, and UKI. Enrolling this certificate in UEFI db
# makes it available to the kernel through the .platform keyring.

set -euo pipefail

CERT_DIR="${1:?usage: ensure_ephemeral_cert.sh <dir> [create|require]}"
MODE="${2:-create}"
KEY="${CERT_DIR}/ca.key"
CERT="${CERT_DIR}/uki-signing-ca.pem"

case "${MODE}" in
    create|require) ;;
    *)
        echo "Invalid certificate mode '${MODE}' (expected create or require)" >&2
        exit 1
        ;;
esac

validate_pair() {
    local pair_key="${1:-${KEY}}" pair_cert="${2:-${CERT}}"
    local key_digest cert_digest

    key_digest="$(
        openssl pkey -in "${pair_key}" -pubout -outform DER 2>/dev/null |
            sha256sum |
            cut -d' ' -f1
    )" || return 1
    cert_digest="$(
        openssl x509 -in "${pair_cert}" -pubkey -noout 2>/dev/null |
            openssl pkey -pubin -outform DER 2>/dev/null |
            sha256sum |
            cut -d' ' -f1
    )" || return 1

    [[ -n "${key_digest}" && "${key_digest}" == "${cert_digest}" ]]
}

if [[ -e "${KEY}" || -e "${CERT}" ]]; then
    if [[ ! -s "${KEY}" || ! -s "${CERT}" ]]; then
        echo "Incomplete ephemeral certificate pair in ${CERT_DIR}" >&2
        exit 1
    fi
    if ! validate_pair; then
        echo "Ephemeral certificate and private key do not match in ${CERT_DIR}" >&2
        exit 1
    fi
    exit 0
fi

if [[ "${MODE}" == "require" ]]; then
    echo "Required ephemeral certificate pair is missing from ${CERT_DIR}" >&2
    exit 1
fi

mkdir -p "$(dirname "${CERT_DIR}")"
WORK_DIR="$(mktemp -d "${CERT_DIR}.tmp.XXXXXX")"
cleanup() {
    [[ -z "${WORK_DIR}" ]] || rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT
openssl req -x509 \
    -newkey rsa:2048 \
    -days 1 \
    -noenc \
    -keyout "${WORK_DIR}/ca.key" \
    -out "${WORK_DIR}/uki-signing-ca.pem" \
    -subj "/CN=ACL Ephemeral Signing $(date +%Y%m%d%H%M%S)" \
    -sha256 \
    -addext "basicConstraints=CA:FALSE" \
    -addext "extendedKeyUsage=codeSigning"
chmod 600 "${WORK_DIR}/ca.key"
validate_pair "${WORK_DIR}/ca.key" "${WORK_DIR}/uki-signing-ca.pem"

rmdir "${CERT_DIR}" 2>/dev/null || true
if ! mv -T "${WORK_DIR}" "${CERT_DIR}" 2>/dev/null; then
    if [[ -s "${KEY}" && -s "${CERT}" ]] && validate_pair; then
        exit 0
    fi
    echo "Could not publish ephemeral certificate pair to ${CERT_DIR}" >&2
    exit 1
fi
WORK_DIR=""
