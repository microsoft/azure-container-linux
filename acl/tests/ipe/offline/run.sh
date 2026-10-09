#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shopt -s nullglob
tests=("${TEST_DIR}"/test-*.sh)

if [[ ${#tests[@]} -eq 0 ]]; then
    echo "No offline IPE tests found in ${TEST_DIR}" >&2
    exit 1
fi

for test in "${tests[@]}"; do
    echo "=== Running ${test##*/} ==="
    "${test}"
done

echo "Offline IPE test suite passed"
