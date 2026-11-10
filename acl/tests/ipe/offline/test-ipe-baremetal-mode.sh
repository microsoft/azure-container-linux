#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
loader="${root}/build_library/rpm/additional_files/dracut-acl-ipe-load/acl-ipe-load.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf 'signed-policy-fixture' > "${work}/policy"
hash="$(sha256sum "${work}/policy" | cut -d' ' -f1)"

run_case() {
    local name="$1" arguments="$2" expect_active="$3"
    local dir="${work}/${name}"
    mkdir -p "${dir}/ipe"
    : > "${dir}/ipe/new_policy"
    printf '1\n' > "${dir}/ipe/enforce"
    printf 'acl.ipe.policy_sha256=%s %s\n' "${hash}" "${arguments}" > "${dir}/cmdline"
    if [[ "${name}" == azure-legacy ]]; then
        command cat > "${dir}/security-profile.sh" <<'EOF'
acl_security_profile() { echo ipe=audit; }
acl_security_profile_value() { echo audit; }
EOF
        printf 'containerd override\n' > "${dir}/containerd-profile"
    fi
    # Emulate kernel policy creation when the loader writes new_policy.
    cat() {
        command cat "$@"
        if [[ "$1" == "${work}/policy" ]]; then
            mkdir -p "${dir}/ipe/policies/acl_ipe_boot_policy"
            printf '0\n' > "${dir}/ipe/policies/acl_ipe_boot_policy/active"
        fi
    }
    export -f cat
    export dir work
    ACL_IPE_DIR="${dir}/ipe" ACL_IPE_CMDLINE_FILE="${dir}/cmdline" \
        ACL_IPE_CREDENTIAL_PATH="${work}/policy" \
        ACL_IPE_SECURITY_PROFILE_HELPER="${dir}/security-profile.sh" \
        ACL_IPE_CONTAINERD_PROFILE="${dir}/containerd-profile" \
        ACL_IPE_CONTAINERD_DROPIN="${dir}/containerd.conf" \
        bash "${loader}" > "${dir}/log" 2>&1
    if [[ "${expect_active}" == yes ]]; then
        [[ "$(<"${dir}/ipe/policies/acl_ipe_boot_policy/active")" == 1 ]]
        [[ "$(<"${dir}/ipe/enforce")" == 0 ]]
        if [[ "${name}" != azure-legacy ]]; then
            grep -q 'leaving containerd configuration unchanged' "${dir}/log"
        fi
    else
        [[ ! -e "${dir}/ipe/policies/acl_ipe_boot_policy/active" ||
            "$(<"${dir}/ipe/policies/acl_ipe_boot_policy/active")" == 0 ]]
    fi
    if [[ "${name}" == azure-legacy ]]; then
        cmp "${dir}/containerd-profile" "${dir}/containerd.conf"
    else
        [[ ! -e "${dir}/containerd.conf" ]]
    fi
}
run_case audit 'acl.ipe.mode=audit' yes
run_case disabled 'acl.ipe.mode=disabled' no
run_case duplicate 'acl.ipe.mode=audit acl.ipe.mode=disabled' no
run_case enforcing 'acl.ipe.mode=enforcing' no
run_case empty 'acl.ipe.mode=' no
run_case missing-value 'acl.ipe.mode' no
run_case azure-explicit 'flatcar.oem.id=azure acl.ipe.mode=audit' yes
run_case azure-legacy 'flatcar.oem.id=azure' yes
echo "Bare-metal explicit IPE mode tests passed"
