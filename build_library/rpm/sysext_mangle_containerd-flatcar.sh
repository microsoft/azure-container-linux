#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -euo pipefail

bash "$(dirname "${BASH_SOURCE[0]}")/install_containerd_integration.sh" \
  "${1:?rootfs is required}" sysext
