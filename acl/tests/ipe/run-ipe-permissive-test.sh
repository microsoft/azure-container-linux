#!/bin/bash
# Live-VM validation of policy-only IPE permissive mode.

set -euo pipefail

ipe_cmdline_field() {
    local input="$1" name="$2" delimiter="${3:- }" field
    local -a fields=()

    IFS="${delimiter}" read -r -a fields <<< "${input}"
    for field in "${fields[@]}"; do
        if [[ "${field}" == "${name}="* ]]; then
            printf '%s\n' "${field#*=}"
            return 0
        fi
    done
    printf '\n'
}

ipe_has_root_hash_signature() {
    local word option
    local -a options=()

    for word in $1; do
        case "${word}" in
            root-hash-signature=*) return 0 ;;
            systemd.verity_usr_options=*)
                IFS=, read -r -a options <<< "${word#*=}"
                for option in "${options[@]}"; do
                    [[ "${option}" != root-hash-signature=* ]] || return 0
                done
                ;;
        esac
    done
    return 1
}

ipe_find_denial_event() {
    local logs="$1" executable="$2" pid="$3"
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || {
        echo "Invalid IPE probe PID: ${pid}" >&2
        return 1
    }
    grep -F "path=\"${executable}\"" <<< "${logs}" |
        grep -E "(^|[[:space:]])pid=${pid}([[:space:]]|$)" |
        grep -E 'ipe_op=EXECUTE([[:space:]]|$)' |
        grep -E 'enforcing=0([[:space:]]|$)' |
        grep -E 'rule="[^"]*action=DENY"'
}

# Sourcing exposes the helpers to host tests without running guest assertions.
# Stdin scripts have no BASH_SOURCE path, so they still execute on the guest.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

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

if [[ " ${cmdline} " == *" ipe.enforce="* ]]; then
    fail "IPE mode must be selected at runtime, not by the signed kernel command line"
fi
usr_hash="$(ipe_cmdline_field "${cmdline}" usrhash)"
usr_hash="${usr_hash,,}"
if ! [[ "${usr_hash}" =~ ^[[:xdigit:]]{64}$ ]]; then
    fail "could not read the /usr dm-verity SHA-256 root hash from the command line"
fi
if ipe_has_root_hash_signature "${cmdline}"; then
    fail "policy-only IPE must not require a /usr root-hash signature"
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

policy="$(cat "${POLICY_DIR}/policy")"
grep -Fq "DEFAULT op=EXECUTE action=DENY" <<< "${policy}" ||
    fail "active policy does not deny untrusted execution by default"
grep -Fq "op=EXECUTE boot_verified=TRUE action=ALLOW" <<< "${policy}" ||
    fail "active policy does not trust boot-verified initramfs files"
grep -Fq "op=EXECUTE dmverity_signature=TRUE action=ALLOW" <<< "${policy}" ||
    fail "active policy does not trust verified dm-verity signatures"
if grep -Fq "dmverity_roothash=" <<< "${policy}"; then
    fail "active policy must not contain dmverity_roothash rules"
fi

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

verity_name="$(
    dmsetup info --columns --noheadings --options name "${verity_device}" 2>/dev/null |
        xargs
)"
if [[ -z "${verity_name}" ]]; then
    fail "could not resolve the active /usr dm-verity mapping"
fi
verity_table="$(dmsetup table --showkeys "${verity_name}" 2>/dev/null)" ||
    fail "could not read the active /usr dm-verity table"
if ! grep -Eq "(^|[[:space:]])${usr_hash}([[:space:]]|$)" <<< "${verity_table}"; then
    fail "active /usr dm-verity table does not contain the UKI root hash"
fi
if grep -Eq '(^|[[:space:]])root_hash_sig_key_desc([[:space:]]|$)' \
    <<< "${verity_table}"; then
    fail "policy-only /usr dm-verity mapping unexpectedly requires a root-hash signature"
fi

# Neither unsigned /usr nor writable storage matches the signature allow rule.
# Record each exec PID so older audit events cannot satisfy these probes.
usr_probe="$(readlink -f /usr/bin/true)" || fail "could not resolve /usr probe"
[[ "${usr_probe}" == /usr/* ]] || fail "probe executable is not on /usr"
usr_probe_pid="$(bash -c 'printf "%s\n" "$$"; exec "$1"' -- "${usr_probe}")" ||
    fail "/usr execution was blocked in permissive mode"
probe="$(mktemp /var/tmp/acl-ipe-permissive-probe.XXXXXX)" ||
    fail "could not create writable-storage probe"
trap 'rm -f "${probe}"' EXIT
cp "${usr_probe}" "${probe}"
chmod 0755 "${probe}"
probe_pid="$(bash -c 'printf "%s\n" "$$"; exec "$1"' -- "${probe}")" ||
    fail "writable-storage execution was blocked in permissive mode"

boot_logs="$(
    {
        dmesg 2>/dev/null || true
        journalctl -b --no-pager 2>/dev/null || true
    } | tail -n 20000
)"
loader_errors="$(
    grep -Ei \
        'acl-ipe-load: (failed|warning)|root hash verification failed|root[- ]hash signature.*(failed|invalid|error)|failed to (set up|activate).*verity|ENOKEY|required key not available' \
        <<< "${boot_logs}" || true
)"
if [[ -n "${loader_errors}" ]]; then
    echo "${loader_errors}" >&2
    fail "IPE or dm-verity boot errors were detected"
fi
probes=("${usr_probe}" "${probe}")
probe_pids=("${usr_probe_pid}" "${probe_pid}")
for index in "${!probes[@]}"; do
    audit_event="$(ipe_find_denial_event \
        "${boot_logs}" "${probes[index]}" "${probe_pids[index]}")" ||
        fail "${probes[index]} (pid=${probe_pids[index]}) succeeded without its expected IPE denial audit event"
    echo "Observed permissive IPE audit event for ${probes[index]}:"
    echo "${audit_event}"
done

echo ""
echo "IPE policy: ${POLICY_NAME}"
echo "IPE enforce state: 0 (permissive)"
echo "/usr dm-verity root hash: ${usr_hash}"
echo "/usr dm-verity mapping: ${verity_name} (no root-hash signature required)"
echo "SUCCESS: IPE is active in permissive mode with no detected boot errors"
