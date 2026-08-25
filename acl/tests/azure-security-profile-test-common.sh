#!/bin/bash

SSH_OPTS=()

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

imds_security_profile() {
    local raw
    raw=$(ssh_cmd "curl -sf -H Metadata:true --noproxy '*' \
        'http://169.254.169.254/metadata/instance/compute/tagsList?api-version=2021-02-01'" \
        2>/dev/null) || return 1
    jq -r '.[] | select(.name=="acl-node-security-profile") | .value' <<<"$raw"
}

boot_id() {
    ssh_cmd 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null
}

set_security_profile_tag() {
    local value="$1"
    local vm_id

    # Use the generic ARM tag endpoint to avoid round-tripping unrelated VM
    # properties through the Compute RP.
    vm_id=$(az vm show --resource-group "$VM_RG" --name "$VM_NAME" --query id -o tsv)
    if [[ -z "$value" ]]; then
        info "Removing acl-node-security-profile tag..."
        az tag update \
            --resource-id "$vm_id" \
            --operation delete \
            --tags "acl-node-security-profile=" \
            --output none
    else
        info "Setting acl-node-security-profile=${value}..."
        az tag update \
            --resource-id "$vm_id" \
            --operation merge \
            --tags "acl-node-security-profile=${value}" \
            --output none
    fi

    info "Waiting for in-guest IMDS to report tag='${value:-<absent>}'..."
    local deadline=$(( $(date +%s) + 60 )) seen
    while (( $(date +%s) < deadline )); do
        seen=$(imds_security_profile) && [[ "$seen" == "$value" ]] && return 0
        sleep 2
    done
    error "IMDS did not converge to '${value:-<absent>}' within 60s"
    return 1
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

    local diag_dir="${DIAGNOSTICS_DIR:-/tmp}"
    mkdir -p "$diag_dir"
    local prefix="${diag_dir}/$(date +%Y%m%d-%H%M%S)-${VM_NAME}"
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

set_security_profile_and_reboot() {
    set_security_profile_tag "$1"
    reboot_and_wait
}
