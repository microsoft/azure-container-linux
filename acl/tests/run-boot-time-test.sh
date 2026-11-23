#!/bin/bash
# Test script to validate boot time is within acceptable thresholds.
# Collects systemd-analyze timing data and fails if total boot time
# exceeds the configured threshold, catching boot-time regressions.
# Designed to run inside the Azure Container Linux (ACL) VM.

set -euo pipefail

# ── Thresholds (seconds) ──────────────────────────────────────────────────
# Override via environment variables if needed.
BOOT_TIME_THRESHOLD_TOTAL="${BOOT_TIME_THRESHOLD_TOTAL:-30}"
BOOT_TIME_THRESHOLD_USERSPACE="${BOOT_TIME_THRESHOLD_USERSPACE:-20}"

echo "========================================="
echo "Boot Time Validation Test"
echo "========================================="
echo ""
echo "Thresholds:"
echo "  Total boot time:     ${BOOT_TIME_THRESHOLD_TOTAL}s"
echo "  Userspace boot time: ${BOOT_TIME_THRESHOLD_USERSPACE}s"
echo ""

# ── Collect systemd-analyze data ──────────────────────────────────────────
if ! command -v systemd-analyze &>/dev/null; then
    echo "FAILED: systemd-analyze command not found"
    exit 1
fi

echo "--- systemd-analyze ---"
if ! ANALYZE_OUTPUT=$(systemd-analyze 2>&1); then
    echo "FAILED: systemd-analyze returned an error"
    echo "  Output: $ANALYZE_OUTPUT"
    exit 1
fi
echo "$ANALYZE_OUTPUT"
echo ""

# Parse timing values from systemd-analyze output.
# Typical output:
#   Startup finished in 812ms (kernel) + 923ms (initrd) + 1.512s (userspace) = 3.247s
# or with minutes:
#   Startup finished in 1.204s (firmware) + ... + 1min 2.345s (userspace) = 1min 5.961s
# Azure VMs typically don't report firmware/loader times.

# Convert a duration string to seconds using awk (no bc dependency).
# Handles: "3.247s", "812ms", "1min 2.345s", "1min", "2s"
parse_seconds() {
    local input="$1"
    echo "$input" | awk '{
        total = 0
        for (i = 1; i <= NF; i++) {
            val = $i
            if (val ~ /min$/) {
                gsub(/min$/, "", val)
                total += val * 60
            } else if (val ~ /ms$/) {
                gsub(/ms$/, "", val)
                total += val / 1000
            } else if (val ~ /s$/) {
                gsub(/s$/, "", val)
                total += val
            }
        }
        if (total > 0) printf "%.3f", total
    }'
}

# Compare two floats: returns 0 (true) if $1 > $2, 1 (false) otherwise.
float_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

# Extract individual phase times.
# Total time: everything after '=' to end of the "Startup finished" line.
# Phase times: everything before '(phase_name)' in the same segment.
TOTAL_TIME=""
KERNEL_TIME=""
INITRD_TIME=""
USERSPACE_TIME=""

# Total: capture everything after '= ' to end of the first line.
# Restrict to the "Startup finished" line to avoid matching text from
# subsequent lines (bash =~ treats . as matching newlines).
STARTUP_LINE=$(echo "$ANALYZE_OUTPUT" | head -1)
if [[ "$STARTUP_LINE" =~ =\ *(.*) ]]; then
    TOTAL_TIME=$(parse_seconds "${BASH_REMATCH[1]}")
fi

# Phase times: capture the full duration string before each phase label.
# Pattern matches spans like "812ms", "4.523s", or "1min 2.345s" before "(phase)".
# The regex allows optional decimals in the first token to correctly handle e.g. "4.523s".
if [[ "$STARTUP_LINE" =~ ([0-9]+\.?[0-9]*[a-z]+[[:space:]]*[0-9]*\.?[0-9]*[a-z]*)\ *\(kernel\) ]]; then
    KERNEL_TIME=$(parse_seconds "${BASH_REMATCH[1]}")
fi

if [[ "$STARTUP_LINE" =~ ([0-9]+\.?[0-9]*[a-z]+[[:space:]]*[0-9]*\.?[0-9]*[a-z]*)\ *\(initrd\) ]]; then
    INITRD_TIME=$(parse_seconds "${BASH_REMATCH[1]}")
fi

if [[ "$STARTUP_LINE" =~ ([0-9]+\.?[0-9]*[a-z]+[[:space:]]*[0-9]*\.?[0-9]*[a-z]*)\ *\(userspace\) ]]; then
    USERSPACE_TIME=$(parse_seconds "${BASH_REMATCH[1]}")
fi

echo "--- Parsed Boot Times ---"
echo "  Kernel:    ${KERNEL_TIME:+${KERNEL_TIME}s}${KERNEL_TIME:-N/A}"
echo "  Initrd:    ${INITRD_TIME:+${INITRD_TIME}s}${INITRD_TIME:-N/A}"
echo "  Userspace: ${USERSPACE_TIME:+${USERSPACE_TIME}s}${USERSPACE_TIME:-N/A}"
echo "  Total:     ${TOTAL_TIME:+${TOTAL_TIME}s}${TOTAL_TIME:-N/A}"
echo ""

# ── Top 10 slowest services ──────────────────────────────────────────────
echo "--- Top 10 Slowest Services (systemd-analyze blame) ---"
systemd-analyze blame 2>/dev/null | head -10 || true
echo ""

# ── Critical chain ────────────────────────────────────────────────────────
echo "--- Critical Chain ---"
systemd-analyze critical-chain --no-pager 2>/dev/null || true
echo ""

# ── Threshold checks ─────────────────────────────────────────────────────
FAILED=0

if [[ -z "$TOTAL_TIME" ]]; then
    echo "FAILED: Could not parse total boot time from systemd-analyze output"
    echo "  Raw output: $ANALYZE_OUTPUT"
    echo "  This may indicate a change in systemd-analyze output format."
    FAILED=1
else
    if float_gt "$TOTAL_TIME" "$BOOT_TIME_THRESHOLD_TOTAL"; then
        echo "FAILED: Total boot time ${TOTAL_TIME}s exceeds threshold ${BOOT_TIME_THRESHOLD_TOTAL}s"
        FAILED=1
    else
        echo "PASSED: Total boot time ${TOTAL_TIME}s within threshold ${BOOT_TIME_THRESHOLD_TOTAL}s"
    fi
fi

if [[ -z "$USERSPACE_TIME" ]]; then
    echo "FAILED: Could not parse userspace boot time from systemd-analyze output"
    echo "  This may indicate a change in systemd-analyze output format."
    FAILED=1
else
    if float_gt "$USERSPACE_TIME" "$BOOT_TIME_THRESHOLD_USERSPACE"; then
        echo "FAILED: Userspace boot time ${USERSPACE_TIME}s exceeds threshold ${BOOT_TIME_THRESHOLD_USERSPACE}s"
        FAILED=1
    else
        echo "PASSED: Userspace boot time ${USERSPACE_TIME}s within threshold ${BOOT_TIME_THRESHOLD_USERSPACE}s"
    fi
fi

echo ""
echo "========================================="
if [[ $FAILED -eq 0 ]]; then
    echo "Boot Time Validation: PASSED"
else
    echo "Boot Time Validation: FAILED"
    echo ""
    echo "Boot time regression detected. If this is expected (e.g. new"
    echo "service added), update the thresholds in this script or set"
    echo "BOOT_TIME_THRESHOLD_TOTAL / BOOT_TIME_THRESHOLD_USERSPACE"
    echo "environment variables."
fi
echo "========================================="

exit $FAILED
