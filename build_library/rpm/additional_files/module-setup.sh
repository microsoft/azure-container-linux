#!/bin/bash

check() {
    # Always include this module - we're building for RPM mode
    # The runtime check is done by the service itself via ConditionPathExists
    return 0
}

depends() {
    echo "systemd"
    return 0
}

install() {
    # Install the setup script that will be called by the systemd service
    inst_script "$moddir/flatcar-etc-overlay.sh" "/usr/sbin/flatcar-etc-overlay"

    # Install the systemd service that runs in the initrd
    inst_simple "$moddir/initrd-setup-etc-overlay.service" \
        "$systemdsystemunitdir/initrd-setup-etc-overlay.service"

    # Enable it before switch-root
    mkdir -p "$initdir/$systemdsystemunitdir/initrd-switch-root.target.requires"
    ln -sf "../initrd-setup-etc-overlay.service" \
        "$initdir/$systemdsystemunitdir/initrd-switch-root.target.requires/initrd-setup-etc-overlay.service"

    # Install mount command if not already present
    inst_multiple -o mount umount mkdir cp
}
