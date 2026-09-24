#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Offline regression checks for the Azure RPM metadata correction.
# Usage: bash build_library/rpm/tests/test_azure_metadata_ipv4.sh
# Bash/jq are real; ip/curl are local fixtures, so no SDK or network is needed.

set -euo pipefail
export LC_ALL=C

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TESTS_DIR}/../../.." && pwd)"
OEM_FILES="${REPO_DIR}/sdk_container/src/third_party/coreos-overlay/coreos-base/oem-azure/files"
HELPER="${OEM_FILES}/azure-metadata-ipv4"
DROPIN="${OEM_FILES}/20-azure-ipv4.conf"
CASE_NAME=setup
CASE_COUNT=0
WORK_DIR=""
FIXTURE_DIR=""
METADATA=""

fail() {
    printf 'FAIL: %s: %s\n' "$CASE_NAME" "$*" >&2
    exit 1
}

pass() {
    CASE_COUNT=$((CASE_COUNT + 1))
    printf 'PASS %02d: %s\n' "$CASE_COUNT" "$CASE_NAME"
}

check_prerequisites() {
    local dependency asset

    for dependency in bash jq; do
        command -v "$dependency" > /dev/null || fail "missing dependency: $dependency"
    done
    for asset in "$HELPER" "$DROPIN" "${OEM_FILES}/manglefs.sh" "${OEM_FILES}/manglefs_rpm.sh"; do
        [[ -f "$asset" ]] || fail "missing source asset: $asset"
    done
}

setup_workspace() {
    WORK_DIR="$(mktemp -d)"
    trap 'rm -rf -- "$WORK_DIR"' EXIT
    mkdir -p "${WORK_DIR}/bin"
    printf 'route\naddresses\ncurl\n' > "${WORK_DIR}/expected-calls"

    # These stubs never fall back to host commands. A protocol error is recorded
    # separately so an expected helper failure cannot conceal wrong arguments.
    cat > "${WORK_DIR}/bin/ip" <<'MOCK_IP'
#!/bin/bash
set -euo pipefail
case "$#:$*" in
    '5:-j -4 route get 168.63.129.16')
        printf 'route\n' >> "${FIXTURE_DIR}/calls"
        cat "${FIXTURE_DIR}/route.json"
        # Valid output must not hide a failed command's exit status.
        if [[ -e "${FIXTURE_DIR}/route-fails" ]]; then
            exit 2
        fi
        ;;
    '5:-j address show dev eth1')
        printf 'addresses\n' >> "${FIXTURE_DIR}/calls"
        cat "${FIXTURE_DIR}/addresses.json"
        ;;
    *)
        printf 'unexpected ip arguments: %s\n' "$*" > "${FIXTURE_DIR}/mock-error"
        exit 64
        ;;
esac
MOCK_IP

    cat > "${WORK_DIR}/bin/curl" <<'MOCK_CURL'
#!/bin/bash
set -euo pipefail
# Exact argv enforces bounded HTTP, Metadata:true, proxy bypass, interface
# binding, and no redirect-following option (including -L/--location).
expected=(
    --noproxy '*' --interface eth1 --proto '=http'
    --fail --silent --show-error --connect-timeout 2 --max-time 10
    --max-filesize 1048576 -H 'Metadata: true'
    'http://169.254.169.254/metadata/instance/network?api-version=2021-02-01'
)
if [[ $# -ne ${#expected[@]} ]]; then
    printf 'unexpected curl argument count: %s\n' "$#" > "${FIXTURE_DIR}/mock-error"
    exit 64
fi
for argument in "${expected[@]}"; do
    if [[ "$1" != "$argument" ]]; then
        printf 'curl: expected <%s>, got <%s>\n' "$argument" "$1" > "${FIXTURE_DIR}/mock-error"
        exit 64
    fi
    shift
done
printf 'curl\n' >> "${FIXTURE_DIR}/calls"
cat "${FIXTURE_DIR}/imds.json"
if [[ -e "${FIXTURE_DIR}/curl-fails" ]]; then
    exit 22
fi
MOCK_CURL
    chmod 0755 "${WORK_DIR}/bin/ip" "${WORK_DIR}/bin/curl"
    export PATH="${WORK_DIR}/bin:${PATH}"
}

new_fixture() {
    CASE_NAME="$1"
    local selected_ipv4="${2:-10.188.33.69}"
    export FIXTURE_DIR="${WORK_DIR}/${CASE_NAME}"
    mkdir -p "$FIXTURE_DIR"
    METADATA="${FIXTURE_DIR}/flatcar"
    cat > "${FIXTURE_DIR}/route.json" <<JSON
[{"dst":"168.63.129.16","dev":"eth1","prefsrc":"${selected_ipv4}"}]
JSON
    cat > "${FIXTURE_DIR}/addresses.json" <<JSON
[{"ifname":"eth1","address":"00:0D:3A:18:83:69","addr_info":[
    {"family":"inet","local":"${selected_ipv4}","scope":"global"}
]}]
JSON
    cat > "${FIXTURE_DIR}/imds.json" <<JSON
{"interface":[{"macAddress":"000D3A188369","ipv4":{"ipAddress":[
    {"privateIpAddress":"${selected_ipv4}"}
]}}]}
JSON
    cat > "$METADATA" <<'METADATA'
# Preserve comments, order, blank lines, and unrelated fields.
COREOS_AZURE_HOSTNAME=fixture-vm
COREOS_AZURE_IPV4_DYNAMIC=10.10.10.10
COREOS_AZURE_IPV4_STATIC=10.10.10.10
COREOS_AZURE_NOTE=literal=value with spaces
OTHER_COREOS_AZURE_IPV4_DYNAMIC=leave-this-alone
# COREOS_AZURE_IPV4_DYNAMIC=leave-this-comment-alone

METADATA
    sed "s/^COREOS_AZURE_IPV4_DYNAMIC=.*/COREOS_AZURE_IPV4_DYNAMIC=${selected_ipv4}/" \
        "$METADATA" > "${FIXTURE_DIR}/expected"
}

run_helper() {
    local expected_result="$1" status
    if [[ -f "$METADATA" ]]; then
        cp -- "$METADATA" "${FIXTURE_DIR}/before"
    fi
    : > "${FIXTURE_DIR}/calls"
    # Always call this function as a standalone command, never in if/!/||.
    # A separate Bash process retains the helper's own errexit semantics.
    set +e
    bash "$HELPER" "$METADATA" > "${FIXTURE_DIR}/output" 2>&1
    status=$?
    set -e
    if [[ -e "${FIXTURE_DIR}/mock-error" ]]; then
        cat "${FIXTURE_DIR}/mock-error" >&2
        fail "unexpected mock invocation"
    fi
    if [[ "$expected_result" == success ]]; then
        if [[ $status -ne 0 ]]; then
            cat "${FIXTURE_DIR}/output" >&2
            fail "helper exited $status"
        fi
        cmp "${WORK_DIR}/expected-calls" "${FIXTURE_DIR}/calls" || fail "expected route, address, and IMDS checks"
    else
        [[ $status -ne 0 ]] || fail "helper accepted invalid input"
        if [[ -f "${FIXTURE_DIR}/before" ]]; then
            cmp "${FIXTURE_DIR}/before" "$METADATA" || fail "metadata changed on rejection"
        else
            [[ ! -e "$METADATA" && ! -L "$METADATA" ]] || fail "missing metadata was created"
        fi
        [[ ! -e "${METADATA}.wireserver" && ! -L "${METADATA}.wireserver" ]] || fail "backup created on rejection"
    fi
}

test_correction_and_regeneration_preserve_first_backup() {
    new_fixture correction-and-regeneration-preserve-first-backup
    run_helper success
    cmp "${FIXTURE_DIR}/expected" "$METADATA" || fail "correction changed more than the target field"
    cmp "${FIXTURE_DIR}/before" "${METADATA}.wireserver" || fail "backup differs from original metadata"
    cp "${FIXTURE_DIR}/before" "${FIXTURE_DIR}/first-backup"
    # A new Afterburn result can be wrong without containing 10.10.10.10.
    sed 's/^COREOS_AZURE_IPV4_DYNAMIC=.*/COREOS_AZURE_IPV4_DYNAMIC=192.0.2.17/' \
        "$METADATA" > "${FIXTURE_DIR}/regenerated"
    printf 'COREOS_AZURE_REGENERATED=preserve-me\n' >> "${FIXTURE_DIR}/regenerated"
    mv "${FIXTURE_DIR}/regenerated" "$METADATA"
    printf 'COREOS_AZURE_REGENERATED=preserve-me\n' >> "${FIXTURE_DIR}/expected"
    run_helper success
    cmp "${FIXTURE_DIR}/expected" "$METADATA" || fail "regenerated metadata was not corrected in place"
    cmp "${FIXTURE_DIR}/first-backup" "${METADATA}.wireserver" || fail "first backup was overwritten"
    pass
}

test_already_correct_byte_identical_without_backup() {
    new_fixture already-correct-byte-identical-without-backup
    cp "${FIXTURE_DIR}/expected" "$METADATA"
    run_helper success
    cmp "${FIXTURE_DIR}/before" "$METADATA" || fail "already-correct metadata changed"
    [[ ! -e "${METADATA}.wireserver" && ! -L "${METADATA}.wireserver" ]] || fail "unnecessary backup"
    pass
}

test_nonfirst_nic_and_ip_with_lowercase_colon_mac() {
    new_fixture nonfirst-nic-and-ip-with-lowercase-colon-mac
    cat > "${FIXTURE_DIR}/addresses.json" <<'JSON'
[{"ifname":"eth1","address":"00:0D:3A:18:83:69","addr_info":[
    {"family":"inet","local":"10.188.33.70","scope":"global"},
    {"family":"inet","local":"10.188.33.69","scope":"global"},
    {"family":"inet6","local":"fe80::20d:3aff:fe18:8369","scope":"link"}
]}]
JSON
    cat > "${FIXTURE_DIR}/imds.json" <<'JSON'
{"interface":[
    {"macAddress":"00155D188330","ipv4":{"ipAddress":[
        {"privateIpAddress":"10.188.34.10"}
    ]}},
    {"macAddress":"00:0d:3a:18:83:69","ipv4":{"ipAddress":[
        {"privateIpAddress":"10.188.33.70"},
        {"privateIpAddress":"10.188.33.69"}
    ]}}
]}
JSON
    run_helper success
    cmp "${FIXTURE_DIR}/expected" "$METADATA" || fail "wrong interface or address selected"
    cmp "${FIXTURE_DIR}/before" "${METADATA}.wireserver" || fail "backup differs from original metadata"
    pass
}

test_genuinely_assigned_10_10_10_10_is_allowed() {
    new_fixture genuinely-assigned-10.10.10.10-is-allowed 10.10.10.10
    sed -i 's/^COREOS_AZURE_IPV4_DYNAMIC=.*/COREOS_AZURE_IPV4_DYNAMIC=192.0.2.17/' "$METADATA"
    run_helper success
    cmp "${FIXTURE_DIR}/expected" "$METADATA" || fail "genuinely assigned 10.10.10.10 was not accepted"
    cmp "${FIXTURE_DIR}/before" "${METADATA}.wireserver" || fail "backup differs from original metadata"
    pass
}

transform_json() {
    local file="${FIXTURE_DIR}/$1"

    jq "$2" "$file" > "${FIXTURE_DIR}/next.json"
    mv "${FIXTURE_DIR}/next.json" "$file"
}

new_rejection_fixture() {
    local rejection="$1"

    new_fixture "$rejection"
    case "$rejection" in
        route-command-fails)
            touch "${FIXTURE_DIR}/route-fails"
            ;;
        route-empty)
            printf '[]\n' > "${FIXTURE_DIR}/route.json"
            ;;
        route-malformed)
            printf '{\n' > "${FIXTURE_DIR}/route.json"
            ;;
        route-ambiguous)
            transform_json route.json '. + .'
            ;;
        route-missing-prefsrc)
            transform_json route.json 'del(.[0].prefsrc)'
            ;;
        source-ip-not-assigned)
            transform_json addresses.json '.[0].addr_info[0].local = "10.188.33.70"'
            ;;
        invalid-ipv4)
            # Assignment and IMDS deliberately agree: IPv4 validation must reject it.
            new_fixture "$rejection" 10.188.33.1024
            ;;
        link-scope-only)
            transform_json addresses.json '.[0].addr_info[0].scope = "link"'
            ;;
        imds-curl-error)
            touch "${FIXTURE_DIR}/curl-fails"
            ;;
        imds-invalid-json)
            printf '{\n' > "${FIXTURE_DIR}/imds.json"
            ;;
        imds-empty-interface)
            printf '{"interface":[]}\n' > "${FIXTURE_DIR}/imds.json"
            ;;
        imds-ip-mismatch)
            transform_json imds.json '.interface[0].ipv4.ipAddress[0].privateIpAddress = "10.188.33.70"'
            ;;
        imds-mac-mismatch)
            transform_json imds.json '.interface[0].macAddress = "00155D188330"'
            ;;
        imds-duplicate-candidate)
            transform_json imds.json '.interface[0].ipv4.ipAddress |= . + .'
            ;;
        missing-metadata)
            rm -- "$METADATA"
            ;;
        missing-key)
            sed -i '/^COREOS_AZURE_IPV4_DYNAMIC=/d' "$METADATA"
            ;;
        duplicate-key)
            printf 'COREOS_AZURE_IPV4_DYNAMIC=192.0.2.17\n' >> "$METADATA"
            ;;
    esac
}

test_rejections() {
    local rejection
    local rejections=(
        route-command-fails route-empty route-malformed route-ambiguous route-missing-prefsrc
        source-ip-not-assigned invalid-ipv4 link-scope-only
        imds-curl-error imds-invalid-json imds-empty-interface imds-ip-mismatch
        imds-mac-mismatch imds-duplicate-candidate missing-metadata missing-key duplicate-key
    )

    for rejection in "${rejections[@]}"; do
        new_rejection_fixture "$rejection"
        run_helper failure
        pass
    done
}

test_rpm_only_packaging_and_appended_dropin() {
    local mode rootfs installed_helper installed_dropin

    CASE_NAME=rpm-only-packaging-and-appended-drop-in
    for mode in RPM PORTAGE; do
        rootfs="${WORK_DIR}/rootfs-${mode}"
        mkdir -p "${rootfs}/etc/systemd/system" "${rootfs}/usr/bin"
        # Source the real entry point; it must decide whether to load the RPM hook.
        (
            export PACKAGE_SOURCE_MODE="$mode"
            source "${OEM_FILES}/manglefs.sh" "$rootfs"
        )
        installed_helper="${rootfs}/usr/libexec/azure-metadata-ipv4"
        installed_dropin="${rootfs}/usr/lib/systemd/system/coreos-metadata.service.d/20-azure-ipv4.conf"
        if [[ "$mode" == RPM ]]; then
            cmp "$HELPER" "$installed_helper" || fail "installed helper differs from source"
            cmp "$DROPIN" "$installed_dropin" || fail "installed drop-in differs from source"
            [[ "$(stat -c '%a' "$installed_helper")" == 755 ]] || fail "helper mode is not 0755"
            [[ "$(stat -c '%a' "$installed_dropin")" == 644 ]] || fail "drop-in mode is not 0644"
        else
            [[ ! -e "$installed_helper" && ! -L "$installed_helper" ]] || fail "helper leaked into PORTAGE"
            [[ ! -e "$installed_dropin" && ! -L "$installed_dropin" ]] || fail "drop-in leaked into PORTAGE"
        fi
    done
    grep -Fxq 'ExecStartPost=/usr/libexec/azure-metadata-ipv4' "$DROPIN" || fail "missing appended helper command"
    [[ "$(grep -Ec '^[[:space:]]*ExecStartPost[[:space:]]*=' "$DROPIN")" == 1 ]] || fail "expected exactly one appended command"
    if grep -Eq '^[[:space:]]*ExecStartPost[[:space:]]*=[[:space:]]*$' "$DROPIN"; then
        fail "drop-in resets existing ExecStartPost commands"
    fi
    if grep -Eq '^[[:space:]]*After[[:space:]]*=.*coreos-metadata\.service' "$DROPIN"; then
        fail "metadata service orders after itself"
    fi
    pass
}

main() {
    check_prerequisites
    setup_workspace

    test_correction_and_regeneration_preserve_first_backup
    test_already_correct_byte_identical_without_backup
    test_nonfirst_nic_and_ip_with_lowercase_colon_mac
    test_genuinely_assigned_10_10_10_10_is_allowed
    test_rejections
    test_rpm_only_packaging_and_appended_dropin

    printf '=== PASS: %d offline Azure metadata IPv4 regression cases ===\n' "$CASE_COUNT"
}

main "$@"