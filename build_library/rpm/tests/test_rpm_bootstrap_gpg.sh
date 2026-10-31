#!/bin/bash

set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_ROOT}/build_library/rpm/rpm_install.sh"

fail() { echo "$*" >&2; exit 1; }
info() { :; }
die() { fail "$*"; }

work_dir="$(mktemp -d)"
trap 'sudo rm -rf -- "${work_dir}"' EXIT
trace_file="${work_dir}/trace"

rpm_init_database "${work_dir}/real-root"
rpm_import_gpg_key "${work_dir}/real-root"
sudo rpm --root="${work_dir}/real-root" -q gpg-pubkey --queryformat='%{name}\n' |
    grep -qx gpg-pubkey || fail "Microsoft signing key was not imported into the fresh RPM database"

rpm_snapshot_args() { :; }
rpm_init_database() { printf 'initdb\n' >> "${trace_file}"; }
rpm_import_gpg_key() { printf 'import-key\n' >> "${trace_file}"; }
rpm_get_staging_dir() { :; }
rpm_setup_repos() { printf 'setup-repos\n' >> "${trace_file}"; }

rpm_install_init "${work_dir}/root"

expected=$'initdb\nimport-key\nsetup-repos'
[[ "$(cat "${trace_file}")" == "${expected}" ]] ||
    fail "Cold bootstrap must import the signing key after initdb and before repo setup"