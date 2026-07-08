#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

install() {
    # mount/blkid are used to find + mount the ESP (by label) to read the policy.
    inst_multiple -o mount umount blkid findfs

    inst_script "${moddir}/acl-ipe-load.sh" \
                "/usr/bin/acl-ipe-load"

    inst_simple "${moddir}/acl-ipe-load.service" \
                "${systemdsystemunitdir}/acl-ipe-load.service"

    # Manually enable the unit -- dracut does not process [Install] sections.
    mkdir -p "${initdir}/${systemdsystemunitdir}/initrd.target.wants"
    ln -sf "../acl-ipe-load.service" \
        "${initdir}/${systemdsystemunitdir}/initrd.target.wants/acl-ipe-load.service"
}

installkernel() {
    # The signed policy lives on the vfat ESP; ensure the initramfs can mount it.
    instmods vfat nls_cp437 nls_ascii nls_iso8859-1
}
