#!/bin/bash
# Query Azure IMDS for an "acl-node-security-profile" tag and set SELinux
# mode before switch-root. The tag value is a comma-separated list of k/v
# pairs, e.g. "selinux=enforcing,...". Runs in the initrd so SELinux is
# configured before real-root services start.

set -euo pipefail

source /usr/lib/acl/acl-node-security-profile.sh

if ! security_profile="$(acl_security_profile)"; then
  exit 1
fi

if [ -z "${security_profile}" ]; then
  echo "ACL: IMDS reached but no acl-node-security-profile tag set, leaving SELinux mode unchanged" >&2
  exit 0
fi

selinux_mode="$(acl_security_profile_value "${security_profile}" "selinux")"

case "${selinux_mode}" in
  permissive)
    echo "ACL: acl-node-security-profile selinux=permissive found, setting SELinux to permissive" >&2
    sed -i "s/^SELINUX=enforcing/SELINUX=permissive/" /sysroot/etc/selinux/config
    ;;
  enforcing)
    echo "ACL: acl-node-security-profile selinux=enforcing found, setting SELinux to enforcing" >&2
    sed -i "s/^SELINUX=permissive/SELINUX=enforcing/" /sysroot/etc/selinux/config
    ;;
  "")
    echo "ACL: acl-node-security-profile tag found but no selinux key present, leaving SELinux mode unchanged" >&2
    ;;
  *)
    echo "ACL: acl-node-security-profile selinux key has unrecognized value '${selinux_mode}', leaving SELinux mode unchanged" >&2
    ;;
esac
