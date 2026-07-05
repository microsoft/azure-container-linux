#!/bin/bash
# Test script to validate systemd health status.
# This script checks for service failures and system degradation.
# Designed to run inside the Azure Container Linux (ACL) VM.

set -uo pipefail

echo "========================================="
echo "Systemd Health Validation Test"
echo "========================================="
echo ""

# Check if systemd is running
if ! command -v systemctl &>/dev/null; then
    echo "❌ FAILED: systemctl command not found"
    exit 1
fi

echo "✓ systemctl command is available"

# ---------------------------------------------------------------------------
# dump_systemd_state — full diagnostic dump. Called on any non-running state.
# Prints every clue a post-mortem needs to name the stuck unit(s) without
# requiring another pipeline retrigger.
# ---------------------------------------------------------------------------
dump_systemd_state() {
    echo ""
    echo "========================================="
    echo "DIAGNOSTIC DUMP: systemd state"
    echo "========================================="

    echo ""
    echo "--- systemd-detect-virt ---"
    systemd-detect-virt 2>&1 || true

    echo ""
    echo "--- systemctl list-jobs (pending jobs) ---"
    systemctl list-jobs --no-pager 2>&1 || true

    echo ""
    echo "--- systemctl list-units --state=activating,waiting,failed ---"
    systemctl list-units --state=activating,waiting,failed --no-pager --no-legend 2>&1 || true

    echo ""
    echo "--- Per-activating-unit status ---"
    ACTIVATING=$(systemctl list-units --state=activating --no-pager --no-legend 2>/dev/null | awk '{print $1}' | grep -v '^$' || true)
    if [ -n "$ACTIVATING" ]; then
        while IFS= read -r u; do
            [ -z "$u" ] && continue
            echo ""
            echo ">>> $u <<<"
            systemctl status "$u" --no-pager -l 2>&1 || true
        done <<< "$ACTIVATING"
    else
        echo "(no activating units)"
    fi

    echo ""
    echo "--- Targets-of-interest status (waagent / chronyd / containerd) ---"
    for u in waagent.service chronyd.service containerd.service; do
        echo ""
        echo ">>> $u <<<"
        systemctl status "$u" --no-pager -l 2>&1 || true
    done

    echo ""
    echo "--- Drop-in directories (/usr and /etc) ---"
    ls -la \
        /usr/lib/systemd/system/waagent.service.d/ \
        /usr/lib/systemd/system/chronyd.service.d/ \
        /usr/lib/systemd/system/containerd.service.d/ \
        /etc/systemd/system/waagent.service.d/ \
        /etc/systemd/system/chronyd.service.d/ \
        /etc/systemd/system/containerd.service.d/ \
        2>&1 || true

    echo ""
    echo "--- Drop-in file contents (if present) ---"
    for f in \
        /usr/lib/systemd/system/waagent.service.d/*.conf \
        /usr/lib/systemd/system/chronyd.service.d/*.conf \
        /usr/lib/systemd/system/containerd.service.d/*.conf \
        /etc/systemd/system/waagent.service.d/*.conf \
        /etc/systemd/system/chronyd.service.d/*.conf; do
        [ -f "$f" ] || continue
        echo ""
        echo ">>> $f <<<"
        cat "$f" 2>&1 || true
    done

    echo ""
    echo "--- journalctl -b -p warning (last 200 lines) ---"
    journalctl -b -p warning --no-pager 2>&1 | tail -200 || true

    echo ""
    echo "--- multi-user.target.wants/ ---"
    ls -la /etc/systemd/system/multi-user.target.wants/ /usr/lib/systemd/system/multi-user.target.wants/ 2>&1 || true

    echo ""
    echo "========================================="
    echo "END DIAGNOSTIC DUMP"
    echo "========================================="
    echo ""
}

# Check for failed units
echo ""
echo "Checking for failed units..."
FAILED_UNITS=$(systemctl --failed --no-legend --no-pager 2>/dev/null || true)

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
        dump_systemd_state
    fi
elif [ "$SYSTEM_STATE" = "degraded" ]; then
    echo "❌ FAILED: System is in 'degraded' state"
    dump_systemd_state
else
    echo "❌ FAILED: Unexpected system state: $SYSTEM_STATE"
    dump_systemd_state
fi

if [ -z "$FAILED_UNITS" ]; then
    echo "✓ No failed systemd units"
else
    echo "❌ FAILED: The following units have failed:"
    echo ""
    echo "$FAILED_UNITS"
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
    done <<< "$FAILED_UNITS"
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

if [ -n "$FAILED_UNITS" ]; then
    FAILED_COUNT=$(echo "$FAILED_UNITS" | wc -l)
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
