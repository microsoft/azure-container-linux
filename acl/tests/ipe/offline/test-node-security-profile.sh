#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

source "${SCRIPT_DIR}/build_library/rpm/additional_files/acl-node-security-profile.sh"

systemctl() { :; }
sleep() { :; }

MOCK_CURL_BODY='[]'
MOCK_CURL_STATUS=0
MOCK_JQ_PARTIAL=false
CURL_CALLS_FILE="${TEST_DIR}/curl-calls"

acl_usrbin() {
    local cmd="$1"
    shift

    case "${cmd}" in
        curl)
            printf 'x\n' >> "${CURL_CALLS_FILE}"
            printf '%s' "${MOCK_CURL_BODY}"
            return "${MOCK_CURL_STATUS}"
            ;;
        jq)
            if [[ "${MOCK_JQ_PARTIAL}" == "true" ]]; then
                printf '%s' 'selinux=permissive'
                return 4
            fi
            command jq "$@"
            ;;
        *)
            return 127
            ;;
    esac
}

prepare_case() {
    local name="$1"

    ACL_SECURITY_PROFILE_CACHE="${TEST_DIR}/${name}/node-security-profile"
    ACL_SECURITY_PROFILE_FAILURE_CACHE="${ACL_SECURITY_PROFILE_CACHE}.failed"
    mkdir -p "${ACL_SECURITY_PROFILE_CACHE%/*}"
    MOCK_CURL_BODY='[]'
    MOCK_CURL_STATUS=0
    MOCK_JQ_PARTIAL=false
    : > "${CURL_CALLS_FILE}"
}

curl_calls() {
    wc -l < "${CURL_CALLS_FILE}" | tr -d '[:space:]'
}

assert_parse_fails() {
    local input="$1"

    if printf '%s' "${input}" | acl_security_profile_parse >/dev/null 2>&1; then
        echo "invalid IMDS response was accepted: ${input}" >&2
        return 1
    fi
}

test_parser_contract() {
    [[ "$(printf '%s' '[]' | acl_security_profile_parse)" == "" ]]
    [[ "$(
        printf '%s' '[{"name":"acl-node-security-profile","value":"ipe=audit"}]' |
            acl_security_profile_parse
    )" == "ipe=audit" ]]
    [[ "$(
        printf '%s' '[{"name":"acl-node-security-profile","value":""}]' |
            acl_security_profile_parse
    )" == "" ]]

    assert_parse_fails '{}'
    assert_parse_fails '[{"name":"acl-node-security-profile","value":null}]'
    assert_parse_fails '[{"name":"acl-node-security-profile","value":"ipe=audit"},{"name":"acl-node-security-profile","value":"ipe=disabled"}]'
    assert_parse_fails '[{"name":"acl-node-security-profile","value":"ipe=audit"}'
    assert_parse_fails '[{"name":"acl-node-security-profile","value":"ipe=audit"}] []'
}

test_valid_response_is_cached() {
    prepare_case valid
    MOCK_CURL_BODY='[{"name":"acl-node-security-profile","value":"ipe=audit"}]'

    [[ "$(acl_security_profile)" == "ipe=audit" ]]
    [[ "$(<"${ACL_SECURITY_PROFILE_CACHE}")" == "ipe=audit" ]]
    [[ ! -e "${ACL_SECURITY_PROFILE_FAILURE_CACHE}" ]]
    [[ "$(curl_calls)" -eq 1 ]]

    MOCK_CURL_STATUS=1
    [[ "$(acl_security_profile)" == "ipe=audit" ]]
    [[ "$(curl_calls)" -eq 1 ]]
}

test_absent_tag_is_successfully_cached() {
    prepare_case absent

    [[ "$(acl_security_profile)" == "" ]]
    [[ -f "${ACL_SECURITY_PROFILE_CACHE}" ]]
    [[ ! -s "${ACL_SECURITY_PROFILE_CACHE}" ]]
    [[ ! -e "${ACL_SECURITY_PROFILE_FAILURE_CACHE}" ]]
}

test_parser_failure_never_publishes_positive_cache() {
    prepare_case parser-failure
    MOCK_CURL_BODY='[{"name":"acl-node-security-profile","value":"selinux=permissive"}]'
    MOCK_JQ_PARTIAL=true

    if acl_security_profile >/dev/null 2>&1; then
        echo "partial parser output was accepted" >&2
        return 1
    fi
    [[ ! -e "${ACL_SECURITY_PROFILE_CACHE}" ]]
    [[ -e "${ACL_SECURITY_PROFILE_FAILURE_CACHE}" ]]

    MOCK_JQ_PARTIAL=false
    MOCK_CURL_BODY='[{"name":"acl-node-security-profile","value":"ipe=audit"}]'
    if acl_security_profile >/dev/null 2>&1; then
        echo "cached parser failure was ignored" >&2
        return 1
    fi
}

test_multiple_documents_never_publish_positive_cache() {
    prepare_case multiple-documents
    MOCK_CURL_BODY='[{"name":"acl-node-security-profile","value":"ipe=audit"}] []'

    if acl_security_profile >/dev/null 2>&1; then
        echo "multiple JSON documents were accepted" >&2
        return 1
    fi
    [[ ! -e "${ACL_SECURITY_PROFILE_CACHE}" ]]
    [[ -e "${ACL_SECURITY_PROFILE_FAILURE_CACHE}" ]]
}

test_transport_failure_never_publishes_positive_cache() {
    prepare_case transport-failure
    MOCK_CURL_BODY='partial'
    MOCK_CURL_STATUS=1

    if acl_security_profile >/dev/null 2>&1; then
        echo "failed IMDS transport was accepted" >&2
        return 1
    fi
    [[ "$(curl_calls)" -eq 30 ]]
    [[ ! -e "${ACL_SECURITY_PROFILE_CACHE}" ]]
    [[ -e "${ACL_SECURITY_PROFILE_FAILURE_CACHE}" ]]
}

test_parser_contract
test_valid_response_is_cached
test_absent_tag_is_successfully_cached
test_parser_failure_never_publishes_positive_cache
test_multiple_documents_never_publish_positive_cache
test_transport_failure_never_publishes_positive_cache

echo "node security profile tests passed"
