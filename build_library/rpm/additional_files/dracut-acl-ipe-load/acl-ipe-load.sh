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
# The signed policy (PKCS#7) is embedded in the UKI's initramfs at
# /etc/ipe/acl.pol.p7b. The kernel verifies it against the .platform keyring;
# the same ephemeral certificate signs the policy and is enrolled in UEFI db.
#
# Enforcement mode comes from the signed UKI's ipe.enforce= kernel command
# line; this script only loads and activates the policy.
#
# Prototype behavior remains fail-open: any loader failure logs and exits 0.
# "enforcing" controls access decisions after successful policy activation; a
# production rollout still needs an explicit fail-closed or recovery design.

set -uo pipefail

POLICY_NAME="acl_ipe_boot_policy"
IPE_DIR="/sys/kernel/security/ipe"
POLICY_FILE="/etc/ipe/acl.pol.p7b"

log() { echo "acl-ipe-load: $*" >&2; }

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
        log "Loaded policy ${POLICY_NAME} from the signed UKI initramfs."
    else
        log "Failed to load ${POLICY_FILE} (untrusted signature, malformed, or write denied)."
        exit 0
    fi
fi

if [[ -w "${IPE_DIR}/policies/${POLICY_NAME}/active" ]]; then
    if echo 1 > "${IPE_DIR}/policies/${POLICY_NAME}/active" 2>/dev/null; then
        log "Activated policy ${POLICY_NAME} (mode from ipe.enforce= cmdline)."
    else
        log "WARNING: failed to activate ${POLICY_NAME}."
    fi
else
    log "WARNING: active node for ${POLICY_NAME} not found/writable."
fi

exit 0
