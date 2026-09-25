#!/bin/bash
# Copyright (c) 2021 The Flatcar Maintainers.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -euo pipefail

# Test execution script for the azure vendor image.
# This script is supposed to run in the mantle container.

AZURE_VENDOR_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source ci-automation/vendor_test.sh
# shellcheck disable=SC1091 # Repository root is resolved before vendor_test changes directory.
source "${AZURE_VENDOR_REPO_ROOT}/build_library/rpm/ipe_artifact.sh"

# $@ now contains tests / test patterns to run

validate_kola_test_arguments() {
    local argument decoded

    ipe_reject_kola_managed_overrides false "$@" || return 1
    for argument; do
        if [[ "${argument}" =~ ^extra-test\.\[[^]]+\]\.(.*)$ ]]; then
            decoded="${BASH_REMATCH[1]}"
            ipe_reject_kola_managed_overrides false "${decoded}" || return 1
        fi
    done
}

probe_buildcache_file() {
    local relative_path="$1"
    local url="https://${BUILDCACHE_SERVER}/${relative_path}"
    local status

    if ! status="$(
        curl --head --silent --show-error --location \
            --retry-delay 1 --retry 3 --retry-connrefused --retry-max-time 60 \
            --connect-timeout 20 --output /dev/null --write-out '%{http_code}' \
            "${url}"
    )"; then
        echo "Failed to query buildcache metadata: ${url}" >&2
        return 2
    fi

    case "${status}" in
        2??) return 0 ;;
        404) return 1 ;;
        *)
            echo "Unexpected buildcache response ${status}: ${url}" >&2
            return 2
            ;;
    esac
}

reconcile_buildcache_ipe_sidecars() {
    local image_path="$1"
    local image_key="$2"
    local source_marker="${image_path}.buildcache-source"
    local artifact_dir marker certificate signing_mode probe_rc
    local managed_by_buildcache=false

    if [[ -e "${source_marker}" || -L "${source_marker}" ]]; then
        if [[ -L "${source_marker}" || ! -f "${source_marker}" ||
            ! -r "${source_marker}" ||
            "$(<"${source_marker}")" != "${image_key}" ]]; then
            echo "Invalid or stale buildcache source marker: ${source_marker}" >&2
            return 1
        fi
        managed_by_buildcache=true
    elif [[ "${image_path}" != */* ]]; then
        # Relative vendor image names are the legacy buildcache layout. Probe
        # sidecars so pre-existing work directories are upgraded safely.
        managed_by_buildcache=true
    fi
    [[ "${managed_by_buildcache}" == "true" ]] || return 0

    artifact_dir="$(dirname "${image_path}")"
    marker="${artifact_dir}/ipe-signing-mode"
    certificate="${artifact_dir}/uki-signing-ca.pem"

    if [[ ! -e "${marker}" && ! -L "${marker}" ]]; then
        if probe_buildcache_file "images/${CIA_ARCH}/${CIA_VERNUM}/ipe-signing-mode"; then
            copy_from_buildcache \
                "images/${CIA_ARCH}/${CIA_VERNUM}/ipe-signing-mode" \
                "${artifact_dir}"
        else
            probe_rc=$?
            [[ ${probe_rc} -eq 1 ]] && return 0
            return "${probe_rc}"
        fi
    fi

    signing_mode="$(ipe_read_signing_mode "${marker}")" || return 1
    if [[ ! -e "${certificate}" && ! -L "${certificate}" ]]; then
        copy_from_buildcache \
            "images/${CIA_ARCH}/${CIA_VERNUM}/uki-signing-ca.pem" \
            "${artifact_dir}"
    fi
}

azure_use_gallery_args=()
ipe_split_argument_string azure_use_gallery_args "${AZURE_USE_GALLERY:-}"
ipe_reject_kola_managed_overrides true "${azure_use_gallery_args[@]}"
validate_kola_test_arguments "$@"

board="${CIA_ARCH}-usr"
basename="ci-${CIA_VERNUM//+/-}-${CIA_ARCH}"
azure_instance_type_var="AZURE_${CIA_ARCH}_MACHINE_SIZE"
azure_instance_type="${!azure_instance_type_var}"
# Use the override if explicitly set (even if empty), otherwise default to location-based name.
if [[ -v AZURE_VNET_SUBNET_NAME ]]; then
    azure_vnet_subnet_name="${AZURE_VNET_SUBNET_NAME}"
else
    azure_vnet_subnet_name="jenkins-vnet-${AZURE_LOCATION}"
fi

# Fetch the Azure image if not present
if [[ -n "${AZURE_DISK_URI:-}" ]]; then
    echo "++++ ${CIA_TESTSCRIPT}: Using gallery image via --azure-disk-uri (skipping VHD download) ++++"
elif [ -f "${AZURE_IMAGE_NAME}" ] ; then
    echo "++++ ${CIA_TESTSCRIPT}: Using existing ${AZURE_IMAGE_NAME} for testing ${CIA_VERNUM} (${CIA_ARCH}) ++++"
else
    echo "++++ ${CIA_TESTSCRIPT}: downloading ${AZURE_IMAGE_NAME} for ${CIA_VERNUM} (${CIA_ARCH}) ++++"
    image_key="images/${CIA_ARCH}/${CIA_VERNUM}/${AZURE_IMAGE_NAME}.bz2"
    copy_from_buildcache "${image_key}" .
    cp --sparse=always <(lbzcat "${AZURE_IMAGE_NAME}.bz2") "${AZURE_IMAGE_NAME}"
    rm "${AZURE_IMAGE_NAME}.bz2"
    printf '%s\n' "${image_key}" > "${AZURE_IMAGE_NAME}.buildcache-source"
fi

if [[ -z "${AZURE_DISK_URI:-}" ]]; then
    image_key="images/${CIA_ARCH}/${CIA_VERNUM}/${AZURE_IMAGE_NAME}.bz2"
    reconcile_buildcache_ipe_sidecars "${AZURE_IMAGE_NAME}" "${image_key}"
fi

ipe_configure_azure_trust "${AZURE_IMAGE_NAME:-}" "${AZURE_IMAGE_NAME:-}"

validate_trusted_launch_generation() {
    local hyperv_gen="$1"

    if [[ "${AZURE_TRUSTED_LAUNCH:-}" == "true" ]] &&
        [[ "${hyperv_gen}" != "V2" ]]; then
        echo "Azure Trusted Launch requires Hyper-V generation V2, got ${hyperv_gen}" >&2
        return 1
    fi
}

should_schedule_v1() {
    [[ -z "${AZURE_DISK_URI:-}" ]] &&
        [[ "${AZURE_TRUSTED_LAUNCH:-}" != "true" ]]
}

run_kola_tests() {
    local instance_type="${1}"; shift
    local instance_tapfile="${1}"; shift
    local hyperv_gen sku

    ipe_reject_kola_managed_overrides false "$@" || return 1
    if [ "${instance_type}" = "V1" ]; then
        hyperv_gen="V1"
        sku="alpha"
        # v5 is the last to support Gen 1. Only amd64 uses Gen 1.
        instance_type="Standard_D2s_v5"
        if [[ -z "${AZURE_DISK_URI:-}" && ${#azure_use_gallery_args[@]} -gt 0 ]]; then
            set -- --azure-use-gallery "${@}"
        fi
    else
        hyperv_gen="V2"
        sku="alpha-gen2"
        # --azure-use-gallery is only consumed by mantle when it is creating a
        # new image from a blob/file. On the --azure-disk-uri path mantle
        # consumes the disk URI directly and ignores --azure-use-gallery, so
        # skip the flag to keep the kola invocation honest.
        if [[ -z "${AZURE_DISK_URI:-}" ]]; then
            set -- --azure-use-gallery "${@}"
        fi
    fi
    validate_trusted_launch_generation "${hyperv_gen}" || return 1

    # Align timeout with ore azure gc --duration parameter
    debug_flag=""
    if [[ "${KOLA_DEBUG:-}" == "true" ]]; then
        debug_flag="--debug"
    fi

    # Determine image reference: gallery image via disk URI or local VHD
    local image_arg
    if [[ -n "${AZURE_DISK_URI:-}" ]]; then
        image_arg="--azure-disk-uri=${AZURE_DISK_URI}"
    else
        image_arg="--azure-image-file=${AZURE_IMAGE_NAME}"
    fi

    local trusted_launch_args=()
    if [[ "${AZURE_TRUSTED_LAUNCH:-}" == "true" ]]; then
        trusted_launch_args+=(--azure-trusted-launch --enable-secureboot)
    fi

    local secure_boot_certificate_args=()
    if [[ -n "${AZURE_SECURE_BOOT_CERTIFICATES:-}" ]]; then
        if [[ "${AZURE_TRUSTED_LAUNCH:-}" != "true" ]]; then
            echo "AZURE_SECURE_BOOT_CERTIFICATES requires AZURE_TRUSTED_LAUNCH=true" >&2
            return 1
        fi
        if [[ -n "${AZURE_DISK_URI:-}" ]]; then
            echo "AZURE_SECURE_BOOT_CERTIFICATES cannot modify an existing gallery image version" >&2
            return 1
        fi
        local certificate
        local certificates=()
        IFS=':' read -r -a certificates <<< "${AZURE_SECURE_BOOT_CERTIFICATES}"
        for certificate in "${certificates[@]}"; do
            if [[ -z "${certificate}" ]]; then
                echo "AZURE_SECURE_BOOT_CERTIFICATES contains an empty path" >&2
                return 1
            fi
            secure_boot_certificate_args+=(--azure-secureboot-certificate="${certificate}")
        done
    fi

    timeout --signal=SIGQUIT 6h \
      kola run \
      ${debug_flag} \
      ${distro_flag:-} \
      --board="${board}" \
      --basename="${basename}" \
      --parallel="${AZURE_PARALLEL}" \
      --offering=basic \
      --platform=azure \
      ${image_arg} \
      --azure-location="${AZURE_LOCATION}" \
      --tapfile="${instance_tapfile}" \
      --azure-size="${instance_type}" \
      --azure-sku="${sku}" \
      --azure-hyper-v-generation="${hyperv_gen}" \
      "${trusted_launch_args[@]}" \
      "${secure_boot_certificate_args[@]}" \
      ${AZURE_KOLA_VNET:+--azure-kola-vnet=${AZURE_KOLA_VNET}} \
      ${azure_vnet_subnet_name:+--azure-vnet-subnet-name=${azure_vnet_subnet_name}} \
      ${AZURE_USE_PRIVATE_IPS:+--azure-use-private-ips=${AZURE_USE_PRIVATE_IPS}} \
      ${AZURE_RESOURCE_GROUP_TAG:+--azure-resource-group-tag=${AZURE_RESOURCE_GROUP_TAG}} \
      ${KOLA_TRUSTED_SOURCE_CIDR:+--trusted-source-cidr=${KOLA_TRUSTED_SOURCE_CIDR}} \
      --image-version "${CIA_VERNUM}" \
      "${@}"
}

query_kola_tests() {
    shift; # ignore the instance type
    kola list --platform=azure --filter "${@}"
}

other_instance_types=()
# RPM/ACL mode: no Gen1 support and no GPU quota, skip extra instance types.
if [[ "${CIA_ARCH}" = 'amd64' ]] && [[ "${PACKAGE_SOURCE_MODE:-PORTAGE}" != 'RPM' ]]; then
    # Gen1 (V1) is incompatible with --azure-disk-uri: a gallery image-definition
    # is locked to a single Hyper-V generation, and our *-test image-defs are
    # Gen2-only. Skip the V1 run when running in disk-URI (gallery) mode.
    if should_schedule_v1; then
        other_instance_types+=('V1')
    fi
    other_instance_types+=('Standard_NC6s_v3')
fi

run_kola_tests_on_instances \
    "${azure_instance_type}" \
    "${CIA_TAPFILE}" \
    "${CIA_FIRST_RUN}" \
    "${other_instance_types[@]}" \
    '--' \
    'cl.internet' 'cl.misc.nvidia'\
    '--' \
    "${@}"
