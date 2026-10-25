#!/bin/bash
# Sourced helpers for IPE artifact metadata and local Azure launch validation.

ipe_read_usr_signature_mode() {
    local marker="$1/usr-signature-mode"
    if [[ ! -e "${marker}" && ! -L "${marker}" ]]; then
        printf '%s\n' disabled
    elif [[ -f "${marker}" && ! -L "${marker}" ]] &&
        cmp -s -- "${marker}" <(printf 'required\n'); then
        printf '%s\n' required
    else
        echo "Invalid /usr signature marker: ${marker}" >&2
        return 1
    fi
}

ipe_validate_cmdline_controls() {
    local text="$1" context="$2" LC_ALL=C
    if [[ "${text}" == *$'\r'* ]]; then
        echo "Unsupported carriage return in IPE command line: ${context}" >&2
        return 1
    fi
    # systemd-stub converts C0 controls and DEL to spaces before boot.
    text="${text//$'\t'/}"
    text="${text//$'\n'/}"
    if [[ "${text}" =~ [[:cntrl:]] ]]; then
        echo "Unsupported control character in IPE command line: ${context}" >&2
        return 1
    fi
}

ipe_validate_usr_signature_assets() (
    local mode="$1" esp_dir="$2" asset cmdline
    [[ "${mode}" != required ]] || return 0

    # Include every UKI conversion may re-sign, not just the boot default.
    shopt -s nullglob nocaseglob
    for asset in "${esp_dir}"/EFI/Linux/*.efi.extra.d/verity-usr-*.p7s.cred \
        "${esp_dir}"/EFI/Linux/*.efi \
        "${esp_dir}"/EFI/Linux/*.efi.extra.d/*.addon.efi \
        "${esp_dir}"/loader/addons/*.addon.efi \
        "${esp_dir}"/acl/uki-addons/*.addon.efi; do
        if [[ "${asset,,}" == *.p7s.cred ]]; then
            echo "Signed /usr assets require usr-signature-mode=required: ${asset}" >&2
            return 1
        fi
        [[ -f "${asset}" && ! -L "${asset}" ]] || {
            echo "Cannot inspect /usr signature state of non-regular EFI asset: ${asset}" >&2
            return 1
        }
        cmdline="$(ukify inspect "${asset}" --json=short --section=.cmdline:text |
            jq -er '
                if type != "object" then error("invalid EFI inspection")
                elif has(".cmdline") then
                    .[".cmdline"].text | select(type == "string" and (contains("\u0000") | not))
                else "" end
            ')" || {
                echo "Cannot inspect /usr signature state: ${asset}" >&2
                return 1
            }
        # Keep this conservative scan syntax-agnostic for non-IPE images too.
        # Also catch signature option names split by systemd quote delimiters.
        cmdline="${cmdline//\"/}"
        cmdline="${cmdline//\'/}"
        if [[ "${cmdline}" == *root-hash-signature=* ]]; then
            echo "Signed /usr assets require usr-signature-mode=required: ${asset}" >&2
            return 1
        fi
    done
)

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
    local artifact_dir signing_mode

    if [[ -L "${image}" || ! -f "${image}" || ! -r "${image}" || ! -s "${image}" ]]; then
        echo "Azure VHD must be a readable, nonempty regular file: ${image}" >&2
        return 1
    fi

    artifact_dir="$(cd "$(dirname "${image}")" && pwd)"
    signing_mode="$(ipe_resolve_artifact_signing_mode "${artifact_dir}" "${expected_capability}")" ||
        return 1
    printf '%s\n' "${signing_mode}"
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

ipe_reject_azure_image_overrides() {
    local argument option

    for argument; do
        if [[ "${argument}" == -i* ]]; then
            echo "IPE-capable Azure launches cannot override -i" >&2
            return 1
        fi
        [[ "${argument}" == --* ]] || continue
        option="$(ipe_option_name "${argument}")"
        if ipe_option_is_abbreviation "${option}" --image --i; then
            echo "IPE-capable Azure launches cannot override ${option}" >&2
            return 1
        fi
    done
}
