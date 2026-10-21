#!/bin/bash
set -euo pipefail
fail() { echo "FAILED: $*" >&2; exit 1; }

expected="${1:?expected disabled or audit}"
[[ "$expected" == disabled || "$expected" == audit ]] || fail "invalid mode"
[[ "$(uname -r)" == "6.6.157.1-1.btrfsipe3.azl3" ]] || fail "wrong kernel"
[[ "$(getenforce)" == Enforcing ]] || fail "SELinux must remain enforcing"
ipe=/sys/kernel/security/ipe
shopt -s nullglob
active_files=("$ipe"/policies/*/active)
[[ ${#active_files[@]} -gt 0 ]] || fail "no loaded policy"
active_count=0
for active in "${active_files[@]}"; do
    if [[ "$(< "$active")" == 1 ]]; then
        active_count=$((active_count + 1))
    fi
done
if [[ "$expected" == disabled ]]; then
    [[ "$active_count" == 0 ]] || fail "a policy is active"
else
    [[ "$active_count" == 1 &&
       "$(< "$ipe/policies/acl_ipe_boot_policy/active")" == 1 &&
       "$(< "$ipe/enforce")" == 0 ]] || fail "expected active audit policy"
fi

tracefs=/sys/kernel/tracing
mounted=false
instance=""
cleanup() {
    local rc=$?
    if [[ -n "$instance" ]]; then
        echo 0 > "$instance/tracing_on" || rc=1
        echo nop > "$instance/current_tracer" || rc=1
        rmdir "$instance" || rc=1
    fi
    if [[ "$mounted" == true ]]; then
        umount "$tracefs" || rc=1
    fi
    exit "$rc"
}
trap cleanup EXIT
if ! mountpoint -q "$tracefs"; then
    mount -t tracefs tracefs "$tracefs"
    mounted=true
fi
grep -qE '^btrfs_get_integrity_bdev([[:space:]]|$)' \
    "$tracefs/available_filter_functions" || fail "callback is not traceable"
target="$tracefs/instances/ipe-fastpath-$$"
mkdir "$target"
instance="$target"
echo 0 > "$instance/tracing_on"
echo btrfs_get_integrity_bdev > "$instance/set_ftrace_filter"
echo function > "$instance/current_tracer"
echo > "$instance/trace"
echo 1 > "$instance/tracing_on"
for ((i=0; i<20; i++)); do
    /usr/bin/true
done
echo 0 > "$instance/tracing_on"
calls="$(grep -c 'btrfs_get_integrity_bdev' "$instance/trace" || test "$?" == 1)"
[[ "$calls" =~ ^[0-9]+$ ]] || fail "cannot count callback events"
for stats in "$instance"/per_cpu/cpu*/stats; do
    awk '/^(overrun|commit overrun|dropped events):/ && $NF != 0 { exit 1 }' \
        "$stats" || fail "trace records were lost"
done
if [[ "$expected" == disabled ]]; then
    [[ "$calls" == 0 ]] || fail "inactive IPE performed $calls Btrfs lookups"
else
    [[ "$calls" -gt 0 ]] || fail "active IPE did not perform Btrfs lookups"
fi
echo "PASS: mode=$expected btrfs_integrity_lookups=$calls executions=20"
