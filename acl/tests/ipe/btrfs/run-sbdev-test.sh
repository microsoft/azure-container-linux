#!/bin/bash
set -euo pipefail
fail() { echo "FAILED: $*" >&2; exit 1; }

expected="${1:?expected disabled or audit}"
[[ "$expected" == disabled || "$expected" == audit ]] || fail "invalid mode"
[[ "$(uname -r)" == "6.6.159.1-2.azl3" ]] || fail "wrong kernel"
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

for tool in mkfs.btrfs losetup blockdev dmsetup mount umount fsfreeze timeout; do
    command -v "$tool" >/dev/null || fail "missing $tool"
done
work="$(mktemp -d /var/tmp/btrfs-sbdev.XXXXXX)"
loop=""
mapped=false
suspended=false
dm_name="ipe-sbdev-$$"
backing="/dev/mapper/$dm_name"
mounted=false
frozen=false
cleanup() {
    local rc=$?
    if [[ "$suspended" == true ]]; then
        dmsetup resume "$dm_name" || return 1
    fi
    if [[ "$frozen" == true ]]; then
        fsfreeze -u "$work/mnt" || return 1
    fi
    if [[ "$mounted" == true ]]; then
        umount "$work/mnt" || return 1
    fi
    if [[ "$mapped" == true ]]; then
        dmsetup remove "$dm_name" || return 1
    fi
    if [[ -n "$loop" ]]; then
        losetup -d "$loop" || return 1
    fi
    rm -f "$work/disk.raw" "$work/remount.log"
    rmdir "$work/mnt" "$work"
    exit "$rc"
}
trap cleanup EXIT
mkdir "$work/mnt"
truncate -s 256M "$work/disk.raw"
loop="$(losetup --find --show "$work/disk.raw")"
dmsetup create "$dm_name" --table "0 $(blockdev --getsz "$loop") linear $loop 0"
mapped=true
mkfs.btrfs -q "$backing"

# Ordinary writable backing must retain read-write remount support.
mount "$backing" "$work/mnt"
mounted=true
printf 'persistent\n' > "$work/mnt/probe"
mount -o remount,ro "$work/mnt"
mount -o remount,rw "$work/mnt"
printf 'mutable\n' >> "$work/mnt/probe"
umount "$work/mnt"
mounted=false

blockdev --setro "$backing"
for ((round=0; round<3; round++)); do
    mount -o ro "$backing" "$work/mnt"
    mounted=true
    [[ "$(< "$work/mnt/probe")" == $'persistent\nmutable' ]] || fail "data changed"
    if mount -o remount,rw "$work/mnt" > "$work/remount.log" 2>&1; then
        fail "read-only backing accepted a writable remount"
    fi
    frozen=true
    timeout 20 fsfreeze -f "$work/mnt"
    timeout 20 fsfreeze -u "$work/mnt"
    frozen=false
    # Unlike FIFREEZE, DM suspend exercises freeze_bdev() and s_bdev lookup.
    suspended=true
    timeout 20 dmsetup suspend "$dm_name"
    timeout 20 dmsetup resume "$dm_name"
    suspended=false
    sync -f "$work/mnt"
    if [[ "$round" == 2 ]]; then
        blockdev --setrw "$backing"
        if mount -o remount,rw "$work/mnt" > "$work/remount.log" 2>&1; then
            fail "published backing accepted a writable remount after setrw"
        fi
    fi
    umount "$work/mnt"
    mounted=false
done
mount "$backing" "$work/mnt"
mounted=true
printf 'fresh-mount\n' >> "$work/mnt/probe"
[[ "$(tail -1 "$work/mnt/probe")" == fresh-mount ]] || fail "fresh mount is not writable"
[[ "$(getenforce)" == Enforcing ]] || fail "SELinux state changed"
echo "PASS: mode=$expected read-only backing, remount, freeze/thaw and unmount lifecycle"
