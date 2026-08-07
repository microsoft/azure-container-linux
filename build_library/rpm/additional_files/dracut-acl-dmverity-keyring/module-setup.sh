#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

# Dracut defines moddir, initdir, and systemdsystemunitdir before sourcing this file.
# shellcheck disable=SC2154
install() {
    inst_multiple awk base64 cat grep keyctl mkdir mktemp modprobe rm sha256sum touch wc

    inst_script "${moddir}/acl-dmverity-keyring-load.sh" \
                "/usr/bin/acl-dmverity-keyring-load"

    inst_simple "${moddir}/acl-dmverity-keyring-load.service" \
                "${systemdsystemunitdir}/acl-dmverity-keyring-load.service"
    inst_simple "${moddir}/osguard-signer.der.b64" \
                "/usr/lib/acl/dmverity-keyring/osguard-signer.der.b64"
    inst_simple "${moddir}/seal-probe.der.b64" \
                "/usr/lib/acl/dmverity-keyring/seal-probe.der.b64"
    inst_simple "${moddir}/certs.sha256" \
                "/usr/lib/acl/dmverity-keyring/certs.sha256"

    # This is a boot requirement, not an optional initrd helper. Failure must
    # prevent the initrd from proceeding to the verity-backed root filesystem.
    mkdir -p "${initdir}/${systemdsystemunitdir}/initrd.target.requires"
    ln -sf "../acl-dmverity-keyring-load.service" \
        "${initdir}/${systemdsystemunitdir}/initrd.target.requires/acl-dmverity-keyring-load.service"
}

installkernel() {
    instmods dm_verity
}
