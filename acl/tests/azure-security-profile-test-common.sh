#!/bin/bash

source "${SCRIPT_DIR}/build_library/rpm/additional_files/acl-node-security-profile.sh"

SSH_OPTS=()
SECURITY_PROFILE_TAG_NAME="acl-node-security-profile"
ORIGINAL_SECURITY_PROFILE_STATE=""
SECURITY_PROFILE_MUTATED=false

setup_ssh_opts() {
    SSH_OPTS=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o BatchMode=yes
        -o ConnectTimeout=10
        -o ServerAliveInterval=5
        -o ServerAliveCountMax=2
        -i "$VM_SSH_KEY"
    )
}

ssh_cmd() {
    ssh "${SSH_OPTS[@]}" "${VM_SSH_USER}@${VM_IP}" "$@"
}

imds_security_profile_state() {
    local raw
    raw=$(ssh_cmd "curl -sf -H Metadata:true --noproxy '*' \
        'http://169.254.169.254/metadata/instance/compute/tagsList?api-version=2021-02-01'" \
        2>/dev/null) || return 1
    jq -sce --arg tag "${SECURITY_PROFILE_TAG_NAME}" \
        "$(acl_security_profile_jq_filter)" <<<"${raw}"
}

imds_security_profile() {
    local state
    state="$(imds_security_profile_state)" || return 1
    jq -r 'if .present then .value else "" end' <<< "${state}"
}

azure_security_profile_state() {
    az vm show \
        --resource-group "${VM_RG}" \
        --name "${VM_NAME}" \
        --query tags \
        --output json |
        jq -ce --arg tag "${SECURITY_PROFILE_TAG_NAME}" '
            if type == "object" and has($tag) then
                if (.[$tag] | type) != "string" then
                    error("security profile tag value is not a string")
                else
                    {present: true, value: .[$tag]}
                end
            else
                {present: false, value: ""}
            end
        '
}

security_profile_with_key() {
    local profile="$1" target_key="$2" target_value="$3"
    local segment segment_key updated=""
    local -a segments=()

    IFS=',' read -r -a segments <<< "${profile}"
    for segment in "${segments[@]}"; do
        [[ -n "${segment}" ]] || continue
        segment_key="${segment%%=*}"
        [[ "${segment_key}" == "${target_key}" ]] && continue
        updated+="${updated:+,}${segment}"
    done
    updated+="${updated:+,}${target_key}=${target_value}"
    printf '%s\n' "${updated}"
}

boot_id() {
    ssh_cmd 'cat /proc/sys/kernel/random/boot_id' 2>>"${SECURITY_PROFILE_SSH_LOG:-/dev/null}"
}

capture_security_profile_diagnostic() {
    local output="$1" limit="$2" status=0
    shift 2

    timeout --signal=TERM --kill-after=5s "${limit}" "$@" \
        >"${output}" 2>"${output}.stderr" || status=$?
    printf '%s\n' "${status}" >"${output}.exit-code"
    if [[ "${status}" -ne 0 ]]; then
        warn "Diagnostic command failed (exit=${status}); see ${output}.stderr"
    fi
    return "${status}"
}

collect_security_profile_guest_diagnostics() {
    local output="$1"
    capture_security_profile_diagnostic "${output}" 30s \
        ssh "${SSH_OPTS[@]}" -v "${VM_SSH_USER}@${VM_IP}" "sudo -n sh -s" \
        <"${SCRIPT_DIR}/acl/tests/collect-security-profile-diagnostics.sh"
}

collect_security_profile_failure_diagnostics() {
    local prefix="$1" agent_script

    capture_security_profile_diagnostic "${prefix}/instance-view.json" 20s \
        az vm get-instance-view --resource-group "${VM_RG}" --name "${VM_NAME}" \
        --query 'instanceView.{statuses:statuses,vmAgent:vmAgent.statuses}' -o json ||
        warn "Could not collect VM instance view"
    capture_security_profile_diagnostic "${prefix}/serial.log" 30s \
        az vm boot-diagnostics get-boot-log --resource-group "${VM_RG}" --name "${VM_NAME}" ||
        warn "Could not collect the serial log"

    if ! collect_security_profile_guest_diagnostics "${prefix}/guest-timeout.log"; then
        warn "SSH diagnostics unavailable; trying bounded, read-only Azure Run Command (output tail only)"
        agent_script="$(printf '%s\n' "timeout --signal=TERM --kill-after=5s 45s sh <<'ACL_SECURITY_PROFILE_DIAGNOSTICS'"
            cat "${SCRIPT_DIR}/acl/tests/collect-security-profile-diagnostics.sh"
            printf '%s\n' 'ACL_SECURITY_PROFILE_DIAGNOSTICS')"
        capture_security_profile_diagnostic "${prefix}/run-command.json" 90s \
            az vm run-command invoke --resource-group "${VM_RG}" --name "${VM_NAME}" \
            --command-id RunShellScript --scripts "${agent_script}" -o json ||
            warn "Could not collect guest diagnostics through Azure Run Command"
    fi
    info "Failure diagnostics saved to ${prefix}; VM cleanup is unchanged"
}

set_security_profile_tag_state() {
    local state="$1"
    local present value vm_id

    # Use the generic ARM tag endpoint to avoid round-tripping unrelated VM
    # properties through the Compute RP.
    vm_id="$(az vm show --resource-group "$VM_RG" --name "$VM_NAME" --query id -o tsv)" || {
        error "Could not resolve the Azure VM resource ID"
        return 1
    }
    [[ -n "${vm_id}" ]] || {
        error "Azure VM resource ID is empty"
        return 1
    }
    if ! jq -e '
        type == "object" and
        (.present | type) == "boolean" and
        (.value | type) == "string"
    ' >/dev/null <<< "${state}"; then
        error "Invalid security profile tag state"
        return 1
    fi
    present="$(jq -r '.present' <<< "${state}")"
    value="$(jq -r '.value' <<< "${state}")"
    SECURITY_PROFILE_MUTATED=true
    if [[ "${present}" == "false" ]]; then
        info "Removing acl-node-security-profile tag..."
        if ! az tag update \
            --resource-id "$vm_id" \
            --operation delete \
            --tags "${SECURITY_PROFILE_TAG_NAME}=" \
            --output none; then
            error "Could not remove acl-node-security-profile"
            return 1
        fi
    else
        info "Setting acl-node-security-profile=${value}..."
        if ! az tag update \
            --resource-id "$vm_id" \
            --operation merge \
            --tags "${SECURITY_PROFILE_TAG_NAME}=${value}" \
            --output none; then
            error "Could not update acl-node-security-profile"
            return 1
        fi
    fi

    info "Waiting for in-guest IMDS to report the updated security profile..."
    local deadline seen_state
    deadline=$(( $(date +%s) + 60 ))
    while (( $(date +%s) < deadline )); do
        seen_state="$(imds_security_profile_state)" &&
            [[ "${seen_state}" == "${state}" ]] &&
            return 0
        sleep 2
    done
    error "IMDS did not converge to the requested security profile within 60s"
    return 1
}

set_security_profile_key() {
    local key="$1" value="$2"
    local current_profile updated_profile desired_state

    current_profile="$(imds_security_profile)" || {
        error "Could not read current acl-node-security-profile from IMDS"
        return 1
    }
    updated_profile="$(security_profile_with_key "${current_profile}" "${key}" "${value}")"
    desired_state="$(jq -cn --arg value "${updated_profile}" '{present: true, value: $value}')"
    set_security_profile_tag_state "${desired_state}"
}

capture_security_profile_state() {
    ORIGINAL_SECURITY_PROFILE_STATE="$(azure_security_profile_state)" || {
        error "Could not capture the original acl-node-security-profile tag"
        return 1
    }
    info "Captured the original acl-node-security-profile tag"
}

reboot_and_wait() {
    local old new reboot_timeout diag_dir prefix probe_status reboot_status=0
    reboot_timeout="${VM_BOOT_TIMEOUT:-$VM_SSH_TIMEOUT}"
    diag_dir="${DIAGNOSTICS_DIR:-/tmp}"
    mkdir -p "${diag_dir}" || { error "Cannot create diagnostics directory"; return 1; }
    prefix="$(mktemp -d "${diag_dir}/security-profile-${VM_NAME}.XXXXXX")" ||
        { error "Cannot create reboot diagnostics directory"; return 1; }
    local SECURITY_PROFILE_SSH_LOG="${prefix}/ssh-poll.log"
    if ! old=$(boot_id); then
        collect_security_profile_failure_diagnostics "${prefix}"
        error "Cannot read boot_id - VM unreachable?"
        return 1
    fi
    printf 'old_boot_id=%s\n' "${old}" >"${prefix}/reboot.log"
    collect_security_profile_guest_diagnostics "${prefix}/guest-before.log" ||
        warn "Pre-reboot guest snapshot incomplete; continuing the test"

    info "Rebooting VM ${VM_NAME} via SSH (old boot_id=${old})..."
    timeout --signal=TERM --kill-after=5s 15s \
        ssh "${SSH_OPTS[@]}" "${VM_SSH_USER}@${VM_IP}" "sudo reboot" \
        >"${prefix}/reboot-command.log" 2>&1 || reboot_status=$?
    printf 'reboot_command_exit=%s (SSH disconnect is expected)\n' "${reboot_status}" \
        >>"${prefix}/reboot.log"
    local deadline=$(( $(date +%s) + reboot_timeout ))
    while (( $(date +%s) < deadline )); do
        probe_status=0
        new=$(boot_id) || probe_status=$?
        printf '%s exit=%s boot_id=%s\n' "$(date -u +%FT%TZ)" "${probe_status}" "${new}" \
            >>"${prefix}/reboot.log"
        if [[ "${probe_status}" -eq 0 && "$new" != "$old" ]]; then
            info "VM rebooted (new boot_id=${new})"
            collect_security_profile_guest_diagnostics "${prefix}/guest-after.log" ||
                warn "Post-reboot guest snapshot incomplete; continuing the test"
            info "Reboot diagnostics saved to ${prefix}"
            return 0
        fi
        sleep 2
    done
    warn "VM did not come back after reboot within ${reboot_timeout}s - capturing VM diagnostics"
    collect_security_profile_failure_diagnostics "${prefix}"
    error "VM did not come back after reboot"
    return 1
}

set_security_profile_key_and_reboot() {
    set_security_profile_key "$1" "$2"
    reboot_and_wait
}

restore_security_profile_on_exit() {
    local primary_status=$?
    local final_status="${primary_status}"

    trap - EXIT
    if [[ "${SECURITY_PROFILE_MUTATED}" == "true" ]] &&
        [[ -n "${ORIGINAL_SECURITY_PROFILE_STATE}" ]]; then
        section "Restoring original acl-node-security-profile tag"
        if ! set_security_profile_tag_state "${ORIGINAL_SECURITY_PROFILE_STATE}" ||
            ! reboot_and_wait; then
            warn "Failed to restore the original security profile and reboot"
            [[ "${final_status}" -ne 0 ]] || final_status=1
        else
            info "Restored the original security profile"
        fi
    fi

    exit "${final_status}"
}
