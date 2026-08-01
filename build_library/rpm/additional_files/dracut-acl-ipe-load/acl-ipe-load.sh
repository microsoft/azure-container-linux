#!/bin/bash
# Load + activate the ACL IPE (Integrity Policy Enforcement) policy in the
# initramfs, BEFORE switch_root.
#
# Why run in the initrd: once the real root's SELinux policy is loaded and
# enforcing, writing /sys/kernel/security/ipe/new_policy requires the SELinux
# `mac_admin` permission and is denied (EPERM) for the loader's domain. In the
# initrd SELinux is not yet loaded, so the CAP_MAC_ADMIN write succeeds. This
# mirrors how 99acl-selinux-toggle runs before switch_root.
#
# The signed policy (PKCS#7) is stored on verified /usr and read through the
# initramfs's /sysroot mount. The kernel verifies it against the .platform
# keyring; the same ephemeral certificate signs the UKI, policy, and /usr
# dm-verity root hash and is enrolled in UEFI db.
#
# The policy is inactive by default. On Azure,
# acl-node-security-profile=ipe=permissive|enforcing selects the mode for this
# boot. The tag is read from IMDS before switch_root.
#
# Prototype behavior remains fail-open: any loader failure logs and exits 0.
# "enforcing" controls access decisions after successful policy activation; a
# production rollout still needs an explicit fail-closed or recovery design.

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
            off|permissive|enforcing)
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

case "${mode}" in
    permissive) enforce_value=0 ;;
    enforcing) enforce_value=1 ;;
esac
if [[ -w "${IPE_DIR}/enforce" ]]; then
    if echo "${enforce_value}" > "${IPE_DIR}/enforce" 2>/dev/null; then
        log "Set IPE enforcement to ${enforce_value} (${mode}) at runtime."
    else
        log "WARNING: failed to set IPE mode to ${mode}."
        exit 0
    fi
else
    log "WARNING: IPE enforcement node not found/writable."
    exit 0
fi

active_file="${IPE_DIR}/policies/${POLICY_NAME}/active"
if [[ -w "${active_file}" ]]; then
    if echo 1 > "${active_file}" 2>/dev/null; then
        log "Activated policy ${POLICY_NAME}."
    else
        log "WARNING: failed to activate ${POLICY_NAME}."
    fi
else
    log "WARNING: active node for ${POLICY_NAME} not found/writable."
fi

policy_active=""
if [[ -r "${active_file}" ]]; then
    read -r policy_active < "${active_file}" || true
fi
if [[ "${policy_active}" != "1" ]]; then
    log "WARNING: policy ${POLICY_NAME} is not active."
    exit 0
fi

exit 0
