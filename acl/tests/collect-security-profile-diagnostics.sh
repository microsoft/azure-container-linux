#!/bin/sh
# Read-only guest snapshot, usable over SSH or Azure Run Command.
set -u

collect() {
    printf '\n=== %s ===\n' "$*"
    timeout --signal=TERM --kill-after=1s 5s "$@"
    status=$?
    printf '[exit=%s]\n' "$status"
    if [ "$status" -ne 0 ]; then
        printf 'WARNING: diagnostic command failed or was unavailable\n'
    fi
}

for boot in -1 0; do
    collect journalctl --no-pager -b "$boot" -n 150 \
        -u sshd.service -u sshd.socket -u systemd-networkd.service \
        -u acl-selinux-toggle.service -u acl-ipe-load.service
    collect journalctl --no-pager -b "$boot" -n 100 \
        --grep 'avc:|USER_AVC|SELINUX_ERR|IPE_ACCESS|audit.*(backlog|lost)|panic|Call trace|BUG:'
done

collect ls -ldZ /etc/ssh /etc/ssh/sshd_config /run/sshd /home
collect find /home -maxdepth 3 \( -name .ssh -o -name authorized_keys \) \
    -exec ls -ldZ '{}' +
collect auditctl -s

# Keep current state last: Azure action Run Command returns only the output tail.
collect date -u
collect uname -a
collect cat /proc/sys/kernel/random/boot_id /proc/cmdline
collect getenforce
collect cat /etc/selinux/config
collect cat /sys/kernel/security/ipe/enforce
for policy in /sys/kernel/security/ipe/policies/*; do
    if [ -d "$policy" ]; then
        collect cat "$policy/name" "$policy/active"
    fi
done
collect cat /run/acl/node-security-profile
collect systemctl --no-pager --failed
collect systemctl show sshd.service -p ActiveState -p SubState -p Result -p ExecMainStatus
collect ip -brief address
collect ip route
collect ss -lntp
collect journalctl --no-pager -b -u sshd.service -n 10
collect journalctl --no-pager -b -n 10 --grep 'avc:|USER_AVC|SELINUX_ERR'
