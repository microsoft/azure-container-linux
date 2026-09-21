#!/bin/bash
# shellcheck disable=SC2034 # Variables below are consumed by extracted functions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
AZURE_SCRIPT="${SCRIPT_DIR}/ci-automation/vendor-testing/azure.sh"

eval "$(
    sed -n \
        -e '/^validate_trusted_launch_generation() {/,/^}/p' \
        -e '/^should_schedule_v1() {/,/^}/p' \
        "${AZURE_SCRIPT}"
)"

AZURE_TRUSTED_LAUNCH=true
validate_trusted_launch_generation V2
if validate_trusted_launch_generation V1 2>/dev/null; then
    echo "Trusted Launch accepted a Generation 1 VM" >&2
    exit 1
fi

AZURE_DISK_URI=""
if should_schedule_v1; then
    echo "Trusted Launch scheduled the automatic Generation 1 test" >&2
    exit 1
fi

AZURE_TRUSTED_LAUNCH=false
should_schedule_v1

AZURE_DISK_URI="/subscriptions/example/gallery/version"
if should_schedule_v1; then
    echo "gallery image scheduled an incompatible Generation 1 test" >&2
    exit 1
fi

echo "Azure Trusted Launch generation tests passed"
