#!/bin/bash

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
set -euo pipefail
url="${*: -1}"
if [[ " $* " == *" --head "* ]]; then
    case "${BUILD_CACHE_MARKER_PROBE:-absent}" in
        present) printf '200' ;;
        absent) printf '404' ;;
        error) exit 7 ;;
        *) exit 2 ;;
    esac
    exit 0
fi

output_dir=.
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--output-dir" ]]; then
        output_dir="$2"
        shift 2
        continue
    fi
    shift
done
mkdir -p "${output_dir}"
case "${url##*/}" in
    *.bz2)
        : > "${output_dir}/${url##*/}"
        ;;
    ipe-signing-mode)
        printf 'ephemeral\n' > "${output_dir}/ipe-signing-mode"
        ;;
    uki-signing-ca.pem)
        cp "${BUILD_CACHE_CERT_SOURCE:?}" "${output_dir}/uki-signing-ca.pem"
        ;;
    *)
        exit 2
        ;;
esac
EOF

cat > "${MOCK_BIN}/lbzcat" <<'EOF'
#!/bin/bash
printf 'vhd\n'
EOF

chmod +x "${MOCK_BIN}/timeout" "${MOCK_BIN}/kola" \
    "${MOCK_BIN}/curl" "${MOCK_BIN}/lbzcat"

create_certificate() {
    local directory="$1"
    local subject='/CN=Azure vendor IPE test/'
    if [[ -n "${MSYSTEM:-}" && "${MSYS2_ARG_CONV_EXCL:-}" != "*" ]]; then
        subject='//CN=Azure vendor IPE test'
    fi
    openssl req -x509 -newkey rsa:2048 -nodes \
        -subj "${subject}" \
        -keyout "${directory}/ca.key" \
        -out "${directory}/uki-signing-ca.pem" \
        -days 1 >/dev/null 2>&1
}

prepare_vendor_work() {
    local root="$1"
    mkdir -p "${root}/work"
    printf 'test-version\n' > "${root}/git_version"
    printf 'developer\n' > "${root}/git_channel"
    touch "${root}/first_run"
}

assert_single_arg() {
    local expected="$1" file="$2"
    [[ "$(grep -Fxc -- "${expected}" "${file}")" -eq 1 ]] || {
        echo "Expected exactly one ${expected} in ${file}" >&2
        return 1
    }
}

run_vendor() {
    local main_dir="$1"
    shift
    (
        cd "${SCRIPT_DIR}"
        PATH="${MOCK_BIN}:${PATH}" \
        KOLA_ARGS_LOG="${KOLA_ARGS_LOG}" \
        PACKAGE_SOURCE_MODE="${TEST_PACKAGE_SOURCE_MODE:-RPM}" \
        AZURE_amd64_MACHINE_SIZE=Standard_D2s_v5 \
        AZURE_LOCATION=westus2 \
        AZURE_PARALLEL=1 \
        bash ci-automation/vendor-testing/azure.sh \
            "${main_dir}" "${main_dir}/work" amd64 1.0.0 results.tap "$@"
    )
}

test_local_ipe_vhd_derives_final_kola_contract() {
    local root="${TEST_DIR}/local"
    local artifact_dir="${root}/artifacts"
    local image="${artifact_dir}/acl_production_azure_test_image.vhd"
    prepare_vendor_work "${root}"
    mkdir -p "${artifact_dir}"
    printf 'vhd\n' > "${image}"
    printf 'ephemeral\n' > "${artifact_dir}/ipe-signing-mode"
    create_certificate "${artifact_dir}"
    KOLA_ARGS_LOG="${root}/kola.args"
    export KOLA_ARGS_LOG

    AZURE_IMAGE_NAME="${image}" \
    AZURE_USE_GALLERY="--azure-use-gallery" \
        run_vendor "${root}" cl.basic

    assert_single_arg "--azure-image-file=${image}" "${KOLA_ARGS_LOG}"
    assert_single_arg "--azure-hyper-v-generation=V2" "${KOLA_ARGS_LOG}"
    assert_single_arg "--azure-trusted-launch" "${KOLA_ARGS_LOG}"
    assert_single_arg "--enable-secureboot" "${KOLA_ARGS_LOG}"
    assert_single_arg "--azure-secureboot-certificate=${artifact_dir}/uki-signing-ca.pem" "${KOLA_ARGS_LOG}"
    assert_single_arg "--azure-use-gallery" "${KOLA_ARGS_LOG}"
}

test_trailing_override_is_rejected_before_kola() {
    local root="${TEST_DIR}/override"
    local artifact_dir="${root}/artifacts"
    local image="${artifact_dir}/acl_production_azure_test_image.vhd"
    prepare_vendor_work "${root}"
    mkdir -p "${artifact_dir}"
    printf 'vhd\n' > "${image}"
    printf 'esrp\n' > "${artifact_dir}/ipe-signing-mode"
    create_certificate "${artifact_dir}"
    KOLA_ARGS_LOG="${root}/kola.args"
    export KOLA_ARGS_LOG
    rm -f "${KOLA_ARGS_LOG}"

    if AZURE_IMAGE_NAME="${image}" \
        run_vendor "${root}" --enable-secureboot=false >/dev/null 2>&1; then
        echo "Trailing Secure Boot override was accepted" >&2
        return 1
    fi
    [[ ! -e "${KOLA_ARGS_LOG}" ]]
}

test_existing_gallery_injects_no_certificate() {
    local root="${TEST_DIR}/gallery"
    prepare_vendor_work "${root}"
    KOLA_ARGS_LOG="${root}/kola.args"
    export KOLA_ARGS_LOG
    unset AZURE_IMAGE_NAME AZURE_USE_GALLERY
    unset ACL_IPE_CAPABLE ACL_IPE_SIGNING_MODE
    unset AZURE_TRUSTED_LAUNCH AZURE_SECURE_BOOT_CERTIFICATES

    AZURE_DISK_URI="/subscriptions/example/imageVersions/1" \
        run_vendor "${root}" cl.basic

    assert_single_arg "--azure-disk-uri=/subscriptions/example/imageVersions/1" "${KOLA_ARGS_LOG}"
    if grep -Fq -- '--azure-secureboot-certificate=' "${KOLA_ARGS_LOG}"; then
        echo "Existing gallery image attempted certificate injection" >&2
        return 1
    fi
}

test_prefixed_retry_override_is_rejected_before_kola() {
    local root="${TEST_DIR}/prefixed-override"
    local artifact_dir="${root}/artifacts"
    local image="${artifact_dir}/acl_production_azure_test_image.vhd"
    prepare_vendor_work "${root}"
    rm "${root}/first_run"
    mkdir -p "${artifact_dir}"
    printf 'vhd\n' > "${image}"
    printf 'ephemeral\n' > "${artifact_dir}/ipe-signing-mode"
    create_certificate "${artifact_dir}"
    KOLA_ARGS_LOG="${root}/kola.args"
    export KOLA_ARGS_LOG
    rm -f "${KOLA_ARGS_LOG}"

    if TEST_PACKAGE_SOURCE_MODE=PORTAGE \
        AZURE_IMAGE_NAME="${image}" \
        run_vendor "${root}" \
            'extra-test.[Standard_NC6s_v3].--enable-secureboot=false' \
            >/dev/null 2>&1; then
        echo "Prefixed retry override was accepted" >&2
        return 1
    fi
    [[ ! -e "${KOLA_ARGS_LOG}" ]]
}

test_buildcache_probe_failure_is_fatal_and_retried() {
    local root="${TEST_DIR}/buildcache"
    local cert_dir="${root}/cert"
    prepare_vendor_work "${root}"
    mkdir -p "${cert_dir}"
    create_certificate "${cert_dir}"
    KOLA_ARGS_LOG="${root}/kola.args"
    export KOLA_ARGS_LOG
    rm -f "${KOLA_ARGS_LOG}"

    if BUILD_CACHE_MARKER_PROBE=error \
        BUILD_CACHE_CERT_SOURCE="${cert_dir}/uki-signing-ca.pem" \
        AZURE_IMAGE_NAME=downloaded.vhd \
        run_vendor "${root}" cl.basic >/dev/null 2>&1; then
        echo "Buildcache metadata transport failure was accepted" >&2
        return 1
    fi
    [[ -f "${root}/work/downloaded.vhd" ]]
    [[ -f "${root}/work/downloaded.vhd.buildcache-source" ]]
    [[ ! -e "${KOLA_ARGS_LOG}" ]]

    CIA_DEBUGIMAGESEXIST=no \
    BUILD_CACHE_MARKER_PROBE=present \
    BUILD_CACHE_CERT_SOURCE="${cert_dir}/uki-signing-ca.pem" \
    AZURE_IMAGE_NAME=downloaded.vhd \
        run_vendor "${root}" cl.basic >/dev/null 2>&1

    assert_single_arg "--azure-image-file=downloaded.vhd" "${KOLA_ARGS_LOG}"
    assert_single_arg "--azure-trusted-launch" "${KOLA_ARGS_LOG}"
    assert_single_arg "--enable-secureboot" "${KOLA_ARGS_LOG}"
    assert_single_arg "--azure-secureboot-certificate=./uki-signing-ca.pem" "${KOLA_ARGS_LOG}"
}

test_local_ipe_vhd_derives_final_kola_contract
test_trailing_override_is_rejected_before_kola
test_existing_gallery_injects_no_certificate
test_prefixed_retry_override_is_rejected_before_kola
test_buildcache_probe_failure_is_fatal_and_retried

echo "Azure vendor IPE contract tests passed"
