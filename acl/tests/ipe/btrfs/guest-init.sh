#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
export PATH=/bin:/sbin
dmesg -n 1
mount -t proc proc /proc
echo 0 > /proc/sys/kernel/printk_ratelimit
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t securityfs securityfs /sys/kernel/security
mkdir -p /usr /plain /unsigned /overlay /writable
mount -t tmpfs tmpfs /writable
mkdir /writable/upper /writable/work
ln -s usr/lib /lib
ln -s usr/lib64 /lib64

tool() {
    executable=$1
    shift
    /tools/ld.so --library-path /tools/lib "/tools/$executable" "$@"
}
fail() {
    echo "BTRFS_IPE_FAILURE $*"
    poweroff -f
}
probe() {
    name=$1
    expected=$2
    shift 2
    (exec "$@") &
    pid=$!
    result=0
    wait "$pid" || result=$?
    sleep 1
    echo "BTRFS_IPE_PROBE name=$name pid=$pid rc=$result expected=$expected"
}

echo "BTRFS_IPE_KERNEL $(uname -r)"
test -f /sys/kernel/security/ipe/enforce || fail "IPE is not active"
echo "BTRFS_IPE_POLICY_BEGIN"
cat /sys/kernel/security/ipe/policies/btrfs_ipe_test/policy
echo "BTRFS_IPE_POLICY_END"
tool auditctl -s
tool auditctl -r 0
tool veritysetup open /dev/vda rejected /dev/vdb "$(cat /signed.hash)" \
    --root-hash-signature /corrupt.p7b && fail "corrupt signature accepted"
echo "BTRFS_IPE_CORRUPT_SIGNATURE_REJECTED"
tool veritysetup open /dev/vda trusted /dev/vdb "$(cat /signed.hash)" \
    --root-hash-signature /signed.p7b || fail "signed mapping rejected"
mount -t btrfs -o ro /dev/mapper/trusted /usr || fail "signed mount failed"
tool veritysetup open /dev/vdd unsigned /dev/vde "$(cat /unsigned.hash)" \
    || fail "unsigned mapping failed"
mount -t btrfs -o ro /dev/mapper/unsigned /unsigned
mount -t btrfs -o ro /dev/vdc /plain
mount -t overlay overlay -o lowerdir=/usr,upperdir=/writable/upper,workdir=/writable/work /overlay
cp /usr/bin/true /writable/true
cp /usr/bin/true /overlay/bin/copied
echo "BTRFS_IPE_MOUNTS_BEGIN"
cat /proc/mounts
echo "BTRFS_IPE_MOUNTS_END"

probe signed-true allow /usr/bin/true
probe signed-ls allow /usr/bin/ls /usr
probe signed-bash allow /usr/bin/bash -c 'exit 0'
probe overlay-true allow /overlay/bin/true
probe overlay-copy deny /overlay/bin/copied
probe unsigned-true deny /unsigned/bin/true
probe plain-true deny /plain/bin/true
probe writable-true deny /writable/true

# Only this disposable initramfs fixture changes IPE mode; no host is changed.
echo 1 > /sys/kernel/security/ipe/enforce
probe enforcing-signed allow /usr/bin/true
probe enforcing-writable deny /writable/true
echo 0 > /sys/kernel/security/ipe/enforce
echo "BTRFS_IPE_AUDIT_STATUS_BEGIN"
tool auditctl -s
echo "BTRFS_IPE_AUDIT_STATUS_END"
dmesg
echo BTRFS_IPE_COMPLETE
poweroff -f
