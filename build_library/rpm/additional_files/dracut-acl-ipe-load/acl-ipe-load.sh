#!/bin/bash
# Load and activate the signed ACL IPE policy before switch_root, while SELinux
# still permits writes to securityfs. IPE is off by default; the Azure IMDS
# profile can enable permissive mode, but not enforcing mode.
#
# Loader failures are fail-open: log the error and continue booting without IPE.

set -uo pipefail

POLICY_NAME="${ACL_IPE_POLICY_NAME:-acl_ipe_boot_policy}"
IPE_DIR="${ACL_IPE_DIR:-/sys/kernel/security/ipe}"
POLICY_FILE="${ACL_IPE_POLICY_FILE:-/sysroot/usr/lib/ipe/acl.pol.p7b}"
CMDLINE_FILE="${ACL_IPE_CMDLINE_FILE:-/proc/cmdline}"
SECURITY_PROFILE_HELPER="${ACL_IPE_SECURITY_PROFILE_HELPER:-/usr/lib/acl/acl-node-security-profile.sh}"

log() { echo "acl-ipe-load: $*" >&2; }

source "${SECURITY_PROFILE_HELPER}"

cmdline="$(cat "${CMDLINE_FILE}")"
mode="off"
mode_source="default"
if [[ " ${cmdline} " == *" flatcar.oem.id=azure "* ]]; then
    if security_profile="$(acl_security_profile)"; then
        requested_mode="$(acl_security_profile_value "${security_profile}" "ipe")"
        case "${requested_mode}" in
            off|permissive)
                mode="${requested_mode}"
                mode_source="acl-node-security-profile"
                ;;
            "")
                ;;
            *)
                log "Ignoring unrecognized acl-node-security-profile ipe mode '${requested_mode}'."
                ;;
        esac
    else
        log "IMDS unavailable; leaving IPE off."
    fi
fi
log "Using IPE mode '${mode}' from ${mode_source}."

if [[ "${mode}" == "off" ]]; then
    log "IPE mode is off; policy activation skipped."
    exit 0
fi

# securityfs exposes the IPE nodes; mount it if it is not already.
if [[ ! -e "${IPE_DIR}/new_policy" ]]; then
    mount -t securityfs none /sys/kernel/security 2>/dev/null || true
fi
if [[ ! -e "${IPE_DIR}/new_policy" ]]; then
    log "IPE securityfs interface missing; IPE not enabled in kernel. Skipping."
    exit 0
fi

if [[ -d "${IPE_DIR}/policies/${POLICY_NAME}" ]]; then
    log "Policy ${POLICY_NAME} already present; ensuring it is active."
else
    if [[ ! -f "${POLICY_FILE}" ]]; then
        log "No signed policy at ${POLICY_FILE}; nothing to load."
        exit 0
    fi

    if cat "${POLICY_FILE}" > "${IPE_DIR}/new_policy" 2>/dev/null; then
        log "Loaded policy ${POLICY_NAME} from verified /usr."
    else
        log "Failed to load ${POLICY_FILE} (untrusted signature, malformed, or write denied)."
        exit 0
    fi
fi

if [[ ! -w "${IPE_DIR}/enforce" ]] ||
    ! echo 0 > "${IPE_DIR}/enforce" 2>/dev/null; then
    log "WARNING: failed to set IPE mode to ${mode}."
    exit 0
fi
log "Set IPE enforcement to 0 (${mode}) at runtime."

active_file="${IPE_DIR}/policies/${POLICY_NAME}/active"
if [[ ! -w "${active_file}" ]] || ! echo 1 > "${active_file}" 2>/dev/null; then
    log "WARNING: failed to activate ${POLICY_NAME}."
    exit 0
fi
log "Activated policy ${POLICY_NAME}."

policy_active="$(cat "${active_file}" 2>/dev/null || true)"
if [[ "${policy_active}" != "1" ]]; then
    log "WARNING: policy ${POLICY_NAME} is not active."
    exit 0
fi
