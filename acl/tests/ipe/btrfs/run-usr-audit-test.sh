#!/bin/bash
# SPDX-License-Identifier: MIT
# Run as root inside the diagnostic ACL VM, never change its IPE/SELinux modes.
set -euo pipefail
fail() { echo "FAILED: $*" >&2; exit 1; }
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
negative=$(mktemp /var/tmp/btrfs-ipe-untrusted.XXXXXX)
trap 'rm -f "$negative"' EXIT
cp /usr/bin/true "$negative"
chmod 755 "$negative"
probe writable "$negative"

journalctl --sync
logs="$(journalctl -b --no-pager -o cat; dmesg)"
if [[ -r /var/log/audit/audit.log ]]; then
    boot_epoch="$(date -d "$(uptime -s)" +%s)"
    logs+=$'\n'"$(awk -v boot="$boot_epoch" '
        /ipe_op=EXECUTE / {
            split($0, parts, /audit\(/)
            split(parts[2], stamp, /[.:]/)
            if (stamp[1] >= boot) print
        }' /var/log/audit/audit.log)"
fi
status="$(/usr/sbin/auditctl -s)" || fail "cannot query kernel audit status"
echo "$status"
grep -qx 'lost 0' <<< "$status" || fail "audit records were lost"
if grep -Ei 'audit.*(backlog limit exceeded|rate limit exceeded|lost=[1-9])' <<< "$logs"; then
    fail "incomplete audit evidence"
fi
if grep 'ipe_op=EXECUTE ' <<< "$logs" | grep 'action=DENY' |
    grep -E 'path="/(usr/|lib/|lib64/)'; then
    fail "/usr or its libraries had IPE denials during this boot"
fi
for i in "${!pids[@]}"; do
    records="$(grep 'ipe_op=EXECUTE ' <<< "$logs" |
        grep -E "(^|[[:space:]])pid=${pids[i]}([[:space:]]|$)")" ||
        fail "${names[i]}: no PID-correlated IPE evidence"
    if [[ "${names[i]}" == writable ]]; then
        grep -q 'ipe_hook=BPRM_CHECK.*action=DENY' <<< "$records" ||
            fail "writable executable did not produce a denial"
    else
        if grep -q action=DENY <<< "$records"; then
            fail "${names[i]}: unexpected denial"
        fi
        for hook in BPRM_CHECK MMAP; do
            grep "ipe_hook=$hook " <<< "$records" |
                grep 'dmverity_signature=TRUE' | grep -q action=ALLOW ||
                fail "${names[i]}: missing $hook signature ALLOW"
        done
    fi
    printf 'PASS %s pid=%s\n' "${names[i]}" "${pids[i]}"
    echo "$records"
done
echo "PASS: patched ACL VM, SELinux enforcing, zero /usr denials, signed BPRM/MMAP allows and writable denial"
