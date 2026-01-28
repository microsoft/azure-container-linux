#!/bin/bash
# Compare kernel configs from two comparison-data.json files using diffconfig
#
# Usage:
#   ./kconfig_diff.sh <json_file_1> <json_file_2>
#
# Example:
#   ./kconfig_diff.sh file1-comparison-data.json file2-comparison-data.json

set -euo pipefail

DIFFCONFIG="${DIFFCONFIG:-/usr/src/linux-headers-$(uname -r)/scripts/diffconfig}"

usage() {
    echo "Usage: $0 <json_file_1> <json_file_2>"
    echo ""
    echo "Extract kernel configs from comparison-data.json files and run diffconfig."
    echo ""
    echo "Environment variables:"
    echo "  DIFFCONFIG    Path to diffconfig script (default: /usr/src/linux-headers-\$(uname -r)/scripts/diffconfig)"
    exit 1
}

if [[ $# -ne 2 ]]; then
    usage
fi

FILE1="$1"
FILE2="$2"

for f in "$FILE1" "$FILE2"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: File not found: $f" >&2
        exit 1
    fi
done

if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not installed" >&2
    exit 1
fi

if [[ ! -x "$DIFFCONFIG" ]]; then
    echo "Error: diffconfig not found or not executable at: $DIFFCONFIG" >&2
    echo "Set DIFFCONFIG environment variable to specify location" >&2
    exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

CONFIG1="$TMPDIR/config1"
CONFIG2="$TMPDIR/config2"

jq -r '.kernel_config.raw' "$FILE1" > "$CONFIG1"
jq -r '.kernel_config.raw' "$FILE2" > "$CONFIG2"

echo "# Kernel config diff: $(basename "$FILE1") -> $(basename "$FILE2")"
echo "# File 1: $FILE1"
echo "# File 2: $FILE2"
echo ""

"$DIFFCONFIG" "$CONFIG1" "$CONFIG2"
