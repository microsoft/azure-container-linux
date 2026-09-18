#!/bin/bash
#
# Check that generate_package_manifest.py emits the expected SPDX 2.2 document.
#
# Usage: test_generate_package_manifest.sh [workdir]

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR="${TESTS_DIR}/../generate_package_manifest.py"

# Conformance is a property of the generator, not of any one rootfs, so this is
# run against a fixture instead of inside the image build. This file is a real
# capture from an ACL production image, trimmed, plus one epoch-bearing entry,
# one non-native arch, and one entry carrying no vendor.
#
# container-manifest-2 is the layout both image and sysext builds feed the
# generator because it includes the RPM vendor.
CONTAINER_MANIFEST_2_PACKAGES_FILE="${TESTS_DIR}/testdata/container-manifest-2-packages.txt"

# When a change to the emitted document is intentional, pass <workdir> to the
# script, copy the output to the golden file, then re-validate it:
#     cp "${WORK_DIR}/package-manifest.spdx.json" testdata/expected-manifest.spdx.json
#     ./validate_golden_manifest.sh
GOLDEN_FILE="${TESTS_DIR}/testdata/expected-manifest.spdx.json"

# Keep a caller-supplied <workdir> so its output can be inspected, or clean up
# one we made ourselves so we don't leave scratch files behind on a local run.
if [[ $# -ge 1 ]]; then
    WORK_DIR="${1}"
else
    WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "${WORK_DIR}"' EXIT
fi
mkdir -p "${WORK_DIR}"

MANIFEST="${WORK_DIR}/package-manifest.spdx.json"
MANIFEST_AGAIN="${MANIFEST}.again"
MANIFEST_NORMALIZED="${MANIFEST}.normalized"

MANIFEST_NAME="azurecontainerlinux"
MANIFEST_VERSION="0.0.0-spec-conformance"
CREATED_EPOCH=1735689600

echo "=== Generating manifest from ${CONTAINER_MANIFEST_2_PACKAGES_FILE##*/} using the default format ==="
"${GENERATOR}" \
    --packages-file="${CONTAINER_MANIFEST_2_PACKAGES_FILE}" \
    --manifest-file="${MANIFEST}" \
    --manifest-name="${MANIFEST_NAME}" \
    --manifest-version="${MANIFEST_VERSION}" \
    --created-epoch="${CREATED_EPOCH}" \
    --force

echo "=== Checking the generator is byte-identical on a second run ==="
"${GENERATOR}" \
    --packages-file="${CONTAINER_MANIFEST_2_PACKAGES_FILE}" \
    --packages-format=container-manifest-2 \
    --manifest-file="${MANIFEST_AGAIN}" \
    --manifest-name="${MANIFEST_NAME}" \
    --manifest-version="${MANIFEST_VERSION}" \
    --created-epoch="${CREATED_EPOCH}" \
    --force
cmp "${MANIFEST}" "${MANIFEST_AGAIN}"

echo "=== Comparing against ${GOLDEN_FILE##*/} ==="
sed -E 's|("Tool: generate_package_manifest)-[0-9a-f]{64}"|\1"|' \
    "${MANIFEST}" > "${MANIFEST_NORMALIZED}"
diff -u "${GOLDEN_FILE}" "${MANIFEST_NORMALIZED}"

echo "=== PASS ==="
