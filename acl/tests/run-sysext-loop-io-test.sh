#!/bin/bash
# Validate the buffered-loop vendor default on a freshly booted Azure ACL image.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

dropin=/usr/lib/systemd/system/systemd-sysext.service.d/60-loop-buffered-io.conf
[[ -r "${dropin}" ]] || fail "Buffered-loop vendor drop-in is missing"

echo "Boot ID: $(cat /proc/sys/kernel/random/boot_id)"
echo "Kernel: $(uname -r)"
cat "${dropin}"
systemctl show systemd-sysext.service -p Environment -p ActiveState -p Result -p DropInPaths
systemctl is-active --quiet systemd-sysext.service ||
    fail "Sysext service is not active"
[[ "$(systemctl show systemd-sysext.service -p Result --value)" == success ]] ||
    fail "Sysext service did not complete successfully"

dropins="$(systemctl show systemd-sysext.service -p DropInPaths --value)"
[[ " ${dropins} " == *" ${dropin} "* ]] ||
    fail "Systemd did not load the vendor drop-in"
environment="$(systemctl show systemd-sysext.service -p Environment --value)"
[[ " ${environment} " == *" SYSTEMD_LOOP_DIRECT_IO=0 "* ]] ||
    fail "Sysext service does not have buffered loop I/O enabled"

loops="$(sudo losetup --json --list --output NAME,BACK-FILE,DIO,LOG-SEC)"
printf '%s\n' "${loops}"
printf '%s\n' "${loops}" | jq -e '
    [.loopdevices[] |
        select((.["back-file"] // "") |
            test("(^|/)containerd\\.raw$|(^|/)oem-azure-[^/]+\\.raw$"))] |
    any(.[]; .["back-file"] | endswith("/containerd.raw")) and
    any(.[]; .["back-file"] | contains("/oem-azure-")) and
    all(.[]; .dio == false or .dio == 0 or .dio == "0")
' > /dev/null || fail "Expected containerd/OEM sysext loops are missing or not buffered"

echo "PASS: vendor drop-in loaded, service environment applied, containerd/OEM loops use DIO=0"
