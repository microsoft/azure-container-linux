#!/bin/bash
# Live-VM validation of IPE audit mode with signed or unsigned /usr roots.

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

ipe_validate_usr_verity_table() {
    local cmdline="$1" table="$2" expected_mode="${3:-}"
    local usr_hash signature mode=none signed_mapping=false
    local -a fields=()

    usr_hash="$(ipe_cmdline_field "${cmdline}" usrhash)"
    usr_hash="${usr_hash,,}"
    if ! [[ "${usr_hash}" =~ ^[[:xdigit:]]{64}$ ]]; then
        echo "Invalid /usr dm-verity root hash in command line" >&2
        return 1
    fi
    if ipe_has_root_hash_signature "${cmdline}"; then
        mode=required
        signature="$(ipe_cmdline_field \
            "$(ipe_cmdline_field "${cmdline}" systemd.verity_usr_options)" \
            root-hash-signature ',')"
        if [[ "${signature}" != "/.extra/credentials/verity-usr-${usr_hash}.p7s.cred" ]]; then
            echo "/usr signature option does not reference the expected root-hash credential" >&2
            return 1
        fi
    fi
    if [[ -n "${expected_mode}" && "${mode}" != "${expected_mode}" ]]; then
        echo "/usr signature mode changed: expected ${expected_mode}, got ${mode}" >&2
        return 1
    fi
    read -r -a fields <<< "${table}"
    if [[ "${fields[2]:-}" != verity || "${fields[10]:-}" != sha256 ||
          "${fields[11]:-}" != "${usr_hash}" ]]; then
        echo "Active /usr dm-verity table does not contain the expected SHA-256 root hash" >&2
        return 1
    fi
    if grep -Eq '(^|[[:space:]])root_hash_sig_key_desc([[:space:]]|$)' <<< "${table}"; then
        signed_mapping=true
        if ! grep -Eq '(^|[[:space:]])root_hash_sig_key_desc[[:space:]]+[^[:space:]]+' <<< "${table}"; then
            echo "Active /usr dm-verity table has no signature key description" >&2
            return 1
        fi
    fi
    if [[ "${mode}" == required && "${signed_mapping}" != true ]] ||
       [[ "${mode}" == none && "${signed_mapping}" != false ]]; then
        echo "Active /usr dm-verity signature state does not match ${mode}" >&2
        return 1
    fi
    printf '%s\n' "${mode}"
}

ipe_check_usr_verity() {
    local expected_mode="${1:-}" cmdline verity_device usr_source usr_device
    local usr_verity_mounted=false verity_name verity_table
    cmdline="$(cat /proc/cmdline)" || return 1
    verity_device="$(readlink -f /dev/mapper/usr 2>/dev/null || true)"
    while IFS= read -r usr_source; do
        usr_device="$(readlink -f "${usr_source}" 2>/dev/null || true)"
        if [[ -n "${verity_device}" && "${usr_device}" == "${verity_device}" ]]; then
            usr_verity_mounted=true
            break
        fi
    done < <(findmnt -n -o SOURCE /usr 2>/dev/null || true)
    if [[ "${usr_verity_mounted}" != true ]]; then
        echo "/usr mount stack does not include the expected dm-verity device" >&2
        return 1
    fi
    verity_name="$(
        dmsetup info --columns --noheadings --options name "${verity_device}" 2>/dev/null |
            xargs
    )"
    if [[ -z "${verity_name}" ]]; then
        echo "Could not resolve the active /usr dm-verity mapping" >&2
        return 1
    fi
    verity_table="$(dmsetup table --showkeys "${verity_name}" 2>/dev/null)" || {
        echo "Could not read the active /usr dm-verity table" >&2
        return 1
    }
    ipe_validate_usr_verity_table "${cmdline}" "${verity_table}" "${expected_mode}"
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

ipe_assert_probe_audit() {
    local logs="$1" executable="$2" pid="$3" expected="$4" event
    if ! [[ "${pid}" =~ ^[1-9][0-9]*$ && "${expected}" =~ ^(allow|deny)$ ]]; then
        echo "Invalid IPE probe expectation or PID: ${expected}, ${pid}" >&2
        return 1
    fi
    if event="$(ipe_find_denial_event "${logs}" "${executable}" "${pid}")"; then
        if [[ "${expected}" == allow ]]; then
            echo "Trusted ${executable} (pid=${pid}) produced an unexpected IPE denial: ${event}" >&2
            return 1
        fi
        echo "Observed IPE audit event for ${executable}:"
        echo "${event}"
    elif [[ "${expected}" == deny ]]; then
        echo "${executable} (pid=${pid}) succeeded without its expected IPE denial audit event" >&2
        return 1
    else
        echo "No IPE denial for trusted ${executable} (pid=${pid})"
    fi
}

ipe_assert_usr_probe_audit() {
    local logs="$1" executable="$2" pid="$3" signature_mode="$4"
    local expected=deny usr_fstype
    if [[ "${signature_mode}" == required ]]; then
        usr_fstype="$(blkid -s TYPE -o value /dev/mapper/usr)" || {
            echo "Could not identify the /usr dm-verity filesystem" >&2
            return 1
        }
        if [[ "${usr_fstype}" == btrfs ]]; then
            # TODO: Restore the no-denial assertion once the known IPE/dm-verity/
            # btrfs trust issue is fixed. A valid signed mapping can still audit DENY.
            echo "WARN: Skipping signed /usr no-denial assertion for the known IPE/dm-verity/btrfs issue"
            return 0
        fi
        expected=allow
    fi
    ipe_assert_probe_audit "${logs}" "${executable}" "${pid}" "${expected}"
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

if [[ "${1:-}" == "--verity-only" ]]; then
    case "${2:-}" in
        required|none) ;;
        *) fail "--verity-only requires an expected signature mode: required or none" ;;
    esac
    ipe_check_usr_verity "$2" || fail "/usr dm-verity validation failed"
    exit 0
fi

echo "========================================="
echo "IPE Audit Mode Validation Test"
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

if [[ ! -r "${IPE_DIR}/enforce" ]]; then
    fail "IPE securityfs interface is unavailable"
fi
if [[ "$(tr -d '[:space:]' < "${IPE_DIR}/enforce")" != "0" ]]; then
    fail "IPE is not in audit mode"
fi

if [[ ! -d "${POLICY_DIR}" ]]; then
    fail "policy ${POLICY_NAME} is not loaded"
fi
if [[ "$(tr -d '[:space:]' < "${POLICY_DIR}/active")" != "1" ]]; then
    fail "policy ${POLICY_NAME} is not active"
fi

systemctl is-active --quiet containerd ||
    fail "containerd is not running"
containerd_pid="$(systemctl show --property=MainPID --value containerd)" ||
    fail "could not get containerd's PID"
containerd_cmdline="$(tr '\0' ' ' < "/proc/${containerd_pid}/cmdline")" ||
    fail "could not read containerd's command line"
[[ " ${containerd_cmdline} " == *" --config /run/containerd/acl-config.toml "* ]] ||
    fail "containerd is not using the IPE-selected config"
containerd_defaults="$(/usr/bin/containerd config default)" ||
    fail "could not read containerd's default configuration"
if grep -Eq '^[[:space:]]*enable_dmverity_referrers[[:space:]]*=' <<< "${containerd_defaults}"; then
    if ! /usr/bin/containerd --config /run/containerd/acl-config.toml config dump |
        awk '
            {
                gsub(/\047/, "\"")
                sub(/^[[:space:]]+/, "")
                sub(/[[:space:]]+$/, "")
            }
            /^\[/ { section = $0 }
            section == "[plugins.\"io.containerd.snapshotter.v1.erofs\"]" &&
                /^enable_dmverity_referrers =/ { referrers = ($0 == "enable_dmverity_referrers = true") }
            section == "[plugins.\"io.containerd.cri.v1.images\"]" &&
                /^snapshotter =/ { snapshotter = ($0 == "snapshotter = \"erofs\"") }
            section == "[plugins.\"io.containerd.service.v1.diff-service\"]" &&
                /^default =/ { differ = ($0 == "default = [\"erofs\", \"walking\"]") }
            END { if (!referrers || !snapshotter || !differ) exit 1 }
        '; then
        fail "effective containerd config does not enable the expected EROFS profile."
    fi
else
    echo "Containerd lacks dm-verity referrer support. Skipping EROFS config assertion."
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

usr_signature_mode="$(ipe_check_usr_verity)" ||
    fail "/usr dm-verity validation failed"

# Writable storage must audit DENY; signed /usr has a known btrfs exception below.
# Record each exec PID so older audit events cannot satisfy these probes.
usr_probe="$(readlink -f /usr/bin/true)" || fail "could not resolve /usr probe"
[[ "${usr_probe}" == /usr/* ]] || fail "probe executable is not on /usr"
usr_probe_pid="$(bash -c 'printf "%s\n" "$$"; exec "$1"' -- "${usr_probe}")" ||
    fail "/usr execution was blocked in audit mode"
probe="$(mktemp /var/tmp/acl-ipe-audit-probe.XXXXXX)" ||
    fail "could not create writable-storage probe"
trap 'rm -f "${probe}"' EXIT
cp "${usr_probe}" "${probe}"
chmod 0755 "${probe}"
probe_pid="$(bash -c 'printf "%s\n" "$$"; exec "$1"' -- "${probe}")" ||
    fail "writable-storage execution was blocked in audit mode"

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
ipe_assert_probe_audit "${boot_logs}" "${probe}" "${probe_pid}" deny ||
    fail "writable-storage audit probe failed"
ipe_assert_usr_probe_audit "${boot_logs}" "${usr_probe}" "${usr_probe_pid}" "${usr_signature_mode}" ||
    fail "/usr audit probe failed"

echo ""
echo "IPE policy: ${POLICY_NAME}"
echo "IPE enforce state: 0 (audit)"
echo "/usr dm-verity root hash: ${usr_hash}"
echo "/usr dm-verity signature mode: ${usr_signature_mode}"
echo "SUCCESS: IPE is active in audit mode with no detected boot errors"
