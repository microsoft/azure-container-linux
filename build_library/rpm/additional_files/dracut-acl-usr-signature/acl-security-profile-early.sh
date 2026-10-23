#!/bin/bash

set -euo pipefail

# shellcheck source=/usr/lib/acl/acl-node-security-profile.sh
source "${ACL_SECURITY_PROFILE_HELPER:-/usr/lib/acl/acl-node-security-profile.sh}"

export ACL_SECURITY_PROFILE_EARLY=true
acl_security_profile >/dev/null
