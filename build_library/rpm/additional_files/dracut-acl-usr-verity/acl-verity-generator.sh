#!/bin/bash
set -euo pipefail
read -r cmdline < "${ACL_VERITY_CMDLINE_FILE:-/proc/cmdline}"
if [[ " ${cmdline} " == *" flatcar.oem.id=azure "* &&
      " ${cmdline} " == *" acl.verity_usr_signature="* ]]; then
    # This VMware-only helper Requires=/usr even when its Azure condition fails.
    # Mask it only for signed-root Azure initrd boots to avoid a network/verity cycle.
    mkdir -p "${2:?early generator directory}"
    ln -sf /dev/null "${2}/afterburn-network-kargs.service"
fi
