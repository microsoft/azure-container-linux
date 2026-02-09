#!/bin/bash

set -euo pipefail

rootfs="${1}"

to_delete=(
    /usr/include
    /usr/lib/debug
    /usr/share/gdb
    /usr/lib64/pkgconfig
)

rm -rf "${to_delete[@]/#/${rootfs}}"

ln -sf /usr/bin/true "${rootfs}/usr/bin/eject"

# At runtime we need the agent to write systemd.service to /etc but during
# package creation it needs to be /usr/lib. waagent uses the same function in
# both cases, so mangle manually.
mkdir -p "${rootfs}"/usr/lib/systemd/system
cp -a "${rootfs}"/{etc,usr/lib}/systemd/system/.

# Remove test stuff from python - it's quite large.
for p in "${rootfs}"/usr/lib/python*; do
    if [[ ! -d ${p} ]]; then
        continue
    fi
    # find directories named tests or test and remove them (-prune
    # avoids searching below those directories)
    find "${p}" \( -name tests -o -name test \) -type d -prune -exec rm -rf '{}' '+'
done

# Create waagent sub-dir if it doesn't exist
mkdir -p "${rootfs}/usr/lib/waagent"
# Move waagent.conf out of /etc to /usr/lib to preserve it in sysext
if [[ -f "${rootfs}/etc/waagent.conf" ]]; then
    mv "${rootfs}/etc/waagent.conf" "${rootfs}/usr/lib/waagent/waagent.conf"
fi

# Patch waagent service file by removing ConditionPathExists line
if [[ -f "${rootfs}/usr/lib/systemd/system/waagent.service" ]]; then
    sed -i \
        '/^ConditionPathExists=/d' \
        "${rootfs}/usr/lib/systemd/system/waagent.service"
fi

# Patch waagent service file to create symlink back to /etc/waagent.conf at ExecStartPre
if [[ -f "${rootfs}/usr/lib/systemd/system/waagent.service" ]]; then
    # Insert ExecStartPre lines after the [Service] header
    sed -i \
        '/^\[Service\]$/a ExecStartPre=/bin/bash -c '\''if [[ ! -e /etc/waagent.conf ]]; then ln -sf /usr/lib/waagent/waagent.conf /etc/waagent.conf; fi'\''' \
        "${rootfs}/usr/lib/systemd/system/waagent.service"

    sed -i \
        '/^\[Service\]$/a ExecStartPre=/bin/bash -c '\''if [[ ! -e /oem/waagent.conf ]]; then ln -sf /etc/waagent.conf /oem/waagent.conf; fi'\''' \
        "${rootfs}/usr/lib/systemd/system/waagent.service"
fi

# Create chrony sub-dir if it doesn't exist
mkdir -p "${rootfs}/usr/lib/chrony"
# Move chrony.conf out of /etc to /usr/lib to preserve it in sysext
if [[ -f "${rootfs}/etc/chrony.conf" ]]; then
    mv "${rootfs}/etc/chrony.conf" "${rootfs}/usr/lib/chrony/chrony.conf"
fi

# Move chrony environment file out of /etc to /usr/lib to preserve it in sysext
if [[ -f "${rootfs}/etc/sysconfig/chronyd" ]]; then
    mv "${rootfs}/etc/sysconfig/chronyd" "${rootfs}/usr/lib/chrony/chronyd"
fi

# Move NTP keys file out of /etc to /usr/lib to preserve it in sysext
if [[ -f "${rootfs}/etc/chrony.keys" ]]; then
    mv "${rootfs}/etc/chrony.keys" "${rootfs}/usr/lib/chrony/chrony.keys"
fi

# Patch chrony service file for chronyd to point to new environment file and config
if [[ -f "${rootfs}/usr/lib/systemd/system/chronyd.service" ]]; then
    # Update EnvironmentFile path
    sed -i \
        's|^EnvironmentFile=-/etc/sysconfig/chronyd$|EnvironmentFile=-/usr/lib/chrony/chronyd|' \
        "${rootfs}/usr/lib/systemd/system/chronyd.service"

    # Update ExecStart to use -f /usr/lib/chrony/chrony.conf
    sed -i \
        's|^ExecStart=/usr/sbin/chronyd $OPTIONS$|ExecStart=/usr/sbin/chronyd -f /usr/lib/chrony/chrony.conf $OPTIONS|' \
        "${rootfs}/usr/lib/systemd/system/chronyd.service"
fi

# Remove the "dangling" os-release file because sysexts are not allowed to have
# a /usr/lib/os-release file. Probably brought over by azurelinux-release dependency.
os_release="${rootfs}/usr/lib/os-release"
if [[ -f "${os_release}" ]]; then
    echo "  Removing ${os_release}"
    rm -f "${os_release}"
fi
