#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

install() {
    # acl-ipe-load needs sha256sum for credential verification and mount for
    # securityfs.
    inst_multiple -o mkdir mount mv cat sha256sum cut

    inst_simple "${moddir}/acl-node-security-profile.sh" \
                "/usr/lib/acl/acl-node-security-profile.sh"

    inst_script "${moddir}/acl-ipe-load.sh" \
                "/usr/bin/acl-ipe-load"

    inst_simple "${moddir}/acl-ipe-load.service" \
                "${systemdsystemunitdir}/acl-ipe-load.service"

    # Manually enable the unit -- dracut does not process [Install] sections.
    mkdir -p "${initdir}/${systemdsystemunitdir}/initrd.target.wants"
    ln -sf "../acl-ipe-load.service" \
        "${initdir}/${systemdsystemunitdir}/initrd.target.wants/acl-ipe-load.service"
}
