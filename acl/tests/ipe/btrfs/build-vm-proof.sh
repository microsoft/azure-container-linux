#!/bin/bash
# SPDX-License-Identifier: MIT
# Run as root on a disposable Linux builder. The host kernel is never replaced.
set -euo pipefail
run_vm() {
    local variant=$1 work=$2
    timeout 180 qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 \
        -nodefaults -nographic -serial mon:stdio -no-reboot \
        -kernel "$work/$variant.bzImage" -initrd "$work/initramfs.gz" \
        -append 'console=ttyS0 rdinit=/init panic=-1 audit=1 audit_backlog_limit=8192 ipe.enforce=0 ipe.success_audit=1' \
        -drive "file=$work/signed.img,if=virtio,format=raw,readonly=on" \
        -drive "file=$work/signed.hash.img,if=virtio,format=raw,readonly=on" \
        -drive "file=$work/plain.img,if=virtio,format=raw,readonly=on" \
        -drive "file=$work/unsigned.img,if=virtio,format=raw,readonly=on" \
        -drive "file=$work/unsigned.hash.img,if=virtio,format=raw,readonly=on" \
        > "$work/$variant.serial.log" 2>&1
    grep -q '^BTRFS_IPE_COMPLETE' "$work/$variant.serial.log"
}
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi
work=${1:?Usage: build-vm-proof.sh NEW_WORK_DIRECTORY PATCH_FILE}
patch_file=$(realpath "${2:?Patch file required}")
scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_commit=05f2698e41ebb5e78abf40749f797a687e15df73
for tool in gcc make flex bison bc cpio openssl curl tar python3 qemu-system-x86_64 \
            mkfs.btrfs veritysetup auditctl busybox; do
    command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done
test -c /dev/kvm || { echo "KVM required" >&2; exit 1; }
test "$(uname -m)" = x86_64 || { echo "This runner currently supports AMD64" >&2; exit 1; }
mkdir "$work"
work=$(realpath "$work")
exec > >(tee "$work/build.log") 2>&1
mkdir "$work/source" "$work/root" "$work/payload"
curl --fail --location --retry 3 \
    "https://codeload.github.com/microsoft/CBL-Mariner-Linux-Kernel/tar.gz/$source_commit" \
    -o "$work/source.tar.gz"
sha256sum "$work/source.tar.gz" "$patch_file" > "$work/input-sha256.txt"
tar -xzf "$work/source.tar.gz" -C "$work/source" --strip-components=1
openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 7 \
    -subj /CN=ACL-Btrfs-IPE-Disposable-Test/ \
    -keyout "$work/test.key" -out "$work/test.pem"
chmod 600 "$work/test.key"
cp "$work/test.pem" "$work/source/certs/btrfs-ipe-test.pem"
cat > "$work/source/security/ipe/btrfs-ipe-test.pol" <<'POLICY'
policy_name=btrfs_ipe_test policy_version=0.0.1
DEFAULT action=ALLOW
DEFAULT op=EXECUTE action=DENY
op=EXECUTE boot_verified=TRUE action=ALLOW
op=EXECUTE dmverity_signature=TRUE action=ALLOW
POLICY
cd "$work/source"
make defconfig
scripts/config --enable BTRFS_FS --enable OVERLAY_FS --enable BLK_DEV_DM \
    --enable DM_VERITY --enable DM_VERITY_VERIFY_ROOTHASH_SIG \
    --enable SECURITY --enable SECURITYFS --enable AUDIT --enable AUDITSYSCALL \
    --enable SECURITY_IPE --enable SYSTEM_TRUSTED_KEYRING \
    --enable IPE_PROP_DM_VERITY --enable IPE_PROP_DM_VERITY_SIGNATURE \
    --enable BLK_DEV_LOOP --enable DEVTMPFS --enable DEVTMPFS_MOUNT \
    --enable VIRTIO_PCI --enable VIRTIO_BLK --enable TMPFS --enable TMPFS_XATTR \
    --set-str SYSTEM_TRUSTED_KEYS certs/btrfs-ipe-test.pem \
    --set-str IPE_BOOT_POLICY security/ipe/btrfs-ipe-test.pol \
    --set-str LSM lockdown,yama,integrity,ipe \
    --set-str LOCALVERSION -b473-stock --disable LOCALVERSION_AUTO \
    --disable DEBUG_INFO --set-val LOG_BUF_SHIFT 20
make olddefconfig
grep -qx 'CONFIG_SECURITY_IPE=y' .config
grep -qx 'CONFIG_IPE_PROP_DM_VERITY_SIGNATURE=y' .config
make -j"$(nproc)" bzImage
cp arch/x86/boot/bzImage "$work/stock.bzImage"
cp .config "$work/stock.config"

ROOT="$work/root" PAYLOAD="$work/payload" python3 - <<'PY'
import os
import pathlib
import re
import shutil
import subprocess
root = pathlib.Path(os.environ["ROOT"])
payload = pathlib.Path(os.environ["PAYLOAD"])
for name in ("bin", "sbin", "proc", "sys", "dev", "tools/lib"):
    (root / name).mkdir(parents=True, exist_ok=True)
busybox = shutil.which("busybox")
description = subprocess.run(["ldd", busybox], capture_output=True, text=True)
if "statically linked" not in description.stdout + description.stderr and \
        "not a dynamic executable" not in description.stdout + description.stderr:
    raise RuntimeError("busybox-static is required")
shutil.copyfile(busybox, root / "bin/busybox")
(root / "bin/busybox").chmod(0o755)
for applet in subprocess.check_output([busybox, "--list"], text=True).splitlines():
    if applet != "busybox":
        (root / "bin" / applet).symlink_to("busybox")
def libraries(binary):
    return set(re.findall(r"(/[^\s()]+)", subprocess.check_output(["ldd", binary], text=True)))
for name in ("true", "ls", "bash"):
    binary = shutil.which(name)
    target = payload / "bin" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, target)
    for library in libraries(binary):
        target = payload / library.lstrip("/")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(library, target)
for name in ("veritysetup", "auditctl"):
    binary = shutil.which(name)
    shutil.copy2(binary, root / "tools" / name)
    for library in libraries(binary):
        shutil.copy2(library, root / "tools/lib" / pathlib.Path(library).name)
        if "ld-linux" in library:
            shutil.copy2(library, root / "tools/ld.so")
PY

for name in signed unsigned plain; do
    truncate -s 256M "$work/$name.img"
    mkfs.btrfs -f -m single -d single -r "$work/payload" "$work/$name.img"
done
for name in signed unsigned; do
    truncate -s 16M "$work/$name.hash.img"
    veritysetup format "$work/$name.img" "$work/$name.hash.img" \
        | tee "$work/$name.verity"
    awk '/Root hash:/ {printf "%s", $3}' "$work/$name.verity" > "$work/root/$name.hash"
    test "$(wc -c < "$work/root/$name.hash")" -eq 64
done
openssl cms -sign -binary -noattr -md sha256 \
    -in "$work/root/signed.hash" -signer "$work/test.pem" -inkey "$work/test.key" \
    -outform DER -out "$work/root/signed.p7b"
python3 - "$work/root/signed.p7b" "$work/root/corrupt.p7b" <<'PY'
import pathlib, sys
data = bytearray(pathlib.Path(sys.argv[1]).read_bytes())
data[-1] ^= 1
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
cp "$scripts/guest-init.sh" "$work/root/init"
chmod 755 "$work/root/init"
(cd "$work/root"; find . -print0 | cpio --null -o -H newc) | gzip > "$work/initramfs.gz"
run_vm stock "$work"
git apply --check "$patch_file"
git apply "$patch_file"
scripts/config --set-str LOCALVERSION -b473-patched
make olddefconfig
make -j"$(nproc)" bzImage
cp arch/x86/boot/bzImage "$work/patched.bzImage"
cp .config "$work/patched.config"
run_vm patched "$work"
python3 "$scripts/verify-results.py" "$work/stock.serial.log" "$work/patched.serial.log" \
    | tee "$work/result.json"
