#!/bin/bash
# Live-VM validation of IPE audit mode with signed or unsigned /usr roots.

set -euo pipefail

ipe_cmdline_field() {
    local input="$1" name="$2" delimiter="${3:- }" field
    local -a fields=()

    IFS="${delimiter}" read -r -a fields <<< "${input}"
    for field in "${fields[@]}"; do
        if [[ "${field}" == "${name}="* ||
            ( "${name}" == systemd.verity_usr_options &&
              "${field}" == systemd.verity[-_]usr[-_]options=* ) ]]; then
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
            systemd.verity[-_]usr[-_]options=*)
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
    local cmdline="$1" table="$2" expected_mode="${3:-auto}"
    local usr_hash signature mode=none signed_mapping=false
    local -a fields=()

    case "${expected_mode}" in
        required|none|auto) ;;
        *) echo "Invalid expected /usr signature mode: ${expected_mode}" >&2; return 1 ;;
    esac
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
    if [[ "${expected_mode}" != auto && "${mode}" != "${expected_mode}" ]]; then
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
    local expected_mode="${1:-auto}" cmdline verity_device usr_source usr_device
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

ipe_find_process_denials() {
    local logs="$1" pid="$2"
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || {
        echo "Invalid IPE probe PID: ${pid}" >&2
        return 1
    }
    grep -E "(^|[[:space:]])pid=${pid}([[:space:]]|$)" <<< "${logs}" |
        grep -E '(^|[[:space:]])(IPE_ACCESS|type=1420)([[:space:]]|$)' |
        grep -E 'ipe_op=EXECUTE([[:space:]]|$)' |
        grep -E 'enforcing=0([[:space:]]|$)' |
        grep -E 'rule="[^"]*action=DENY"'
}

ipe_find_denial_event() {
    ipe_find_process_denials "$1" "$3" | grep -F "path=\"$2\""
}

ipe_assert_probe_audit() {
    local logs="$1" executable="$2" pid="$3" expected="$4" event
    if ! [[ "${pid}" =~ ^[1-9][0-9]*$ && "${expected}" =~ ^(allow|deny)$ ]]; then
        echo "Invalid IPE probe expectation or PID: ${expected}, ${pid}" >&2
        return 1
    fi
    if [[ "${expected}" == allow ]]; then
        if event="$(ipe_find_process_denials "${logs}" "${pid}")"; then
            echo "Trusted ${executable} (pid=${pid}) produced an unexpected IPE denial (target or dependency): ${event}" >&2
            return 1
        fi
        echo "No IPE denial observed for trusted ${executable} (pid=${pid}) or its dependencies"
        return 0
    fi
    if event="$(ipe_find_denial_event "${logs}" "${executable}" "${pid}")"; then
        if ! grep -Eq 'ipe_hook=BPRM_CHECK([[:space:]]|$)' <<< "${event}"; then
            echo "${executable} (pid=${pid}) has no target BPRM_CHECK denial" >&2
            return 1
        fi
        echo "Expected IPE would-deny event for ${executable} (execution succeeded in audit mode):"
        echo "${event}"
    else
        echo "${executable} (pid=${pid}) succeeded without its expected IPE denial audit event" >&2
        return 1
    fi
}

ipe_assert_usr_probe_audit() {
    local logs="$1" executable="$2" pid="$3" signature_mode="$4"
    local expected=deny
    if [[ "${signature_mode}" == required ]]; then
        expected=allow
    fi
    ipe_assert_probe_audit "${logs}" "${executable}" "${pid}" "${expected}"
}

ipe_check_sysext_inventory() {
    local available="$1" status="$2" name
    jq -e 'type == "array" and all(.[];
        (.name | type == "string") and (.path | type == "string"))' \
        <<< "${available}" >/dev/null || {
        echo "Invalid systemd-sysext image inventory" >&2
        return 1
    }
    jq -e '[.[] | select(.hierarchy == "/usr")] |
        length == 1 and (.[0].extensions | type == "array" and all(.[]; type == "string"))' \
        <<< "${status}" >/dev/null || {
        echo "No valid active /usr sysext inventory" >&2
        return 1
    }
    for name in containerd oem-azure; do
        jq -e --arg name "${name}" \
            '[.[] | select(.name == $name)] | length == 1 and
             (.[0].type == "raw") and (.[0].path | startswith("/"))' \
            <<< "${available}" >/dev/null || {
            echo "Required sysext ${name} is missing, ambiguous, or not a raw image" >&2
            return 1
        }
        jq -e --arg name "${name}" \
            '.[] | select(.hierarchy == "/usr") | .extensions | index($name) != null' \
            <<< "${status}" >/dev/null || {
            echo "Required sysext ${name} is not active on /usr" >&2
            return 1
        }
        echo "IPE_SYSEXT name=${name} active=true probe=planned"
    done
    while IFS= read -r name; do
        echo "WARN: IPE_SYSEXT name=${name} active=true coverage=UNPROBED (no safe probe defined)"
    done < <(jq -r '.[] | select(.hierarchy == "/usr") | .extensions[] |
        select(. != "containerd" and . != "oem-azure")' <<< "${status}")
}

ipe_check_probe_payload() {
    local directory="$1" origin="$2" relative="$3" target="$4"
    local provider payload count=0
    for provider in base containerd oem-azure; do
        payload="${directory}/${provider}/usr/${relative}"
        [[ "${provider}" != base ]] || payload="${directory}/base/${relative}"
        if [[ -e "${payload}" || -L "${payload}" ]]; then
            [[ "${provider}" == "${origin}" && ! -L "${payload}" && -f "${payload}" ]] || {
                echo "Ambiguous probe provider: ${target} also exists in ${provider}" >&2
                return 1
            }
            cmp -- "${target}" "${payload}" || {
                echo "Probe content does not match ${origin}: ${target}" >&2
                return 1
            }
            [[ "$(stat -Lc %i "${target}")" == "$(stat -Lc %i "${payload}")" ]] || {
                echo "Probe inode does not match ${origin}: ${target}" >&2
                return 1
            }
            count=$((count + 1))
        fi
    done
    [[ "${count}" == 1 ]] || { echo "Missing payload for ${origin}:${target}" >&2; return 1; }
    echo "IPE_ORIGIN expected=${origin} target=${target} payload=matched"
}

ipe_verify_probe_payloads() {
    local directory="$1" available="$2" containerd_image oem_image
    containerd_image="$(jq -r '.[] | select(.name == "containerd") | .path' <<< "${available}")"
    oem_image="$(jq -r '.[] | select(.name == "oem-azure") | .path' <<< "${available}")"
    export -f ipe_check_probe_payload
    # Sysext lowerdirs are in a private namespace; inspect fixed payloads in
    # our own namespace, without unmerging /usr or changing the host mounts.
    unshare --mount --propagation private bash -s -- \
        "${directory}" "${containerd_image}" "${oem_image}" <<'EOF'
set -euo pipefail
directory="$1"
mkdir "${directory}/base" "${directory}/containerd" "${directory}/oem-azure"
mount -o ro,nosuid,nodev,noexec /dev/mapper/usr "${directory}/base"
for name in containerd oem-azure; do
    image="$2"
    [[ "${name}" != oem-azure ]] || image="$3"
    image="$(readlink -f "${image}")"
    source_image="${image}"
    if [[ "${image}" == /usr/* ]]; then
        source_image="${directory}/base/${image#/usr/}"
        cmp -- "${image}" "${source_image}"
    fi
    # Looking up a loop by the merged /usr pathname can miss its real inode.
    loop="$(losetup -j "${source_image}" --noheadings --output NAME)"
    [[ "${loop}" =~ ^/dev/loop[0-9]+$ ]] || {
        echo "Could not uniquely resolve the active ${name} loop device" >&2
        exit 1
    }
    [[ "$(blkid -s TYPE -o value "${loop}")" == squashfs ]] || {
        echo "${name} does not have the expected unsigned squashfs backing" >&2
        exit 1
    }
    echo "IPE_BACKING name=${name} image=${image} device=${loop} expected=unsigned"
    mount -t squashfs -o ro,nosuid,nodev,noexec "${loop}" "${directory}/${name}"
done
for spec in base:/usr/bin/true base:/usr/bin/bash base:/usr/bin/systemctl \
    containerd:/usr/bin/containerd oem-azure:/usr/sbin/chronyd; do
    origin="${spec%%:*}"
    target="$(readlink -f "${spec#*:}")"
    [[ "${target}" == /usr/* && -f "${target}" && -x "${target}" ]] || {
        echo "Invalid executable probe target: ${spec}" >&2
        exit 1
    }
    ipe_check_probe_payload "${directory}" "${origin}" "${target#/usr/}" "${target}"
done
EOF
}

ipe_run_probe() {
    local directory="$1" name="$2" status=0 command
    shift 2
    printf -v command '%q ' "$@"
    printf '%s\n' "${command% }" > "${directory}/${name}.command" || return 1
    timeout --signal=KILL 15s bash --noprofile --norc -p -c \
        'printf "%s\n" "$$" > "$1"; shift; exec "$@"' -- \
        "${directory}/${name}.pid" "$@" \
        > "${directory}/${name}.stdout" 2> "${directory}/${name}.stderr" || status=$?
    printf '%s\n' "${status}" > "${directory}/${name}.status"
}

ipe_run_base_probes() {
    local directory="$1" true_probe="$2" bash_probe="$3" systemctl_probe="$4"
    ipe_run_probe "${directory}" base "${true_probe}"
    # Privileged mode ignores BASH_ENV and imported functions/options.
    ipe_run_probe "${directory}" base-bash "${bash_probe}" --noprofile --norc -p -c ':'
    ipe_run_probe "${directory}" base-systemctl "${systemctl_probe}" --version
}

ipe_collect_probe_audit() {
    local directory="$1" boot_id="$2" cursor="$3" control="$4" pid="$5"
    local attempt logs
    for ((attempt = 0; attempt < 15; attempt++)); do
        [[ "$(cat /proc/sys/kernel/random/boot_id)" == "${boot_id}" ]] || {
            echo "Boot changed during IPE audit capture" >&2
            return 1
        }
        journalctl --boot="${boot_id}" --after-cursor="${cursor}" \
            _TRANSPORT=audit --no-pager -o cat > "${directory}/audit.log" || {
            echo "Could not read the probe audit window" >&2
            return 1
        }
        logs="$(cat "${directory}/audit.log")"
        if ipe_find_denial_event "${logs}" "${control}" "${pid}" |
            grep -Eq 'ipe_hook=BPRM_CHECK([[:space:]]|$)'; then
            # Drain delayed records before judging absence for earlier probes.
            sleep 2
            journalctl --boot="${boot_id}" --after-cursor="${cursor}" \
                _TRANSPORT=audit --no-pager -o cat > "${directory}/audit.log" || return 1
            [[ "$(cat /proc/sys/kernel/random/boot_id)" == "${boot_id}" ]] || return 1
            ipe_find_denial_event "$(cat "${directory}/audit.log")" "${control}" "${pid}" |
                grep -Eq 'ipe_hook=BPRM_CHECK([[:space:]]|$)' || {
                echo "Final control record disappeared during audit collection" >&2
                return 1
            }
            return 0
        fi
        sleep 1
    done
    echo "Audit telemetry failed: no fresh target BPRM_CHECK denial for the final writable control" >&2
    return 1
}

ipe_report_probe() {
    local directory="$1" name="$2" target="$3" expected="$4" telemetry="$5"
    local pid status events dependencies observed=NO_DENIAL_OBSERVED result=PASS hooks=- message
    local command stream line
    if ! command="$(cat "${directory}/${name}.command")"; then
        echo "IPE_PROBE name=${name} result=FAIL reason=missing-command"
        return 1
    fi
    printf 'Probe: %s\nCommand: %s\n' "${name}" "${command}"
    for stream in stdout stderr; do
        printf '%s:\n' "${stream}"
        if [[ ! -r "${directory}/${name}.${stream}" ]]; then
            echo "IPE_PROBE name=${name} result=FAIL reason=missing-${stream}"
            return 1
        elif [[ -s "${directory}/${name}.${stream}" ]]; then
            while IFS= read -r line || [[ -n "${line}" ]]; do
                printf '  %s\n' "${line}"
            done < "${directory}/${name}.${stream}" || return 1
        else
            printf '  <empty>\n'
        fi
    done
    if ! pid="$(cat "${directory}/${name}.pid")"; then
        echo "IPE_PROBE name=${name} result=FAIL reason=missing-execution-pid"
        return 1
    fi
    status="$(cat "${directory}/${name}.status")" || return 1
    events="$(ipe_find_denial_event "$(cat "${directory}/audit.log")" "${target}" "${pid}" || true)"
    if [[ -n "${events}" ]]; then
        observed=WOULD_DENY
        hooks="$(sed -n 's/.*ipe_hook=\([^ ]*\).*/\1/p' <<< "${events}" | sort -u | paste -sd,)"
    fi
    if [[ "${status}" != 0 ]]; then
        result=FAIL
        message="execution failed (exit=${status})"
    elif [[ "${telemetry}" != pass ]]; then
        result=FAIL
        observed=UNKNOWN
        message="audit telemetry unavailable; absence is not a pass"
    elif ! message="$(ipe_assert_probe_audit "$(cat "${directory}/audit.log")" "${target}" "${pid}" "${expected}" 2>&1)"; then
        result=FAIL
    fi
    echo "IPE_PROBE name=${name} target=${target} pid=${pid} exit=${status} expected=${expected} observed=${observed} hooks=${hooks} result=${result}"
    [[ -z "${events}" ]] || printf '  %s\n' "${events}"
    dependencies="$(ipe_find_process_denials "$(cat "${directory}/audit.log")" "${pid}" |
        grep -Fv "path=\"${target}\"" || true)"
    if [[ -n "${dependencies}" ]]; then
        echo "  IPE dependency denials (not target-file verdicts):"
        printf '  %s\n' "${dependencies}"
    fi
    if [[ "${result}" != PASS ]]; then
        echo "  ${message}"
        return 1
    fi
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
        required|none|auto) ;;
        *) fail "--verity-only requires an expected signature mode: required, none or auto" ;;
    esac
    [[ "$#" -eq 2 ]] || fail "Unexpected arguments after --verity-only mode"
    ipe_check_usr_verity "$2" || fail "/usr dm-verity validation failed"
    exit 0
fi

expected_usr_signature_mode=auto
if [[ "${1:-}" == "--expected-usr-signature-mode" && "$#" -eq 2 ]]; then
    expected_usr_signature_mode="$2"
elif [[ "$#" -ne 0 ]]; then
    fail "Usage: $0 [--expected-usr-signature-mode required|none|auto]"
fi
case "${expected_usr_signature_mode}" in
    required|none|auto) ;;
    *) fail "Invalid expected /usr signature mode: ${expected_usr_signature_mode}" ;;
esac

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

usr_signature_mode="$(ipe_check_usr_verity "${expected_usr_signature_mode}")" ||
    fail "/usr dm-verity validation failed"

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

probe_dir="$(mktemp -d /var/tmp/acl-ipe-audit.XXXXXX)" ||
    fail "could not create the probe workspace"
trap 'rm -rf -- "${probe_dir}"' EXIT
available_sysexts="$(systemd-sysext list --json=short)" ||
    fail "could not discover available sysexts"
active_sysexts="$(systemd-sysext status --json=short)" ||
    fail "could not discover active sysexts"
ipe_check_sysext_inventory "${available_sysexts}" "${active_sysexts}" ||
    fail "required sysext coverage is unavailable"
ipe_verify_probe_payloads "${probe_dir}" "${available_sysexts}" ||
    fail "could not verify the fixed probe payloads"

usr_probe="$(readlink -f /usr/bin/true)" || fail "could not resolve /usr probe"
bash_probe="$(readlink -f /usr/bin/bash)" || fail "could not resolve base Bash probe"
systemctl_probe="$(readlink -f /usr/bin/systemctl)" || fail "could not resolve base systemctl probe"
containerd_probe="$(readlink -f /usr/bin/containerd)" || fail "could not resolve containerd probe"
oem_probe="$(readlink -f /usr/sbin/chronyd)" || fail "could not resolve OEM probe"
probe="${probe_dir}/writable-true"
cp "${usr_probe}" "${probe}"
chmod 0755 "${probe}"
boot_id="$(cat /proc/sys/kernel/random/boot_id)"
cursor_output="$(journalctl -b -n 0 --show-cursor --no-pager)" ||
    fail "could not establish the journal cursor"
cursor="$(sed -n 's/^-- cursor: //p' <<< "${cursor_output}")"
[[ -n "${cursor}" ]] || fail "journal did not return a cursor"
echo "IPE_REPORT schema=1 boot=${boot_id} kernel=$(uname -r) policy=${POLICY_NAME} enforce=0 usr_signature=${usr_signature_mode}"
echo "IPE_CAPTURE transport=audit after_cursor=${cursor}"
# The final known-denial control establishes collection health for earlier probes.
ipe_run_base_probes "${probe_dir}" "${usr_probe}" "${bash_probe}" "${systemctl_probe}"
ipe_run_probe "${probe_dir}" containerd "${containerd_probe}" --version
ipe_run_probe "${probe_dir}" oem-azure "${oem_probe}" -v
ipe_run_probe "${probe_dir}" writable "${probe}"
telemetry=fail
if [[ -r "${probe_dir}/writable.pid" ]] &&
    ipe_collect_probe_audit "${probe_dir}" "${boot_id}" "${cursor}" \
        "${probe}" "$(cat "${probe_dir}/writable.pid")"; then
    telemetry=pass
fi
[[ -f "${probe_dir}/audit.log" ]] || : > "${probe_dir}/audit.log"
usr_expected=deny
[[ "${usr_signature_mode}" != required ]] || usr_expected=allow
probe_failures=0
ipe_report_probe "${probe_dir}" base "${usr_probe}" "${usr_expected}" "${telemetry}" || probe_failures=1
ipe_report_probe "${probe_dir}" base-bash "${bash_probe}" "${usr_expected}" "${telemetry}" || probe_failures=1
ipe_report_probe "${probe_dir}" base-systemctl "${systemctl_probe}" "${usr_expected}" "${telemetry}" || probe_failures=1
ipe_report_probe "${probe_dir}" containerd "${containerd_probe}" deny "${telemetry}" || probe_failures=1
ipe_report_probe "${probe_dir}" oem-azure "${oem_probe}" deny "${telemetry}" || probe_failures=1
ipe_report_probe "${probe_dir}" writable "${probe}" deny "${telemetry}" || probe_failures=1
[[ "${probe_failures}" == 0 ]] || fail "IPE probe matrix failed"
[[ "$(tr -d '[:space:]' < "${IPE_DIR}/enforce")" == 0 &&
   "$(tr -d '[:space:]' < "${POLICY_DIR}/active")" == 1 ]] ||
    fail "IPE state changed during the probe matrix"

# Boot diagnostics are separate from the cursor-bound probe evidence.
boot_logs="$(journalctl -b --no-pager -o cat)" || fail "could not read boot diagnostics"
loader_errors="$(
    grep -Ei \
        'acl-ipe-load: (failed|warning)|root hash verification failed|root[- ]hash signature.*(failed|invalid|error)|failed to (set up|activate).*verity|ENOKEY|required key not available' \
        <<< "${boot_logs}" || true
)"
if [[ -n "${loader_errors}" ]]; then
    echo "${loader_errors}" >&2
    fail "IPE or dm-verity boot errors were detected"
fi
echo ""
echo "IPE policy: ${POLICY_NAME}"
echo "IPE enforce state: 0 (audit)"
echo "/usr dm-verity root hash: ${usr_hash}"
echo "/usr dm-verity signature mode: ${usr_signature_mode}"
echo "SUCCESS: IPE is active in audit mode with no detected boot errors"
