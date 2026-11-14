#!/bin/bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_ROOT}/build_library/rpm/rpm_install.sh"

fail() { echo "$*" >&2; exit 1; }
info() { :; }
die() { echo "$*" >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT

# Create a fresh ESP containing one kernel config with the given lines.
make_esp() {
    local esp="${work_dir}/$1" subdir="$2"
    shift 2
    mkdir -p "${esp}/${subdir}"
    printf '%s\n' "$@" > "${esp}/${subdir}/config-6.6.0-1.azl3"
    printf '%s\n' "${esp}"
}

expect_arg() {
    local esp="$1" expected="$2" actual
    actual="$(rpm_bpf_lsm_cmdline_arg "${esp}")" ||
        fail "rpm_bpf_lsm_cmdline_arg failed for ${esp##*/}"
    [[ "${actual}" == "${expected}" ]] ||
        fail "${esp##*/}: expected '${expected}', got '${actual}'"
}

expect_failure() {
    local esp="$1"
    if (rpm_bpf_lsm_cmdline_arg "${esp}") >/dev/null 2>&1; then
        fail "${esp##*/}: rpm_bpf_lsm_cmdline_arg should have failed"
    fi
}

esp="$(make_esp append . 'CONFIG_BPF_LSM=y' 'CONFIG_LSM="lockdown,yama,integrity,selinux"')"
expect_arg "${esp}" "lsm=lockdown,yama,integrity,selinux,bpf"

esp="$(make_esp already-bpf . 'CONFIG_BPF_LSM=y' 'CONFIG_LSM="lockdown,selinux,bpf,ipe"')"
expect_arg "${esp}" "lsm=lockdown,selinux,bpf,ipe"

esp="$(make_esp boot-subdir boot 'CONFIG_BPF_LSM=y' 'CONFIG_LSM="selinux"')"
expect_arg "${esp}" "lsm=selinux,bpf"

esp="$(make_esp no-bpf-lsm . '# CONFIG_BPF_LSM is not set' 'CONFIG_LSM="selinux"')"
expect_failure "${esp}"

esp="$(make_esp no-lsm-list . 'CONFIG_BPF_LSM=y')"
expect_failure "${esp}"

esp="$(make_esp two-configs . 'CONFIG_BPF_LSM=y' 'CONFIG_LSM="selinux"')"
cp "${esp}/config-6.6.0-1.azl3" "${esp}/config-6.6.0-2.azl3"
expect_failure "${esp}"

mkdir -p "${work_dir}/empty"
expect_failure "${work_dir}/empty"

echo "PASS: rpm_bpf_lsm_cmdline_arg"
