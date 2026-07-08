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
# The signed policy (PKCS#7) is on the ESP (vfat) at /acl-ipe/acl.pol.p7b,
# placed there by sign_uki_ephemeral.sh (the rootfs is read-only at build time).
# The kernel verifies the policy signature against the .platform keyring (the
# ephemeral UKI-signing cert is enrolled in the UEFI db), so the file's location
# is not security-relevant.
#
# Enforcement mode comes from the ipe.enforce= kernel cmdline (permissive for
# this rollout); this script only loads + activates the policy.
#
# Best-effort: any failure logs and exits 0 so boot is never blocked.

set -uo pipefail

POLICY_NAME="acl_ipe_boot_policy"
IPE_DIR="/sys/kernel/security/ipe"
ESP_LABEL="EFI-SYSTEM"
ESP_MNT="/run/acl-ipe-esp"
POLICY_REL="acl-ipe/acl.pol.p7b"

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
    # Mount the ESP (vfat) read-only to read the signed policy.
    mkdir -p "${ESP_MNT}"
    mounted=0
    if mount -L "${ESP_LABEL}" -o ro "${ESP_MNT}" 2>/dev/null; then
        mounted=1
    elif [[ -e "/dev/disk/by-label/${ESP_LABEL}" ]] \
         && mount -o ro "/dev/disk/by-label/${ESP_LABEL}" "${ESP_MNT}" 2>/dev/null; then
        mounted=1
    fi
    if [[ "${mounted}" -ne 1 ]]; then
        log "Could not mount ESP (label ${ESP_LABEL}); cannot load policy. Skipping."
        exit 0
    fi

    policy_file="${ESP_MNT}/${POLICY_REL}"
    if [[ ! -f "${policy_file}" ]]; then
        log "No policy at ESP:/${POLICY_REL}; nothing to load."
        umount "${ESP_MNT}" 2>/dev/null || true
        exit 0
    fi

    if cat "${policy_file}" > "${IPE_DIR}/new_policy" 2>/dev/null; then
        log "Loaded policy ${POLICY_NAME} from ESP."
    else
        log "Failed to load ${policy_file} (untrusted signature, malformed, or write denied)."
        umount "${ESP_MNT}" 2>/dev/null || true
        exit 0
    fi
    umount "${ESP_MNT}" 2>/dev/null || true
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
