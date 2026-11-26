#!/bin/bash
# Test script to validate that the BPF LSM is active.
# This script checks that "bpf" is in the active LSM list so BPF LSM programs
# (e.g. Tetragon, KubeArmor enforcement) can attach, and that enabling it did
# not drop SELinux or IPE from the stack.
# Designed to run inside the Azure Container Linux (ACL) VM.

set -euo pipefail

echo "========================================="
echo "BPF LSM Validation Test"
echo "========================================="
echo ""

LSM_FILE="/sys/kernel/security/lsm"

if [ ! -r "$LSM_FILE" ]; then
    echo "❌ FAILED: $LSM_FILE is not readable (securityfs not mounted?)"
    exit 1
fi

ACTIVE_LSMS=$(cat "$LSM_FILE")
CMDLINE=$(cat /proc/cmdline)

echo "Active LSMs: $ACTIVE_LSMS"
echo "Kernel cmdline: $CMDLINE"
echo ""

lsm_active() {
    [[ ",${ACTIVE_LSMS}," == *",$1,"* ]]
}

EXIT_CODE=0

if lsm_active bpf; then
    echo "✅ bpf is in the active LSM list"
else
    echo "❌ bpf is NOT in the active LSM list"
    EXIT_CODE=1
fi

if lsm_active selinux; then
    echo "✅ selinux is still in the active LSM list"
else
    echo "❌ selinux is NOT in the active LSM list"
    EXIT_CODE=1
fi

# IPE is only expected when the image was built with an IPE policy.
if [[ "$CMDLINE" == *"acl.ipe.policy_sha256="* ]]; then
    if lsm_active ipe; then
        echo "✅ ipe is still in the active LSM list"
    else
        echo "❌ ipe is NOT in the active LSM list (IPE policy present on cmdline)"
        EXIT_CODE=1
    fi
else
    echo "ℹ IPE policy not on cmdline, skipping ipe check"
fi

# Check the kernel advertises the BPF LSM program type, if bpftool is available.
if command -v bpftool &>/dev/null; then
    # Capture first: with pipefail, grep -q closing the pipe early would make
    # bpftool exit with SIGPIPE and fail the check even on a match.
    BPFTOOL_PROBE=$(sudo bpftool feature probe kernel 2>/dev/null || true)
    if grep -q "program_type lsm is available" <<<"$BPFTOOL_PROBE"; then
        echo "✅ bpftool reports BPF program type lsm is available"
    else
        echo "❌ bpftool reports BPF program type lsm is NOT available"
        EXIT_CODE=1
    fi
else
    echo "ℹ bpftool not found, skipping program type probe"
fi

# Final summary
echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ SUCCESS: BPF LSM is active"
else
    echo "❌ FAILED: BPF LSM validation failed"
fi

exit $EXIT_CODE
