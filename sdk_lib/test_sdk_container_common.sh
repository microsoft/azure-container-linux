#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sdk_container_common.sh
source "${SCRIPT_DIR}/sdk_container_common.sh"

WORK="$(mktemp -d)"
cleanup() {
    rm -rf -- "${WORK}"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local want="$1"
    local got="$2"
    local message="$3"
    if [[ "${got}" != "${want}" ]]; then
        fail "${message}: want '${want}', got '${got}'"
    fi
}

repo="${WORK}/repo"
mkdir -p "${repo}"
git -C "${repo}" init -q
git -C "${repo}" config user.email test@example.com
git -C "${repo}" config user.name "SDK version test"

printf 'first\n' > "${repo}/content"
git -C "${repo}" add content
git -C "${repo}" commit -qm "first"
git -C "${repo}" tag 3.0.20260706-3.0-1153684

printf 'second\n' >> "${repo}/content"
git -C "${repo}" commit -qam "second"

fallback="$(cd "${repo}" && get_git_version)"
if [[ ! "${fallback}" =~ ^3\.0\.20260706-3\.0-1153684-1-g[0-9a-f]+$ ]]; then
    fail "no exact tag should preserve git describe fallback, got '${fallback}'"
fi

git -C "${repo}" tag 3.0.20260707-3.0-1154000
single="$(cd "${repo}" && get_git_version 2>"${WORK}/single.err")"
assert_eq "3.0.20260707-3.0-1154000" "${single}" "single exact tag"
if [[ -s "${WORK}/single.err" ]]; then
    fail "single exact tag should not emit a warning"
fi

git -C "${repo}" tag 3.0.20260809-3.0-1179296
multiple="$(cd "${repo}" && get_git_version 2>"${WORK}/multiple.err")"
assert_eq "3.0.20260809-3.0-1179296" "${multiple}" "multiple exact tags"
if [[ "${multiple}" == *$'\n'* ]]; then
    fail "multiple exact tags returned a multiline version"
fi
grep -F "multiple tags point at HEAD" "${WORK}/multiple.err" >/dev/null \
    || fail "multiple exact tags should emit a warning"
grep -F "3.0.20260707-3.0-1154000" "${WORK}/multiple.err" >/dev/null \
    || fail "warning should list the older candidate"
grep -F "3.0.20260809-3.0-1179296" "${WORK}/multiple.err" >/dev/null \
    || fail "warning should list the selected candidate"

docker_version="$(vernum_to_docker_image_version "${multiple}")"
assert_eq "3.0.20260809-3.0-1179296" "${docker_version}" "Docker-safe selected version"

echo "PASS: sdk_container_common version detection"
