#!/bin/bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

ipe_verity_write_roothash() {
    local roothash="${1,,}" output="$2"

    [[ "${roothash}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${roothash}" > "${output}"
}
