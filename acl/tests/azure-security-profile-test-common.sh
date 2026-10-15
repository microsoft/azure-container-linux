#!/bin/bash
# Shared host-side IPE/SELinux helpers for Azure profile changes and reboots.
# Provide exit cleanup that restores the original profile after test mutations.

source "${SCRIPT_DIR}/build_library/rpm/additional_files/acl-node-security-profile.sh"

SSH_OPTS=()
SECURITY_PROFILE_TAG_NAME="acl-node-security-profile"
ORIGINAL_SECURITY_PROFILE_STATE=""
SECURITY_PROFILE_MUTATED=false
SECURITY_PROFILE_DIAGNOSTICS_PREFIX=""
SECURITY_PROFILE_DIAGNOSTICS_CAPTURED=false

security_profile_diagnostics_enabled() {
    [[ -n "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}" ]]
}

security_profile_diag() {
    security_profile_diagnostics_enabled || return 0
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" "$*" \
        >> "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-events.log"
}

security_profile_diagnostic_read() {
    local name="$1" status=0
    shift
    timeout --signal=TERM --kill-after=5s 20s "$@" \
        > "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-${name}.stdout" \
        2> "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-${name}.stderr" || status=$?
    security_profile_diag "snapshot=${name} status=${status}"
}

capture_security_profile_diagnostics() {
    security_profile_diagnostics_enabled || return 0
    [[ "${SECURITY_PROFILE_DIAGNOSTICS_CAPTURED}" == "false" ]] || return 0
    SECURITY_PROFILE_DIAGNOSTICS_CAPTURED=true
    security_profile_diag "snapshot-start reason=$1"

    security_profile_diagnostic_read vm az vm show -g "$VM_RG" -n "$VM_NAME" \
        --query '{id:id,tags:tags,networkProfile:networkProfile,provisioningState:provisioningState}' -o json
    security_profile_diagnostic_read instance az vm get-instance-view -g "$VM_RG" -n "$VM_NAME" -o json
    security_profile_diagnostic_read activity az monitor activity-log list \
        --resource-group "$VM_RG" --offset 30m --max-events 200 -o json

    local nic_id uri status=0
    nic_id="$(jq -r '.networkProfile.networkInterfaces[0].id // empty' \
        "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-vm.stdout" 2>/dev/null)" || true
    if [[ -n "${nic_id}" ]]; then
        security_profile_diagnostic_read nic az network nic show --ids "${nic_id}" -o json
        security_profile_diagnostic_read effective-nsg az network nic list-effective-nsg \
            --ids "${nic_id}" -o json
    fi

    # Resolve the SAS URL in memory only; never publish it in diagnostics.
    uri="$(timeout --signal=TERM --kill-after=5s 20s \
        az vm boot-diagnostics get-boot-log-uris -g "$VM_RG" -n "$VM_NAME" \
        --query serialConsoleLogBlobUri -o tsv \
        2> "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-serial-uri.stderr")" || status=$?
    security_profile_diag "snapshot=serial-uri status=${status}"
    if [[ "${status}" -eq 0 && -n "${uri}" ]]; then
        status=0
        curl -fsS --connect-timeout 10 --max-time 30 "${uri}" \
            > "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-serial.log" \
            2> "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-serial.stderr" || status=$?
        security_profile_diag "snapshot=serial status=${status}"
    fi

    security_profile_diagnostic_read guest ssh "${SSH_OPTS[@]}" "${VM_SSH_USER}@${VM_IP}" '
        date -u; cat /proc/sys/kernel/random/boot_id; cat /proc/cmdline
        sudo getenforce; sudo cat /sys/kernel/security/ipe/enforce
        sudo cat /sys/kernel/security/ipe/policies/acl_ipe_boot_policy/active
        systemctl show sshd.socket -p ActiveState -p SubState -p Result \
            -p NAccepted -p NConnections -p MaxConnections \
            -p TriggerLimitBurst -p TriggerLimitIntervalUSec
        ip route get 169.254.169.254
        sudo journalctl -b --no-pager -o short-precise -n 4000
    '
    security_profile_diag "snapshot-end"
}

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
    if [[ "${ACL_SECURITY_PROFILE_DIAGNOSTICS:-0}" == "1" && -n "${DIAGNOSTICS_DIR:-}" ]]; then
        mkdir -p "${DIAGNOSTICS_DIR}"
        SECURITY_PROFILE_DIAGNOSTICS_PREFIX="${DIAGNOSTICS_DIR}/security-profile-${BASHPID}"
        SSH_OPTS+=(-vv -E "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-ssh.log")
    fi
}

ssh_cmd() {
    ssh "${SSH_OPTS[@]}" "${VM_SSH_USER}@${VM_IP}" "$@"
}

imds_security_profile_state() {
    local raw
    if security_profile_diagnostics_enabled; then
        local status=0 state
        security_profile_diag "probe-start"
        raw=$(ssh_cmd "printf 'ACL_SSH_CONNECTION=%s\n' \"\${SSH_CONNECTION:-}\" >&2; \
            curl -sfS -H Metadata:true --noproxy '*' \
            -w '%{stderr}ACL_IMDS_HTTP_STATUS=%{http_code}\n' \
            'http://169.254.169.254/metadata/instance/compute/tagsList?api-version=2021-02-01'" \
            2>> "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-imds.stderr") || status=$?
        security_profile_diag "probe-ssh-or-remote-exit=${status}"
        [[ "${status}" -eq 0 ]] || return 1
        state="$(jq -sce --arg tag "${SECURITY_PROFILE_TAG_NAME}" \
            "$(acl_security_profile_jq_filter)" <<< "${raw}" \
            2>> "${SECURITY_PROFILE_DIAGNOSTICS_PREFIX}-parse.stderr")" || status=$?
        security_profile_diag "probe-parser-exit=${status} observed=${state}"
        [[ "${status}" -ne 0 ]] || printf '%s\n' "${state}"
        return "${status}"
    fi
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
    ssh_cmd 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null
}

set_security_profile_tag_state() {
    local state="$1"
    local present value vm_id
    security_profile_diag "requested=${state}"

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
    local deadline seen_state attempts=0
    deadline=$(( $(date +%s) + 60 ))
    while (( $(date +%s) < deadline )); do
        attempts=$((attempts + 1))
        security_profile_diag "poll-attempt=${attempts}"
        seen_state="$(imds_security_profile_state)" &&
            [[ "${seen_state}" == "${state}" ]] &&
            return 0
        sleep 2
    done
    security_profile_diag "poll-timeout attempts=${attempts}"
    capture_security_profile_diagnostics "imds-timeout" || true
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
    local old new reboot_timeout
    reboot_timeout="${VM_BOOT_TIMEOUT:-$VM_SSH_TIMEOUT}"
    old=$(boot_id) || { error "Cannot read boot_id - VM unreachable?"; return 1; }
    info "Rebooting VM ${VM_NAME} via SSH (old boot_id=${old})..."
    timeout --signal=TERM --kill-after=5s 15s \
        ssh "${SSH_OPTS[@]}" "${VM_SSH_USER}@${VM_IP}" "sudo reboot" || true
    local deadline=$(( $(date +%s) + reboot_timeout ))
    while (( $(date +%s) < deadline )); do
        new=$(boot_id) && [[ "$new" != "$old" ]] && {
            info "VM rebooted (new boot_id=${new})"
            return 0
        }
        sleep 2
    done
    warn "VM did not come back after reboot within ${reboot_timeout}s - capturing VM diagnostics"
    if security_profile_diagnostics_enabled; then
        capture_security_profile_diagnostics "reboot-timeout" || true
        error "VM did not come back after reboot"
        return 1
    fi

    local diag_dir prefix
    diag_dir="${DIAGNOSTICS_DIR:-/tmp}"
    mkdir -p "$diag_dir"
    prefix="${diag_dir}/$(date +%Y%m%d-%H%M%S)-${VM_NAME}"
    az vm get-instance-view --resource-group "$VM_RG" --name "$VM_NAME" \
        --query 'instanceView.{statuses:statuses,vmAgent:vmAgent.statuses}' \
        -o json 2>&1 | tee "${prefix}-instance-view.json" || true
    az vm boot-diagnostics get-boot-log --resource-group "$VM_RG" --name "$VM_NAME" 2>&1 \
        | jq -r . > "${prefix}-serial.log" || true

    info "Full serial log: ${prefix}-serial.log ($(wc -c <"${prefix}-serial.log") bytes); last 200 lines:"
    tail -200 "${prefix}-serial.log" | sed 's/^/  [serial] /' || true
    info "Diagnostics saved to ${prefix}-{instance-view.json,serial.log}"
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
    if [[ "${primary_status}" -ne 0 ]]; then
        capture_security_profile_diagnostics "exit-${primary_status}" || true
    fi
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
