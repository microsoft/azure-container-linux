#!/bin/bash
# Test the acl-selinux-toggle dracut module: set an Azure VM tag, reboot,
# and verify SELinux mode changed. Requires an already-provisioned Azure VM.

set -euo pipefail

source "${SCRIPT_DIR}/acl/validate/validate_common.sh"

# ── Helpers ────────────────────────────────────────────────────────

# Get current SELinux mode via getenforce.
get_selinux_mode() {
    ssh_cmd "sudo getenforce" 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

# Read the acl-node-security-profile tag value as IMDS sees it from the VM.
# Returns non-zero if the IMDS request fails or the response cannot be parsed.
imds_tag() {
    local raw
    raw=$(ssh_cmd "curl -sf -H Metadata:true --noproxy '*' \
        'http://169.254.169.254/metadata/instance/compute/tagsList?api-version=2021-02-01'" \
        2>/dev/null) || return 1
    jq -r '.[] | select(.name=="acl-node-security-profile") | .value' <<<"$raw"
}

# Set (or remove) the tag on the VM, then wait for in-guest IMDS to converge.
#
# Uses the generic ARM tag endpoint (`az tag update`) rather than
# `az vm update --set tags.…`. The latter round-trips the whole VM resource
# through the Compute RP, so it can fail on unrelated VM properties.
set_selinux_tag() {
    local value="$1"
    local vm_id
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
        seen=$(imds_tag) && [[ "$seen" == "$value" ]] && return 0
        sleep 2
    done
    error "IMDS did not converge to '${value:-<absent>}' within 60s"
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
