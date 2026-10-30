#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -euo pipefail

# Find the absolute path of the directory containing this script
ACL_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

ARTIFACT_PUBLISH_DIR="${ACL_DIR}/../__build__/rpm-staging"
BUILD_DIR="${ACL_DIR}/../__build__/rpms_build_dir"
OUT_DIR="${ACL_DIR}/../__build__/rpms_out_dir"
REUSE_SOURCES="${REUSE_SOURCES:-true}"

function log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

SPECS_DIR="${ACL_DIR}/SPECS"

function cleanup() {
    log "Cleaning up..."

    if [[ -n "$LOG_PUBLISH_DIR" ]]; then
        publish_build_logs
    fi
}

function clone_azl3() {
    if [[ -d "azurelinux" && "$REUSE_SOURCES" == "false" ]]; then
        sudo rm -rf azurelinux
    fi
    if [ ! -d "azurelinux" ]; then
        git clone -b "3.0-stable" "https://github.com/microsoft/azurelinux.git"
    fi
}

# Build a list of specs in a spec folder with a list of remote repos
# Expects toolchain and worker chroot to be present before being called.
#
# Arguments:
#  $1 Path to specs folder
function build_specs() {
    local SPECS_DIR="$1"

    local -a snapshot_args=()
    local snapshot_mode="${ACL_RPM_SNAPSHOT_MODE:-materialized}"
    if [[ -n "${PACKAGE_SNAPSHOT_TIME:-}" ]]; then
        if [[ ! "${PACKAGE_SNAPSHOT_TIME}" =~ ^[1-9][0-9]{9}$ ]]; then
            log "!!! ERROR: PACKAGE_SNAPSHOT_TIME must be a ten-digit Unix UTC timestamp"
            exit 1
        fi
        snapshot_args=(REPO_SNAPSHOT_TIME="${PACKAGE_SNAPSHOT_TIME}")
        log "Building RPM dependencies as of ${PACKAGE_SNAPSHOT_TIME}"
        if [[ "$snapshot_mode" != "materialized" && "$snapshot_mode" != "tdnf" ]]; then
            log "!!! ERROR: ACL_RPM_SNAPSHOT_MODE must be materialized or tdnf"
            exit 1
        fi
    fi
    pushd "${BUILD_DIR}/azurelinux/toolkit"
    local -a make_args=(
        -j"$(nproc)"
        SRPM_PACK_LIST="${package_build_list[*]}"
        SPECS_DIR="${SPECS_DIR}"
        QUICK_REBUILD_PACKAGES=y
        PRECACHE=n
        CONFIG_FILE=
        REBUILD_TOOLS=y
        GOFLAGS="-buildvcs=false"
        BUILD_DIR="$BUILD_DIR"
        OUT_DIR="$OUT_DIR"
        LOG_LEVEL=info
    )
    if [[ -n "${PACKAGE_SNAPSHOT_TIME:-}" && "$snapshot_mode" == "materialized" ]]; then
        if [[ -n "${REPO_LIST:-}" || -n "${PACKAGE_CACHE_SUMMARY:-}" ]]; then
            log "!!! ERROR: Materialized snapshots do not support external REPO_LIST or PACKAGE_CACHE_SUMMARY"
            exit 1
        fi
        sudo make chroot-tools "${make_args[@]}"
        sudo python3 "${ACL_DIR}/materialize_rpm_snapshot.py" \
            --worker-tar "${BUILD_DIR}/worker/worker_chroot.tar.gz" \
            --cutoff "${PACKAGE_SNAPSHOT_TIME}" \
            --architecture "$(uname -m)" \
            --cache-dir "${BUILD_DIR}/snapshot-repositories" \
            -- make build-packages "${make_args[@]}"
    else
        sudo make build-packages "${make_args[@]}" "${snapshot_args[@]}"
    fi
    MAKE_STATUS=${PIPESTATUS[0]}

    if [ "$MAKE_STATUS" -ne 0 ]; then
        log "!!! ERROR: make build-packages failed with status $MAKE_STATUS"
        exit "$MAKE_STATUS"
    fi

    sudo chown -R "$(id -u):$(id -g)" "${BUILD_DIR}" "${OUT_DIR}"

    popd
}

# Package build artifacts and place in build artifact publishing directory
# This overwrites packaged artifacts from previous calls to this function
# The SRPMs and RPMs from previous calls are preserved and packaged as long as
#  `make clean` has not been called between builds of separate repos
#
# No arguments
# Global variables expected to be defined: BUILD_DIR, OUT_DIR, $ARTIFACT_PUBLISH_DIR
# Assumes toolkit is at ${BUILD_DIR}/azurelinux/toolkit
publish_package_build_artifacts() {
    log "pack built RPMs and SRPMs"

    pushd "${BUILD_DIR}/azurelinux/toolkit"
    sudo make compress-srpms compress-rpms \
        BUILD_DIR="$BUILD_DIR" \
        OUT_DIR="$OUT_DIR"
    MAKE_STATUS=${PIPESTATUS[0]}
    if [ $MAKE_STATUS -ne 0 ]; then
        log "!!! ERROR: make compress-srpms compress-rpms failed with status $MAKE_STATUS"
        exit $MAKE_STATUS
    fi

    if [[ -n "$ARTIFACT_PUBLISH_DIR" ]]; then
        log "Publishing artifacts to $ARTIFACT_PUBLISH_DIR"
        PACKAGE_PUBLISH_DIR="$ARTIFACT_PUBLISH_DIR"
        mkdir -p "$PACKAGE_PUBLISH_DIR"
        if [[ -d "$OUT_DIR/RPMS/x86_64/" ]]; then
            find "$OUT_DIR/RPMS/x86_64/" -name "*.rpm" -exec cp {} "$PACKAGE_PUBLISH_DIR" \; || log "warning: no x86_64 RPMs found to publish"
        else
            log "warning: no x86_64 RPMs found to publish (directory not found)"
        fi
        if [[ -d "$OUT_DIR/RPMS/noarch/" ]]; then
            find "$OUT_DIR/RPMS/noarch/" -name "*.rpm" -exec cp {} "$PACKAGE_PUBLISH_DIR" \; || log "warning: no noarch RPMs found to publish"
        else
            log "warning: no noarch RPMs found to publish (directory not found)"
        fi
        if [[ -d "$OUT_DIR/RPMS/aarch64/" ]]; then
            find "$OUT_DIR/RPMS/aarch64/" -name "*.rpm" -exec cp {} "$PACKAGE_PUBLISH_DIR" \; || log "warning: no aarch64 RPMs found to publish"
        else
            log "warning: no aarch64 RPMs found to publish (directory not found)"
        fi
    fi
    popd
}

# Package log artifacts and place in log artifact publishing directory
# This overwrites packaged logs from previous calls to this function
# The logs from previous calls are preserved and packaged as long as
#  `make clean` has not been called between builds of separate repos
#
# No arguments
# Global variables expected to be defined: LOG_PUBLISH_DIR, BUILD_DIR
publish_build_logs() {
    log "-- pack logs"
    mkdir -p "$LOG_PUBLISH_DIR"
    if [[ -d "$BUILD_DIR/logs" ]]; then
        tar -C "$BUILD_DIR/logs" -czf "$LOG_PUBLISH_DIR/pkggen.logs.tar.gz" .
    else
        log "-- Warning - no 'logs' folder under $BUILD_DIR"
    fi
    log "-- pack package build artifacts"
    if [[ -d "$BUILD_DIR/pkg_artifacts" ]]; then
        tar -C "$BUILD_DIR/pkg_artifacts" -czf "$LOG_PUBLISH_DIR/pkg_artifacts.tar.gz" .
    else
        log "-- Warning - no 'pkg_artifacts' folder under $BUILD_DIR"
    fi
}

#
# main
#

trap cleanup EXIT

#
# Derive Variables
#
LOG_PUBLISH_DIR=""
if [[ -n "$ARTIFACT_PUBLISH_DIR" ]]; then
    LOG_PUBLISH_DIR="${ARTIFACT_PUBLISH_DIR}/LOGS"
    mkdir -p "${LOG_PUBLISH_DIR}"
fi

mkdir -p "${BUILD_DIR}"
mkdir -p "${OUT_DIR}"

pushd "${BUILD_DIR}"

#
# Build local packages
#
log "Build local packages"

declare -a package_build_list
package_build_list=("$@")

if [[ ${#package_build_list[@]} -eq 0 ]]; then
    log "ERROR: No packages specified. Pass package names as arguments."
    exit 1
fi

clone_azl3

build_specs "$SPECS_DIR"

publish_package_build_artifacts
