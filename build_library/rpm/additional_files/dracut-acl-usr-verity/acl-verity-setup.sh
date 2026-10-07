#!/bin/bash
# Sole owner of /usr activation. The generator's device ordering is retained.
set -euo pipefail
export PATH="/usr/lib/acl/initrd-bin:${PATH}"
RUN_DIR="${ACL_VERITY_RUN_DIR:-/run/acl}"
CMDLINE_FILE="${ACL_VERITY_CMDLINE_FILE:-/proc/cmdline}"
VERITYSETUP="${ACL_VERITYSETUP:-/usr/lib/systemd/systemd-veritysetup}"
PAYLOAD_HELPER="${ACL_VERITY_PAYLOAD_HELPER:-/usr/lib/acl/acl-usr-verity-payload.sh}"
PROFILE_HELPER="${ACL_VERITY_PROFILE_HELPER:-/usr/lib/acl/acl-node-security-profile.sh}"

log() { echo "acl-verity-setup: $*" >&2; }

acl_verity_arg() {
    local key="$1" word value="" count=0
    for word in "${words[@]}"; do
        if [[ "${word}" == "${key}="* ]]; then
            value="${word#*=}"
            count=$((count + 1))
        fi
    done
    (( count <= 1 )) || { log "Duplicate ${key}"; return 1; }
    printf '%s' "${value}"
}

acl_verity_profile() {
    # shellcheck source=build_library/rpm/additional_files/acl-node-security-profile.sh
    source "${PROFILE_HELPER}"
    ACL_SECURITY_PROFILE_CACHE="${RUN_DIR}/ipe-early-profile"
    # shellcheck disable=SC2034 # Consumed by the sourced profile reader.
    ACL_SECURITY_PROFILE_FAILURE_CACHE="${ACL_SECURITY_PROFILE_CACHE}.failed"
    acl_usrbin() { command "$@"; }
    acl_security_profile
}

acl_verity_status() {
    local verification="$1" reason="$2"
    jq -n --arg slot "${slot}" --arg hash "${root_hash}" --arg mode "${mode}" \
        --arg verification "${verification}" --arg reason "${reason}" \
        '{version:1,slot:$slot,rootHash:$hash,requestedMode:$mode,verification:$verification,reason:$reason}' \
        > "${RUN_DIR}/usr-verity.json.tmp" || return 1
    mv -f "${RUN_DIR}/usr-verity.json.tmp" "${RUN_DIR}/usr-verity.json" || return 1
    log "mode=${mode} verification=${verification} reason=${reason}"
}

acl_verity_mapping_exists() {
    [[ -e /dev/mapper/usr ]] || dmsetup info usr > /dev/null 2>&1
}

acl_verity_unsigned() {
    local verification="$1" reason="$2"
    if acl_verity_mapping_exists; then
        log "Refusing to reuse an existing /usr mapping with unknown verification state"
        return 1
    fi
    "${VERITYSETUP}" attach usr "${data_device}" "${hash_device}" "${root_hash}" "${options}" ||
        return 1
    acl_verity_status "${verification}" "${reason}"
}

acl_verity_signature_device() {
    local uuid="$1" disk hash_disk type expected_type device label part_uuid part_type count=0 found=""
    disk="$(lsblk -nro PKNAME "${data_device}")"
    hash_disk="$(lsblk -nro PKNAME "${hash_device}")"
    [[ -n "${disk}" && "${disk}" == "${hash_disk}" && "${disk}" != *$'\n'* ]] || return 1
    case "$(uname -m)" in
        x86_64) expected_type=e7bb33fb-06cf-4e81-8273-e543b413e2e2 ;;
        aarch64) expected_type=c23ce4ff-44bd-4b00-b2d4-b41b3419e02a ;;
        *) return 1 ;;
    esac
    # Resolve on the data disk, not through a globally ambiguous PARTUUID symlink.
    while read -r device part_uuid label type; do
        [[ "${part_uuid,,}" == "${uuid}" ]] || continue
        part_type="${type,,}"
        [[ "${label}" == "HASH-SIG-${slot^^}" && "${part_type}" == "${expected_type}" ]] || return 1
        found="${device}"
        count=$((count + 1))
    done < <(lsblk -rpn -o PATH,PARTUUID,PARTLABEL,PARTTYPE "/dev/${disk}")
    (( count == 1 )) && printf '%s\n' "${found}"
}

acl_verity_signed() {
    local signature="$1"
    if acl_verity_mapping_exists; then
        log "Refusing to call an already active mapping signature-verified"
        return 1
    fi
    if timeout --kill-after=2s 30s \
        "${VERITYSETUP}" attach usr "${data_device}" "${hash_device}" \
        "${root_hash}" "${options},root-hash-signature=${signature}"; then
        acl_verity_status verified kernel-verified || return 1
        return 0
    fi
    log "Signed activation failed; retrying ordinary dm-verity with the same root hash"
    acl_verity_unsigned degraded signed-activation-failed
}

acl_verity_main() {
    local cmdline profile requested token signature_ref signature_uuid signature_device capacity count
    local -a words
    read -r cmdline < "${CMDLINE_FILE}" || { log "Could not read kernel command line"; return 1; }
    read -r -a words <<< "${cmdline}"
    root_hash="$(acl_verity_arg usrhash)" || return 1
    slot="$(acl_verity_arg acl.slot)" || return 1
    data_device="$(acl_verity_arg systemd.verity_usr_data)" || return 1
    hash_device="$(acl_verity_arg systemd.verity_usr_hash)" || return 1
    options="$(acl_verity_arg systemd.verity_usr_options)" || return 1
    signature_ref="$(acl_verity_arg acl.verity_usr_signature)" || return 1
    [[ "${root_hash}" =~ ^[0-9a-f]{64}$ && "${slot}" =~ ^[ab]$ ]] ||
        { log "Invalid root hash or slot"; return 1; }
    for token in "${data_device}" "${hash_device}"; do
        [[ "${token}" =~ ^PARTUUID=[0-9a-fA-F-]{36}$ ]] ||
            { log "Expected explicit data/hash PARTUUIDs"; return 1; }
    done
    [[ "${options}" == panic-on-corruption ]] ||
        { log "Unsupported signed-root activation options: ${options}"; return 1; }
    data_device="/dev/disk/by-partuuid/${data_device#PARTUUID=}"
    hash_device="/dev/disk/by-partuuid/${hash_device#PARTUUID=}"
    mkdir -p "${RUN_DIR}"
    chmod 700 "${RUN_DIR}"
    mode=off
    if [[ -z "${signature_ref}" ]]; then
        acl_verity_unsigned not-requested legacy-image
        return
    fi
    if [[ " ${cmdline} " == *" flatcar.oem.id=azure "* ]]; then
        if profile="$(timeout --kill-after=2s 25s "${BASH_SOURCE[0]}" --profile)"; then
            requested=""
            count=0
            for token in ${profile//,/ }; do
                [[ "${token}" == ipe=* ]] || continue
                count=$((count + 1))
                (( count == 1 )) || { log "Duplicate IPE mode"; mode=unavailable; break; }
                requested="${token#ipe=}"
            done
            if [[ "${mode}" != unavailable ]]; then
                case "${requested}" in
                    audit) mode=audit ;;
                    ""|off|disabled) ;;
                    *) log "Unsupported IPE mode '${requested}'; leaving IPE inactive" ;;
                esac
            fi
        else
            mode=unavailable
            log "Early IMDS lookup failed or exceeded 25 seconds; leaving IPE inactive"
        fi
    fi
    if [[ "${mode}" == unavailable ]]; then
        printf 'lookup-failed\n' > "${RUN_DIR}/ipe-early-mode"
        acl_verity_unsigned degraded mode-lookup-failed
        return
    fi
    printf '%s\n' "${mode}" > "${RUN_DIR}/ipe-early-mode"
    if [[ "${mode}" != audit ]]; then
        acl_verity_unsigned not-requested audit-not-requested
        return
    fi
    signature_uuid="${signature_ref#PARTUUID=}"
    if [[ "${signature_ref}" != PARTUUID=* || ! "${signature_uuid}" =~ ^[0-9a-f-]{36}$ ]]; then
        acl_verity_unsigned degraded invalid-signature-partuuid
        return
    fi
    if ! signature_device="$(acl_verity_signature_device "${signature_uuid}")"; then
        acl_verity_unsigned degraded signature-partition-unavailable
        return
    fi
    capacity="$(blockdev --getsize64 "${signature_device}")"
    if [[ ! "${capacity}" =~ ^[0-9]+$ ]] ||
        (( capacity == 0 || capacity > 1048576 || capacity % 4096 != 0 )); then
        acl_verity_unsigned degraded invalid-signature-partition-size
        return
    fi
    if ! timeout --kill-after=1s 5s dd if="${signature_device}" \
        of="${RUN_DIR}/usr-verity.payload" bs=4096 count="$((capacity / 4096))" status=none; then
        acl_verity_unsigned degraded signature-read-failed
        return
    fi
    if ! timeout --kill-after=1s 5s "${BASH_SOURCE[0]}" --check-signature \
        "${root_hash}" "${RUN_DIR}/usr-verity.payload" "${RUN_DIR}/usr.p7s"; then
        acl_verity_unsigned degraded signature-validation-failed-or-timed-out
        return
    fi
    acl_verity_signed "${RUN_DIR}/usr.p7s"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    umask 077
    case "${1:-}" in
        --profile) acl_verity_profile ;;
        --check-signature)
            # shellcheck source=build_library/rpm/additional_files/acl-usr-verity-payload.sh
            source "${PAYLOAD_HELPER}"
            acl_verity_decode_payload "${3:?payload}" "${2:?root hash}" "${4:?signature output}" || exit 1
            acl_verity_check_cms "${2}" "${4}" || exit 1
            ;;
        "") acl_verity_main ;;
        *) log "Unknown invocation"; exit 1 ;;
    esac
fi
