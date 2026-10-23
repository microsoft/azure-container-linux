#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Verify the staged IPE signer and selected UKI's credential binding before
# image conversion re-signs the UKI.

set -euo pipefail

CERT_DIR="${1:?usage: verify_ipe_signer_continuity.sh <cert-dir> <artifact-dir> <esp-dir>}"
ARTIFACT_DIR="${2:?usage: verify_ipe_signer_continuity.sh <cert-dir> <artifact-dir> <esp-dir>}"
ESP_DIR="${3:?usage: verify_ipe_signer_continuity.sh <cert-dir> <artifact-dir> <esp-dir>}"
CERT="${CERT_DIR}/uki-signing-ca.pem"
STAGED_POLICY="${ARTIFACT_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred"
source "$(dirname "${BASH_SOURCE[0]}")/ipe_artifact.sh"
usr_signature_mode="$(ipe_read_usr_signature_mode "${ARTIFACT_DIR}")"
ipe_validate_usr_signature_assets "${usr_signature_mode}" "${ESP_DIR}"

verify_attached_cms() {
    local signature="$1"

    openssl smime -verify -inform der -binary \
        -in "${signature}" \
        -nointern -certfile "${CERT}" -noverify \
        -out /dev/null >/dev/null 2>&1
}

validate_generated_cmdline_syntax() {
    ipe_validate_cmdline_controls "$1" "$2" || return 1
    # Base and slot metadata are generated, not user-supplied. Keep them
    # canonical for the policy loader and guest signature checks.
    case "$1" in
        *\"*|*\'*|*\\*)
            echo "Unsupported quoting or escaping in IPE command line: $2" >&2
            return 1
            ;;
    esac
}

[[ -s "${CERT}" ]] || {
    echo "IPE signer certificate is missing: ${CERT}" >&2
    exit 1
}
[[ -s "${STAGED_POLICY}" ]] || {
    echo "Staged IPE policy credential is missing: ${STAGED_POLICY}" >&2
    exit 1
}
verify_attached_cms "${STAGED_POLICY}" || {
    echo "Staged IPE policy is not signed by ${CERT}" >&2
    exit 1
}

config="${ESP_DIR}/loader/loader.conf"
[[ -r "${config}" ]] || {
    echo "IPE UKI loader configuration is missing: ${config}" >&2
    exit 1
}
uki_name=""
while read -r key value extra; do
    [[ "${key}" == "default" ]] || continue
    if [[ -n "${uki_name}" || -n "${extra:-}" ||
        ! "${value:-}" =~ ^[A-Za-z0-9_.+-]+[.]efi$ ]]; then
        echo "IPE verification requires exactly one literal UKI default in ${config}" >&2
        exit 1
    fi
    uki_name="${value}"
done < "${config}"
[[ -n "${uki_name}" ]] || {
    echo "No UKI default found in ${config}" >&2
    exit 1
}

uki="${ESP_DIR}/EFI/Linux/${uki_name}"
installed="${uki}.extra.d/acl-ipe-policy.p7b.cred"
[[ -f "${installed}" && ! -L "${installed}" ]] &&
    cmp -s -- "${STAGED_POLICY}" "${installed}" || {
        echo "Selected UKI credential differs from staged policy: ${installed}" >&2
        exit 1
    }

cmdline="$(ukify inspect "${uki}" --json=short --section=.cmdline:text |
    jq -er '.[".cmdline"].text | select(type == "string" and (contains("\u0000") | not))')" || {
        echo "Cannot read the selected UKI command line: ${uki}" >&2
        exit 1
    }
validate_generated_cmdline_syntax "${cmdline}" "${uki}"
read -r -a tokens <<< "${cmdline//$'\n'/ }"
expected_hash="$(sha256sum "${STAGED_POLICY}" | cut -d' ' -f1)"
hashes=()
for token in "${tokens[@]}"; do
    if [[ "${token}" == acl.ipe.policy_sha256=* ]]; then
        hashes+=("${token#*=}")
    fi
done
if [[ "${#hashes[@]}" -ne 1 || "${hashes[0]:-}" != "${expected_hash}" ]]; then
    echo "Selected UKI must bind exactly one matching IPE policy SHA-256: ${uki}" >&2
    exit 1
fi
if [[ "${usr_signature_mode}" == "required" &&
    "${cmdline}" =~ (usrhash=|systemd[.]verity|root-hash-signature=) ]]; then
    echo "Signed /usr metadata belongs in slot addons, not the base UKI" >&2
    exit 1
fi
if [[ "${usr_signature_mode}" == "required" ]]; then
    mounts=()
    for token in "${tokens[@]}"; do
        case "${token}" in
            mount.usr=*|rd.mount.usr=*) mounts+=("${token#*=}") ;;
        esac
    done
    [[ "${#mounts[@]}" -eq 1 && "${mounts[0]}" == /dev/mapper/usr ]] || {
        echo "Signed /usr must mount /dev/mapper/usr" >&2
        exit 1
    }
fi

shopt -s nullglob nocaseglob
template_a="${ESP_DIR}/acl/uki-addons/slot-a.addon.efi"
template_b="${ESP_DIR}/acl/uki-addons/slot-b.addon.efi"
active_slot=""
if [[ "${usr_signature_mode}" == "required" ]]; then
    active_slots=("${uki}.extra.d"/slot-*.addon.efi)
    if [[ "${#active_slots[@]}" -ne 1 ||
        ( "${active_slots[0]:-}" != "${uki}.extra.d/slot-a.addon.efi" &&
          "${active_slots[0]:-}" != "${uki}.extra.d/slot-b.addon.efi" ) ]]; then
        echo "Signed /usr requires exactly one active slot-a or slot-b addon" >&2
        exit 1
    fi
    active_slot="${active_slots[0]}"
fi
for addon in "${uki}.extra.d"/*.addon.efi "${ESP_DIR}/loader/addons"/*.addon.efi \
    "${ESP_DIR}/acl/uki-addons"/*.addon.efi; do
    [[ -f "${addon}" && ! -L "${addon}" ]] || {
        echo "IPE UKI addon must be a regular file: ${addon}" >&2
        exit 1
    }
    addon_json="$(ukify inspect "${addon}" --json=short --section=.cmdline:text)" || {
        echo "Cannot inspect IPE UKI addon: ${addon}" >&2
        exit 1
    }
    addon_cmdline="$(jq -er '
        if type != "object" then error("invalid addon inspection")
        elif has(".cmdline") then
            .[".cmdline"].text | select(type == "string" and (contains("\u0000") | not))
        else "" end
    ' <<< "${addon_json}")" || {
        echo "Cannot read IPE UKI addon command line: ${addon}" >&2
        exit 1
    }
    reserved_slot=false
    case "${addon}" in
        "${template_a}"|"${template_b}"|"${uki}.extra.d/slot-a.addon.efi"|"${uki}.extra.d/slot-b.addon.efi")
            reserved_slot=true
            validate_generated_cmdline_syntax "${addon_cmdline}" "${addon}"
            ;;
    esac
    # The initrd policy loader uses raw whitespace splitting, unlike systemd.
    # Check that view too, including policy tokens inside quoted user values.
    read -r -a addon_tokens <<< "${addon_cmdline//$'\n'/ }"
    for token in "${addon_tokens[@]}"; do
        if [[ "${token}" == acl.ipe.policy_sha256=* ]]; then
            echo "IPE UKI addon must not set acl.ipe.policy_sha256: ${addon}" >&2
            exit 1
        fi
    done
    ipe_split_systemd_cmdline addon_tokens "${addon_cmdline}" "${addon}"
    for token in "${addon_tokens[@]}"; do
        if [[ "${token}" == acl.ipe.policy_sha256=* ]]; then
            echo "IPE UKI addon must not set acl.ipe.policy_sha256: ${addon}" >&2
            exit 1
        fi
        if [[ "${usr_signature_mode}" == "required" ]]; then
            case "${token}" in
                rd.systemd.verity*|rd.usrhash=*|mount.usr*|rd.mount.usr*|systemd.verity=*)
                    echo "Addon overrides required /usr verification: ${addon}" >&2
                    exit 1
                    ;;
            esac
            if [[ "${reserved_slot}" == false ]]; then
                key="${token%%=*}"
                key="${key#rd.}"
                key="${key//-/_}"
                case "${key}" in
                    usrhash|systemd.verity*|mount.usr*|root_hash_signature)
                        echo "Unexpected slot addon or signed /usr metadata: ${addon}" >&2
                        exit 1
                        ;;
                esac
                if [[ "${token}" == *root-hash-signature=* ]]; then
                    echo "Unexpected slot addon or signed /usr metadata: ${addon}" >&2
                    exit 1
                fi
            fi
        fi
    done
    if [[ "${usr_signature_mode}" == "required" &&
        "${addon}" != "${template_a}" && "${addon}" != "${template_b}" &&
        "${addon}" != "${active_slot}" ]]; then
        addon_name="${addon##*/}"
        if [[ "${addon_name,,}" == slot-*.addon.efi ]]; then
            echo "Unexpected slot addon or signed /usr metadata: ${addon}" >&2
            exit 1
        fi
    fi
done

if [[ "${usr_signature_mode}" == "required" ]]; then
    root_hash=""
    for addon in "${template_a}" "${template_b}" "${active_slot}"; do
        slot_cmdline="$(ukify inspect "${addon}" --json=short --section=.cmdline:text |
            jq -er '.[".cmdline"].text | select(type == "string" and (contains("\u0000") | not))')" || exit 1
        validate_generated_cmdline_syntax "${slot_cmdline}" "${addon}"
        hashes=()
        options=()
        read -r -a tokens <<< "${slot_cmdline//$'\n'/ }"
        for token in "${tokens[@]}"; do
            # Match systemd's equivalent key spellings, retaining values verbatim.
            case "${token//-/_}" in
                usrhash=*) hashes+=("${token#*=}") ;;
                systemd.verity_usr_options=*) options+=("${token#*=}") ;;
            esac
        done
        if [[ "${#hashes[@]}" -ne 1 || ! "${hashes[0]:-}" =~ ^[0-9a-f]{64}$ ||
            "${#options[@]}" -ne 1 ]]; then
            echo "Invalid signed /usr slot metadata: ${addon}" >&2
            exit 1
        fi
        [[ -n "${root_hash}" ]] || root_hash="${hashes[0]}"
        expected="panic-on-corruption,root-hash-signature=/.extra/credentials/verity-usr-${root_hash}.p7s.cred"
        if [[ "${hashes[0]}" != "${root_hash}" || "${options[0]}" != "${expected}" ]]; then
            echo "Inconsistent signed /usr slot metadata: ${addon}" >&2
            exit 1
        fi
    done
    openssl cms -verify -binary -inform DER \
        -in "${uki}.extra.d/verity-usr-${root_hash}.p7s.cred" \
        -content <(printf '%s' "${root_hash}") \
        -nointern -certfile "${CERT}" -noverify -out /dev/null ||
        { echo "Invalid /usr signature candidate" >&2; exit 1; }
fi
