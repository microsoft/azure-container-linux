#!/bin/bash

# Load functions with name() { headers without executing top-level script code.
# Only whitespace or a comment may follow the closing brace.
source_test_functions() {
    if [[ $# -lt 2 || ! -f "$1" ]]; then
        echo "Expected a script and at least one function name" >&2
        return 1
    fi

    local file="$1" name definition line diagnostics complete
    shift

    for name; do
        if [[ ! "${name}" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]]; then
            echo "Invalid function name: ${name}" >&2
            return 1
        fi
        definition=""
        complete=false
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ -z "${definition}" && "${line}" != "${name}() {" ]]; then
                continue
            fi

            # Let Bash distinguish closing braces from quoted text and heredocs.
            while [[ "${line}" == *'}'* ]]; do
                definition+="${line%%\}*}}"
                line="${line#*\}}"
                if diagnostics="$(bash -n <<< "${definition}" 2>&1)"; then
                    if [[ -n "${diagnostics}" ||
                        ! "${line}" =~ ^([[:space:]]+#.*|[[:space:]]*)$ ]]; then
                        echo "Unsupported trailing syntax in function ${name} from ${file}" >&2
                        return 1
                    fi
                    complete=true
                    break
                fi
            done
            [[ "${complete}" == true ]] && break
            definition+="${line}"$'\n'
        done < "${file}"

        if [[ "${complete}" != true ]]; then
            echo "Could not extract complete function ${name} from ${file}" >&2
            return 1
        fi
        eval "${definition}"
    done
}
