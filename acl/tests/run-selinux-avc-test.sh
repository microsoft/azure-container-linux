#!/bin/bash
# Test script to validate that SELinux has no unexpected denied AVCs and
# enforces a known denial.
# Designed to run inside the Azure Container Linux (ACL) VM.

set -euo pipefail

echo "========================================="
echo "SELinux AVC Denial Validation Test"
echo "========================================="
echo ""

# Check if dmesg is available
if ! command -v dmesg &>/dev/null; then
    echo "❌ FAILED: dmesg command not found"
    exit 1
fi

echo "✓ dmesg command is available"

# Capture dmesg output
echo ""
echo "Checking kernel ring buffer for SELinux AVC denials..."

DMESG_OUTPUT=$(dmesg 2>/dev/null || true)

if [ -z "$DMESG_OUTPUT" ]; then
    echo "⚠ WARNING: dmesg returned no output (may need root privileges)"
    echo "Attempting with sudo..."
    DMESG_OUTPUT=$(sudo dmesg 2>/dev/null || true)
    if [ -z "$DMESG_OUTPUT" ]; then
        echo "❌ FAILED: Unable to read dmesg output"
        exit 1
    fi
fi

# Only exclude AVCs from this test's known probe, not other container_t denials.
probe_avc='avc:[[:space:]]+denied[[:space:]]+\{[[:space:]]+read[[:space:]]+\}.*comm="cat" name="acl-selinux-denial\.[^"]+".*scontext=system_u:system_r:container_t:s0.*tcontext=[^[:space:]]*:shadow_t:s0.*tclass=file.*permissive=0'
DMESG_AVC_DENIALS=$(echo "$DMESG_OUTPUT" | grep -E "avc:[[:space:]]+denied" | grep -Ev "$probe_avc" || true)

# Also check journalctl for AVC denials
JOURNAL_AVC_DENIALS=""
if command -v journalctl &>/dev/null; then
    echo "Checking journal for SELinux AVC denials..."
    JOURNAL_AVC_DENIALS=$(journalctl --no-pager -q -k 2>/dev/null | grep -E "avc:[[:space:]]+denied" | grep -Ev "$probe_avc" || true)
fi

# Final summary
echo ""
echo "========================================="
echo "Test Summary"
echo "========================================="

EXIT_CODE=0

if [ -n "$DMESG_AVC_DENIALS" ]; then
    DENIAL_COUNT=$(echo "$DMESG_AVC_DENIALS" | wc -l)
    echo "❌ AVC denials found in dmesg: $DENIAL_COUNT"
    echo ""
    echo "Denial details (dmesg):"
    echo "-----------------------------"
    echo "$DMESG_AVC_DENIALS"
    echo "-----------------------------"
    EXIT_CODE=1
else
    echo "✅ AVC denials in dmesg: 0"
fi

if [ -n "$JOURNAL_AVC_DENIALS" ]; then
    JOURNAL_COUNT=$(echo "$JOURNAL_AVC_DENIALS" | wc -l)
    echo "❌ AVC denials found in journal: $JOURNAL_COUNT"
    echo ""
    echo "Denial details (journal):"
    echo "-----------------------------"
    echo "$JOURNAL_AVC_DENIALS"
    echo "-----------------------------"
    EXIT_CODE=1
else
    echo "✅ AVC denials in journal: 0"
fi

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ No unexpected SELinux AVC denials detected"
else
    echo "❌ FAILED: SELinux AVC denials detected"
fi

if [ "$EXIT_CODE" -ne 0 ]; then
    exit "$EXIT_CODE"
fi

# Check enforcement after the log scan; subsequent invocations exclude only
# the probe's narrowly identified AVCs.
check_enforced_denial() (
    local file context error_file status
    [ "$(getenforce)" = "Enforcing" ] || {
        echo "❌ FAILED: SELinux is not enforcing"
        return 1
    }
    for tool in runcon chcon stat mktemp; do
        command -v "$tool" &>/dev/null || {
            echo "❌ FAILED: $tool command not found"
            return 1
        }
    done

    file=$(mktemp /tmp/acl-selinux-denial.XXXXXX)
    error_file=$(mktemp /tmp/acl-selinux-error.XXXXXX) || {
        rm -f -- "$file"
        return 1
    }
    trap 'rm -f -- "$file" "$error_file"' EXIT
    printf 'SELinux denial probe\n' > "$file"
    chmod 644 "$file"
    chcon -t shadow_t "$file"
    context=$(stat -c %C "$file")
    [[ "$context" == *:shadow_t:* ]] || {
        echo "❌ FAILED: Probe file has unexpected label: $context"
        return 1
    }
    cat "$file" > /dev/null || {
        echo "❌ FAILED: Probe file is not readable without confinement"
        return 1
    }

    context=$(runcon -u system_u -r system_r -t container_t -l s0 -- id -Z) || {
        echo "❌ FAILED: Cannot enter the confined container_t domain"
        return 1
    }
    [[ "$context" == system_u:system_r:container_t:s0 ]] || {
        echo "❌ FAILED: Probe process has unexpected context: $context"
        return 1
    }

    status=0
    LC_ALL=C runcon -u system_u -r system_r -t container_t -l s0 -- cat "$file" > /dev/null 2> "$error_file" || status=$?
    if [ "$status" -ne 1 ] || ! grep -q 'Permission denied' "$error_file"; then
        echo "❌ FAILED: Confined read was not denied as expected (exit $status)"
        cat "$error_file"
        return 1
    fi
    echo "✅ Enforcing SELinux denied container_t read of shadow_t despite DAC read permission"
)

check_enforced_denial
