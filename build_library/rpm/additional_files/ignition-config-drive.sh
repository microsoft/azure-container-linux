#!/bin/bash
# Load Ignition config from a CDROM/block device with label "ignition"
# This script runs before Ignition and copies the config to where Ignition expects it.

set -e

IGNITION_LABEL="ignition"
IGNITION_DEST_DIR="/usr/lib/ignition"
IGNITION_DEST="${IGNITION_DEST_DIR}/user.ign"
MOUNT_POINT="/run/ignition-configdrive"

log() {
    echo "ignition-config-drive: $*" >&2
}

# Wait for udev to settle and look for the config drive
find_config_drive() {
    local dev=""
    local timeout=30
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        # Try to find by label first
        if [[ -b "/dev/disk/by-label/${IGNITION_LABEL}" ]]; then
            dev="/dev/disk/by-label/${IGNITION_LABEL}"
            break
        fi
        
        # Also check for uppercase label (some tools create uppercase labels)
        if [[ -b "/dev/disk/by-label/${IGNITION_LABEL^^}" ]]; then
            dev="/dev/disk/by-label/${IGNITION_LABEL^^}"
            break
        fi
        
        # Fallback: scan for CD-ROM devices
        for cdrom in /dev/sr* /dev/cdrom; do
            if [[ -b "$cdrom" ]]; then
                # Check if this device has our label
                local label
                label=$(blkid -s LABEL -o value "$cdrom" 2>/dev/null || true)
                if [[ "$label" == "$IGNITION_LABEL" ]] || [[ "$label" == "${IGNITION_LABEL^^}" ]]; then
                    dev="$cdrom"
                    break 2
                fi
            fi
        done
        
        ((count++))
        sleep 1
    done
    
    echo "$dev"
}

main() {
    log "Looking for config drive with label '${IGNITION_LABEL}'..."
    
    local config_dev
    config_dev=$(find_config_drive)
    
    if [[ -z "$config_dev" ]]; then
        log "No config drive found, skipping config drive import"
        exit 0
    fi
    
    log "Found config drive at: $config_dev"
    
    # Create mount point
    mkdir -p "$MOUNT_POINT"
    
    # Mount the config drive (read-only)
    if ! mount -o ro "$config_dev" "$MOUNT_POINT"; then
        log "Failed to mount config drive"
        exit 1
    fi
    
    # Look for ignition config in various locations
    local config_file=""
    local search_paths=(
        "$MOUNT_POINT/ignition/config.ign"
        "$MOUNT_POINT/config.ign"
        "$MOUNT_POINT/ignition.json"
        "$MOUNT_POINT/user-data"
    )
    
    for path in "${search_paths[@]}"; do
        if [[ -f "$path" ]]; then
            config_file="$path"
            break
        fi
    done
    
    if [[ -z "$config_file" ]]; then
        log "No ignition config found on config drive"
        umount "$MOUNT_POINT" 2>/dev/null || true
        rmdir "$MOUNT_POINT" 2>/dev/null || true
        exit 0
    fi
    
    log "Found ignition config at: $config_file"
    
    # Create destination directory
    mkdir -p "$IGNITION_DEST_DIR"
    
    # Copy the config
    cp "$config_file" "$IGNITION_DEST"
    chmod 600 "$IGNITION_DEST"
    
    log "Copied ignition config to $IGNITION_DEST"
    
    # Unmount the config drive
    umount "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    
    log "Config drive import complete"
}

main "$@"
