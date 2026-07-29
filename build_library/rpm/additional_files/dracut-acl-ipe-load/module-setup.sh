#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

install() {
    # acl-ipe-load mounts securityfs if the initramfs has not mounted it yet.
    inst_multiple -o mount

    inst_script "${moddir}/acl-ipe-load.sh" \
                "/usr/bin/acl-ipe-load"

    inst_simple "${moddir}/acl-ipe-load.service" \
                "${systemdsystemunitdir}/acl-ipe-load.service"

    # Manually enable the unit -- dracut does not process [Install] sections.
    mkdir -p "${initdir}/${systemdsystemunitdir}/initrd.target.wants"
    ln -sf "../acl-ipe-load.service" \
        "${initdir}/${systemdsystemunitdir}/initrd.target.wants/acl-ipe-load.service"
}
