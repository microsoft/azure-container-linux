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
    inst_script "$moddir/etc-overlay.sh" "/usr/sbin/etc-overlay"

    # Install the systemd service that runs in the initrd
    inst_simple "$moddir/initrd-setup-etc-overlay.service" \
        "$systemdsystemunitdir/initrd-setup-etc-overlay.service"

    # Enable it before switch-root (for non-ignition boots)
    mkdir -p "$initdir/$systemdsystemunitdir/initrd-switch-root.target.requires"
    ln -sf "../initrd-setup-etc-overlay.service" \
        "$initdir/$systemdsystemunitdir/initrd-switch-root.target.requires/initrd-setup-etc-overlay.service"

    # Also enable it for ignition-complete.target (so it runs during ignition boot flow)
    mkdir -p "$initdir/$systemdsystemunitdir/ignition-complete.target.wants"
    ln -sf "../initrd-setup-etc-overlay.service" \
        "$initdir/$systemdsystemunitdir/ignition-complete.target.wants/initrd-setup-etc-overlay.service"

    # Create drop-in to make ignition-files.service depend on our /etc overlay
    mkdir -p "$initdir/$systemdsystemunitdir/ignition-files.service.d"
    cat > "$initdir/$systemdsystemunitdir/ignition-files.service.d/10-etc-overlay.conf" <<EOF
[Unit]
# Ensure /etc overlay is set up before ignition tries to write to /sysroot/etc
After=initrd-setup-etc-overlay.service
Wants=initrd-setup-etc-overlay.service
EOF

    # Install dummy setfiles for SELinux-disabled systems
    # Ignition calls setfiles even with SELINUX=disabled, this no-op prevents errors
    inst_script "$moddir/setfiles" "/usr/sbin/setfiles"

    # Install commands needed by etc-overlay.sh
    # mount/umount for overlay, mkdir/chmod/chown for /home/core setup
    inst_multiple -o mount umount mkdir cp blkid sleep chmod chown ls
}
