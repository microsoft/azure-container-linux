#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export ACL_VERITY_RUN_DIR="${work}"
source "${ROOT}/build_library/rpm/additional_files/dracut-acl-usr-verity/acl-verity-setup.sh"
root_hash="$(printf 'a%.0s' {1..64})"
slot=a mode=audit options=panic-on-corruption
data_device=/dev/data hash_device=/dev/tree
mapping=false signed_result=0 unsigned_result=0 error_number=0 result=success
VERITYSETUP=mock_veritysetup
acl_verity_mapping_exists() { [[ "${mapping}" == true ]]; }
mock_veritysetup() {
    printf '%s\n' "$*" >> "${work}/unsigned.calls"
    [[ "$*" == "attach usr ${data_device} ${hash_device} ${root_hash} panic-on-corruption" ]] || return 1
    return "${unsigned_result}"
}
systemd-run() {
    printf '%s\n' "$*" >> "${work}/signed.calls"
    [[ "$*" == *"root-hash-signature="* ]] || return 1
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
mock_errno=0 mock_result=success
acl_verity_signed "${work}/sig"
[[ "$(jq -r .verification "${work}/usr-verity.json")" == verified ]]
[[ ! -e "${work}/unsigned.calls" ]]
rm "${work}/usr-verity.json"
jq() { return 1; }
reject acl_verity_signed "${work}/sig"
[[ ! -e "${work}/usr-verity.json" ]]
unset -f jq
signed_result=1
for mock_errno in 126 127 128 129; do
    mock_result=exit-code
    acl_verity_signed "${work}/sig"
    [[ "$(jq -r .verification "${work}/usr-verity.json")" == degraded ]]
done
[[ "$(wc -l < "${work}/unsigned.calls")" == 4 ]]
for mock_errno in 0 5 12 22; do
    mock_result=exit-code
    reject acl_verity_signed "${work}/sig"
done
mock_errno=126 mock_result=timeout
reject acl_verity_signed "${work}/sig"
[[ "$(wc -l < "${work}/unsigned.calls")" == 4 ]]
mapping=true
reject acl_verity_signed "${work}/sig"
reject acl_verity_unsigned degraded bad-signature
mapping=false unsigned_result=1 mock_result=exit-code
rm "${work}/usr-verity.json"
reject acl_verity_signed "${work}/sig"
[[ ! -e "${work}/usr-verity.json" ]]
unsigned_result=0 mode=off
acl_verity_unsigned not-requested audit-not-requested
[[ "$(jq -r .requestedMode "${work}/usr-verity.json")" == off ]]
words=("usrhash=${root_hash}" "usrhash=${root_hash}")
reject acl_verity_arg usrhash

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
profile_value=ipe=audit
acl_verity_main
[[ "$(<"${work}/ipe-early-mode")" == audit ]]
[[ "$(jq -r .reason "${work}/usr-verity.json")" == signature-partition-unavailable ]]
profile_result=124
acl_verity_main
[[ "$(<"${work}/ipe-early-mode")" == lookup-failed ]]
[[ "$(jq -r .requestedMode "${work}/usr-verity.json")" == unavailable ]]
profile_result=0 signature_available=true signed_result=0
acl_verity_main
[[ "$(jq -r .verification "${work}/usr-verity.json")" == verified ]]
validation_result=124
acl_verity_main
[[ "$(jq -r .verification "${work}/usr-verity.json")" == degraded ]]
[[ "$(<"${work}/ipe-early-mode")" == audit ]]
profile_value='ipe=,ipe=audit'
acl_verity_main
[[ "$(<"${work}/ipe-early-mode")" == lookup-failed ]]
echo "Signed /usr activation: typed failure classification, mapping ownership and unchanged ordinary options passed"
