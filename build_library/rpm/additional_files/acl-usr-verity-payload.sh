#!/bin/bash
# DPS payload helpers shared by image construction and the initrd consumer.

acl_verity_decode_payload() (
    set -euo pipefail
    local payload="$1" root_hash="$2" signature="$3" bytes
    [[ "${root_hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
    bytes="$(wc -c < "${payload}")" || return 1
    (( bytes > 0 && bytes <= 1048576 && bytes % 4096 == 0 )) || return 1
    local json="${signature}.json" temporary="${signature}.tmp"
    trap 'rm -f "${json}" "${temporary}"' EXIT
    jq -jen --rawfile payload "${payload}" '
        ($payload | index("\u0000")) as $end |
        if $end == null then $payload
        elif ($payload[$end:] | test("^\u0000+$")) then $payload[:$end]
        else error("nonzero bytes after DPS JSON padding") end
    ' > "${json}" || return 1
    # Streaming preserves repeated object keys, unlike ordinary JSON decoding.
    jq --stream -se '
        map(select(length == 2) | .[0]) | sort ==
        [["rootHash"], ["signature"]]
    ' "${json}" > /dev/null || return 1
    jq -se --arg hash "${root_hash}" '
        length == 1 and (.[0] | type == "object" and .rootHash == $hash and
        (.signature | type == "string" and length > 0 and
        test("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$")))
    ' "${json}" > /dev/null || return 1
    jq -jr '.signature' "${json}" | base64 --decode > "${temporary}" || return 1
    [[ -s "${temporary}" ]] || return 1
    # Reject noncanonical encodings, including nonzero Base64 padding bits.
    [[ "$(base64 -w0 "${temporary}")" == "$(jq -jr .signature "${json}")" ]] || return 1
    mv -f "${temporary}" "${signature}"
)

acl_verity_encode_payload() (
    set -euo pipefail
    local root_hash="$1" signature="$2" output="$3" capacity="$4" bytes
    [[ "${root_hash}" =~ ^[0-9a-f]{64}$ && -s "${signature}" ]] || return 1
    [[ "${capacity}" =~ ^[0-9]+$ ]] || return 1
    (( capacity > 0 && capacity <= 1048576 && capacity % 4096 == 0 )) || return 1
    jq -cjn --arg hash "${root_hash}" --arg signature "$(base64 -w0 "${signature}")" \
        '{rootHash: $hash, signature: $signature}' > "${output}" || return 1
    bytes="$(wc -c < "${output}")" || return 1
    (( bytes <= capacity )) || return 1
    truncate -s "${capacity}" "${output}"
)

acl_verity_check_cms() (
    set -euo pipefail
    local root_hash="$1" signature="$2" content="${2}.content" description="${2}.cms"
    trap 'rm -f "${content}" "${description}"' EXIT
    printf '%s' "${root_hash}" > "${content}" || return 1
    openssl cms -cmsout -print -inform DER -in "${signature}" > "${description}" || return 1
    grep -Eq '^[[:space:]]+eContent: <ABSENT>$' "${description}" || return 1
    # Crypto validity is not kernel trust; trust is checked during activation.
    openssl cms -verify -binary -inform DER -in "${signature}" \
        -content "${content}" -noverify -out /dev/null
)
