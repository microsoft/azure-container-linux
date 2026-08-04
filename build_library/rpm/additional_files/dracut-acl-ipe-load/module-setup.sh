#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

# Dracut defines moddir, initdir, and systemdsystemunitdir before sourcing this file.
# shellcheck disable=SC2154
install() {
    inst_multiple -o mount umount findfs

    inst_script "${moddir}/acl-ipe-load.sh" \
                "/usr/bin/acl-ipe-load"

    inst_simple "${moddir}/acl-ipe-load.service" \
                "${systemdsystemunitdir}/acl-ipe-load.service"

    mkdir -p "${initdir}/${systemdsystemunitdir}/initrd.target.wants"
    ln -sf "../acl-ipe-load.service" \
        "${initdir}/${systemdsystemunitdir}/initrd.target.wants/acl-ipe-load.service"
}

installkernel() {
    instmods vfat nls_cp437 nls_ascii nls_iso8859-1
}
