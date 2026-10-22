#!/bin/bash

set -euo pipefail

# shellcheck source=/usr/lib/acl/acl-node-security-profile.sh
source "${ACL_SECURITY_PROFILE_HELPER:-/usr/lib/acl/acl-node-security-profile.sh}"

case "${1:-}" in
    lookup)
        export ACL_SECURITY_PROFILE_EARLY=true
        acl_security_profile >/dev/null
        ;;
    finalize)
        acl_security_profile_finalize
        ;;
    *)
        echo "Usage: acl-security-profile-early lookup|finalize" >&2
        exit 1
        ;;
esac
