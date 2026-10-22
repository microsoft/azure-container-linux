#!/bin/bash
# shellcheck disable=SC2034 # Variables below are consumed by extracted functions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TEST_DIR="$(mktemp -d)"
export TMPDIR="${TEST_DIR}"
trap 'rm -rf "${TEST_DIR}"' EXIT

source "${SCRIPT_DIR}/build_library/rpm/rpm_install.sh"
source "${SCRIPT_DIR}/build_library/rpm/ipe_artifact.sh"
source "${SCRIPT_DIR}/acl/tests/ipe/offline/function-extraction.sh"

info() { :; }
die() { echo "$*" >&2; exit 1; }
sudo() {
    if [[ "$1" == "chroot" ]]; then
        return 0
    fi
    command "$@"
}

export BUILD_LIBRARY_DIR="${SCRIPT_DIR}/build_library"
export BOOTLOADER_MODE=uki
policy="${BUILD_LIBRARY_DIR}/rpm/additional_files/ipe/acl-ipe-boot-policy.pol"

prepare_case() {
    local name="$1"
    export BUILD_DIR="${TEST_DIR}/${name}-build"
    CASE_ROOT="${TEST_DIR}/${name}-root"
    mkdir -p "${BUILD_DIR}" "${CASE_ROOT}"
}

test_ipe_disabled_by_default() {
    prepare_case default
    unset ACL_IPE_MODE ACL_IPE_SIGNING_MODE

    rpm_install_ipe_policy "${CASE_ROOT}"

    # Absent marker means disabled; no marker file, no staged artifacts.
    [[ ! -f "${BUILD_DIR}/ipe-signing-mode" ]]
    [[ ! -d "${BUILD_DIR}/acl-ipe-policy" ]]
}

test_ipe_disabled_stages_nothing() {
    prepare_case disabled-explicit
    export ACL_IPE_MODE=disabled
    unset ACL_IPE_SIGNING_MODE

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ ! -f "${BUILD_DIR}/ipe-signing-mode" ]]
    [[ ! -d "${BUILD_DIR}/acl-ipe-policy" ]]
}

test_disabled_cleanup_removes_stale_assets() {
    prepare_case disabled-cleanup
    mkdir -p "${BUILD_DIR}/acl-ipe-ephemeral" "${BUILD_DIR}/acl-ipe-policy"
    printf 'stale-key\n' > "${BUILD_DIR}/acl-ipe-ephemeral/ca.key"
    printf 'stale-cred\n' > "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred"
    printf 'ephemeral\n' > "${BUILD_DIR}/ipe-signing-mode"

    export ACL_IPE_MODE=disabled
    unset ACL_IPE_SIGNING_MODE

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ ! -f "${BUILD_DIR}/ipe-signing-mode" ]]
    [[ ! -d "${BUILD_DIR}/acl-ipe-policy" ]]
    [[ ! -d "${BUILD_DIR}/acl-ipe-ephemeral" ]]
}

test_audit_ephemeral_stages_candidate() {
    prepare_case audit-ephemeral
    export ACL_IPE_MODE=audit
    export ACL_IPE_SIGNING_MODE=ephemeral

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ -s "${BUILD_DIR}/acl-ipe-ephemeral/ca.key" ]]
    [[ -s "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" ]]
    [[ ! -e "${BUILD_DIR}/acl-ipe-policy/acl-ipe-boot-policy.pol" ]]
    # Verify the CMS wraps the canonical policy
    openssl smime -verify -inform der -binary \
        -in "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" \
        -noverify -out "${TEST_DIR}/verified.pol" >/dev/null 2>&1
    cmp -s "${policy}" "${TEST_DIR}/verified.pol"
    [[ "$(<"${BUILD_DIR}/ipe-signing-mode")" == "ephemeral" ]]
}

test_audit_esrp_stages_candidate() {
    prepare_case audit-esrp
    export ACL_IPE_MODE=audit
    export ACL_IPE_SIGNING_MODE=esrp

    rpm_install_ipe_policy "${CASE_ROOT}"

    [[ -s "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" ]]
    [[ -s "${BUILD_DIR}/acl-ipe-policy/acl-ipe-boot-policy.pol" ]]
    # Verify the CMS wraps the canonical policy
    openssl smime -verify -inform der -binary \
        -in "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" \
        -noverify -out "${TEST_DIR}/ext-verified.pol" >/dev/null 2>&1
    cmp -s "${policy}" "${TEST_DIR}/ext-verified.pol"
    [[ "$(<"${BUILD_DIR}/ipe-signing-mode")" == "esrp" ]]
}

test_enforcing_mode_rejected() {
    prepare_case enforcing-rejected
    export ACL_IPE_MODE=enforcing

    if (rpm_install_ipe_policy "${CASE_ROOT}") 2>/dev/null; then
        echo "reserved 'enforcing' mode was accepted by the producer" >&2
        return 1
    fi
    unset ACL_IPE_MODE
}

test_uki_provision_preserves_unsigned_verity() (
    source_test_functions "${SCRIPT_DIR}/build_library/rpm/uki_install.sh" \
        uki_provision_rpm _uki_build_verity_addons
    sudo() { "$@"; }
    _uki_build_firstboot_addon() { :; }
    _uki_build_fips_addon() { :; }
    _uki_build_kdump_addon() { :; }
    _uki_build_debug_addon() { :; }
    ukify() {
        local argument output="" cmdline=""
        for argument; do
            case "${argument}" in
                --cmdline=@*) cmdline="${argument#--cmdline=@}" ;;
                --output=*) output="${argument#--output=}" ;;
            esac
        done
        cp "${cmdline}" "${BUILD_DIR}/${output##*/}.cmdline"
        cp "${cmdline}" "${output}"
    }

    local scenario capable esp extra cmdline policy_hash failure
    local slot addon_cmdline data_uuid hash_uuid
    local uki_name="vmlinuz-6.6.145.2.efi"
    local roothash="000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"
    FLAGS_TRUE=0
    for scenario in x64:false x64:true aa64:false aa64:true x64:required aa64:required; do
        EFI_ARCH="${scenario%:*}"
        capable="${scenario#*:}"
        ROOT_HASH_SIGNING_ENABLED=false
        if [[ "${capable}" == "required" ]]; then
            capable=true
            ROOT_HASH_SIGNING_ENABLED=true
            roothash="${roothash,,}"
        fi
        prepare_case "uki-${scenario//:/-}"
        IPE_CAPABLE="${capable}"
        BOARD_ROOT="${CASE_ROOT}/board"
        FLAGS_disk_image="${BUILD_DIR}/image.bin"
        FLAGS_verity_hash="${BUILD_DIR}/usrhash"
        FLAGS_fs_uuid="${BUILD_DIR}/fs_uuid"
        FLAGS_verity_uuid="${BUILD_DIR}/verity_uuid"
        esp="${CASE_ROOT}/esp"
        extra="${esp}/EFI/Linux/${uki_name}.extra.d"
        mkdir -p "${esp}/flatcar" "${extra}" \
            "${BOARD_ROOT}/usr/lib/systemd/boot/efi" \
            "${BOARD_ROOT}/boot/efi/EFI/BOOT" \
            "${BUILD_DIR}/acl-ipe-policy"
        touch "${esp}/vmlinuz-6.6.145.2" "${esp}/flatcar/initramfs-a.img" \
            "${BOARD_ROOT}/usr/lib/systemd/boot/efi/linux${EFI_ARCH}.efi.stub" \
            "${BOARD_ROOT}/boot/efi/EFI/BOOT/boot${EFI_ARCH}.efi" \
            "${BOARD_ROOT}/boot/efi/EFI/BOOT/grub${EFI_ARCH}.efi"
        printf 'policy credential\n' > "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred"
        printf 'stale\n' > "${extra}/acl-ipe-policy.p7b.cred"
        printf '11111111-2222-3333-4444-555555555555\n' > "${FLAGS_fs_uuid}"
        printf '66666666-7777-8888-9999-aaaaaaaaaaaa\n' > "${FLAGS_verity_uuid}"

        FLAGS_verity=0
        if failure="$(_uki_build_verity_addons "${esp}" "${uki_name}" 2>&1)"; then
            echo "UKI addons accepted a missing /usr root hash" >&2
            return 1
        fi
        [[ "${failure}" == *"Verity enabled but no hash file"* ]]
        printf '%s\n' "${roothash}" > "${FLAGS_verity_hash}"
        if [[ "${ROOT_HASH_SIGNING_ENABLED}" == "true" ]]; then
            bash "${BUILD_LIBRARY_DIR}/rpm/ensure_ephemeral_cert.sh" \
                "${BUILD_DIR}/acl-ipe-ephemeral" create
        fi
        if [[ "${capable}" == "true" ]]; then
            FLAGS_verity=1
            if failure="$(uki_provision_rpm "${esp}" 2>&1)"; then
                echo "IPE-capable UKI accepted disabled /usr verity" >&2
                return 1
            fi
            [[ "${failure}" == *"IPE assets require a /usr dm-verity root hash"* ]]
            FLAGS_verity=0

            mv "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" \
                "${BUILD_DIR}/policy.cred"
            if failure="$(uki_provision_rpm "${esp}" 2>&1)"; then
                echo "IPE-capable UKI accepted a missing policy credential" >&2
                return 1
            fi
            [[ "${failure}" == *"staged IPE policy candidate not found"* ]]
            mv "${BUILD_DIR}/policy.cred" \
                "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred"
        fi
        uki_provision_rpm "${esp}"
        cmdline="$(<"${BUILD_DIR}/${uki_name}.cmdline")"
        [[ "${cmdline}" == *"mount.usr=/dev/mapper/usr mount.usrflags=ro"* ]]
        [[ "${cmdline}" != *"usrhash="* && "${cmdline}" != *"systemd.verity_usr_"* ]]
        [[ "${cmdline}" != *"acl.slot="* ]]
        [[ "${cmdline}" != *"root-hash-signature="* ]]
        for slot in a b; do
            addon_cmdline="$(<"${BUILD_DIR}/slot-${slot}.addon.efi.cmdline")"
            data_uuid="$(jq -r --arg label "USR-${slot^^}" \
                '.layouts.base[] | select(.label == $label) | .uuid' \
                "${BUILD_LIBRARY_DIR}/disk_layout_uki.json")"
            hash_uuid="$(jq -r --arg label "HASH-${slot^^}" \
                '.layouts.base[] | select(.label == $label) | .uuid' \
                "${BUILD_LIBRARY_DIR}/disk_layout_uki.json")"
            local signature_option=""
            if [[ "${ROOT_HASH_SIGNING_ENABLED}" == "true" ]]; then
                signature_option=",root-hash-signature=/.extra/credentials/verity-usr-${roothash}.p7s.cred"
                [[ -s "${extra}/verity-usr-${roothash}.p7s.cred" ]]
                [[ "$(<"${BUILD_DIR}/usr-signature-mode")" == required ]]
            else
                [[ ! -e "${BUILD_DIR}/usr-signature-mode" ]]
            fi
            [[ "${addon_cmdline}" == "systemd.verity_usr_data=PARTUUID=${data_uuid} systemd.verity_usr_hash=PARTUUID=${hash_uuid} systemd.verity_usr_options=panic-on-corruption${signature_option} usrhash=${roothash} acl.slot=${slot}" ]]
            cmp "${BUILD_DIR}/slot-${slot}.addon.efi.cmdline" \
                "${esp}/acl/uki-addons/slot-${slot}.addon.efi"
        done
        cmp "${esp}/acl/uki-addons/slot-a.addon.efi" "${extra}/slot-a.addon.efi"
        [[ ! -e "${extra}/slot-b.addon.efi" ]]
        if [[ "${capable}" == "true" ]]; then
            policy_hash="$(sha256sum "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" | cut -d' ' -f1)"
            [[ " ${cmdline} " == *" acl.ipe.policy_sha256=${policy_hash} "* ]]
            cmp "${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred" \
                "${extra}/acl-ipe-policy.p7b.cred"
        else
            [[ "${cmdline}" != *"acl.ipe.policy_sha256="* ]]
            [[ ! -e "${extra}/acl-ipe-policy.p7b.cred" ]]
        fi
        cmp "${BUILD_DIR}/${uki_name}.cmdline" "${esp}/EFI/Linux/${uki_name}"
    done
)

test_uki_binds_policy_before_writing_cmdline() {
    local uki_install="${SCRIPT_DIR}/build_library/rpm/uki_install.sh"
    local declaration_line append_line write_line

    declaration_line="$(grep -nF 'local ipe_policy_hash_token=""' "${uki_install}" | cut -d: -f1)"
    append_line="$(grep -nF 'cmdline+=" ${ipe_policy_hash_token}"' "${uki_install}" | cut -d: -f1)"
    write_line="$(grep -nF 'echo "${cmdline}" > "${uki_temp_dir}/cmdline.txt"' "${uki_install}" | cut -d: -f1)"

    [[ -n "${declaration_line}" && -n "${append_line}" && -n "${write_line}" ]]
    [[ "${declaration_line}" -lt "${append_line}" ]]
    [[ "${append_line}" -lt "${write_line}" ]]
    grep -Fq 'EFI/Linux/${uki_name}.extra.d/acl-ipe-policy.p7b.cred' "${uki_install}"
}

write_test_uki() {
    printf 'mock UKI\n' > "$1"
    printf '%s\n' "$2" > "$1.cmdline"
}

test_required_usr_signature_continuity() (
    local cert_dir="$1" other_cert_dir="$2" artifact_dir="$3" esp_dir="$4" token="$5"
    local uki="${esp_dir}/EFI/Linux/acl.efi"
    local extra_dir="${uki}.extra.d" template_dir="${esp_dir}/acl/uki-addons"
    local verifier="${SCRIPT_DIR}/build_library/rpm/verify_ipe_signer_continuity.sh"
    local root_hash other_hash options slot data_uuid hash_uuid addon original bad_cmdline
    root_hash="$(printf '%064d' 1)"
    other_hash="$(printf '%064d' 2)"
    options="panic-on-corruption,root-hash-signature=/.extra/credentials/verity-usr-${root_hash}.p7s.cred"
    local credential="${extra_dir}/verity-usr-${root_hash}.p7s.cred"

    verify_required() {
        bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}"
    }
    reject_required() {
        local failure
        if failure="$(verify_required 2>&1)"; then
            echo "Required /usr verification accepted $1" >&2
            return 1
        fi
        [[ "${failure}" == *"$2"* ]] || {
            echo "Unexpected failure for $1: ${failure}" >&2
            return 1
        }
    }

    mkdir -p "${template_dir}"
    printf 'required\n' > "${artifact_dir}/usr-signature-mode"
    write_test_uki "${uki}" "${token} mount.usr=/dev/mapper/usr mount.usrflags=ro"
    for slot in a b; do
        data_uuid="$(jq -r --arg label "USR-${slot^^}" \
            '.layouts.base[] | select(.label == $label) | .uuid' \
            "${BUILD_LIBRARY_DIR}/disk_layout_uki.json")"
        hash_uuid="$(jq -r --arg label "HASH-${slot^^}" \
            '.layouts.base[] | select(.label == $label) | .uuid' \
            "${BUILD_LIBRARY_DIR}/disk_layout_uki.json")"
        write_test_uki "${template_dir}/slot-${slot}.addon.efi" \
            "systemd.verity_usr_data=PARTUUID=${data_uuid} systemd.verity_usr_hash=PARTUUID=${hash_uuid} systemd.verity_usr_options=${options} usrhash=${root_hash} acl.slot=${slot}"
    done
    openssl cms -sign -binary -noattr -nosmimecap -outform DER \
        -in <(printf '%s' "${root_hash}") \
        -signer "${cert_dir}/uki-signing-ca.pem" -inkey "${cert_dir}/ca.key" \
        -out "${credential}"
    cp "${credential}" "${TEST_DIR}/original-usr.cred"

    for slot in a b; do
        cp "${template_dir}/slot-${slot}.addon.efi"* "${extra_dir}/"
        verify_required
        original="$(<"${extra_dir}/slot-${slot}.addon.efi.cmdline")"
        write_test_uki "${extra_dir}/slot-${slot}.addon.efi" \
            "${original//${options}/panic-on-corruption}"
        reject_required "unsigned active slot ${slot}" "Inconsistent signed /usr slot metadata"
        rm "${extra_dir}/slot-${slot}.addon.efi"*
    done
    reject_required "no active slot" "exactly one active"
    cp "${template_dir}/slot-"*.addon.efi* "${extra_dir}/"
    reject_required "both active slots" "exactly one active"
    write_test_uki "${extra_dir}/slot-b.addon.efi" \
        "systemd.verity_usr_options=panic-on-corruption"
    reject_required "extra unsigned active slot B" "exactly one active"
    rm "${extra_dir}/slot-b.addon.efi"*

    for addon in "${esp_dir}/loader/addons/slot-b.addon.efi" \
        "${template_dir}/slot-c.addon.efi"; do
        write_test_uki "${addon}" "$(<"${template_dir}/slot-b.addon.efi.cmdline")"
        reject_required "misplaced slot ${addon}" "Unexpected slot addon"
        rm "${addon}"*
    done

    original="$(<"${uki}.cmdline")"
    for bad_cmdline in "${token}" "${token} mount.usr=PARTUUID=unverified" \
        "${original} mount.usr=PARTUUID=unverified"; do
        write_test_uki "${uki}" "${bad_cmdline}"
        reject_required "missing, wrong or duplicate mount binding" "must mount /dev/mapper/usr"
    done
    for bad_cmdline in '"mount.usr=PARTUUID=unverified"' \
        "'mount.usr=PARTUUID=unverified'" 'mount\.usr=PARTUUID=unverified'; do
        write_test_uki "${uki}" "${original} ${bad_cmdline}"
        reject_required "quoted or escaped base override" "Unsupported quoting or escaping"
    done
    write_test_uki "${uki}" "${original}"

    for addon in "${extra_dir}/slot-a.addon.efi" \
        "${template_dir}/slot-a.addon.efi" "${template_dir}/slot-b.addon.efi"; do
        original="$(<"${addon}.cmdline")"
        for bad_cmdline in '"mount.usr=PARTUUID=unverified"' \
            '"systemd.verity_usr_options=panic-on-corruption"' \
            "'systemd.verity_usr_options=panic-on-corruption'" \
            'systemd\.verity_usr_options=panic-on-corruption'; do
            write_test_uki "${addon}" "${original} ${bad_cmdline}"
            reject_required "quoted or escaped slot override" "Unsupported quoting or escaping"
        done
        write_test_uki "${addon}" "${original} systemd.verity_usr_options=panic-on-corruption"
        reject_required "duplicate slot options" "Invalid signed /usr slot metadata"
        write_test_uki "${addon}" "${original//${options}/panic-on-corruption}"
        reject_required "unsigned slot options" "Inconsistent signed /usr slot metadata"
        write_test_uki "${addon}" "${original//${root_hash}/${other_hash}}"
        reject_required "slot root hash disagreement" "Inconsistent signed /usr slot metadata"
        write_test_uki "${addon}" "${original}"
    done

    for addon in "${extra_dir}/debug.addon.efi" \
        "${esp_dir}/loader/addons/global.addon.efi" "${template_dir}/debug.addon.efi"; do
        write_test_uki "${addon}" '"mount.usr=PARTUUID=unverified"'
        reject_required "quoted addon mount override" "Unsupported quoting or escaping"
        write_test_uki "${addon}" 'systemd.verity_usr_options=panic-on-corruption'
        reject_required "non-slot verity override" "Unexpected slot addon"
        rm "${addon}"*
    done

    rm "${credential}"
    reject_required "missing root signature" "Invalid /usr signature candidate"
    printf 'tampered\n' > "${credential}"
    reject_required "tampered root signature" "Invalid /usr signature candidate"
    openssl cms -sign -binary -noattr -nosmimecap -outform DER \
        -in <(printf '%s' "${root_hash}") \
        -signer "${other_cert_dir}/uki-signing-ca.pem" -inkey "${other_cert_dir}/ca.key" \
        -out "${credential}"
    reject_required "wrong root signer" "Invalid /usr signature candidate"
    openssl cms -sign -binary -noattr -nosmimecap -outform DER \
        -in <(printf '%s' "${other_hash}") \
        -signer "${cert_dir}/uki-signing-ca.pem" -inkey "${cert_dir}/ca.key" \
        -out "${credential}"
    reject_required "signature for another root hash" "Invalid /usr signature candidate"
    cp "${TEST_DIR}/original-usr.cred" "${credential}"
    verify_required
)

test_vm_conversions_share_secure_boot_cert() {
    local cert_dir="${TEST_DIR}/vm-shared-cert"
    local other_cert_dir="${TEST_DIR}/vm-other-cert"
    local first_cert="${TEST_DIR}/vm-first-cert.pem"
    local artifact_dir="${TEST_DIR}/vm-artifact"
    local esp_dir="${TEST_DIR}/vm-esp"
    local extra_dir="${esp_dir}/EFI/Linux/acl.efi.extra.d"
    local uki="${esp_dir}/EFI/Linux/acl.efi"
    local verifier="${SCRIPT_DIR}/build_library/rpm/verify_ipe_signer_continuity.sh"

    ukify() {
        [[ "$1" == inspect && "$3" == --json=short &&
            "$4" == --section=.cmdline:text && "$(<"$2")" == "mock UKI" ]] || return 1
        if [[ -e "$2.invalid-json" ]]; then
            printf '{\n'
        elif [[ -e "$2.invalid-text" ]]; then
            printf '{".cmdline":{"text":123}}\n'
        elif [[ -e "$2.nul" ]]; then
            printf '{".cmdline":{"text":"quiet\\u0000bad"}}\n'
        elif [[ -r "$2.cmdline" ]]; then
            jq -n --arg text "$(<"$2.cmdline")" '{".cmdline": {"text": $text}}'
        else
            printf '{}\n'
        fi
    }
    export -f ukify

    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" "${cert_dir}" create >/dev/null 2>&1
    cp "${cert_dir}/uki-signing-ca.pem" "${first_cert}"
    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" "${cert_dir}" require >/dev/null 2>&1
    cmp -s "${first_cert}" "${cert_dir}/uki-signing-ca.pem"

    mkdir -p "${artifact_dir}/acl-ipe-policy" "${extra_dir}" "${esp_dir}/loader"
    printf 'default acl.efi\n' > "${esp_dir}/loader/loader.conf"
    openssl smime -sign -binary \
        -in "${policy}" \
        -signer "${cert_dir}/uki-signing-ca.pem" \
        -inkey "${cert_dir}/ca.key" \
        -noattr -nodetach -nosmimecap \
        -outform der \
        -out "${artifact_dir}/acl-ipe-policy/acl-ipe-policy.p7b.cred" 2>/dev/null
    cp "${artifact_dir}/acl-ipe-policy/acl-ipe-policy.p7b.cred" \
        "${extra_dir}/acl-ipe-policy.p7b.cred"

    local hash token
    hash="$(sha256sum "${extra_dir}/acl-ipe-policy.p7b.cred" | cut -d' ' -f1)"
    token="acl.ipe.policy_sha256=${hash}"
    write_test_uki "${uki}" "quiet ${token}"
    bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}"

    local bad_cmdline
    for bad_cmdline in "" quiet "acl.ipe.policy_sha256=bad" \
        "acl.ipe.policy_sha256=$(printf '%064d' 0)" "${token} ${token}"; do
        write_test_uki "${uki}" "${bad_cmdline}"
        if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
            echo "missing, malformed, wrong or duplicate UKI policy hash was accepted" >&2
            return 1
        fi
    done
    write_test_uki "${uki}" "${token}"

    local addon="${extra_dir}/debug.addon.efi"
    local global_dir="${esp_dir}/loader/addons"
    write_test_uki "${addon}" "systemd.log_level=debug"
    bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}"
    for bad_cmdline in "${token}" "quiet acl.ipe.policy_sha256=bad" \
        "acl.ipe.policy_sha256="; do
        write_test_uki "${addon}" "${bad_cmdline}"
        if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
            echo "IPE policy hash in active debug addon was accepted" >&2
            return 1
        fi
    done
    rm "${addon}.cmdline"
    bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}"
    : > "${addon}.invalid-json"
    if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "invalid addon inspection was accepted" >&2
        return 1
    fi
    rm "${addon}.invalid-json"
    : > "${addon}.invalid-text"
    if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "non-text addon command line was accepted" >&2
        return 1
    fi
    rm "${addon}.invalid-text"
    : > "${addon}.nul"
    if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "NUL in addon command line was accepted" >&2
        return 1
    fi
    rm "${addon}.nul"
    printf 'invalid UKI\n' > "${addon}"
    if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "unreadable active addon was accepted" >&2
        return 1
    fi
    rm "${addon}"

    write_test_uki "${extra_dir}/custom.ADDON.EFI" "${token}"
    if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "IPE policy hash in another active addon was accepted" >&2
        return 1
    fi
    rm "${extra_dir}/custom.ADDON.EFI"*

    mkdir -p "${global_dir}" "${esp_dir}/EFI/Linux/other.efi.extra.d"
    write_test_uki "${global_dir}/global.addon.efi" "${token}"
    if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "IPE policy hash in global addon was accepted" >&2
        return 1
    fi
    rm "${global_dir}/global.addon.efi"*
    write_test_uki "${esp_dir}/EFI/Linux/other.efi.extra.d/other.addon.efi" "${token}"
    bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}"
    rm -r "${esp_dir}/EFI/Linux/other.efi.extra.d"

    local loader_config
    for loader_config in "" "default other.efi" "default *.efi" \
        $'default acl.efi\ndefault other.efi'; do
        printf '%s\n' "${loader_config}" > "${esp_dir}/loader/loader.conf"
        if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
            echo "missing or ambiguous selected UKI was accepted" >&2
            return 1
        fi
    done
    printf 'default acl.efi\n' > "${esp_dir}/loader/loader.conf"
    mv "${extra_dir}" "${esp_dir}/EFI/Linux/other.efi.extra.d"
    if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "another UKI's credential satisfied the selected UKI" >&2
        return 1
    fi
    mv "${esp_dir}/EFI/Linux/other.efi.extra.d" "${extra_dir}"

    printf 'not a UKI\n' > "${uki}"
    if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "invalid UKI was accepted" >&2
        return 1
    fi
    write_test_uki "${uki}" "${token}"

    local staged="${artifact_dir}/acl-ipe-policy/acl-ipe-policy.p7b.cred"
    cp "${staged}" "${TEST_DIR}/original.cred"
    { cat "${policy}"; printf '\n# alternate signed input\n'; } > "${TEST_DIR}/alternate.pol"
    openssl smime -sign -binary -in "${TEST_DIR}/alternate.pol" \
        -signer "${cert_dir}/uki-signing-ca.pem" -inkey "${cert_dir}/ca.key" \
        -noattr -nodetach -nosmimecap -outform der \
        -out "${extra_dir}/acl-ipe-policy.p7b.cred" 2>/dev/null
    if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "different installed credential with the same signer was accepted" >&2
        return 1
    fi
    cp "${extra_dir}/acl-ipe-policy.p7b.cred" "${staged}"
    if bash "${verifier}" "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "matching credentials not bound into the UKI were accepted" >&2
        return 1
    fi
    cp "${TEST_DIR}/original.cred" "${staged}"
    cp "${staged}" "${extra_dir}/acl-ipe-policy.p7b.cred"

    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${other_cert_dir}" create >/dev/null 2>&1
    if bash "${verifier}" \
        "${other_cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "matching but unrelated signer pair was accepted" >&2
        return 1
    fi
    test_required_usr_signature_continuity \
        "${cert_dir}" "${other_cert_dir}" "${artifact_dir}" "${esp_dir}" "${token}"
    printf 'invalid policy credential\n' > "${extra_dir}/acl-ipe-policy.p7b.cred"
    if bash "${verifier}" \
        "${cert_dir}" "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "invalid installed policy credential was accepted" >&2
        return 1
    fi
    unset -f ukify
}

test_disabled_vm_signing_is_scoped_to_build() (
    source_test_functions "${SCRIPT_DIR}/image_to_vm.sh" get_disabled_vm_signing_dir
    unset ACL_EPHEMERAL_CERT_DIR

    local board_dir="${TEST_DIR}/disabled signer/amd64-usr"
    local first_output="${board_dir}/build-1" second_output="${board_dir}/build-2"
    local first_dir second_dir
    local first_key="${TEST_DIR}/disabled-first-key"
    local ensure_cert="${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh"
    mkdir -p "${first_output}" "${second_output}"

    first_dir="$(get_disabled_vm_signing_dir "${first_output}")"
    second_dir="$(get_disabled_vm_signing_dir "${second_output}")"
    [[ "${first_dir}" == "${board_dir}/.acl-secureboot-signing/build-1" ]]
    [[ "${second_dir}" == "${board_dir}/.acl-secureboot-signing/build-2" ]]
    [[ "${first_dir}" != "${first_output}/"* && "${second_dir}" != "${second_output}/"* ]]

    "${ensure_cert}" "${first_dir}" create >/dev/null 2>&1
    cp "${first_dir}/ca.key" "${first_key}"
    "${ensure_cert}" "$(get_disabled_vm_signing_dir "${first_output}")" create >/dev/null 2>&1
    cmp -s "${first_key}" "${first_dir}/ca.key"

    "${ensure_cert}" "${second_dir}" create >/dev/null 2>&1
    if cmp -s "${first_dir}/ca.key" "${second_dir}/ca.key"; then
        echo "unrelated disabled builds reused the same private key" >&2
        return 1
    fi

    ACL_EPHEMERAL_CERT_DIR=""
    [[ "$(get_disabled_vm_signing_dir "${first_output}")" == "${first_dir}" ]]
    ACL_EPHEMERAL_CERT_DIR="${TEST_DIR}/explicit signer"
    [[ "$(get_disabled_vm_signing_dir "${first_output}")" == "${ACL_EPHEMERAL_CERT_DIR}" ]]
    [[ "$(get_disabled_vm_signing_dir "${second_output}")" == "${ACL_EPHEMERAL_CERT_DIR}" ]]
)

test_markerless_ipe_assets_are_rejected() {
    local image_to_vm="${SCRIPT_DIR}/image_to_vm.sh"
    local artifact_dir="${TEST_DIR}/markerless-artifact"
    local esp_dir="${TEST_DIR}/markerless-esp"

    source_test_functions "${image_to_vm}" \
        has_ipe_assets validate_ipe_marker_consistency

    mkdir -p "${artifact_dir}/acl-ipe-policy" "${esp_dir}/EFI/Linux/acl.efi.extra.d"
    : > "${artifact_dir}/acl-ipe-policy/acl-ipe-policy.p7b.cred"

    if validate_ipe_marker_consistency "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "markerless IPE assets bypassed conversion validation" >&2
        return 1
    fi

    printf 'ephemeral\n' > "${artifact_dir}/ipe-signing-mode"
    validate_ipe_marker_consistency "${artifact_dir}" "${esp_dir}"
}

test_vm_conversion_requires_ipe_for_usr_signatures() (
    source_test_functions "${SCRIPT_DIR}/image_to_vm.sh" \
        has_ipe_assets validate_ipe_marker_consistency
    local artifact_dir="${TEST_DIR}/required-marker-artifact"
    local esp_dir="${TEST_DIR}/required-marker-esp" failure mode
    mkdir -p "${artifact_dir}" "${esp_dir}/EFI/Linux"
    [[ "$(validate_ipe_marker_consistency "${artifact_dir}" "${esp_dir}")" == disabled ]]

    printf 'required\n' > "${artifact_dir}/usr-signature-mode"
    if failure="$(validate_ipe_marker_consistency "${artifact_dir}" "${esp_dir}" 2>&1)"; then
        echo "Direct VM conversion accepted required signatures without IPE metadata or assets" >&2
        return 1
    fi
    [[ "${failure}" == *"Required /usr signatures need a valid ipe-signing-mode marker"* ]]
    for mode in ephemeral esrp; do
        printf '%s\n' "${mode}" > "${artifact_dir}/ipe-signing-mode"
        [[ "$(validate_ipe_marker_consistency "${artifact_dir}" "${esp_dir}")" == "${mode}" ]]
    done
    printf 'disabled\n' > "${artifact_dir}/usr-signature-mode"
    if validate_ipe_marker_consistency "${artifact_dir}" "${esp_dir}" 2>/dev/null; then
        echo "Direct VM conversion accepted invalid /usr signature metadata" >&2
        return 1
    fi
)

test_direct_vm_conversion_rejects_required_before_signing() (
    local fixture="${TEST_DIR}/direct-conversion"
    local library="${fixture}/build_library" output
    export CONVERSION_FIXTURE="${fixture}"
    mkdir -p "${library}/rpm" "${fixture}/input" "${fixture}/output" \
        "${fixture}/mounted/boot/EFI/Linux"
    cp "${SCRIPT_DIR}/image_to_vm.sh" "${fixture}/image_to_vm.sh"
    cp "${SCRIPT_DIR}/build_library/rpm/ipe_artifact.sh" "${library}/rpm/"
    # Stub disk/SDK setup, but execute the conversion entry point and its real
    # metadata checks. Signing stubs record whether they were reached.
    cat > "${fixture}/common.sh" <<'SH'
BUILD_LIBRARY_DIR="${CONVERSION_FIXTURE}/build_library"
DEFAULT_BOARD=amd64-usr
DEFAULT_MEM=1024
DEFAULT_BUILD_ROOT="${CONVERSION_FIXTURE}"
VM_TMP_ROOT="${CONVERSION_FIXTURE}/mounted"
PACKAGE_SOURCE_MODE=RPM
BOOTLOADER_MODE=uki
FLATCAR_PRODUCTION_IMAGE_NAME=image.bin
FLATCAR_PRODUCTION_IMAGE_SYSEXT_BASE=image_sysext
FLAGS_FALSE=1
FLAGS_TRUE=0
FLAGS_ARGV=""
VALID_IMG_TYPES=(azure)
assert_inside_chroot() { :; }
assert_not_root_user() { :; }
DEFINE_string() { printf -v "FLAGS_$1" '%s' "$2"; }
DEFINE_integer() { DEFINE_string "$@"; }
DEFINE_boolean() { DEFINE_string "$@"; }
FLAGS() {
    FLAGS_from="${CONVERSION_FIXTURE}/input"
    FLAGS_to="${CONVERSION_FIXTURE}/output"
    FLAGS_format=azure
}
switch_to_strict_mode() { set -euo pipefail; }
info() { :; }
die_notrace() { echo "$*" >&2; exit 1; }
set_vm_type() { :; }
set_vm_paths() { :; }
vm_cleanup() { :; }
fix_mtab() { :; }
setup_disk_image() { :; }
install_oem_package() { :; }
install_oem_sysext() { :; }
run_fs_hook() { :; }
_dst_dir() { printf '%s\n' "${CONVERSION_FIXTURE}/output"; }
write_vm_disk() { exit 0; }
SH
    local helper
    for helper in toolchain_util build_image_util vm_image_util cros_vm_constants \
        release_util board_options; do
        : > "${library}/${helper}.sh"
    done
    for helper in ensure_ephemeral_cert sign_uki_ephemeral; do
        cat > "${library}/rpm/${helper}.sh" <<'SH'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "${CONVERSION_FIXTURE}/signing-actions"
SH
        chmod +x "${library}/rpm/${helper}.sh"
    done

    bash "${fixture}/image_to_vm.sh"
    grep -qxF 'sign_uki_ephemeral.sh' "${fixture}/signing-actions"
    rm "${fixture}/signing-actions"
    printf 'required\n' > "${fixture}/input/usr-signature-mode"
    if output="$(bash "${fixture}/image_to_vm.sh" 2>&1)"; then
        echo "Direct conversion signed required input without IPE metadata" >&2
        return 1
    fi
    [[ "${output}" == *"Required /usr signatures need a valid ipe-signing-mode marker"* ]]
    [[ ! -e "${fixture}/signing-actions" && ! -e "${fixture}/output/usr-signature-mode" ]]
)

test_incomplete_or_mismatched_cert_pair_rejected() {
    local cert_dir="${TEST_DIR}/incomplete-cert"
    local empty_cert_dir="${TEST_DIR}/empty-cert"
    local other_cert_dir="${TEST_DIR}/mismatched-cert"
    local original_cert="${TEST_DIR}/incomplete-original.pem"

    mkdir -p "${empty_cert_dir}"
    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${empty_cert_dir}" create >/dev/null 2>&1
    [[ -s "${empty_cert_dir}/ca.key" ]]
    [[ -s "${empty_cert_dir}/uki-signing-ca.pem" ]]

    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${cert_dir}" create >/dev/null 2>&1
    cp "${cert_dir}/uki-signing-ca.pem" "${original_cert}"
    rm "${cert_dir}/ca.key"
    if "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${cert_dir}" require 2>/dev/null; then
        echo "incomplete certificate pair was accepted" >&2
        return 1
    fi
    if "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${cert_dir}" create 2>/dev/null; then
        echo "incomplete certificate pair was silently rotated" >&2
        return 1
    fi
    cmp -s "${original_cert}" "${cert_dir}/uki-signing-ca.pem"

    rm -rf "${cert_dir}"
    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${cert_dir}" create >/dev/null 2>&1
    "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${other_cert_dir}" create >/dev/null 2>&1
    cp "${other_cert_dir}/ca.key" "${cert_dir}/ca.key"
    if "${SCRIPT_DIR}/build_library/rpm/ensure_ephemeral_cert.sh" \
        "${cert_dir}" require 2>/dev/null; then
        echo "mismatched certificate pair was accepted" >&2
        return 1
    fi
}

test_root_hash_signing_boolean_and_hydration() (
    source_test_functions "${SCRIPT_DIR}/acl/build_rpm_image.sh" \
        validate_ipe_mode_value configure_ipe_mode load_artifact_ipe_signing_mode
    error() { echo "$*" >&2; }
    ACL_IPE_MODE=audit
    ACL_IPE_SIGNING_MODE=ephemeral
    ACL_ROOT_HASH_SIGNING_ENABLED=true
    configure_ipe_mode
    ACL_ROOT_HASH_SIGNING_ENABLED=required
    if configure_ipe_mode 2>/dev/null; then
        echo "non-boolean root signing value was accepted" >&2
        return 1
    fi
    ACL_ROOT_HASH_SIGNING_ENABLED=true
    ACL_IPE_MODE=disabled
    if configure_ipe_mode 2>/dev/null; then
        echo "root signing without IPE capability was accepted" >&2
        return 1
    fi

    prepare_case root-signing-hydration
    printf 'ephemeral\n' > "${BUILD_DIR}/ipe-signing-mode"
    printf 'required\n' > "${BUILD_DIR}/usr-signature-mode"
    IPE_MODE_OVERRIDE_SET=false
    IPE_SIGNING_MODE_OVERRIDE_SET=false
    ROOT_HASH_SIGNING_OVERRIDE_SET=false
    ACL_ROOT_HASH_SIGNING_ENABLED=false
    load_artifact_ipe_signing_mode "${BUILD_DIR}"
    [[ "${ACL_ROOT_HASH_SIGNING_ENABLED}" == true ]]
    ROOT_HASH_SIGNING_OVERRIDE_SET=true
    ACL_ROOT_HASH_SIGNING_ENABLED=false
    if load_artifact_ipe_signing_mode "${BUILD_DIR}" 2>/dev/null; then
        echo "explicit false downgraded a required source image" >&2
        return 1
    fi
)

test_markerless_secure_boot_cert_remains_disabled() {
    local build_script="${SCRIPT_DIR}/acl/build_rpm_image.sh"
    source_test_functions "${build_script}" load_artifact_ipe_signing_mode
    configure_ipe_mode() { :; }
    error() { echo "$*" >&2; }

    prepare_case markerless-secure-boot-cert
    mkdir -p "${BUILD_DIR}/acl-ipe-ephemeral"
    printf 'test-cert\n' > "${BUILD_DIR}/acl-ipe-ephemeral/uki-signing-ca.pem"
    IPE_MODE_OVERRIDE_SET=false
    ROOT_HASH_SIGNING_OVERRIDE_SET=false
    ACL_ROOT_HASH_SIGNING_ENABLED=false
    ACL_IPE_MODE=audit
    ACL_IPE_SIGNING_MODE=ephemeral

    load_artifact_ipe_signing_mode "${BUILD_DIR}"
    [[ "${ACL_IPE_MODE}" == "disabled" ]]

    mkdir -p "${BUILD_DIR}/acl-ipe-policy"
    if load_artifact_ipe_signing_mode "${BUILD_DIR}" 2>/dev/null; then
        echo "markerless IPE policy assets were accepted" >&2
        return 1
    fi
}

test_pure_vm_reuse_skips_local_artifact() {
    local build_script="${SCRIPT_DIR}/acl/build_rpm_image.sh"
    source_test_functions "${build_script}" \
        operation_uses_vm_image operation_uses_gallery_image \
        operation_uses_local_image_artifact

    BUILD_IMAGE=false
    BUILD_VM_IMAGE=false
    BUILD_TEST_IMAGE=false
    START_VM=true
    RUN_KOLA_TESTS=false
    REUSE_VM=true
    REUSE_IMAGE=false
    ACG_IMAGE_VERSION_ID=""

    if operation_uses_local_image_artifact; then
        echo "pure VM reuse was classified as local-artifact consumption" >&2
        return 1
    fi

    BUILD_VM_IMAGE=true
    operation_uses_local_image_artifact
}

test_reused_vm_type_loaded_from_state() {
    local build_script="${SCRIPT_DIR}/acl/build_rpm_image.sh"
    local state_file="${TEST_DIR}/vm-state.env"
    source_test_functions "${build_script}" load_reused_vm_type
    error() { echo "$*" >&2; }

    REUSE_VM=true
    VM_TYPE=qemu
    printf 'VM_TYPE=azure\n' > "${state_file}"
    load_reused_vm_type "${state_file}"
    [[ "${VM_TYPE}" == "azure" ]]

    printf 'VM_TYPE=invalid\n' > "${state_file}"
    if load_reused_vm_type "${state_file}" 2>/dev/null; then
        echo "invalid reused VM type was accepted" >&2
        return 1
    fi
}

test_ipe_disabled_by_default
test_ipe_disabled_stages_nothing
test_disabled_cleanup_removes_stale_assets
test_audit_ephemeral_stages_candidate
test_audit_esrp_stages_candidate
test_enforcing_mode_rejected
test_uki_provision_preserves_unsigned_verity
test_uki_binds_policy_before_writing_cmdline
test_vm_conversions_share_secure_boot_cert
test_disabled_vm_signing_is_scoped_to_build
test_markerless_ipe_assets_are_rejected
test_vm_conversion_requires_ipe_for_usr_signatures
test_direct_vm_conversion_rejects_required_before_signing
test_incomplete_or_mismatched_cert_pair_rejected
test_root_hash_signing_boolean_and_hydration
test_markerless_secure_boot_cert_remains_disabled
test_pure_vm_reuse_skips_local_artifact
test_reused_vm_type_loaded_from_state

echo "IPE policy input tests passed"
