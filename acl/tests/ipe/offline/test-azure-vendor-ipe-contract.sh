#!/bin/bash
# shellcheck disable=SC1091,SC2016,SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

MOCK_BIN="${TEST_DIR}/bin"
mkdir -p "${MOCK_BIN}"

cat > "${MOCK_BIN}/timeout" <<'EOF'
#!/bin/bash
set -euo pipefail
while [[ "${1:-}" == --* ]]; do
    shift
done
shift
exec "$@"
EOF

cat > "${MOCK_BIN}/kola" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" > "${KOLA_ARGS_LOG:?}"
if [[ "${1:-}" == "list" ]]; then
    printf '%s\n' cl.basic
fi
EOF

cat > "${MOCK_BIN}/curl" <<'EOF'
#!/bin/bash
echo "Unexpected network request: $*" >&2
exit 1
EOF
chmod +x "${MOCK_BIN}/timeout" "${MOCK_BIN}/kola" "${MOCK_BIN}/curl"

assert_single_arg() {
    local expected="$1" file="$2"
    [[ "$(grep -Fxc -- "${expected}" "${file}")" -eq 1 ]] || {
        echo "Expected exactly one ${expected} in ${file}" >&2
        return 1
    }
}

run_vendor() {
    local main_dir="$1" arch="$2"
    shift 2
    (
        cd "${SCRIPT_DIR}"
        PATH="${MOCK_BIN}:${PATH}" \
        PACKAGE_SOURCE_MODE=RPM \
        AZURE_amd64_MACHINE_SIZE=Standard_D2s_v5 \
        AZURE_arm64_MACHINE_SIZE=Standard_D2ps_v5 \
        AZURE_LOCATION=westus2 \
        AZURE_PARALLEL=1 \
        bash ci-automation/vendor-testing/azure.sh \
            "${main_dir}" "${main_dir}/work" "${arch}" 1.0.0 results.tap "$@"
    ) > "${main_dir}/vendor.log" 2>&1 || {
        cat "${main_dir}/vendor.log" >&2
        return 1
    }
}

test_ipe_does_not_select_kola_security() (
    local arch="$1" source="$2"
    local root="${TEST_DIR}/${arch}-${source}" mode size=Standard_D2s_v5
    [[ "${arch}" != arm64 ]] || size=Standard_D2ps_v5
    mkdir -p "${root}/work" "${root}/artifacts"
    printf 'test-version\n' > "${root}/git_version"
    printf 'developer\n' > "${root}/git_channel"
    touch "${root}/first_run"
    export KOLA_ARGS_LOG="${root}/kola.args"
    export AZURE_IMAGE_NAME="${root}/artifacts/test.vhd"
    export AZURE_USE_GALLERY=""
    export AZURE_DISK_URI=""
    export AZURE_TRUSTED_LAUNCH=true
    export AZURE_SECURE_BOOT_CERTIFICATES="${root}/artifacts/uki-signing-ca.pem"
    if [[ "${source}" == gallery ]]; then
        AZURE_DISK_URI="/subscriptions/example/imageVersions/1"
    else
        printf 'vhd\n' > "${AZURE_IMAGE_NAME}"
    fi

    for mode in disabled ephemeral esrp; do
        export ACL_IPE_CAPABLE=false
        export ACL_IPE_SIGNING_MODE="${mode}"
        if [[ "${mode}" != disabled ]]; then
            ACL_IPE_CAPABLE=true
            printf '%s\n' "${mode}" > "${root}/artifacts/ipe-signing-mode"
        fi
        run_vendor "${root}" "${arch}" cl.basic >/dev/null
        assert_single_arg "--board=${arch}-usr" "${KOLA_ARGS_LOG}"
        assert_single_arg "--azure-size=${size}" "${KOLA_ARGS_LOG}"
        assert_single_arg "--azure-hyper-v-generation=V2" "${KOLA_ARGS_LOG}"
        assert_single_arg "--azure-resource-group-tag=kolaArch=${arch}" "${KOLA_ARGS_LOG}"
        if [[ "${source}" == gallery ]]; then
            assert_single_arg "--azure-disk-uri=${AZURE_DISK_URI}" "${KOLA_ARGS_LOG}"
            if grep -Fq -- '--azure-use-gallery' "${KOLA_ARGS_LOG}"; then
                echo "Existing gallery launch unexpectedly requested image creation" >&2
                return 1
            fi
        else
            assert_single_arg "--azure-image-file=${AZURE_IMAGE_NAME}" "${KOLA_ARGS_LOG}"
            assert_single_arg "--azure-use-gallery" "${KOLA_ARGS_LOG}"
        fi
        if grep -Eq -- '^--(azure-trusted-launch|enable-secureboot|azure-secureboot-certificate)' "${KOLA_ARGS_LOG}"; then
            echo "IPE unexpectedly changed ${arch} ${source} launch security" >&2
            return 1
        fi
        if [[ "${mode}" == disabled ]]; then
            cp "${KOLA_ARGS_LOG}" "${root}/baseline.args"
        else
            cmp "${root}/baseline.args" "${KOLA_ARGS_LOG}"
        fi
    done

    AZURE_USE_GALLERY="--azure-trusted-launch --enable-secureboot" \
        run_vendor "${root}" "${arch}" --azure-use-gallery=false >/dev/null
    assert_single_arg --azure-trusted-launch "${KOLA_ARGS_LOG}"
    assert_single_arg --enable-secureboot "${KOLA_ARGS_LOG}"
    assert_single_arg --azure-use-gallery=false "${KOLA_ARGS_LOG}"
)

test_wrapper_does_not_forward_ipe_security() (
    source "${SCRIPT_DIR}/run_azure_tests.sh"
    local root="${TEST_DIR}/wrapper"
    mkdir -p "${root}/sdk_container" "${root}/home/.azure"
    cd "${root}"
    export HOME="${root}/home"
    export AZURE_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000
    export AZURE_TRUSTED_LAUNCH=true
    export AZURE_SECURE_BOOT_CERTIFICATES=/work/uki-signing-ca.pem
    export ACL_IPE_CAPABLE=true
    export ACL_IPE_SIGNING_MODE=esrp
    export PACKAGE_SOURCE_MODE=RPM
    export AZURE_USE_GALLERY=--azure-use-gallery
    az() { printf 'test-tenant\n'; }
    set_azure_vars arm64 1
    if grep -Eq 'AZURE_TRUSTED_LAUNCH|AZURE_SECURE_BOOT_CERTIFICATES|ACL_IPE_' sdk_container/.env; then
        echo "Wrapper unexpectedly forwarded IPE launch settings" >&2
        return 1
    fi
    unset AZURE_USE_GALLERY
    source sdk_container/.env
    [[ "${AZURE_USE_GALLERY}" == --azure-use-gallery ]]
    [[ "${AZURE_IMAGE_NAME}" == /work/__build__/images/images/arm64-usr/latest/acl_production_azure_test_image.vhd ]]
)

for arch in amd64 arm64; do
    for source in local gallery; do
        test_ipe_does_not_select_kola_security "${arch}" "${source}"
    done
done
test_wrapper_does_not_forward_ipe_security
echo "Azure vendor baseline launch contract tests passed"
