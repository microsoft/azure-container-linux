#!/bin/bash
# Validate the IPE permissive-mode proof of concept inside a Secure Boot VM.

set -euo pipefail

POLICY_NAME="acl_ipe_boot_policy"
IPE_DIR="/sys/kernel/security/ipe"
POLICY_DIR="${IPE_DIR}/policies/${POLICY_NAME}"

fail() {
    echo "FAILED: $*" >&2
    exit 1
}

echo "========================================="
echo "IPE Permissive Mode Validation Test"
echo "========================================="
echo ""

cmdline="$(cat /proc/cmdline)"
echo "Kernel command line: ${cmdline}"

if [[ " ${cmdline} " != *" ipe.enforce=0 "* ]]; then
    fail "expected ipe.enforce=0 in the signed kernel command line"
fi
if [[ " ${cmdline} " == *" root-hash-signature="* ]]; then
    fail "obsolete dm-verity root-hash-signature option is still present"
fi

if [[ ! -r "${IPE_DIR}/enforce" ]]; then
    fail "IPE securityfs interface is unavailable"
fi
if [[ "$(tr -d '[:space:]' < "${IPE_DIR}/enforce")" != "0" ]]; then
    fail "IPE is not in permissive mode"
fi

if [[ ! -d "${POLICY_DIR}" ]]; then
    fail "policy ${POLICY_NAME} is not loaded"
fi
if [[ "$(tr -d '[:space:]' < "${POLICY_DIR}/active")" != "1" ]]; then
    fail "policy ${POLICY_NAME} is not active"
fi

usr_hash="$(
    tr ' ' '\n' <<< "${cmdline}" |
        sed -n 's/^usrhash=//p' |
        head -n 1 |
        tr '[:upper:]' '[:lower:]'
)"
if ! [[ "${usr_hash}" =~ ^[[:xdigit:]]{64}$ ]]; then
    fail "could not read the /usr dm-verity SHA-256 root hash from the command line"
fi

policy="$(cat "${POLICY_DIR}/policy")"
grep -Fq "DEFAULT op=EXECUTE action=DENY" <<< "${policy}" ||
    fail "active policy does not deny untrusted execution by default"
grep -Fq "op=EXECUTE boot_verified=TRUE action=ALLOW" <<< "${policy}" ||
    fail "active policy does not trust boot-verified initramfs files"
grep -Fq "op=EXECUTE dmverity_roothash=sha256:${usr_hash} action=ALLOW" <<< "${policy}" ||
    fail "active policy is not bound to the booted /usr dm-verity root hash"

verity_device="$(readlink -f /dev/mapper/usr 2>/dev/null || true)"
usr_verity_mounted=false
while IFS= read -r usr_source; do
    usr_device="$(readlink -f "${usr_source}" 2>/dev/null || true)"
    if [[ -n "${verity_device}" && "${usr_device}" == "${verity_device}" ]]; then
        usr_verity_mounted=true
        break
    fi
done < <(findmnt -n -o SOURCE /usr 2>/dev/null || true)
if [[ "${usr_verity_mounted}" != "true" ]]; then
    fail "/usr mount stack does not include the expected dm-verity device"
fi

# An executable copied away from verified /usr matches the policy's deny
# default. It must still run in permissive mode while generating audit data.
probe="/var/tmp/acl-ipe-permissive-probe"
trap 'rm -f "${probe}"' EXIT
cp /usr/bin/true "${probe}"
chmod 0755 "${probe}"
"${probe}" || fail "untrusted execution was blocked in permissive mode"

boot_logs="$(
    {
        dmesg 2>/dev/null || true
        journalctl -b --no-pager 2>/dev/null || true
    } | tail -n 20000
)"
loader_errors="$(
    grep -Ei \
        'acl-ipe-load: (failed|warning)|root hash verification failed|failed to set up verity device' \
        <<< "${boot_logs}" || true
)"
if [[ -n "${loader_errors}" ]]; then
    echo "${loader_errors}" >&2
    fail "IPE or dm-verity boot errors were detected"
fi

audit_event="$(
    grep -F "${probe}" <<< "${boot_logs}" |
        grep -E 'ipe_op=EXECUTE.*enforcing=0|enforcing=0.*ipe_op=EXECUTE' ||
        true
)"
if [[ -n "${audit_event}" ]]; then
    echo "Observed permissive IPE audit event:"
    echo "${audit_event}"
else
    echo "WARNING: the permissive probe succeeded, but its audit event was not retained in the boot logs"
fi

echo ""
echo "IPE policy: ${POLICY_NAME}"
echo "IPE enforce state: 0 (permissive)"
echo "/usr dm-verity root hash: ${usr_hash}"
echo "SUCCESS: IPE is active in permissive mode with no detected boot errors"
