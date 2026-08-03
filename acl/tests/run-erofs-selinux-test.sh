#!/bin/bash
# Validate EROFS, dm-verity, sysext, and early-runtime SELinux integration.

set -euo pipefail

fail() {
    echo "FAILED: $*" >&2
    exit 1
}

assert_selinux_type() {
    local path=$1
    local expected_type=$2
    local context

    [[ -e "${path}" || -L "${path}" ]] || fail "missing path: ${path}"
    context=$(stat -c '%C' "${path}") || fail "could not read SELinux context for ${path}"
    [[ "${context}" == *":${expected_type}:"* ]] ||
        fail "${path} has context ${context}, expected ${expected_type}"
}

assert_not_untrusted_type() {
    local path=$1
    local context

    [[ -e "${path}" || -L "${path}" ]] || fail "missing path: ${path}"
    context=$(stat -c '%C' "${path}") || fail "could not read SELinux context for ${path}"
    case "${context}" in
        '?'|*':tmpfs_t:'*|*':unlabeled_t:'*)
            fail "${path} has untrusted context ${context}"
            ;;
    esac
}

echo "========================================="
echo "EROFS SELinux Integration Validation"
echo "========================================="

[[ "$(getenforce)" == "Enforcing" ]] || fail "SELinux is not enforcing"

verity_status=$(dmsetup status usr)
[[ "${verity_status##* }" == "V" ]] ||
    fail "/dev/mapper/usr is not in the verified dm-verity state: ${verity_status}"

verity_device=$(readlink -f /dev/mapper/usr)
usr_verity_mounted=false
while IFS= read -r source; do
    if [[ "$(readlink -f "${source}" 2>/dev/null || true)" == "${verity_device}" ]]; then
        usr_verity_mounted=true
        break
    fi
done < <(findmnt -n -o SOURCE /usr)
[[ "${usr_verity_mounted}" == "true" ]] ||
    fail "/usr mount stack does not include /dev/mapper/usr"

assert_selinux_type / root_t
assert_selinux_type /bin bin_t
assert_selinux_type /sbin bin_t
assert_selinux_type /lib lib_t
[[ ! -e /lib64 && ! -L /lib64 ]] || assert_selinux_type /lib64 lib_t
assert_selinux_type /usr usr_t
assert_selinux_type /usr/bin/bash shell_exec_t
assert_selinux_type /usr/bin/systemd-sysusers systemd_sysusers_exec_t
assert_selinux_type /usr/lib/systemd/systemd-journald syslogd_exec_t
assert_selinux_type \
    /usr/lib/systemd/system-generators/systemd-fstab-generator \
    systemd_generator_exec_t
assert_selinux_type /run/log/journal systemd_journal_t
assert_selinux_type /etc/passwd etc_t
assert_selinux_type /etc/machine-id etc_runtime_t
assert_selinux_type /home home_root_t
assert_selinux_type /var var_t

# These assertions intentionally require the systemd v255 sysext SELinux
# backport to be installed in the same validation image.
assert_not_untrusted_type /usr/.systemd-sysext
assert_selinux_type /run/systemd/sysext/meta/usr usr_t
assert_not_untrusted_type /run/systemd/sysext/meta/usr/.systemd-sysext

systemctl is-active --quiet acl-selinux-relabel-journal.service ||
    fail "early SELinux runtime-state relabel service is not active"
systemctl is-active --quiet systemd-journald.service ||
    fail "systemd-journald.service is not active"

systemctl daemon-reload ||
    fail "systemd generator reload failed"

boot_failure_pattern='error while loading shared libraries: .*Permission denied'
boot_failure_pattern+='|systemd-journald.*status=127|generator.*status=127'
boot_failure_pattern+='|failed to open /etc/(crypttab|fstab|integritytab|veritytab): Permission denied'
boot_failure_pattern+='|failed to resolve (user|group).*: Permission denied'
selinux_boot_failures=$(
    journalctl -b --no-pager -o cat |
        grep -Ei "${boot_failure_pattern}" ||
        true
)
if [[ -n "${selinux_boot_failures}" ]]; then
    echo "${selinux_boot_failures}" >&2
    fail "SELinux-related boot failures were detected"
fi

echo "SELinux: enforcing"
echo "/usr: EROFS over verified dm-verity"
echo "/usr SELinux type: usr_t"
echo "systemd-sysext metadata: labeled"
echo "SUCCESS: EROFS SELinux integration is healthy"
