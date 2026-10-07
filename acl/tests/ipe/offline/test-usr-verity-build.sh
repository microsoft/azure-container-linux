#!/bin/bash
# shellcheck disable=SC2034 # The extracted production functions consume these values.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "${ROOT}/acl/tests/ipe/offline/function-extraction.sh"
source_test_functions "${ROOT}/acl/build_rpm_image.sh" configure_ipe_mode validate_ipe_mode_value
error() { echo "$*" >&2; }
ACL_IPE_MODE=disabled ACL_IPE_SIGNING_MODE=ephemeral ACL_USR_HASH_SIGNATURE=false
configure_ipe_mode
[[ "${ACL_IPE_CAPABLE}" == false ]]
ACL_USR_HASH_SIGNATURE=true
if configure_ipe_mode; then echo "Signed /usr accepted disabled IPE capability" >&2; exit 1; fi
ACL_IPE_MODE=audit
configure_ipe_mode
[[ "${ACL_IPE_CAPABLE}" == true && "${ACL_USR_HASH_SIGNATURE}" == true ]]
ACL_USR_HASH_SIGNATURE=invalid
if configure_ipe_mode; then echo "Malformed signed /usr flag accepted" >&2; exit 1; fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export ACL_VERITY_RUN_DIR="${work}" ACL_VERITY_PROFILE_HELPER="${work}/profile.sh"
cat > "${work}/profile.sh" <<'EOF'
acl_security_profile() {
    printf 'failed\n' > "${ACL_SECURITY_PROFILE_FAILURE_CACHE}"
    return 1
}
EOF
if bash "${ROOT}/build_library/rpm/additional_files/dracut-acl-usr-verity/acl-verity-setup.sh" --profile; then
    echo "Failed early lookup succeeded" >&2; exit 1
fi
[[ -f "${work}/ipe-early-profile.failed" && ! -e "${work}/node-security-profile.failed" ]]

mkdir -p "${work}/bin"
cat > "${work}/bin/ln" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "${ACL_GENERATOR_LINK_LOG}"
EOF
chmod +x "${work}/bin/ln"
export ACL_VERITY_CMDLINE_FILE="${work}/cmdline" ACL_GENERATOR_LINK_LOG="${work}/links"
generator="${ROOT}/build_library/rpm/additional_files/dracut-acl-usr-verity/acl-verity-generator.sh"
printf '%s\n' 'flatcar.oem.id=azure acl.verity_usr_signature=PARTUUID=3514648f-e3da-44ae-89ba-8d0552418f88' > "${ACL_VERITY_CMDLINE_FILE}"
PATH="${work}/bin:${PATH}" bash "${generator}" "${work}/normal" "${work}/early" "${work}/late"
[[ -d "${work}/early" && ! -e "${work}/normal" && ! -e "${work}/late" ]]
printf '%s\n' '-sf' '/dev/null' "${work}/early/afterburn-network-kargs.service" > "${work}/expected-links"
cmp "${work}/expected-links" "${ACL_GENERATOR_LINK_LOG}"
for cmdline in \
    'flatcar.oem.id=azure' \
    'flatcar.oem.id=vmware acl.verity_usr_signature=PARTUUID=3514648f-e3da-44ae-89ba-8d0552418f88'; do
    : > "${ACL_GENERATOR_LINK_LOG}"
    printf '%s\n' "${cmdline}" > "${ACL_VERITY_CMDLINE_FILE}"
    PATH="${work}/bin:${PATH}" bash "${generator}" "${work}/normal" "${work}/early" "${work}/late"
    [[ ! -s "${ACL_GENERATOR_LINK_LOG}" ]]
done
echo "Signed /usr build opt-in, SELinux cache isolation, and generator ordering tests passed"
