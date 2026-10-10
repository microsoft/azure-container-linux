#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export AZL_PIN
AZL_PIN="$(jq -r .azurelinux_commit "$root/acl/SPECS/kernel/source.json")"

git() {
    if [[ "$*" == "-C azurelinux rev-parse HEAD" ]]; then
        printf '%s\n' "${GIT_HEAD:-$AZL_PIN}"
    else
        echo "Unexpected git command: $*" >&2
        return 1
    fi
}
make() { printf '%s\n' "$@" >> "$CALLS"; }
sudo() {
    case "$1" in
        make) shift; make "$@" ;;
        chown) ;;
        *) echo "Unexpected sudo command: $*" >&2; return 1 ;;
    esac
}
export -f git make sudo

run_case() {
    local name=$1 mode=$2 package=$3 expected=$4
    local dir="$work/$name"
    mkdir -p "$dir/acl/SPECS" "$dir/__build__/rpms_build_dir/azurelinux/toolkit"
    cp "$root/acl/build.sh" "$dir/acl/build.sh"
    cp -R "$root/acl/SPECS/kernel" "$dir/acl/SPECS/"
    if ACL_BTRFS_IPE_KERNEL="$mode" CALLS="$dir/calls" REUSE_SOURCES=true \
        bash "$dir/acl/build.sh" "$package" > "$dir/output" 2>&1; then
        [[ "$expected" != reject ]] || { cat "$dir/output"; return 1; }
    else
        [[ "$expected" == reject ]] || { cat "$dir/output"; return 1; }
        [[ ! -e "$dir/calls" ]]
        return
    fi
    grep -Fxq "SRPM_PACK_LIST=$expected" "$dir/calls"
    grep -Fxq "SPECS_DIR=$dir/acl/SPECS" "$dir/calls"
    local manifest="$dir/__build__/rpm-staging/btrfs-ipe-kernel.json"
    if [[ "$mode" == 1 ]]; then
        [[ "$(jq -r .azurelinux_commit "$manifest")" == "$AZL_PIN" ]]
        [[ "$(jq -r .patch_sha256 "$manifest")" == \
           "$(sha256sum "$dir/acl/SPECS/kernel/btrfs-ipe.patch" | cut -d' ' -f1)" ]]
    else
        [[ ! -e "$manifest" ]]
    fi
}

run_case stock 0 coreos-init coreos-init
run_case opted-in 1 coreos-init "coreos-init kernel"
run_case explicit-kernel 1 kernel kernel
run_case missing-opt-in 0 kernel reject
run_case invalid-opt-in 2 coreos-init reject
GIT_HEAD=wrong-toolkit run_case stale-toolkit 1 coreos-init reject
echo "Btrfs kernel package selection tests passed"
