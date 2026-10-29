#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
ENTRYPOINT="$(tr -d '\r' < "${SCRIPT_DIR}/.pipelines/github-pr-validation.yml")"

assert_contract() {
    local name="$1" expected="$2"
    if [[ "${ENTRYPOINT}" != *"${expected}"* ]]; then
        printf 'GitHub PR validation contract failed: %s\n' "${name}" >&2
        printf 'Expected entrypoint block:\n%s\n' "${expected}" >&2
        exit 1
    fi
}

if grep -Eq '^parameters[[:space:]]*:' <<< "${ENTRYPOINT}" ||
    grep -Eq '\$\{\{[[:space:]]*parameters(\.|\[)' <<< "${ENTRYPOINT}"; then
    echo "GitHub PR validation must use fixed settings without queue-time parameters" >&2
    exit 1
fi

assert_contract "unchanged PR triggers" "$(cat <<'YAML'
trigger: none
YAML
)"
assert_contract "aclmain and release PR coverage" "$(cat <<'YAML'
pr:
  branches:
    include:
      - aclmain
      - release/*
YAML
)"

assert_contract "shared template repository remains on main" "$(cat <<'YAML'
    - repository: acl_pipelines
      type: git
      name: ACL/acl-pipelines
      ref: refs/heads/main
YAML
)"
assert_contract "ACL resource follows the PR source" "$(cat <<'YAML'
    - repository: azure_container_linux
      type: github
      endpoint: github.com_acl
      name: microsoft/azure-container-linux
      ref: $(Build.SourceBranch)
YAML
)"
assert_contract "Mantle resource remains on aclmain" "$(cat <<'YAML'
    - repository: mantle
      type: github
      endpoint: github.com_acl
      name: microsoft/azure-container-linux-mantle
      ref: refs/heads/aclmain
YAML
)"

assert_contract "ephemeral IPE on PR sources with shared build and smoke defaults" "$(cat <<'YAML'
extends:
  template: pipelines/ACL-GitHub-PR.yml@acl_pipelines
  parameters:
    aclRef: $(Build.SourceBranch)
    mantleRef: 'aclmain'
    ipeMode: 'audit'
    ipeSigningMode: 'ephemeral'
    rootHashSigningEnabled: true
    testGeneratePackageManifest: true
YAML
)"

echo "IPE GitHub PR validation contract tests passed"
