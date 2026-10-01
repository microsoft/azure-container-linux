#!/bin/bash

# Load named functions without executing an entry-point script's main().
source_test_functions() {
    if [[ $# -lt 2 || ! -f "$1" ]]; then
        echo "Expected a script and at least one function name" >&2
        return 1
    fi

    local file="$1" name definition
    shift

    for name; do
        if [[ ! "${name}" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]]; then
            echo "Invalid function name: ${name}" >&2
            return 1
        fi
        definition="$(sed -n "/^${name}() {/,/^}/p" "${file}")"
        if [[ "${definition}" != "${name}() {"$'\n'* ]] ||
            ! bash -n <<< "${definition}"; then
            echo "Could not extract complete function ${name} from ${file}" >&2
            return 1
        fi
        eval "${definition}"
    done
}
