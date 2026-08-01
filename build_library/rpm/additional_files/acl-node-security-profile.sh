#!/bin/bash

ACL_SECURITY_PROFILE_CACHE="/run/acl/node-security-profile"

acl_usrbin() {
    local cmd="$1"
    shift
    LD_LIBRARY_PATH=/sysusr/usr/lib64 /sysusr/usr/bin/"${cmd}" "$@"
}

acl_security_profile() {
    local cache_dir imds_tags security_profile temporary_cache
    local i

    if [[ -r "${ACL_SECURITY_PROFILE_CACHE}" ]]; then
        printf '%s\n' "$(<"${ACL_SECURITY_PROFILE_CACHE}")"
        return 0
    fi

    echo "ACL: Starting networkd for IMDS security profile check" >&2
    systemctl start --quiet systemd-networkd systemd-resolved 2>/dev/null || true

    imds_tags=""
    for ((i = 1; i <= 30; i++)); do
        if imds_tags="$(
            acl_usrbin curl -sf -H "Metadata:true" --noproxy "*" --max-time 5 \
                "http://169.254.169.254/metadata/instance/compute/tagsList?api-version=2021-02-01" \
                2>/dev/null
        )"; then
            break
        fi
        echo "ACL: IMDS not ready, retry ${i}/30" >&2
        sleep 1
    done
    if [[ -z "${imds_tags}" ]]; then
        echo "ACL: IMDS unreachable after 30 retries" >&2
        return 1
    fi

    security_profile="$(
        echo "${imds_tags}" |
            acl_usrbin jq -r '.[] | select(.name=="acl-node-security-profile") | .value'
    )"
    cache_dir="${ACL_SECURITY_PROFILE_CACHE%/*}"
    mkdir -p "${cache_dir}"
    temporary_cache="${ACL_SECURITY_PROFILE_CACHE}.$$"
    printf '%s' "${security_profile}" > "${temporary_cache}"
    mv -f "${temporary_cache}" "${ACL_SECURITY_PROFILE_CACHE}"
    printf '%s\n' "${security_profile}"
}

acl_security_profile_value() {
    local profile="$1" wanted_key="$2" pair key value
    local -a pairs

    IFS=',' read -ra pairs <<< "${profile}"
    for pair in "${pairs[@]}"; do
        IFS='=' read -r key value <<< "${pair}"
        if [[ "${key}" == "${wanted_key}" ]]; then
            echo "${value}"
            return 0
        fi
    done
    return 0
}
