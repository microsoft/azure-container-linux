#!/bin/bash

set -euo pipefail

for tool in dnf5 rpm rpmbuild createrepo_c; do
    command -v "${tool}" >/dev/null || {
        echo "Missing required test tool: ${tool}" >&2
        exit 1
    }
done
[[ ${EUID} -eq 0 ]] || {
    echo "Run this test as root in an RPM/DNF5 SDK or test container" >&2
    exit 1
}

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${SCRIPT_ROOT}/build_library/rpm/rpm_install.sh"
info() { :; }
die() { echo "$*" >&2; exit 1; }
sudo() { "$@"; }
unset PACKAGE_SNAPSHOT_TIME FASTTRACK_REPO_FILE

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
mkdir -p "${work_dir}"/{build,local,pipeline-rpms,pmc}
package=acl-repository-priority-test

build_rpm() {
    local name="$1" version="$2" repository="$3"
    cat > "${work_dir}/fixture.spec" <<EOF
Name: ${name}
Version: ${version}
Release: 1
Summary: Repository selection fixture
License: MIT
BuildArch: noarch

%description
Repository selection fixture.

%files
EOF
    rpmbuild --quiet --define "_topdir ${work_dir}/build" -bb "${work_dir}/fixture.spec"
    cp "${work_dir}/build/RPMS/noarch/${name}-${version}-1.noarch.rpm" "${repository}/"
}

install_and_check() {
    local label="$1" name="$2" expected="$3"
    shift 3
    local root="${work_dir}/${label}"
    rpm_setup_repos "${root}" 3.0 "${work_dir}/local" "${work_dir}/pipeline-rpms"
    cat > "${root}/etc/yum.repos.d/pmc.repo" <<EOF
[pmc-fixture]
name=PMC fixture
baseurl=file://${work_dir}/pmc
enabled=1
gpgcheck=0
repo_gpgcheck=0
EOF
    if ! dnf5 -y --installroot="${root}" --releasever=3.0 \
        --setopt=reposdir="${root}/etc/yum.repos.d" \
        --disable-repo=azurelinux-bootstrap "$@" install "${name}" \
        > "${work_dir}/${label}.log" 2>&1; then
        cat "${work_dir}/${label}.log" >&2
        die "DNF selection failed: ${label}"
    fi
    local actual
    actual="$(rpm --root="${root}" -q --queryformat='%{VERSION}' "${name}")"
    [[ "${actual}" == "${expected}" ]] ||
        die "${label}: expected ${expected}, selected ${actual}"
    echo "PASS: ${label}"
}

build_rpm "${package}" 0.1 "${work_dir}/local"
build_rpm "${package}" 1 "${work_dir}/pipeline-rpms"
build_rpm "${package}" 2 "${work_dir}/pmc"
build_rpm trident 99 "${work_dir}/pipeline-rpms"
build_rpm trident 1 "${work_dir}/pmc"
for repository in local pipeline-rpms pmc; do
    createrepo_c --quiet "${work_dir}/${repository}"
done

install_and_check acl-override "${package}" 0.1
install_and_check newer-pmc "${package}" 2 --disable-repo=azurelinux-local-cache
build_rpm "${package}" 3 "${work_dir}/pipeline-rpms"
createrepo_c --quiet --update "${work_dir}/pipeline-rpms"
install_and_check newer-pipeline "${package}" 3 --disable-repo=azurelinux-local-cache
install_and_check explicit-trident trident 1 --disable-repo=azurelinux-local-cache
