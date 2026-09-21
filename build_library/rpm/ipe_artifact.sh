#!/bin/bash

ipe_read_signing_mode() {
    local marker="$1"

    if [[ ! -e "${marker}" && ! -L "${marker}" ]]; then
        return 1
    fi
    if [[ -L "${marker}" || ! -f "${marker}" || ! -r "${marker}" ]]; then
        echo "Invalid IPE signing marker: ${marker} must be a readable regular file" >&2
        return 2
    fi
    if cmp -s -- "${marker}" <(printf 'ephemeral\n'); then
        printf '%s\n' ephemeral
        return 0
    fi
    if cmp -s -- "${marker}" <(printf 'esrp\n'); then
        printf '%s\n' esrp
        return 0
    fi

    echo "Invalid IPE signing marker: ${marker} must contain exactly one canonical ephemeral or esrp line" >&2
    return 2
}

ipe_resolve_artifact_signing_mode() {
    local artifact_dir="$1"
    local expected_capability="${2:-}"
    local marker="${artifact_dir}/ipe-signing-mode"
    local signing_mode rc

    case "${expected_capability}" in
        ""|true|false) ;;
        *)
            echo "Invalid ACL_IPE_CAPABLE value: ${expected_capability}" >&2
            return 1
            ;;
    esac

    if signing_mode="$(ipe_read_signing_mode "${marker}")"; then
        if [[ "${expected_capability}" == "false" ]]; then
            echo "IPE signing marker contradicts ACL_IPE_CAPABLE=false: ${marker}" >&2
            return 1
        fi
        printf '%s\n' "${signing_mode}"
        return 0
    else
        rc=$?
    fi
    [[ ${rc} -eq 1 ]] || return 1

    if [[ "${expected_capability}" == "true" ]]; then
        echo "IPE-capable artifact is missing ${marker}" >&2
        return 1
    fi
    if [[ -e "${artifact_dir}/acl-ipe-policy" || -L "${artifact_dir}/acl-ipe-policy" ]]; then
        echo "IPE policy assets are present but ${marker} is missing" >&2
        return 1
    fi

    printf '%s\n' disabled
}

ipe_validate_signing_certificate() {
    local certificate="$1"

    if [[ -L "${certificate}" || ! -f "${certificate}" || ! -r "${certificate}" || ! -s "${certificate}" ]]; then
        echo "IPE signing certificate must be a readable, nonempty regular file: ${certificate}" >&2
        return 1
    fi
    if ! openssl x509 -in "${certificate}" -noout >/dev/null 2>&1; then
        echo "IPE signing certificate is not a valid X.509 PEM: ${certificate}" >&2
        return 1
    fi
}

ipe_validate_local_vhd_contract() {
    local image="$1"
    local expected_capability="${2:-}"
    local artifact_dir signing_mode certificate

    if [[ -L "${image}" || ! -f "${image}" || ! -r "${image}" || ! -s "${image}" ]]; then
        echo "Azure VHD must be a readable, nonempty regular file: ${image}" >&2
        return 1
    fi

    artifact_dir="$(cd "$(dirname "${image}")" && pwd)"
    signing_mode="$(ipe_resolve_artifact_signing_mode "${artifact_dir}" "${expected_capability}")" ||
        return 1
    if [[ "${signing_mode}" != "disabled" ]]; then
        certificate="${artifact_dir}/uki-signing-ca.pem"
        ipe_validate_signing_certificate "${certificate}" || return 1
    fi

    printf '%s\n' "${signing_mode}"
}

ipe_configure_azure_trust() {
    local host_image="$1"
    local runtime_image="$2"
    local signing_mode host_certificate runtime_certificate

    case "${ACL_IPE_CAPABLE:-}" in
        ""|true|false) ;;
        *)
            echo "Invalid ACL_IPE_CAPABLE value: ${ACL_IPE_CAPABLE}" >&2
            return 1
            ;;
    esac

    if [[ -n "${AZURE_DISK_URI:-}" ]]; then
        if [[ -n "${AZURE_SECURE_BOOT_CERTIFICATES:-}" ]]; then
            echo "AZURE_SECURE_BOOT_CERTIFICATES cannot modify an existing gallery image version" >&2
            return 1
        fi
        if [[ "${ACL_IPE_CAPABLE:-false}" == "true" ]]; then
            case "${AZURE_TRUSTED_LAUNCH:-}" in
                ""|true) AZURE_TRUSTED_LAUNCH=true ;;
                *)
                    echo "IPE-capable gallery images require AZURE_TRUSTED_LAUNCH=true" >&2
                    return 1
                    ;;
            esac
        fi
        export AZURE_TRUSTED_LAUNCH
        return 0
    fi

    signing_mode="$(
        ipe_validate_local_vhd_contract "${host_image}" "${ACL_IPE_CAPABLE:-}"
    )" || return 1
    if [[ "${signing_mode}" == "disabled" ]]; then
        if [[ -z "${ACL_IPE_CAPABLE:-}" ]]; then
            ACL_IPE_CAPABLE=false
        fi
        export ACL_IPE_CAPABLE
        return 0
    fi

    host_certificate="$(dirname "${host_image}")/uki-signing-ca.pem"
    runtime_certificate="$(dirname "${runtime_image}")/uki-signing-ca.pem"
    ipe_validate_signing_certificate "${host_certificate}" || return 1

    case "${AZURE_TRUSTED_LAUNCH:-}" in
        ""|true) ;;
        *)
            echo "IPE-capable local VHDs require AZURE_TRUSTED_LAUNCH=true" >&2
            return 1
            ;;
    esac
    case "${AZURE_SECURE_BOOT_CERTIFICATES:-}" in
        ""|"${runtime_certificate}") ;;
        *)
            echo "IPE-capable local VHDs require the exact certificate ${runtime_certificate}" >&2
            return 1
            ;;
    esac

    ACL_IPE_CAPABLE=true
    ACL_IPE_SIGNING_MODE="${signing_mode}"
    AZURE_TRUSTED_LAUNCH=true
    AZURE_SECURE_BOOT_CERTIFICATES="${runtime_certificate}"
    export ACL_IPE_CAPABLE ACL_IPE_SIGNING_MODE
    export AZURE_TRUSTED_LAUNCH AZURE_SECURE_BOOT_CERTIFICATES
}

ipe_split_argument_string() {
    local output_name="$1"
    local argument_string="$2"
    local -n output_ref="${output_name}"

    argument_string="${argument_string//$'\r'/ }"
    argument_string="${argument_string//$'\n'/ }"
    output_ref=()
    # shellcheck disable=SC2034 # The nameref writes into the caller's array.
    [[ -z "${argument_string}" ]] || read -r -a output_ref <<< "${argument_string}"
}

ipe_option_name() {
    printf '%s\n' "${1%%=*}"
}

ipe_option_is_abbreviation() {
    local option="$1"
    local canonical="$2"
    local minimum_prefix="$3"

    [[ "${option}" == "${canonical}" ]] ||
        [[ "${option}" == "${minimum_prefix}"* && "${canonical}" == "${option}"* ]]
}

ipe_reject_azure_security_overrides() {
    local argument option

    for argument; do
        [[ "${argument}" == --* ]] || continue
        option="$(ipe_option_name "${argument}")"
        if ipe_option_is_abbreviation "${option}" --security-type --secu ||
            ipe_option_is_abbreviation "${option}" --enable-vtpm --enable-v ||
            ipe_option_is_abbreviation "${option}" --enable-secure-boot --enable-s; then
            echo "IPE-capable Azure launches cannot override ${option}" >&2
            return 1
        fi
    done
}

ipe_reject_azure_ipe_overrides() {
    local argument option

    ipe_reject_azure_security_overrides "$@" || return 1
    for argument; do
        [[ "${argument}" == --* ]] || continue
        option="$(ipe_option_name "${argument}")"
        if ipe_option_is_abbreviation "${option}" --image --ima; then
            echo "IPE-capable Azure launches cannot override ${option}" >&2
            return 1
        fi
    done
}

ipe_reject_arm_size_overrides() {
    local argument option

    for argument; do
        [[ "${argument}" == --* ]] || continue
        option="$(ipe_option_name "${argument}")"
        if ipe_option_is_abbreviation "${option}" --size --si; then
            echo "Azure ARM launches cannot override ${option}" >&2
            return 1
        fi
    done
}

ipe_reject_kola_managed_overrides() {
    local allow_use_gallery="${1:-false}"
    shift
    local argument option

    for argument; do
        [[ "${argument}" == --* ]] || continue
        option="$(ipe_option_name "${argument}")"
        case "${option}" in
            --azure-trusted-launch|--enable-secureboot|--azure-secureboot-certificate|\
            --azure-image-file|--azure-disk-uri|--azure-blob-url|\
            --azure-hyper-v-generation)
                echo "Azure Kola launch arguments cannot override ${option}" >&2
                return 1
                ;;
            --azure-use-gallery)
                if [[ "${allow_use_gallery}" != "true" || "${argument}" != "--azure-use-gallery" ]]; then
                    echo "Azure Kola launch arguments cannot override ${argument}" >&2
                    return 1
                fi
                ;;
        esac
    done
}
