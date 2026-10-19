#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Run with bash build_library/rpm/tests/test_runtime_package_selection.sh.
set -euo pipefail

RPM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for board in amd64-usr arm64-usr; do
    for bootloader in uki grub; do
        (
            export BOARD="${board}" BOOTLOADER_MODE="${bootloader}"
            unset BUILD_DIR
            source "${RPM_DIR}/package_catalog.sh"
            source "${RPM_DIR}/rpm_install.sh"

            info() { :; }
            error() { echo "$*" >&2; }
            # Exercise the real catalog installation path without DNF or
            # emerge; installation is captured at the transaction boundary.
            rpm_install_package() { printf '%s\n' "${@:2}"; }
            get_portage_dependencies() {
                echo "Unexpected emerge dependency resolution: $*" >&2
                exit 1
            }

            selected="$(rpm_install_package_using_portage_name /unused \
                sys-apps/systemd sys-apps/iproute2 sys-fs/cryptsetup)"
            selected="$(printf '%s\n' "${selected}" | tr ' ' '\n' | sort -u)"
            for package in bzip2 zstd iproute iproute-tc systemd-container \
                cryptsetup veritysetup integritysetup; do
                grep -qx "${package}" <<< "${selected}"
            done
            if [[ "${bootloader}" == uki ]]; then
                grep -qx trident-acl <<< "${selected}"
            else
                if grep -qx trident-acl <<< "${selected}"; then
                    echo "Unexpected trident-acl in GRUB selection" >&2
                    exit 1
                fi
            fi

            # Documented proposals must not become active mappings or
            # additions to existing mappings accidentally.
            for key in "${!PACKAGE_CATALOG[@]}"; do
                for package in ${PACKAGE_CATALOG[$key]}; do
                    case "${package}" in
                        quota-rpc|quota-warnquota|tdb-tools|idn2|psl|xxhash|\
                        vim-extra|erofs-utils|bind-dnssec-utils|p11-kit-server|\
                        glibc-nscd|libseccomp-devel)
                            echo "Unexpected optional package: ${key}: ${package}" >&2
                            exit 1
                            ;;
                    esac
                done
            done
            echo "PASS: ${board} ${bootloader}"
        )
    done
done
