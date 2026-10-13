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

cat > "${TEST_DIR}/indented.sh" <<'EOF'
indented() {
    printf 'indented\n'
    }
printf 'executed\n' > "${TEST_DIR}/main-ran"
EOF
source_test_functions "${TEST_DIR}/indented.sh" indented
[[ "$(indented)" == indented ]]
[[ ! -e "${TEST_DIR}/main-ran" ]]

cat > "${TEST_DIR}/formatting.sh" <<'EOF'
printf 'executed\n' > "${TEST_DIR}/main-ran"
nested() {
    {
        printf 'nested\n'
}
    printf 'tail\n'
} # A closing brace may have a comment.
heredoc() {
    cat <<'JSON'
{
    "value": "}"
}
JSON
}
quoted() {
    printf '%s\n' "${1:-}}" '{' \
        'quoted
}
text'
    # A comment containing } must not close the function.
}
printf 'executed\n' > "${TEST_DIR}/main-ran"
EOF

source_test_functions "${TEST_DIR}/formatting.sh" nested heredoc quoted
[[ "$(nested)" == $'nested\ntail' ]]
[[ "$(heredoc)" == $'{\n    "value": "}"\n}' ]]
[[ "$(quoted)" == $'}\n{\nquoted\n}\ntext' ]]
[[ ! -e "${TEST_DIR}/main-ran" ]]

printf 'no_newline() {\n    printf "loaded\\n"\n    }' > "${TEST_DIR}/no-newline.sh"
source_test_functions "${TEST_DIR}/no-newline.sh" no_newline
[[ "$(no_newline)" == loaded ]]

cat > "${TEST_DIR}/trailing.sh" <<'EOF'
trailing() {
    :
}; printf 'executed\n' > "${TEST_DIR}/main-ran"
trailing_compound() {
    :
}; printf 'executed\n' > "${TEST_DIR}/main-ran"; another() {
    :
}
redirected() {
    :
} > "${TEST_DIR}/main-ran"
pending_heredoc() {
    cat <<'PAYLOAD'; }
}
PAYLOAD
printf 'executed\n' > "${TEST_DIR}/main-ran"
EOF

for name in trailing trailing_compound redirected pending_heredoc; do
    assert_extraction_fails "${TEST_DIR}/trailing.sh" "${name}"
    if declare -F "${name}" >/dev/null; then
        printf 'Rejected function was defined: %s\n' "${name}" >&2
        exit 1
    fi
    [[ ! -e "${TEST_DIR}/main-ran" ]]
done

echo "Function extraction contract tests passed"
