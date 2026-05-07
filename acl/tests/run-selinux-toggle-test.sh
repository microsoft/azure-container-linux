#!/bin/bash
# Test the acl-selinux-toggle dracut module: set an Azure VM tag, reboot,
# and verify SELinux mode changed. Requires an already-provisioned Azure VM.

set -euo pipefail

source "${SCRIPT_DIR}/acl/validate_common.sh"

# ── Helpers ────────────────────────────────────────────────────────

SSH_OPTS=()

setup_ssh_opts() {
    SSH_OPTS=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o BatchMode=yes
        -o ConnectTimeout=10
        -i "$VM_SSH_KEY"
    )
}

ssh_cmd() {
    ssh "${SSH_OPTS[@]}" "${VM_SSH_USER}@${VM_IP}" "$@"
}

# Get current SELinux mode via getenforce.
get_selinux_mode() {
    ssh_cmd "sudo getenforce" 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

# Set (or remove) the acl-node-security-profile tag on the Azure VM.
set_selinux_tag() {
    local value="$1"
    if [[ -z "$value" ]]; then
        info "Removing acl-node-security-profile tag..."
        az vm update \
            --resource-group "$VM_RG" \
            --name "$VM_NAME" \
            --remove tags.acl-node-security-profile \
            --output none 2>/dev/null || true
    else
        info "Setting acl-node-security-profile=${value}..."
        az vm update \
            --resource-group "$VM_RG" \
            --name "$VM_NAME" \
            --set "tags.acl-node-security-profile=${value}" \
            --output none
    fi
}

# Reboot the VM (in-guest via SSH) and wait for it to come back.
# `sudo reboot` kills sshd before the session can return cleanly, so ssh
# exits 255; ignore that and rely on wait_for_ssh to detect real failure.
reboot_and_wait() {
    info "Rebooting VM ${VM_NAME} via SSH..."
    ssh_cmd "sudo reboot" || true
    info "Waiting for VM to come back up..."
    sleep 10
    if wait_for_ssh "$VM_IP" "$VM_SSH_TIMEOUT"; then
        return 0
    fi
    warn "SSH did not return after reboot — capturing VM diagnostics"

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

# Assert that SELinux is in the expected mode.
assert_selinux_mode() {
    local expected="$1"
    local actual
    actual=$(get_selinux_mode)
    if [[ "$actual" == "$expected" ]]; then
        info "✅ SELinux mode is '${actual}' (expected '${expected}')"
        return 0
    else
        error "❌ SELinux mode is '${actual}' but expected '${expected}'"
        return 1
    fi
}

# ── Main ───────────────────────────────────────────────────────────

main() {
    parse_validate_args "$@"

    section "SELinux Toggle Test"

    if [[ "$VM_TYPE" != "azure" ]]; then
        info "Skipping SELinux toggle test (requires Azure VM with IMDS)"
        exit 0
    fi

    read_vm_state
    setup_ssh_opts

    info "VM: ${VM_NAME} (RG: ${VM_RG}, IP: ${VM_IP})"

    if ! wait_for_ssh "$VM_IP" "$VM_SSH_TIMEOUT"; then
        error "Cannot reach VM via SSH"
        exit 1
    fi

    local exit_code=0

    # Step 1: Record the starting mode (expected: enforcing).
    section "Step 1: Check initial SELinux mode"
    local initial_mode
    initial_mode=$(get_selinux_mode)
    info "Current SELinux mode: ${initial_mode}"

    if [[ "$initial_mode" != "enforcing" ]]; then
        warn "Expected initial mode 'enforcing' but got '${initial_mode}'"
        warn "The test will still toggle and verify, but the baseline is unexpected."
    fi

    # Step 2: Toggle to permissive (with extra k/v to exercise comma-separated parsing).
    section "Step 2: Toggle SELinux to permissive via IMDS tag"
    set_selinux_tag "selinux=permissive,foo=bar"
    reboot_and_wait
    if ! assert_selinux_mode "permissive"; then
        exit_code=1
    fi

    # Step 3: Toggle back to enforcing.
    section "Step 3: Toggle SELinux back to enforcing via IMDS tag"
    set_selinux_tag "selinux=enforcing"
    reboot_and_wait
    if ! assert_selinux_mode "enforcing"; then
        exit_code=1
    fi

    # Step 4: Clean up — remove the tag, reboot, verify mode stays enforcing.
    section "Step 4: Cleanup — remove tag and reboot"
    set_selinux_tag ""
    reboot_and_wait
    if ! assert_selinux_mode "enforcing"; then
        exit_code=1
    fi

    # Summary
    section "SELinux Toggle Test Summary"
    if [[ "$exit_code" -eq 0 ]]; then
        info "✅ All SELinux toggle assertions passed"
    else
        error "❌ One or more assertions failed"
    fi

    exit "$exit_code"
}

main "$@"
