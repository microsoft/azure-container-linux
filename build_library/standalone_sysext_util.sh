# Copyright (c) 2025 Microsoft Corporation.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Utility for building standalone sysext images.
# Sourced by build_standalone_sysexts (inside the SDK container) and
# called from build_rpm_image.sh via run_sdk_container.
#
# Required globals (set by common.sh):
#   SCRIPT_ROOT, BUILD_LIBRARY_DIR, BOARD
#
# Required environment:
#   STANDALONE_SYSEXTS_SPEC  — space-separated "name|category/package[&pkg]" entries
#
# Optional environment:
#   SYSEXT_COMPRESSION       — override default sysext compression (zstd)
#   PACKAGE_SOURCE_MODE      — "RPM" to pass RPM env vars to build_sysext
#   RPM_STAGING_DIR, IMAGE_VERSION, IMAGE_VERSION_ID, IMAGE_BUILD_ID

# Parse standalone_sysexts.yaml and emit a space-separated STANDALONE_SYSEXTS_SPEC
# string filtered for the given board.  Entries without an 'archs' key are
# included for every board.
#
# Usage:
#   spec=$(parse_standalone_sysexts_yaml "/path/to/standalone_sysexts.yaml" "amd64-usr")
#
# The board name (e.g. "amd64-usr") is mapped to an arch (e.g. "amd64")
# to match the 'archs' values in the YAML.
#
# Output format (one token per sysext, space-separated):
#   name|pkg1&pkg2
#
# Package names can be RPM names or portage-style category/package names.
# In RPM mode, rpm_install_package_using_portage_name() will try each name
# as a direct RPM first, then fall back to the catalog.
#
# Requires: yq v4 (https://github.com/mikefarah/yq/)
parse_standalone_sysexts_yaml() {
    local yaml_file="$1"
    local board="$2"
    # Map board name to arch: "amd64-usr" → "amd64", "arm64-usr" → "arm64"
    local arch="${board%%-*}"

    if [[ ! -f "${yaml_file}" ]]; then
        echo ""
        return 0
    fi

    # For each sysext entry: if .archs is null (omitted) or contains the
    # arch, emit "name|pkg1&pkg2".  yq handles the filtering natively.
    # Package entries can be plain strings or objects with 'name' and 'archs'
    # fields for per-package architecture filtering.
    yq eval -r "
        .sysexts[]
        | select(.archs == null or (.archs[] | select(. == \"${arch}\")))
        | .name + \"|\" + ([.packages[]
            | select(tag == \"!!str\" or .archs == null or (.archs[] | select(. == \"${arch}\")))
            | (select(tag == \"!!str\") // .name)]
            | join(\"&\"))
    " "${yaml_file}" | tr '\n' ' '
}

# Build standalone sysext .raw images from STANDALONE_SYSEXTS_SPEC.
#
# Arguments:
#   $1  squashfs_base — path to the sysext base squashfs image
#   $2  output_dir    — directory for intermediate builds and final artifacts
#
# The function is a no-op when STANDALONE_SYSEXTS_SPEC is empty.
build_standalone_sysext_images() {
    local squashfs_base="$1"
    local output_dir="$2"

    if [[ -z "${STANDALONE_SYSEXTS_SPEC:-}" ]]; then
        return 0
    fi

    local compression_opt=""
    if [[ -n "${SYSEXT_COMPRESSION:-}" ]]; then
        compression_opt="--compression=${SYSEXT_COMPRESSION}"
    fi

    # For RPM mode, set environment variables to pass to build_sysext
    local -a build_sysext_env=()
    if [[ "${PACKAGE_SOURCE_MODE:-}" == "RPM" ]]; then
        build_sysext_env=(
            "PACKAGE_SOURCE_MODE=${PACKAGE_SOURCE_MODE}"
            "RPM_STAGING_DIR=${RPM_STAGING_DIR:-}"
            "IMAGE_VERSION=${IMAGE_VERSION:-}"
            "IMAGE_VERSION_ID=${IMAGE_VERSION_ID:-}"
            "IMAGE_BUILD_ID=${IMAGE_BUILD_ID:-}"
        )
    fi

    local sysext_spec
    for sysext_spec in ${STANDALONE_SYSEXTS_SPEC}; do
        local name="${sysext_spec%%|*}"
        local packages="${sysext_spec#*|}"
        info "Building standalone sysext: ${name} (${packages//&/, })"

        # Expand multi-package separator & → individual package args
        local -a pkg_args=()
        IFS='&' read -ra pkg_args <<< "$packages"

        local built_sysext_dir="${output_dir}/${name}-sysext"
        mkdir -p "${built_sysext_dir}"

        local -a sysext_flags=(
            --board="${BOARD}"
            --squashfs_base="${squashfs_base}"
            --image_builddir="${built_sysext_dir}"
            --install_root_basename="${name}-standalone-sysext-rootfs"
            ${compression_opt}
        )

        # Use mangle script if one exists under build_library/
        local mangle_fs="${BUILD_LIBRARY_DIR}/sysext_mangle_${name}"
        if [[ -x "${mangle_fs}" ]]; then
            sysext_flags+=(
                --manglefs_script="${mangle_fs}"
            )
        fi

        # Sysext name + packages as positional args
        sysext_flags+=("${name}" "${pkg_args[@]}")

        sudo "${build_sysext_env[@]}" "${SCRIPT_ROOT}/build_sysext" "${sysext_flags[@]}"

        # Move sysext artifacts to output directory
        local to_move
        for to_move in "${built_sysext_dir}/${name}"*; do
            [[ -e "${to_move}" ]] && mv -f "${to_move}" "${output_dir}/${to_move##*/}"
        done

        # Clean up work directory
        rm -rf "${built_sysext_dir}"
        info "Built standalone sysext: ${output_dir}/${name}.raw"
    done
}
