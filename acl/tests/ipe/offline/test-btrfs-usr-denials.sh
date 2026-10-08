#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$root/acl/tests/ipe/btrfs/run-usr-audit-test.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture"/{oem,containerd,live}/usr/bin
printf 'extension' > "$fixture/oem/usr/bin/python"
cp "$fixture/oem/usr/bin/python" "$fixture/live/usr/bin/python"
printf 'containerd' > "$fixture/containerd/usr/bin/containerd"
cp "$fixture/containerd/usr/bin/containerd" "$fixture/live/usr/bin/containerd"
extension_roots=("$fixture/oem" "$fixture/containerd")
readlink() {
    case "${@: -1}" in
        /usr/*) printf '%s\n' "${@: -1}" ;;
        /lib/*) printf '/usr%s\n' "${@: -1}" ;;
        *) command readlink "$@" ;;
    esac
}
cmp() { command cmp -s -- "${@: -2:1}" "$fixture/live${@: -1}"; }
event() {
    printf 'type=1420 ipe_op=EXECUTE ipe_hook=BPRM_CHECK pid=12 path="%s" dev="%s" ino=%s rule="DEFAULT op=EXECUTE action=DENY"\n' "$1" "$2" "$3"
}
reject() {
    if (check_usr_denials <<< "$1") > "$fixture/error" 2>&1; then
        echo "Accepted invalid denial: $1" >&2
        exit 1
    fi
    grep -Eq 'FAILED: (base /usr or unclassified|unparseable|missing)' "$fixture/error"
}
inode="$(stat -Lc '%i' "$fixture/oem/usr/bin/python")"
check_usr_denials <<< "$(event /usr/bin/python overlay "$inode")"
check_usr_denials <<< "$(event /usr/bin/containerd overlay "$(stat -Lc '%i' "$fixture/containerd/usr/bin/containerd")")"
reject "$(event /usr/bin/true overlay 100)"
reject "$(event /usr/bin/python dm-0 "$inode")"
reject "$(event /usr/bin/python overlay 999999)"
reject "$(event /usr/bin/missing overlay "$inode")"
reject 'ipe_op=EXECUTE path=2F7573722F62696E2F74727565 action=DENY'
reject 'ipe_op=EXECUTE path="/usr/bin/python" action=DENY'
printf 'changed' > "$fixture/live/usr/bin/python"
reject "$(event /usr/bin/python overlay "$inode")"

# A lower extension must not hide a mismatch in a higher-precedence layer.
cp "$fixture/containerd/usr/bin/containerd" "$fixture/oem/usr/bin/containerd"
printf 'shadowed' > "$fixture/oem/usr/bin/containerd"
reject "$(event /usr/bin/containerd overlay "$(stat -Lc '%i' "$fixture/containerd/usr/bin/containerd")")"
ln -s "$fixture/live/usr/bin/python" "$fixture/oem/usr/bin/escape"
reject "$(event /usr/bin/escape overlay "$inode")"
check_usr_denials <<< "$(event /var/tmp/untrusted sda 12)"
check_usr_denials <<< 'ipe_op=EXECUTE path="/usr/bin/true" action=ALLOW'

(
    work="$fixture/mounts"
    mkdir "$work"
    mounted=()
    extension_roots=()
    findmnt() {
        [[ "$*" == *"-t overlay"* ]] || {
            echo "Must distinguish stacked base and overlay mounts" >&2
            return 1
        }
        case "${@: -1}" in
            SOURCE) echo sysext ;;
            OPTIONS) echo 'ro,lowerdir=/run/systemd/sysext/meta/usr:/run/systemd/sysext/extensions/oem-azure/usr:/run/systemd/sysext/extensions/containerd/usr:/usr,redirect_dir=on' ;;
            *) return 1 ;;
        esac
    }
    losetup() { printf '/dev/loop2 /sysext/oem-azure-1.raw\n/dev/loop3 /share/distro/sysext/containerd.raw\n'; }
    blockdev() { echo 1; }
    mount() { [[ "$*" == "-o ro,nosuid,nodev,noexec /dev/loop"* ]]; }
    prepare_usr_layers
    [[ "${extension_roots[*]}" == "$work/oem-azure $work/containerd" ]]
    [[ "${mounted[*]}" == "${extension_roots[*]}" ]]
)
echo "PASS: source-qualified Btrfs /usr denial classification"
