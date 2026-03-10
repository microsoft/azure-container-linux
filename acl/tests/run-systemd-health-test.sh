#!/bin/bash
# Test script to validate systemd health status.
# This script checks for service failures and system degradation.
# Designed to run inside the Azure Container Linux (ACL) VM.

set -euo pipefail

echo "========================================="
echo "Systemd Health Validation Test"
echo "========================================="
echo ""

# Known services that may fail in specific boot configurations.
# Populated conditionally below based on detected boot environment.
KNOWN_FAILURES=()

# Detect UKI boot (systemd-stub sets StubPcrKernelImage EFI variable) and Secure
# Boot status. When booted via UKI without Secure Boot, the systemd-pcrlock
# services activate (ConditionSecurity=measured-uki passes) but fail because the
# TPM2 event log cannot be validated against actual PCR state. In GRUB mode
# these services are silently skipped.
# EFI_LOADER_VARIABLE (systemd) namespace
STUB_EFI_VAR=/sys/firmware/efi/efivars/StubPcrKernelImage-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f

if [ -f "$STUB_EFI_VAR" ] && ! mokutil --sb 2>/dev/null | grep -q "SecureBoot enabled"; then
    echo "Detected UKI boot without Secure Boot — excluding pcrlock services from checks"
    KNOWN_FAILURES=(
        "systemd-pcrlock-firmware-code.service"
        "systemd-pcrlock-firmware-config.service"
        "systemd-pcrlock-secureboot-policy.service"
        "systemd-pcrlock-secureboot-authority.service"
        "systemd-pcrlock-file-system.service"
        "systemd-pcrlock-machine-id.service"
        "systemd-pcrlock-make-policy.service"
    )
fi

# Check if systemd is running
if ! command -v systemctl &>/dev/null; then
    echo "❌ FAILED: systemctl command not found"
    exit 1
fi

echo "✓ systemctl command is available"

# Check for failed units
echo ""
echo "Checking for failed units..."
FAILED_UNITS=$(systemctl --failed --no-legend --no-pager 2>/dev/null || true)

# Filter out known non-critical failures
UNEXPECTED_UNITS=""
EXCLUDED_UNITS=""

if [ -n "$FAILED_UNITS" ]; then
    while IFS= read -r line; do
        UNIT_NAME=$(echo "$line" | awk '{print $2}')
        is_known=false
        for known in "${KNOWN_FAILURES[@]+"${KNOWN_FAILURES[@]}"}"; do
            if [ "$UNIT_NAME" = "$known" ]; then
                is_known=true
                break
            fi
        done
        if $is_known; then
            if [ -n "$EXCLUDED_UNITS" ]; then
                EXCLUDED_UNITS+=$'\n'
            fi
            EXCLUDED_UNITS+="$line"
        else
            if [ -n "$UNEXPECTED_UNITS" ]; then
                UNEXPECTED_UNITS+=$'\n'
            fi
            UNEXPECTED_UNITS+="$line"
        fi
    done <<< "$FAILED_UNITS"
fi

if [ -n "$EXCLUDED_UNITS" ]; then
    EXCLUDED_COUNT=$(echo "$EXCLUDED_UNITS" | wc -l)
    echo "Excluded $EXCLUDED_COUNT known non-critical failure(s):"
    echo "$EXCLUDED_UNITS"
    echo ""
fi

# Check overall system state
echo "Checking system state..."
SYSTEM_STATE=$(systemctl is-system-running 2>/dev/null || true)

echo "System State: $SYSTEM_STATE"
echo ""

if [ "$SYSTEM_STATE" = "running" ]; then
    echo "✓ System is in 'running' state"
elif [ "$SYSTEM_STATE" = "initializing" ] || [ "$SYSTEM_STATE" = "starting" ]; then
    echo "⚠ System is still starting up ($SYSTEM_STATE), waiting..."
    sleep 10
    SYSTEM_STATE=$(systemctl is-system-running 2>/dev/null || true)
    echo "System State after waiting: $SYSTEM_STATE"
    if [ "$SYSTEM_STATE" != "running" ]; then
        echo "❌ FAILED: System did not reach 'running' state"
    fi
elif [ "$SYSTEM_STATE" = "degraded" ]; then
    # If the only failed units are known non-critical ones, treat degraded as acceptable
    if [ -z "$UNEXPECTED_UNITS" ]; then
        echo "System is 'degraded' but only due to known non-critical failures — treating as healthy"
        SYSTEM_STATE="running"
    else
        echo "❌ FAILED: System is in 'degraded' state"
    fi
else
    echo "❌ FAILED: Unexpected system state: $SYSTEM_STATE"
fi

if [ -z "$UNEXPECTED_UNITS" ]; then
    echo "✓ No unexpected failed systemd units"
else
    echo "❌ FAILED: The following units have failed:"
    echo ""
    echo "$UNEXPECTED_UNITS"
    echo ""

    # Get details for each failed unit
    echo "Detailed failure information:"
    echo "-----------------------------"
    while IFS= read -r line; do
        UNIT_NAME=$(echo "$line" | awk '{print $2}')
        if [ -n "$UNIT_NAME" ]; then
            echo ""
            echo "Unit: $UNIT_NAME"
            systemctl status "$UNIT_NAME" --no-pager 2>/dev/null || true
            echo ""
        fi
    done <<< "$UNEXPECTED_UNITS"
fi

# Final summary
echo ""
echo "========================================="
echo "Test Summary"
echo "========================================="

EXIT_CODE=0

if [ "$SYSTEM_STATE" != "running" ]; then
    echo "❌ System state: $SYSTEM_STATE (expected: running)"
    EXIT_CODE=1
else
    echo "✅ System state: running"
fi

if [ -n "$UNEXPECTED_UNITS" ]; then
    FAILED_COUNT=$(echo "$UNEXPECTED_UNITS" | wc -l)
    echo "❌ Failed units: $FAILED_COUNT"
    EXIT_CODE=1
else
    echo "✅ Failed units: 0"
fi

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ SUCCESS: Systemd is healthy with no failures"
else
    echo "❌ FAILED: Systemd health check failed"
fi

exit $EXIT_CODE
