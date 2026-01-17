#!/bin/sh
# Set up /etc as overlay with /usr/share/flatcar/etc as lowerdir
# Like Flatcar's initrd-setup-root: upperdir=/sysroot/etc, lowerdir=/sysroot/usr/share/flatcar/etc
# NOTE: Avoid grep/mountpoint - use basic shell and /proc reads instead
set -e

SYSROOT="/sysroot"

echo "flatcar-etc: Starting /etc overlay setup"

# Check if sysroot has content (simpler than mountpoint command)
if [ ! -d "${SYSROOT}/usr" ]; then
    echo "flatcar-etc: ERROR - ${SYSROOT}/usr not found, sysroot may not be mounted"
    ls -la "${SYSROOT}" 2>/dev/null || echo "  Cannot list ${SYSROOT}"
    exit 1
fi
echo "flatcar-etc: ${SYSROOT} appears to be mounted (found /usr)"

# Check if source directory exists
if [ ! -d "${SYSROOT}/usr/share/flatcar/etc" ]; then
    echo "flatcar-etc: /usr/share/flatcar/etc not found, skipping overlay setup"
    ls -la "${SYSROOT}/usr/share/" 2>/dev/null | head -10 || echo "  Cannot list /usr/share/"
    exit 0
fi
echo "flatcar-etc: Found ${SYSROOT}/usr/share/flatcar/etc"

# Check if overlay is already mounted (read /proc/mounts directly with shell)
if [ -f /proc/mounts ]; then
    while read -r dev mnt fstype opts rest; do
        if [ "$mnt" = "${SYSROOT}/etc" ] && [ "$fstype" = "overlay" ]; then
            echo "flatcar-etc: /etc overlay already mounted"
            exit 0
        fi
    done < /proc/mounts
fi

# Ensure /sysroot/etc exists as a directory (it's the upperdir)
if [ -L "${SYSROOT}/etc" ]; then
    echo "flatcar-etc: /etc is a symlink, removing it"
    rm -f "${SYSROOT}/etc"
fi
if [ ! -d "${SYSROOT}/etc" ]; then
    echo "flatcar-etc: Creating ${SYSROOT}/etc directory"
    mkdir -p "${SYSROOT}/etc"
fi

# Create work directory for overlayfs
mkdir -p "${SYSROOT}/.etc-work"

# Mount the overlay
echo "flatcar-etc: Mounting /etc overlay"
echo "  lowerdir=${SYSROOT}/usr/share/flatcar/etc"
echo "  upperdir=${SYSROOT}/etc"
echo "  workdir=${SYSROOT}/.etc-work"

mount -t overlay overlay \
    -o "lowerdir=${SYSROOT}/usr/share/flatcar/etc,upperdir=${SYSROOT}/etc,workdir=${SYSROOT}/.etc-work,redirect_dir=on,metacopy=off,noatime" \
    "${SYSROOT}/etc"

echo "flatcar-etc: /etc overlay mounted successfully"

# Verify mount
if [ -f /proc/mounts ]; then
    while read -r dev mnt fstype opts rest; do
        if [ "$mnt" = "${SYSROOT}/etc" ] && [ "$fstype" = "overlay" ]; then
            echo "flatcar-etc: Verified /etc overlay is active"
            exit 0
        fi
    done < /proc/mounts
    echo "flatcar-etc: WARNING - overlay mount not found in /proc/mounts"
fi
