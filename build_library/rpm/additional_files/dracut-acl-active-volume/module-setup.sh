#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh
#
# dracut module publishing the active A/B volume marker to /run/acl.

check() {
    return 0
}

depends() {
    return 0
}

install() {
    inst_script "${moddir}/acl-active-volume.sh" \
                "/usr/bin/acl-active-volume"

    inst_simple "${moddir}/acl-active-volume.service" \
                "${systemdsystemunitdir}/acl-active-volume.service"

    # Manually enable the unit — dracut does not process [Install] sections.
    mkdir -p "${initdir}/${systemdsystemunitdir}/initrd.target.wants"
    ln -sf "../acl-active-volume.service" \
        "${initdir}/${systemdsystemunitdir}/initrd.target.wants/acl-active-volume.service"
}
