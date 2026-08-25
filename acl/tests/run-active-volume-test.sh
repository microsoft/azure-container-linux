#!/bin/bash
# Validate the acl-active-volume dracut module.
#
# Asserts that the initramfs published the active A/B slot marker to /run/acl
# and that it survived switch-root into the real root. Designed to run inside
# the Azure Container Linux (ACL) VM. Works on both QEMU and Azure VMs — the
# module derives everything from /proc/cmdline, so no platform metadata is
# needed.

set -uo pipefail

MARKER=/run/acl/active-volume
ENVFILE=/run/acl/active-volume.env

FAILURES=0

pass() { echo "✓ $*"; }
fail() { echo "❌ FAILED: $*"; FAILURES=$((FAILURES + 1)); }
note() { echo "  … $*"; }

echo "========================================="
echo "Active Volume Marker Validation Test"
echo "========================================="
echo ""

# ── 1. Marker file exists and survived switch-root ──────────────────
echo "Checking marker file..."
if [[ ! -f "$MARKER" ]]; then
    fail "$MARKER does not exist — initrd module did not run, or /run did not survive switch-root"
    echo ""
    echo "Diagnostics:"
    ls -la /run/acl 2>&1 | sed 's/^/  /' || echo "  /run/acl missing entirely"
    journalctl -b -u acl-active-volume.service --no-pager 2>&1 | tail -20 | sed 's/^/  /'
    exit 1
fi
pass "$MARKER exists (survived switch-root)"

VOLUME=$(cat "$MARKER")
case "$VOLUME" in
    A|B) pass "marker contains a valid slot: '${VOLUME}'" ;;
    *)   fail "marker contains '${VOLUME}', expected exactly 'A' or 'B'" ;;
esac

# ── 2. Env file exists and is consistent with the marker ────────────
echo ""
echo "Checking env file..."
if [[ ! -f "$ENVFILE" ]]; then
    fail "$ENVFILE does not exist"
else
    pass "$ENVFILE exists"
    # shellcheck disable=SC1090
    if ! source "$ENVFILE"; then
        fail "$ENVFILE is not shell-parseable (breaks EnvironmentFile= consumers)"
    else
        pass "env file parses as EnvironmentFile"
        note "ACL_ACTIVE_VOLUME=${ACL_ACTIVE_VOLUME:-<unset>}"
        note "ACL_ACTIVE_USR_LABEL=${ACL_ACTIVE_USR_LABEL:-<unset>}"
        note "ACL_ACTIVE_USR_PARTUUID=${ACL_ACTIVE_USR_PARTUUID:-<unset>}"
        note "ACL_ACTIVE_VOLUME_SOURCE=${ACL_ACTIVE_VOLUME_SOURCE:-<unset>}"
        note "ACL_ACTIVE_VOLUME_STATUS=${ACL_ACTIVE_VOLUME_STATUS:-<unset>}"
        note "ACL_ACTIVE_VOLUME_DEFAULTED=${ACL_ACTIVE_VOLUME_DEFAULTED:-<unset>}"

        if [[ "${ACL_ACTIVE_VOLUME:-}" != "$VOLUME" ]]; then
            fail "env ACL_ACTIVE_VOLUME='${ACL_ACTIVE_VOLUME:-}' disagrees with marker '${VOLUME}'"
        else
            pass "env file agrees with marker"
        fi

        if [[ "${ACL_ACTIVE_USR_LABEL:-}" != "USR-${VOLUME}" ]]; then
            fail "env ACL_ACTIVE_USR_LABEL='${ACL_ACTIVE_USR_LABEL:-}' should be 'USR-${VOLUME}'"
        fi
    fi
fi

# ── 3. The slot was DERIVED, not defaulted ──────────────────────────
# This is the assertion that actually exercises the cmdline parser. Because
# the module falls back to "A" when it cannot derive the slot, a completely
# broken parser still yields a plausible-looking "A". Only DEFAULTED=0 proves
# the PARTUUID was really read off the kernel command line and matched.
echo ""
echo "Checking the slot was derived rather than defaulted..."
if [[ "${ACL_ACTIVE_VOLUME_DEFAULTED:-1}" != "0" ]]; then
    fail "slot was DEFAULTED (status='${ACL_ACTIVE_VOLUME_STATUS:-}') — the cmdline parser did not match a USR PARTUUID"
    note "kernel cmdline was:"
    tr ' ' '\n' < /proc/cmdline | grep -E 'verity_usr|mount\.usr' | sed 's/^/    /' || echo "    (no usr args found)"
else
    pass "slot was derived from ${ACL_ACTIVE_VOLUME_SOURCE:-?} (not defaulted)"
fi

if [[ "${ACL_ACTIVE_VOLUME_STATUS:-}" != "ok" ]]; then
    fail "ACL_ACTIVE_VOLUME_STATUS='${ACL_ACTIVE_VOLUME_STATUS:-}', expected 'ok'"
fi

# ── 4. Cross-check the PARTUUID against the real GPT ────────────────
# Independent of the module's hardcoded constants: ask udev what the GPT
# actually calls the partition the module identified. This is what catches a
# stale UUID table after a disk-layout change (e.g. PR #28 renumbering).
echo ""
echo "Cross-checking PARTUUID against the on-disk GPT..."
if [[ -z "${ACL_ACTIVE_USR_PARTUUID:-}" ]]; then
    fail "ACL_ACTIVE_USR_PARTUUID is empty — cannot cross-check"
elif [[ ! -e "/dev/disk/by-partuuid/${ACL_ACTIVE_USR_PARTUUID}" ]]; then
    fail "/dev/disk/by-partuuid/${ACL_ACTIVE_USR_PARTUUID} does not exist — hardcoded UUID table is stale"
else
    GPT_NAME=$(udevadm info --query=property \
        --name="/dev/disk/by-partuuid/${ACL_ACTIVE_USR_PARTUUID}" 2>/dev/null \
        | sed -n 's/^ID_PART_ENTRY_NAME=//p')
    if [[ "$GPT_NAME" == "USR-${VOLUME}" ]]; then
        pass "GPT partition name is '${GPT_NAME}', matching slot ${VOLUME}"
    else
        fail "GPT says '${GPT_NAME}' but the module reported slot ${VOLUME} (USR-${VOLUME})"
    fi
fi

# ── 5. Confirm it really ran in the initrd ──────────────────────────
# Informational: the initrd journal is flushed into the runtime journal, so
# the unit's log lines should be visible for this boot even though the unit
# file itself does not exist on the real root.
echo ""
echo "Checking initrd journal (informational)..."
if journalctl -b -u acl-active-volume.service --no-pager 2>/dev/null | grep -q 'acl-active-volume'; then
    pass "found acl-active-volume.service log entries from this boot"
    journalctl -b -u acl-active-volume.service --no-pager -o cat 2>/dev/null | sed 's/^/  /'
else
    note "no journal entries found (initrd journal may not have been flushed; not treated as a failure)"
fi

# ── 6. SELinux label (informational) ────────────────────────────────
echo ""
echo "Checking SELinux label (informational)..."
if command -v getenforce &>/dev/null; then
    note "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"
fi
ls -Z "$MARKER" 2>/dev/null | sed 's/^/  /' || note "ls -Z unavailable"

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "========================================="
if [[ "$FAILURES" -eq 0 ]]; then
    echo "✅ Active volume marker validation PASSED (slot ${VOLUME})"
    echo "========================================="
    exit 0
fi
echo "❌ Active volume marker validation FAILED (${FAILURES} assertion(s))"
echo "========================================="
exit 1
