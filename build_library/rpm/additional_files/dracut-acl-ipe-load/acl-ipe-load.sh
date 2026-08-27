#!/bin/bash
# Best-effort load and activate the UKI-bound ACL IPE policy during Azure initrd.
# systemd-stub exposes the credential at /.extra/credentials/.

set -uo pipefail

POLICY_NAME="${ACL_IPE_POLICY_NAME:-acl_ipe_boot_policy}"
IPE_DIR="${ACL_IPE_DIR:-/sys/kernel/security/ipe}"
CREDENTIAL_PATH="${ACL_IPE_CREDENTIAL_PATH:-/.extra/credentials/acl-ipe-policy.p7b.cred}"
CMDLINE_FILE="${ACL_IPE_CMDLINE_FILE:-/proc/cmdline}"
SECURITY_PROFILE_HELPER="${ACL_IPE_SECURITY_PROFILE_HELPER:-/usr/lib/acl/acl-node-security-profile.sh}"

log()  { echo "acl-ipe-load: $*" >&2; }
skip() { log "WARNING: $*; continuing boot without activating IPE."; exit 0; }
write_value() {
    local path="$1" value="$2"
    [[ -w "${path}" ]] && printf '%s\n' "${value}" > "${path}" 2>/dev/null
}

if ! cmdline="$(cat "${CMDLINE_FILE}")"; then
    skip "could not read kernel command line from ${CMDLINE_FILE}"
fi

expected_hash=""
token_count=0
for word in ${cmdline}; do
    [[ "${word}" == acl.ipe.policy_sha256=* ]] || continue
    expected_hash="${word#acl.ipe.policy_sha256=}"
    token_count=$((token_count + 1))
done

case "${token_count}" in
    0) log "No acl.ipe.policy_sha256 token; IPE disabled for this image."; exit 0 ;;
    1) ;;
    *) skip "duplicate acl.ipe.policy_sha256 tokens on cmdline (count=${token_count})" ;;
esac

[[ "${expected_hash}" =~ ^[0-9a-f]{64}$ ]] ||
    skip "malformed acl.ipe.policy_sha256 value: ${expected_hash}"
[[ "${expected_hash}" != "0000000000000000000000000000000000000000000000000000000000000000" ]] ||
    skip "acl.ipe.policy_sha256 is all zeros"

[[ -e "${CREDENTIAL_PATH}" ]] || skip "policy credential missing: ${CREDENTIAL_PATH}"
[[ ! -L "${CREDENTIAL_PATH}" ]] || skip "credential must not be a symlink: ${CREDENTIAL_PATH}"
[[ -f "${CREDENTIAL_PATH}" ]] || skip "credential is not a regular file: ${CREDENTIAL_PATH}"
[[ -s "${CREDENTIAL_PATH}" ]] || skip "credential is empty: ${CREDENTIAL_PATH}"

actual_hash="$(sha256sum "${CREDENTIAL_PATH}" | cut -d' ' -f1)"
actual_hash="${actual_hash,,}"
[[ "${actual_hash}" == "${expected_hash}" ]] ||
    skip "credential SHA-256 mismatch: expected=${expected_hash} actual=${actual_hash}"
log "Credential SHA-256 verified: ${expected_hash}"

if [[ ! -e "${IPE_DIR}/new_policy" ]]; then
    mount -t securityfs none /sys/kernel/security 2>/dev/null || true
fi
[[ -e "${IPE_DIR}/new_policy" ]] ||
    skip "IPE securityfs interface missing; kernel does not support IPE"

if compgen -G "${IPE_DIR}/policies/*" >/dev/null; then
    skip "IPE already has a loaded policy; refusing ambiguous state"
fi

cat "${CREDENTIAL_PATH}" > "${IPE_DIR}/new_policy" 2>/dev/null ||
    skip "kernel rejected policy load from ${CREDENTIAL_PATH}"
log "Loaded policy ${POLICY_NAME} into kernel IPE."

[[ -r "${SECURITY_PROFILE_HELPER}" ]] ||
    skip "security profile helper is missing or unreadable: ${SECURITY_PROFILE_HELPER}"
# shellcheck source=/usr/lib/acl/acl-node-security-profile.sh
source "${SECURITY_PROFILE_HELPER}" ||
    skip "could not load security profile helper: ${SECURITY_PROFILE_HELPER}"
declare -F acl_security_profile >/dev/null ||
    skip "security profile helper is missing required functions"
declare -F acl_security_profile_value >/dev/null ||
    skip "security profile helper is missing required functions"

mode="off"
if [[ " ${cmdline} " == *" flatcar.oem.id=azure "* ]]; then
    if security_profile="$(acl_security_profile)"; then
        requested_mode="$(acl_security_profile_value "${security_profile}" "ipe")"
        case "${requested_mode}" in
            off|permissive) mode="${requested_mode}" ;;
            "") ;;
            *) log "Ignoring unrecognized IPE mode '${requested_mode}' from IMDS." ;;
        esac
    else
        log "IMDS unavailable; leaving IPE inactive (policy loaded but not activated)."
    fi
fi
log "Using IPE mode '${mode}'."

if [[ "${mode}" == "off" ]]; then
    log "IPE mode is off; policy loaded but activation skipped."
    exit 0
fi

write_value "${IPE_DIR}/enforce" 0 ||
    skip "failed to set IPE enforce=0 (${mode})"
log "Set IPE enforcement to 0 (${mode}) at runtime."

active_file="${IPE_DIR}/policies/${POLICY_NAME}/active"
write_value "${active_file}" 1 || skip "failed to activate ${POLICY_NAME}"
log "Activated policy ${POLICY_NAME}."

policy_active="$(cat "${active_file}" 2>/dev/null || true)"
[[ "${policy_active}" == "1" ]] ||
    skip "policy ${POLICY_NAME} activation verification failed"
