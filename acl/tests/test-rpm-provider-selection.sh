#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

info() { :; }
warn() { :; }
error() { echo "$*" >&2; }
die() { echo "$*" >&2; return 1; }

source "${SCRIPT_DIR}/build_library/rpm/package_catalog.sh"
source "${SCRIPT_DIR}/build_library/rpm/rpm_install.sh"

MOCK_DEPENDENCY=""
get_all_dependencies() {
    echo "${MOCK_DEPENDENCY}"
}

CAPTURED_PACKAGES=()
rpm_install_package() {
    shift
    CAPTURED_PACKAGES=("$@")
}

contains_package() {
    local expected="$1"
    local package

    for package in "${CAPTURED_PACKAGES[@]}"; do
        [[ "${package}" == "${expected}" ]] && return 0
    done

    return 1
}

assert_provider_selection() {
    MOCK_DEPENDENCY="$1"
    CAPTURED_PACKAGES=()

    rpm_install_package_using_portage_name "/tmp/test-root" "coreos-base/coreos"

    [[ ${#CAPTURED_PACKAGES[@]} -eq 2 ]]
    contains_package "gettext"
    contains_package "libgomp"
}

assert_provider_selection "app-misc/gettext"
assert_provider_selection "sys-devel/gettext"

echo "RPM provider selection contract passed"
