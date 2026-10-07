#!/bin/bash

# Copyright (c) 2013 The CoreOS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# common.sh must be properly sourced before this file.
[[ -n "${FLATCAR_SDK_VERSION}" ]] || exit 1

FLATCAR_SDK_ARCH="amd64" # We are unlikely to support anything else.
FLATCAR_SDK_TARBALL="flatcar-sdk-${FLATCAR_SDK_ARCH}-${FLATCAR_SDK_VERSION}.tar.bz2"
FLATCAR_SDK_TARBALL_CACHE="${REPO_CACHE_DIR}/sdks"
FLATCAR_SDK_TARBALL_PATH="${FLATCAR_SDK_TARBALL_CACHE}/${FLATCAR_SDK_TARBALL}"
FLATCAR_DEV_BUILDS_SDK="${FLATCAR_DEV_BUILDS_SDK-$FLATCAR_DEV_BUILDS/sdk}"
FLATCAR_SDK_URL="${FLATCAR_DEV_BUILDS_SDK}/${FLATCAR_SDK_ARCH}/${FLATCAR_SDK_VERSION}/${FLATCAR_SDK_TARBALL}"

# How many times a single download is resumed after a transient network error
# before giving up on the server it is being fetched from.
FLATCAR_SDK_DOWNLOAD_ATTEMPTS="${FLATCAR_SDK_DOWNLOAD_ATTEMPTS:-6}"

# curl exit codes that indicate a transient network/transfer problem and are
# therefore worth resuming. Notably absent is 22 (--fail, i.e. HTTP >= 400):
# a server that does not host this SDK answers 404 and we want to fall through
# to the next server immediately rather than hammer it.
_sdk_curl_retryable() {
    case "${1}" in
        # 18 partial transfer, 28 timeout, 33 no range support, 52 empty reply,
        # 55 send error, 56 recv error, 92 HTTP/2 stream error
        18|28|33|52|55|56|92) return 0 ;;
        *) return 1 ;;
    esac
}

# Download a single URL, resuming after transient failures.
#
# The SDK tarball is ~1.5G and takes several minutes to fetch, which is far
# longer than curl's own --retry-max-time budget. Once that budget is spent
# curl stops retrying, so a connection that breaks mid-transfer (e.g. the
# HTTP/2 INTERNAL_ERROR the release mirror occasionally emits) aborts the
# whole bootstrap. Drive the retries from here instead and use --continue-at
# so each attempt resumes rather than restarting from zero.
_sdk_curl_download() {
    local url="${1}" output="${2}"
    local -i attempt=1 rc=0

    while true; do
        rc=0
        curl --fail --silent --show-error --location \
            --retry-delay 1 --retry 60 --retry-connrefused --retry-max-time 60 \
            --connect-timeout 20 --continue-at - \
            --speed-limit 10240 --speed-time 120 \
            --output "${output}" "${url}" || rc=$?

        if [[ ${rc} -eq 0 ]]; then
            return 0
        fi

        if [[ ${attempt} -ge ${FLATCAR_SDK_DOWNLOAD_ATTEMPTS} ]] \
           || ! _sdk_curl_retryable "${rc}"; then
            return "${rc}"
        fi

        # The server refused to serve a range, so resuming is impossible;
        # drop what we have and start the next attempt from scratch.
        if [[ ${rc} -eq 33 ]]; then
            rm -f "${output}"
        fi

        info "Download of ${url} failed (curl exit ${rc}), retrying" \
             "($((attempt + 1))/${FLATCAR_SDK_DOWNLOAD_ATTEMPTS})"
        attempt+=1
        sleep 5
    done
}

# Download the current SDK tarball (if required) and verify digests/sig
sdk_download_tarball() {
    if sdk_verify_digests; then
        return 0
    fi

    info "Downloading ${FLATCAR_SDK_TARBALL}"
    local server url suffix
    local -a suffixes

    suffixes=('' '.DIGESTS') # TODO(marineam): download .asc

    # Start from a clean slate so the resume logic below only ever continues
    # bytes fetched during this invocation.
    _sdk_remove_downloads "${FLATCAR_SDK_TARBALL_PATH}" "${suffixes[@]}"

    for server in "${FLATCAR_SDK_SERVERS[@]}"; do
        url="${server}/sdk/${FLATCAR_SDK_ARCH}/${FLATCAR_SDK_VERSION}/${FLATCAR_SDK_TARBALL}"
        info "URL: ${url}"
        for suffix in "${suffixes[@]}"; do
            # If all downloads fail, we will detect it later.
            if ! _sdk_curl_download "${url}${suffix}" \
                 "${FLATCAR_SDK_TARBALL_PATH}${suffix}"; then
                break
            fi
        done
        if _sdk_check_downloads "${FLATCAR_SDK_TARBALL_PATH}" "${suffixes[@]}"; then
            if sdk_verify_digests; then
                sdk_clean_cache
                return 0
            fi
            info "SDK digest verification failed, cleaning up and will try another server"
        else
            info "Downloading SDK from ${url} failed, cleaning up and will try another server"
        fi
        _sdk_remove_downloads "${FLATCAR_SDK_TARBALL_PATH}" "${suffixes[@]}"
    done
    die_notrace "SDK download failed!"
}

_sdk_remove_downloads() {
    local path="${1}"; shift
    # rest of the params are suffixes

    rm -f "${@/#/${path}}"
}

_sdk_check_downloads() {
    local path="${1}"; shift
    # rest of the params are suffixes
    local suffix

    for suffix; do
        if [[ ! -s "${path}${suffix}" ]]; then
            return 1
        fi
    done
    return 0
}

sdk_verify_digests() {
    if [[ ! -f "${FLATCAR_SDK_TARBALL_PATH}" || \
          ! -f "${FLATCAR_SDK_TARBALL_PATH}.DIGESTS" ]]; then
        return 1
    fi

    # TODO(marineam): Add gpg signature verification too.

    verify_digests "${FLATCAR_SDK_TARBALL_PATH}" || return 1
}

sdk_clean_cache() {
    pushd "${FLATCAR_SDK_TARBALL_CACHE}" >/dev/null
    local filename
    for filename in *; do
        if [[ "${filename}" == "${FLATCAR_SDK_TARBALL}"* ]]; then
            continue
        fi
        info "Cleaning up ${filename}"
        # Not a big deal if this fails
        rm -f "${filename}" || true
    done
    popd >/dev/null
}
