#!/bin/bash
# shellcheck disable=SC2034,SC2154 # Variables are shared with sourced/extracted production functions.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export ACL_VERITY_RUN_DIR="${work}"
source "${ROOT}/build_library/rpm/additional_files/dracut-acl-usr-verity/acl-verity-setup.sh"
root_hash="$(printf 'a%.0s' {1..64})"
mapping=false signed_result=0 unsigned_result=0
signed_calls=0 unsigned_calls=0
VERITYSETUP=mock_veritysetup
acl_verity_mapping_exists() { [[ "${mapping}" == true ]]; }
mock_veritysetup() {
    unsigned_calls=$((unsigned_calls + 1))
    [[ "$*" == "attach usr ${data_device} ${hash_device} ${root_hash} panic-on-corruption" ]] || return 1
    return "${unsigned_result}"
}
systemd-run() {
    signed_calls=$((signed_calls + 1))
    [[ "$*" == *"attach usr ${data_device} ${hash_device} ${root_hash} panic-on-corruption,root-hash-signature=${work}/usr.p7s" ]] || return 1
    return "${signed_result}"
}
systemctl() {
    case "$*" in
        "show --value -p StatusErrno "*) echo "${mock_errno}" ;;
        "show --value -p Result "*) echo "${mock_result}" ;;
        "reset-failed "*) ;;
        *) echo "Unexpected systemctl call: $*" >&2; return 1 ;;
    esac
}
reject() {
    if "$@" > "${work}/failure.out" 2>&1; then
        echo "Unexpected success: $*" >&2
        exit 1
    fi
}
CMDLINE_FILE="${work}/cmdline"
profile_result=0 profile_value=ipe=off signature_available=false validation_result=0
timeout() {
    case "$*" in
        *--profile) printf '%s\n' "${profile_value}"; return "${profile_result}" ;;
        *--check-signature*) return "${validation_result}" ;;
        *) command timeout "$@" ;;
    esac
}
acl_verity_signature_device() {
    [[ "${signature_available}" == true ]] || return 1
    echo "${work}/signature-partition"
}
blockdev() { echo 4096; }
printf '\0' > "${work}/signature-partition"
truncate -s 4096 "${work}/signature-partition"
printf '%s\n' "flatcar.oem.id=azure usrhash=${root_hash} acl.slot=a systemd.verity_usr_data=PARTUUID=7130c94a-213a-4e5a-8e26-6cce9662f132 systemd.verity_usr_hash=PARTUUID=b736baf1-cdb4-4535-beba-ddaaa30ad7b7 systemd.verity_usr_options=panic-on-corruption acl.verity_usr_signature=PARTUUID=3514648f-e3da-44ae-89ba-8d0552418f88" > "${CMDLINE_FILE}"
acl_verity_main
[[ "$(<"${work}/ipe-early-mode")" == off ]]
[[ "$(jq -r .verification "${work}/usr-verity.json")" == not-requested ]]
[[ "${signed_calls}" == 0 ]]
profile_value=ipe=audit
acl_verity_main
[[ "$(<"${work}/ipe-early-mode")" == audit ]]
[[ "$(jq -r .reason "${work}/usr-verity.json")" == signature-partition-unavailable ]]
profile_result=124
acl_verity_main
[[ "$(<"${work}/ipe-early-mode")" == lookup-failed ]]
[[ "$(jq -r .requestedMode "${work}/usr-verity.json")" == unavailable ]]
[[ "$(jq -r .verification "${work}/usr-verity.json")" == degraded ]]
profile_result=0 signature_available=true signed_result=0
acl_verity_main
[[ "$(jq -r .verification "${work}/usr-verity.json")" == verified ]]
before="${unsigned_calls}"
signed_result=1 mock_result=exit-code
for mock_errno in 126 127 128 129; do
    acl_verity_main
    [[ "$(jq -r .verification "${work}/usr-verity.json")" == degraded ]]
done
[[ "${unsigned_calls}" == "$((before + 4))" ]]
before="${unsigned_calls}"
for mock_errno in 0 5 22; do
    reject acl_verity_main
done
mock_errno=126 mock_result=timeout
reject acl_verity_main
mapping=true
reject acl_verity_main
[[ "${unsigned_calls}" == "${before}" ]]
mapping=false unsigned_result=1 mock_result=exit-code
rm "${work}/usr-verity.json"
reject acl_verity_main
[[ ! -e "${work}/usr-verity.json" ]]
unsigned_result=0
validation_result=124
acl_verity_main
[[ "$(jq -r .verification "${work}/usr-verity.json")" == degraded ]]
[[ "$(<"${work}/ipe-early-mode")" == audit ]]
profile_value='ipe=,ipe=audit'
acl_verity_main
[[ "$(<"${work}/ipe-early-mode")" == lookup-failed ]]
(
    source "${ROOT}/acl/tests/ipe/offline/function-extraction.sh"
    source_test_functions "${ROOT}/acl/build_rpm_image.sh" configure_ipe_mode validate_ipe_mode_value
    error() { echo "$*" >&2; }
    ACL_IPE_MODE=disabled ACL_IPE_SIGNING_MODE=ephemeral ACL_USR_HASH_SIGNATURE=false
    configure_ipe_mode
    ACL_USR_HASH_SIGNATURE=true
    reject configure_ipe_mode
    ACL_IPE_MODE=audit
    configure_ipe_mode
    ACL_USR_HASH_SIGNATURE=invalid
    reject configure_ipe_mode
)
(
    ln() { printf '%s\n' "$*" > "${work}/link"; }
    export -f ln
    export work ACL_VERITY_CMDLINE_FILE="${CMDLINE_FILE}"
    generator="${ROOT}/build_library/rpm/additional_files/dracut-acl-usr-verity/acl-verity-generator.sh"
    bash "${generator}" "${work}/normal" "${work}/early" "${work}/late"
    [[ "$(<"${work}/link")" == "-sf /dev/null ${work}/early/afterburn-network-kargs.service" ]]
    printf '%s\n' 'flatcar.oem.id=azure' > "${CMDLINE_FILE}"
    rm "${work}/link"
    bash "${generator}" "${work}/normal" "${work}/early" "${work}/late"
    [[ ! -e "${work}/link" ]]
)
echo "Signed /usr boot gating, failure handling and initrd ordering tests passed"
