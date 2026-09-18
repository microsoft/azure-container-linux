#!/bin/bash

ACL_SECURITY_PROFILE_CACHE="/run/acl/node-security-profile"
ACL_SECURITY_PROFILE_FAILURE_CACHE="${ACL_SECURITY_PROFILE_CACHE}.failed"

acl_usrbin() {
    local cmd="$1"
    shift
    LD_LIBRARY_PATH=/sysusr/usr/lib64 /sysusr/usr/bin/"${cmd}" "$@"
}

acl_security_profile_cache_failure() {
    local cache_dir temporary_failure_cache

    cache_dir="${ACL_SECURITY_PROFILE_FAILURE_CACHE%/*}"
    mkdir -p "${cache_dir}"
    temporary_failure_cache="${ACL_SECURITY_PROFILE_FAILURE_CACHE}.$$"
    : > "${temporary_failure_cache}"
    mv -f "${temporary_failure_cache}" "${ACL_SECURITY_PROFILE_FAILURE_CACHE}"
}

acl_security_profile_parse() {
    acl_usrbin jq -ser '
        if length != 1 then
            error("IMDS response must contain exactly one JSON document")
        elif (.[0] | type) != "array" then
            error("IMDS tagsList response is not an array")
        else
            .[0] as $document
            |
            [
                $document[]
                | select(type == "object" and .name? == "acl-node-security-profile")
            ] as $matches
            | if ($matches | length) == 0 then
                ""
              elif ($matches | length) > 1 then
                error("duplicate acl-node-security-profile tags")
              elif ($matches[0].value | type) != "string" then
                error("acl-node-security-profile value is not a string")
              else
                $matches[0].value
              end
        end
    '
}

acl_security_profile() {
    local cache_dir imds_tags security_profile temporary_cache
    local i transport_succeeded=false

    if [[ -r "${ACL_SECURITY_PROFILE_CACHE}" ]]; then
        printf '%s\n' "$(<"${ACL_SECURITY_PROFILE_CACHE}")"
        return 0
    fi
    if [[ -e "${ACL_SECURITY_PROFILE_FAILURE_CACHE}" ]]; then
        echo "ACL: Using cached IMDS security profile failure" >&2
        return 1
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
            transport_succeeded=true
            break
        fi
        echo "ACL: IMDS not ready, retry ${i}/30" >&2
        sleep 1
    done
    if [[ "${transport_succeeded}" != "true" ]]; then
        echo "ACL: IMDS unreachable after 30 retries" >&2
        acl_security_profile_cache_failure
        return 1
    fi

    if ! security_profile="$(
        printf '%s' "${imds_tags}" |
            acl_security_profile_parse 2>/dev/null
    )"; then
        echo "ACL: IMDS security profile response failed validation" >&2
        acl_security_profile_cache_failure
        return 1
    fi

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
