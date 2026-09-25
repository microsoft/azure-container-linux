#!/bin/bash

set -euo pipefail

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT
# shellcheck disable=SC1091 # Resolve the helper beside this test at runtime.
source "$(dirname "${BASH_SOURCE[0]}")/function-extraction.sh"

cat > "${TEST_DIR}/entrypoint.sh" <<'EOF'
example() {
    printf 'loaded\n'
}
printf 'executed\n' > "${TEST_DIR}/main-ran"
EOF

source_test_functions "${TEST_DIR}/entrypoint.sh" example
[[ "$(example)" == "loaded" ]]
[[ ! -e "${TEST_DIR}/main-ran" ]]

assert_extraction_fails() {
    if source_test_functions "$@" >/dev/null 2>&1; then
        printf 'Invalid function extraction succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

assert_extraction_fails
assert_extraction_fails "${TEST_DIR}/entrypoint.sh"
assert_extraction_fails "${TEST_DIR}/entrypoint.sh" 'example; echo injected'
assert_extraction_fails "${TEST_DIR}/entrypoint.sh" missing

cat > "${TEST_DIR}/incomplete.sh" <<'EOF'
incomplete() {
    printf 'missing closing brace\n'
EOF
assert_extraction_fails "${TEST_DIR}/incomplete.sh" incomplete

echo "Function extraction contract tests passed"
