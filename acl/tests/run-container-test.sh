#!/bin/bash
# Smoke test: pull and run an nginx container, verifying the container runtime works.
# On QEMU VMs, build_rpm_image.sh follows up with a curl check against the VM IP.
# On Azure VMs, the NSG doesn't expose port 80, so the curl check is skipped —
# a successful exit from this script is sufficient to validate container functionality.
set -euo pipefail

iptables -I INPUT -p tcp --dport 80 -j ACCEPT
# Network-isolated CI blocks Docker Hub; use the multi-arch Azure Linux image in MCR.
image="mcr.microsoft.com/azurelinux/base/nginx:1"
ctr image pull "${image}" > /dev/null
ctr run --detach --net-host "${image}" nginx
sleep 2
