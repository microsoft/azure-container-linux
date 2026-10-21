#!/bin/bash
# SPDX-License-Identifier: MIT
# Run as root inside the diagnostic ACL VM, never change its IPE/SELinux modes.
set -euo pipefail
fail() { echo "FAILED: $*" >&2; exit 1; }

prepare_usr_layers() {
    local options lowerdir layer extension device backing matches
    options="$(findmnt -rn -T /usr -t overlay -o OPTIONS)"
    [[ "$(findmnt -rn -T /usr -t overlay -o SOURCE)" == sysext ]] ||
        fail "expected the systemd-sysext /usr overlay"
    [[ ",$options," == *,ro,* && ",$options," != *,upperdir=* ]] ||
        fail "/usr overlay is not read-only"
    usr_mount_options="$options"
    lowerdir="$(sed -n 's/.*lowerdir=\([^,]*\).*/\1/p' <<< "$options")"
    [[ "$lowerdir" == /run/systemd/sysext/meta/usr:*:/usr ]] ||
        fail "unrecognized /usr lower layers: $lowerdir"
    IFS=: read -ra layers <<< "$lowerdir"
    for layer in "${layers[@]:1:${#layers[@]}-2}"; do
        [[ "$layer" =~ ^/run/systemd/sysext/extensions/([a-zA-Z0-9_-]+)/usr$ ]] ||
            fail "unrecognized sysext layer: $layer"
        extension="${BASH_REMATCH[1]}"
        matches=()
        while read -r device backing; do
            backing="${backing##*/}"
            if [[ "$backing" == "$extension.raw" ||
                  "$backing" == "$extension"-*.raw ]]; then
                matches+=("$device")
            fi
        done < <(losetup --list --noheadings --output NAME,BACK-FILE)
        [[ ${#matches[@]} == 1 ]] || fail "$extension: expected one backing loop device"
        [[ "$(blockdev --getro "${matches[0]}")" == 1 ]] ||
            fail "$extension: writable loop device"
        mkdir "$work/$extension"
        mount -o ro,nosuid,nodev,noexec "${matches[0]}" "$work/$extension"
        mounted+=("$work/$extension")
        extension_roots+=("$work/$extension")
    done
    [[ ${#extension_roots[@]} -gt 0 ]] || fail "no sysext layers discovered"
}

# A path prefix is not provenance. Only accept the first visible sysext file,
# with the same bytes and backing inode as the denied read-only overlay file.
expected_sysext_denial() {
    local path=$1 device=$2 inode=$3 canonical root candidate resolved
    [[ "$device" == overlay && "$inode" =~ ^[0-9]+$ ]] || return 1
    canonical="$(readlink -f -- "$path")" || return 1
    [[ "$canonical" == /usr/* && "$canonical" != */../* ]] || return 1
    for root in "${extension_roots[@]}"; do
        candidate="$root$canonical"
        if [[ -e "$candidate" || -L "$candidate" ]]; then
            resolved="$(readlink -f -- "$candidate")" || return 1
            [[ "$resolved" == "$root/usr/"* && -f "$resolved" ]] || return 1
            [[ "$(stat -Lc '%i' -- "$resolved")" == "$inode" ]] || return 1
            cmp -s -- "$resolved" "$canonical" || return 1
            printf 'EXPECTED SYSEXT DENIAL source=%s path=%s inode=%s\n' \
                "${root##*/}" "$path" "$inode"
            return 0
        fi
    done
    return 1
}

check_usr_denials() {
    local record path device inode
    while IFS= read -r record; do
        [[ "$record" == *"ipe_op=EXECUTE "* && "$record" == *"action=DENY"* ]] || continue
        [[ "$record" =~ path=\"([^\"]+)\" ]] || fail "unparseable denied path: $record"
        path="${BASH_REMATCH[1]}"
        case "$path" in /usr/*|/lib/*|/lib64/*) ;; *) continue ;; esac
        [[ "$record" =~ dev=\"([^\"]+)\" ]] || fail "missing denied device: $record"
        device="${BASH_REMATCH[1]}"
        [[ "$record" =~ [[:space:]]ino=([0-9]+)([[:space:]]|$) ]] ||
            fail "missing denied inode: $record"
        inode="${BASH_REMATCH[1]}"
        expected_sysext_denial "$path" "$device" "$inode" ||
            fail "base /usr or unclassified denial: $record"
    done
}

main() {
[[ "$(uname -r)" == "6.6.157.1-1.btrfsipe1.azl3" ]] || fail "wrong kernel"
[[ "$(getenforce)" == Enforcing ]] || fail "SELinux must be enforcing"
[[ -x /usr/sbin/auditctl ]] || fail "diagnostic image is missing /usr/sbin/auditctl"
ipe=/sys/kernel/security/ipe
policy="$ipe/policies/acl_ipe_boot_policy"
[[ "$(cat "$ipe/enforce")" == 0 && "$(cat "$policy/active")" == 1 ]] ||
    fail "expected active IPE audit policy"
grep -Fxq 'DEFAULT op=EXECUTE action=DENY' "$policy/policy" || fail "missing default deny"
grep -Fxq 'op=EXECUTE dmverity_signature=TRUE action=ALLOW' "$policy/policy" ||
    fail "missing signed dm-verity rule"
if grep -q dmverity_roothash= "$policy/policy"; then
    fail "root-hash allow rule would mask the regression"
fi
grep -q 'ipe.success_audit=1' /proc/cmdline || fail "positive auditing is required"
grep -q 'root-hash-signature=' /proc/cmdline || fail "missing root signature"
dmsetup table usr | grep -qw root_hash_sig_key_desc || fail "unsigned /usr dm-verity mapping"
verity_device="$(readlink -f /dev/mapper/usr)"
backed=false
while read -r source; do
    if [[ "$(readlink -f "${source%%\[*}")" == "$verity_device" ]]; then
        backed=true
    fi
done < <(findmnt -rn -t btrfs -o SOURCE)
[[ "$backed" == true ]] || fail "Btrfs is not backed by /dev/mapper/usr"

work="$(mktemp -d /var/tmp/btrfs-ipe-audit.XXXXXX)"
declare -ga mounted=() extension_roots=()
cleanup() {
    local i
    for ((i=${#mounted[@]}-1; i>=0; i--)); do
        umount "${mounted[i]}" || { echo "FAILED: unmount ${mounted[i]}" >&2; return 1; }
        rmdir "${mounted[i]}"
    done
    rm -f "$work/untrusted"
    rmdir "$work"
}
trap cleanup EXIT
prepare_usr_layers
declare -a pids=() names=()
probe() {
    local name=$1 pid
    shift
    pid="$(bash -c 'echo "$$"; exec "$@" >/dev/null' -- "$@")" ||
        fail "$name did not execute"
    [[ "$pid" =~ ^[0-9]+$ ]] || fail "invalid probe PID"
    names+=("$name")
    pids+=("$pid")
}
probe true /usr/bin/true
probe ls /usr/bin/ls /usr
probe bash /usr/bin/bash -c 'exit 0'
negative="$work/untrusted"
cp /usr/bin/true "$negative"
chmod 755 "$negative"
probe writable "$negative"
probe sysext /usr/bin/containerd --version

sleep 3
journalctl --sync
logs="$(journalctl -b --no-pager -o cat; dmesg)"
if [[ -r /var/log/audit/audit.log ]]; then
    boot_epoch="$(date -d "$(uptime -s)" +%s)"
    shopt -s nullglob
    audit_files=(/var/log/audit/audit.log /var/log/audit/audit.log.[0-9]*)
    logs+=$'\n'"$(awk -v boot="$boot_epoch" '
        /ipe_op=EXECUTE / {
            split($0, parts, /audit\(/)
            split(parts[2], stamp, /[.:]/)
            if (stamp[1] >= boot) print
        }' "${audit_files[@]}")"
fi
status="$(/usr/sbin/auditctl -s)" || fail "cannot query kernel audit status"
echo "$status"
grep -qx 'lost 0' <<< "$status" || fail "audit records were lost"
if grep -Ei 'audit.*(backlog limit exceeded|rate limit exceeded|lost=[1-9])' <<< "$logs"; then
    fail "incomplete audit evidence"
fi
[[ "$(findmnt -rn -T /usr -t overlay -o OPTIONS)" == "$usr_mount_options" ]] ||
    fail "/usr layers changed during validation"
check_usr_denials <<< "$logs"
for i in "${!pids[@]}"; do
    records="$(grep 'ipe_op=EXECUTE ' <<< "$logs" |
        grep -E "(^|[[:space:]])pid=${pids[i]}([[:space:]]|$)")" ||
        fail "${names[i]}: no PID-correlated IPE evidence"
    if [[ "${names[i]}" == writable ]]; then
        grep -F "path=\"$negative\"" <<< "$records" |
            grep -q 'ipe_hook=BPRM_CHECK.*action=DENY' ||
            fail "writable executable did not produce a denial"
    elif [[ "${names[i]}" == sysext ]]; then
        grep -F 'path="/usr/bin/containerd"' <<< "$records" |
            grep -q 'ipe_hook=BPRM_CHECK.*action=DENY' ||
            fail "sysext executable did not produce a denial"
    else
        if grep -q action=DENY <<< "$records"; then
            fail "${names[i]}: unexpected denial"
        fi
        for hook in BPRM_CHECK MMAP; do
            grep "ipe_hook=$hook " <<< "$records" |
                grep -F "path=\"/usr/bin/${names[i]}\"" |
                grep 'dmverity_signature=TRUE' | grep -q action=ALLOW ||
                fail "${names[i]}: missing $hook signature ALLOW"
        done
    fi
    printf 'PASS %s pid=%s\n' "${names[i]}" "${pids[i]}"
    echo "$records"
done
status="$(/usr/sbin/auditctl -s)" || fail "cannot recheck kernel audit status"
grep -qx 'lost 0' <<< "$status" || fail "audit records were lost during validation"
echo "PASS: patched ACL VM, SELinux enforcing, zero base /usr denials, signed BPRM/MMAP allows, sysext and writable denials"
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || "$0" == bash ]]; then
    main "$@"
fi
