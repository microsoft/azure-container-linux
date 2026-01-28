#!/bin/sh
# Set up /etc as overlay with /usr/share/flatcar/etc as lowerdir.
# Like Flatcar's initrd-setup-root: upperdir=/sysroot/etc, lowerdir=/sysroot/usr/share/flatcar/etc.
# NOTE: Avoid grep/mountpoint - use basic shell and /proc reads instead
set -e

SYSROOT="/sysroot"

echo "etc-overlay: Starting /etc overlay setup"

# In the initrd, /usr is mounted at /sysusr/usr (not /sysroot/usr)
# We need to find where the flatcar etc files actually are
FLATCAR_ETC=""

# Check /sysusr/usr first (initrd layout)
if [ -d "/sysusr/usr/share/flatcar/etc" ]; then
    FLATCAR_ETC="/sysusr/usr/share/flatcar/etc"
    echo "flatcar-etc: Found flatcar etc at /sysusr/usr/share/flatcar/etc"
# Fall back to /sysroot/usr (if bind mounted)
elif [ -d "${SYSROOT}/usr/share/flatcar/etc" ]; then
    FLATCAR_ETC="${SYSROOT}/usr/share/flatcar/etc"
    echo "flatcar-etc: Found flatcar etc at ${SYSROOT}/usr/share/flatcar/etc"
else
    echo "flatcar-etc: /usr/share/flatcar/etc not found in any location, skipping overlay setup"
    echo "  Checked: /sysusr/usr/share/flatcar/etc"
    echo "  Checked: ${SYSROOT}/usr/share/flatcar/etc"
    ls -la /sysusr/usr/share/ 2>/dev/null | head -10 || echo "  Cannot list /sysusr/usr/share/"
    ls -la "${SYSROOT}/usr/share/" 2>/dev/null | head -10 || echo "  Cannot list ${SYSROOT}/usr/share/"
    exit 0
fi

# Check if sysroot is mounted (look for boot dir which should always exist)
if [ ! -d "${SYSROOT}" ] || [ ! -d "${SYSROOT}/boot" ]; then
    echo "etc-overlay: ERROR - ${SYSROOT} not properly mounted"
    ls -la "${SYSROOT}" 2>/dev/null || echo "  Cannot list ${SYSROOT}"
    exit 1
fi
echo "etc-overlay: ${SYSROOT} appears to be mounted"

# Check if overlay is already mounted (read /proc/mounts directly with shell)
if [ -f /proc/mounts ]; then
    while read -r dev mnt fstype opts rest; do
        if [ "$mnt" = "${SYSROOT}/etc" ] && [ "$fstype" = "overlay" ]; then
            echo "etc-overlay: /etc overlay already mounted"
            exit 0
        fi
    done < /proc/mounts
fi

# Ensure /sysroot/etc exists as a directory (it's the upperdir)
if [ -L "${SYSROOT}/etc" ]; then
    echo "etc-overlay: /etc is a symlink, removing it"
    rm -f "${SYSROOT}/etc"
fi
if [ ! -d "${SYSROOT}/etc" ]; then
    echo "etc-overlay: Creating ${SYSROOT}/etc directory"
    mkdir -p "${SYSROOT}/etc"
fi

# Create work directory for overlayfs
mkdir -p "${SYSROOT}/.etc-work"

# Mount the overlay
echo "etc-overlay: Mounting /etc overlay"
echo "  lowerdir=${FLATCAR_ETC}"
echo "  upperdir=${SYSROOT}/etc"
echo "  workdir=${SYSROOT}/.etc-work"

mount -t overlay overlay \
    -o "lowerdir=${FLATCAR_ETC},upperdir=${SYSROOT}/etc,workdir=${SYSROOT}/.etc-work,redirect_dir=on,metacopy=off,noatime" \
    "${SYSROOT}/etc"

echo "etc-overlay: /etc overlay mounted successfully"

# Verify mount
if [ -f /proc/mounts ]; then
    while read -r dev mnt fstype opts rest; do
        if [ "$mnt" = "${SYSROOT}/etc" ] && [ "$fstype" = "overlay" ]; then
            echo "etc-overlay: Verified /etc overlay is active"
        fi
    done < /proc/mounts
fi

# Create /home/core directory structure BEFORE ignition runs
# Ignition needs this to exist so it can write SSH authorized_keys
# The core user has UID/GID 500 (defined in /etc/passwd from the image)
echo "etc-overlay: Creating /home/core directory structure for ignition"

# Create /home directory if it doesn't exist
if [ ! -d "${SYSROOT}/home" ]; then
    echo "etc-overlay: Creating ${SYSROOT}/home"
    mkdir -p "${SYSROOT}/home"
    chmod 755 "${SYSROOT}/home"
fi

# Create /home/core owned by core user (UID/GID 500)
if [ ! -d "${SYSROOT}/home/core" ]; then
    echo "etc-overlay: Creating ${SYSROOT}/home/core"
    mkdir -p "${SYSROOT}/home/core"
    chown 500:500 "${SYSROOT}/home/core"
    chmod 700 "${SYSROOT}/home/core"
fi

# Create .ssh directory structure that ignition expects
if [ ! -d "${SYSROOT}/home/core/.ssh" ]; then
    echo "etc-overlay: Creating ${SYSROOT}/home/core/.ssh"
    mkdir -p "${SYSROOT}/home/core/.ssh"
    chown 500:500 "${SYSROOT}/home/core/.ssh"
    chmod 700 "${SYSROOT}/home/core/.ssh"
fi

# Create authorized_keys.d directory (ignition writes to authorized_keys.d/ignition)
if [ ! -d "${SYSROOT}/home/core/.ssh/authorized_keys.d" ]; then
    echo "etc-overlay: Creating ${SYSROOT}/home/core/.ssh/authorized_keys.d"
    mkdir -p "${SYSROOT}/home/core/.ssh/authorized_keys.d"
    chown 500:500 "${SYSROOT}/home/core/.ssh/authorized_keys.d"
    chmod 700 "${SYSROOT}/home/core/.ssh/authorized_keys.d"
fi

echo "etc-overlay: /home/core directory structure created successfully"
ls -la "${SYSROOT}/home/core/" 2>/dev/null || echo "etc-overlay: Could not list ${SYSROOT}/home/core"
