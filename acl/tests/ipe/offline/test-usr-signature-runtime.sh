#!/bin/bash
# shellcheck disable=SC2034 # Variables are consumed by sourced production functions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MODULE="${SCRIPT_DIR}/build_library/rpm/additional_files/dracut-acl-usr-signature"
PROFILE_HELPER="${SCRIPT_DIR}/build_library/rpm/additional_files/acl-node-security-profile.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

export ACL_SECURITY_PROFILE_HELPER="${TEST_DIR}/helper.sh"
export ACL_USR_VERITY_REAL="${TEST_DIR}/veritysetup"
export CALLS="${TEST_DIR}/calls" NETWORK_CALLS="${TEST_DIR}/network"
export REAL_STATUS=0 MOCK_CURL_STATUS=0 MOCK_PROFILE=ipe=audit
hash="$(printf '%064d' 1)"
signature="root-hash-signature=/.extra/credentials/verity-usr-${hash}.p7s.cred"
options="hash-offset=4096,${signature},panic-on-corruption"

cat > "${ACL_SECURITY_PROFILE_HELPER}" <<EOF
source "${PROFILE_HELPER}"
acl_usrbin() {
    case "\$1" in
        curl)
            printf 'curl\n' >> "\${NETWORK_CALLS}"
            [[ "\${ACL_SECURITY_PROFILE_EARLY:-false}" == true ]] || return 99
            printf '[{"name":"acl-node-security-profile","value":"%s"}]' "\${MOCK_PROFILE}"
            return "\${MOCK_CURL_STATUS}"
            ;;
        jq) shift; command jq "\$@" ;;
        *) return 99 ;;
    esac
}
systemctl() { echo systemctl >> "\${NETWORK_CALLS}"; return 99; }
sleep() { :; }
EOF
cat > "${ACL_USR_VERITY_REAL}" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" >> "${CALLS}"
exit "${REAL_STATUS}"
EOF
chmod +x "${ACL_USR_VERITY_REAL}"

prepare_case() {
    export ACL_SECURITY_PROFILE_CACHE="${TEST_DIR}/$1/profile"
    mkdir -p "${ACL_SECURITY_PROFILE_CACHE%/*}"
    : > "${CALLS}"
    : > "${NETWORK_CALLS}"
    REAL_STATUS=0
    MOCK_CURL_STATUS=0
    MOCK_PROFILE=ipe=audit
}

attach() {
    bash "${MODULE}/systemd-veritysetup" attach usr /dev/data /dev/hash "${hash}" "${1:-${options}}"
}

assert_options() {
    printf '%s\0' attach usr /dev/data /dev/hash "${hash}" "$1" > "${TEST_DIR}/expected"
    cmp "${TEST_DIR}/expected" "${CALLS}"
}

test_runtime_selection() {
    local mode expected
    for mode in audit disabled off enforcing unknown ""; do
        prepare_case "mode-${mode}"
        printf 'selinux=enforcing,ipe=%s' "${mode}" > "${ACL_SECURITY_PROFILE_CACHE}"
        attach
        expected="hash-offset=4096,panic-on-corruption"
        [[ "${mode}" != audit ]] || expected="${options}"
        assert_options "${expected}"
        [[ ! -s "${NETWORK_CALLS}" ]]
    done
}

test_empty_options_and_passthrough() {
    prepare_case empty-options
    printf ipe=off > "${ACL_SECURITY_PROFILE_CACHE}"
    attach "${signature}"
    assert_options ""
    : > "${CALLS}"
    attach ",${signature},panic-on-corruption,,"
    assert_options ",panic-on-corruption,,"

    local operation
    for operation in attach detach; do
        : > "${CALLS}"
        bash "${MODULE}/systemd-veritysetup" "${operation}" root /dev/data /dev/hash "${hash}" "${options}"
        printf '%s\0' "${operation}" root /dev/data /dev/hash "${hash}" "${options}" > "${TEST_DIR}/expected"
        cmp "${TEST_DIR}/expected" "${CALLS}"
    done
    : > "${CALLS}"
    bash "${MODULE}/systemd-veritysetup" detach usr
    printf '%s\0' detach usr > "${TEST_DIR}/expected"
    cmp "${TEST_DIR}/expected" "${CALLS}"
    [[ ! -s "${NETWORK_CALLS}" ]]
}

test_invalid_options_and_helper_failure() {
    prepare_case invalid-options
    printf ipe=audit > "${ACL_SECURITY_PROFILE_CACHE}"
    local invalid
    for invalid in "${options},${signature}" "/legacy/signature" \
        "${signature},foo=escaped\\,comma" "root-hash-signature=" \
        "${signature/verity-usr-/verity-other-}" "panic-on-corruption" \
        "${options}"$'\n' "panic-on-corruption"$'\r'",${signature}"; do
        if attach "${invalid}"; then
            echo "Accepted invalid signature options: ${invalid}" >&2
            return 1
        fi
        [[ ! -s "${CALLS}" ]]
    done
    if bash "${MODULE}/systemd-veritysetup" attach usr; then
        echo "Accepted incomplete /usr attachment" >&2
        return 1
    fi
    REAL_STATUS=17
    local rc=0
    attach || rc=$?
    [[ "${rc}" == 17 ]]
    assert_options "${options}" # Exactly one call, with no unsigned retry.
}

test_lookup_and_cached_fallback() {
    prepare_case early-success
    bash "${MODULE}/acl-security-profile-early.sh"
    attach
    assert_options "${options}"
    [[ "$(cat "${NETWORK_CALLS}")" == curl ]]
    [[ ! -e "${ACL_SECURITY_PROFILE_CACHE}.failed" ]]

    local outcome
    for outcome in failed malformed timed-out skipped; do
        prepare_case "${outcome}"
        if [[ "${outcome}" == failed || "${outcome}" == malformed ]]; then
            if [[ "${outcome}" == failed ]]; then
                MOCK_CURL_STATUS=1
            else
                MOCK_PROFILE='"invalid-json'
            fi
            if bash "${MODULE}/acl-security-profile-early.sh"; then
                echo "Invalid IMDS response was accepted" >&2
                return 1
            fi
            if [[ "${outcome}" == failed ]]; then
                [[ "$(wc -l < "${NETWORK_CALLS}")" -eq 30 ]]
            fi
        fi
        # A timed-out or skipped lookup leaves no result; the wrapper must seal it.
        : > "${NETWORK_CALLS}"
        attach
        assert_options hash-offset=4096,panic-on-corruption
        [[ -f "${ACL_SECURITY_PROFILE_CACHE}.failed" ]]
        # Late consumers must not turn an unsigned fallback into an audit request.
        if bash -c 'source "${ACL_SECURITY_PROFILE_HELPER}"; acl_security_profile'; then
            echo "Late lookup ignored the cached failure" >&2
            return 1
        fi
        [[ ! -s "${NETWORK_CALLS}" ]]
    done
}

test_module_staging() (
    source "${SCRIPT_DIR}/build_library/rpm/dracut_install.sh"
    BUILD_LIBRARY_DIR="${SCRIPT_DIR}/build_library"
    ACL_IPE_CAPABLE=true
    ACL_ROOT_HASH_SIGNING_ENABLED=true
    BOOTLOADER_MODE=uki
    info() { :; }
    die() { echo "$*" >&2; exit 1; }
    sudo() { command "$@"; }
    local root="${TEST_DIR}/root"
    local staged="${root}/usr/lib/dracut/modules.d/99acl-usr-signature"
    _dracut_install_usr_signature_module "${root}"
    cmp "${MODULE}/systemd-veritysetup" "${staged}/systemd-veritysetup"
    cmp "${PROFILE_HELPER}" "${staged}/acl-node-security-profile.sh"
    ACL_ROOT_HASH_SIGNING_ENABLED=false
    _dracut_install_usr_signature_module "${root}"
    [[ ! -e "${staged}" ]]
    ACL_ROOT_HASH_SIGNING_ENABLED=true
    BOOTLOADER_MODE=grub
    if ( _dracut_install_usr_signature_module "${root}" ); then
        echo "Installed signature wrapper on GRUB" >&2
        return 1
    fi
)

test_module_overwrites_stock_binary() (
    local moddir="${MODULE}" initdir="${TEST_DIR}/initrd"
    local systemdutildir=/usr/lib/systemd systemdsystemunitdir=/usr/lib/systemd/system
    mkdir -p "${initdir}/usr/lib/systemd"
    printf stock > "${initdir}/usr/lib/systemd/systemd-veritysetup"
    inst_multiple() { :; }
    inst_binary() {
        mkdir -p "${initdir}${2%/*}"
        printf 'binary:%s' "$1" > "${initdir}$2"
    }
    inst_simple() {
        [[ ! -e "${initdir}$2" ]] || return 0
        mkdir -p "${initdir}${2%/*}"
        cp "$1" "${initdir}$2"
    }
    inst_script() { inst_simple "$@"; }
    local staged="${TEST_DIR}/module"
    mkdir -p "${staged}"
    cp "${MODULE}/"* "${staged}/"
    cp "${PROFILE_HELPER}" "${staged}/"
    moddir="${staged}"
    source "${MODULE}/module-setup.sh"
    install
    cmp "${MODULE}/systemd-veritysetup" "${initdir}/usr/lib/systemd/systemd-veritysetup"
    [[ "$(<"${initdir}/usr/lib/acl/real/systemd-veritysetup")" == binary:/usr/lib/systemd/systemd-veritysetup ]]
    [[ "$(<"${initdir}/usr/lib/acl/early/curl")" == binary:/usr/bin/curl ]]
    [[ "$(<"${initdir}/usr/lib/acl/early/jq")" == binary:/usr/bin/jq ]]
    cmp "${MODULE}/acl-usr-signature-generator" \
        "${initdir}${systemdutildir}/system-generators/acl-usr-signature-generator"
)

test_azure_only_dependency_generation() (
    export ACL_IPE_CMDLINE_FILE="${TEST_DIR}/cmdline"
    local provider output
    for provider in azure vmware qemu; do
        output="${TEST_DIR}/generator-${provider}"
        mkdir -p "${output}/normal" "${output}/early"
        printf 'flatcar.oem.id=%s\n' "${provider}" > "${ACL_IPE_CMDLINE_FILE}"
        bash "${MODULE}/acl-usr-signature-generator" "${output}/normal" "${output}/early"
        if [[ "${provider}" == azure ]]; then
            grep -Fxq 'Wants=acl-security-profile-early.service' \
                "${output}/normal/systemd-veritysetup@usr.service.d/audit-signature.conf"
            grep -Fxq 'After=acl-security-profile-early.service' \
                "${output}/normal/systemd-veritysetup@usr.service.d/audit-signature.conf"
            ! grep -Eq '^(Requires|BindsTo)=' \
                "${output}/normal/systemd-veritysetup@usr.service.d/audit-signature.conf"
            [[ -L "${output}/early/afterburn-network-kargs.service" ]] &&
                [[ "$(readlink "${output}/early/afterburn-network-kargs.service")" == /dev/null ]]
        else
            [[ -z "$(find "${output}" -mindepth 2 -print)" ]]
        fi
    done
)

test_runtime_selection
test_empty_options_and_passthrough
test_invalid_options_and_helper_failure
test_lookup_and_cached_fallback
test_module_staging
test_module_overwrites_stock_binary
test_azure_only_dependency_generation
echo "audit-only /usr signature tests passed"
