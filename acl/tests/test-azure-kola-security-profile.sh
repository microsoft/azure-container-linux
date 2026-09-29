#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(mktemp -d "${ROOT}/.azure-profile-test.XXXXXX")"
cleanup() {
    local rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        for log in "${TEST_DIR}"/*.log; do
            [[ ! -f "${log}" ]] || tail -20 "${log}" >&2
        done
    fi
    rm -rf "${TEST_DIR}"
}
trap cleanup EXIT
mkdir -p "${TEST_DIR}/bin"

cat > "${TEST_DIR}/bin/timeout" <<'EOF'
#!/bin/bash
while [[ "${1:-}" == --* ]]; do shift; done
shift
exec "$@"
EOF
cat > "${TEST_DIR}/bin/kola" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == list ]]; then
    echo cl.internet
    exit 0
fi
printf '%s\n' "$@" >> "${KOLA_ARGS_LOG:?}"
for argument; do
    if [[ "${argument}" == --tapfile=* ]]; then
        printf '1..1\nok 1 - cl.basic\n' > "${argument#*=}"
    fi
done
EOF
chmod +x "${TEST_DIR}/bin/timeout" "${TEST_DIR}/bin/kola"

# shellcheck source=run_azure_tests.sh
source "${ROOT}/run_azure_tests.sh"

run_case() (
    local name="$1" profile="$2" image_source="$3" certificates="$4"
    local package_mode="${5:-RPM}" arch="${6:-amd64}"
    local work="${TEST_DIR}/${name}"
    mkdir -p "${work}/sdk_container" "${work}/home/.azure" "${work}/vendor"
    printf 'test-version\n' > "${work}/git_version"
    printf 'developer\n' > "${work}/git_channel"
    touch "${work}/first_run" "${work}/image.vhd"
    export HOME="${work}/home" PATH="${TEST_DIR}/bin:${PATH}"
    export KOLA_ARGS_LOG="${work}/kola.args"
    export AZURE_TRUSTED_LAUNCH="${profile}"
    export AZURE_SECURE_BOOT_CERTIFICATES="${certificates}"
    export AZURE_USE_GALLERY="" PACKAGE_SOURCE_MODE="${package_mode}"
    export AZURE_SUBSCRIPTION_ID=11111111-1111-1111-1111-111111111111
    export AZURE_amd64_MACHINE_SIZE="${7:-Standard_D2s_v5}"
    export AZURE_arm64_MACHINE_SIZE=Standard_D2ps_v6
    export AZURE_DISK_URI=""
    if [[ "${image_source}" == gallery ]]; then
        export AZURE_DISK_URI=/subscriptions/test/gallery/image/versions/1
    fi
    az() { echo 22222222-2222-2222-2222-222222222222; }

    cd "${work}"
    set_azure_vars "${arch}" 1
    unset AZURE_TRUSTED_LAUNCH AZURE_SECURE_BOOT_CERTIFICATES
    # Only the actual generated container environment may supply these values.
    source sdk_container/.env
    if [[ "${AZURE_TRUSTED_LAUNCH:-}" != "${profile}" ||
        "${AZURE_SECURE_BOOT_CERTIFICATES:-}" != "${certificates}" ]]; then
        echo "FAIL: profile or certificate setting lost at container boundary" >&2
        return 1
    fi
    export AZURE_IMAGE_NAME="${work}/image.vhd" AZURE_PARALLEL=1
    cd "${ROOT}"
    bash ci-automation/vendor-testing/azure.sh \
        "${work}" "${work#"${ROOT}/"}/vendor" "${arch}" 1.0.0 results.tap cl.basic
)

assert_arg() {
    local name="$1" argument="$2"
    grep -Fxq -- "${argument}" "${TEST_DIR}/${name}/kola.args" || {
        echo "FAIL: ${name} did not pass ${argument} to actual kola invocation" >&2
        cat "${TEST_DIR}/${name}/kola.args" >&2
        return 1
    }
}

assert_standard() {
    local name="$1"
    if grep -Eq '^--(azure-trusted-launch|enable-secureboot|azure-secureboot-certificate)' \
        "${TEST_DIR}/${name}/kola.args"; then
        echo "FAIL: ${name} unexpectedly enabled Trusted Launch" >&2
        return 1
    fi
}

expect_failure() {
    local name="$1" diagnostic="$2"
    shift 2
    local rc=0
    # Run in a fresh shell: an `if function` would disable errexit inside it.
    bash "${BASH_SOURCE[0]}" --case "${name}" "$@" > "${TEST_DIR}/${name}.log" 2>&1 || rc=$?
    [[ "${rc}" -ne 0 ]] || {
        echo "FAIL: ${name} unexpectedly succeeded" >&2
        return 1
    }
    grep -Fq -- "${diagnostic}" "${TEST_DIR}/${name}.log"
}

if [[ "${1:-}" == --case ]]; then
    shift
    run_case "$@"
    exit
fi

run_case standard false gallery "" > "${TEST_DIR}/standard.log" 2>&1
assert_standard standard
assert_arg standard --azure-hyper-v-generation=V2
run_case legacy "" local "" > "${TEST_DIR}/legacy.log" 2>&1
assert_standard legacy
run_case trusted true gallery "" > "${TEST_DIR}/trusted.log" 2>&1
assert_arg trusted --azure-trusted-launch
assert_arg trusted --enable-secureboot
run_case arm true gallery "" RPM arm64 > "${TEST_DIR}/arm.log" 2>&1
assert_arg arm --azure-trusted-launch
assert_arg arm --board=arm64-usr
run_case certificates true local "/work/cert one.pem:/work/cert-two.pem" \
    > "${TEST_DIR}/certificates.log" 2>&1
assert_arg certificates "--azure-secureboot-certificate=/work/cert one.pem"
assert_arg certificates --azure-secureboot-certificate=/work/cert-two.pem
run_case trusted_portage true local "" PORTAGE > "${TEST_DIR}/trusted-portage.log" 2>&1
if grep -Fxq -- --azure-hyper-v-generation=V1 "${TEST_DIR}/trusted_portage/kola.args"; then
    echo 'FAIL: Trusted Launch scheduled Gen1' >&2
    exit 1
fi
run_case standard_portage false local "" PORTAGE > "${TEST_DIR}/standard-portage.log" 2>&1
assert_arg standard_portage --azure-hyper-v-generation=V1
expect_failure invalid 'AZURE_TRUSTED_LAUNCH must be true or false' invalid gallery ""
expect_failure standard_cert 'requires AZURE_TRUSTED_LAUNCH=true' false local /work/cert.pem
expect_failure gallery_cert 'cannot modify an existing gallery' true gallery /work/cert.pem
expect_failure empty_cert 'contains an empty path' true local /work/cert.pem:
expect_failure trusted_gen1 'requires Hyper-V generation V2' true local "" RPM amd64 V1

(
    work="${TEST_DIR}/failed-auth"
    mkdir -p "${work}/ci-automation" "${work}/sdk_container/.repo/manifests"
    printf 'mantle:test\n' > "${work}/sdk_container/.repo/manifests/mantle-container"
    printf 'test_run() { touch unexpected-test-run; }\n' > "${work}/ci-automation/test.sh"
    cd "${work}"
    set_azure_vars() { echo 'Expected mocked authentication failure' >&2; return 1; }
    rc=0
    run_azure_tests amd64 1 cl.basic >/dev/null 2>&1 || rc=$?
    [[ "${rc}" -ne 0 && ! -e unexpected-test-run ]]
)

# shellcheck disable=SC2034 # Variables are consumed by the extracted parser.
check_default_test_selection() (
    local expected="$1"
    shift
    eval "$(sed -n '/^parse_args() {/,/^}/p' "${ROOT}/acl/build_rpm_image.sh")"
    declare -F parse_args >/dev/null
    local BOARD=amd64-usr GROUP=production VM_TYPE=azure RETRY_ATTEMPTS=0
    local BUILD_VM_IMAGE=false START_VM=false REUSE_IMAGE=false ACG_IMAGE_VERSION_ID=""
    local SECURE_BOOT_ENABLED=true RUN_TESTS=false
    local -a RUN_SCRIPTS=() RUN_HOST_SCRIPTS=()
    parse_args "$@"
    local script count=0
    for script in "${RUN_SCRIPTS[@]}"; do
        if [[ "${script}" == ./acl/tests/run-secureboot-test.sh ]]; then
            count=$((count + 1))
        fi
    done
    [[ "${count}" == "${expected}" ]]
)
check_default_test_selection 1 --run-tests
check_default_test_selection 0 --run-tests --no-secure-boot
check_default_test_selection 0 --no-secure-boot --run-tests
check_default_test_selection 1 --run-tests --no-secure-boot --run-script=./acl/tests/run-secureboot-test.sh
check_default_test_selection 1 --board=arm64-usr --run-tests --no-secure-boot
check_default_test_selection 0 --run-script=custom-test.sh

echo 'Azure Kola security profile tests passed'
