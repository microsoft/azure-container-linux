#!/bin/bash
# Azure validation module for Azure Container Linux (ACL) images.
#
# Provides Azure-specific VM lifecycle functions:
#   - Azure infrastructure provisioning (storage, gallery, image definitions)
#   - VHD upload and gallery image version management
#   - Azure VM creation, start, and removal
#   - Azure serial console and run-command execution
#   - Azure CLI prerequisite checks
#
# Sourced by validate_rpm_image.sh (requires validate_common.sh loaded first).
#
# Copyright (c) 2026, Microsoft Corporation.

# Guard against double-sourcing
[[ -n "${_VALIDATE_AZURE_LOADED:-}" ]] && return 0
_VALIDATE_AZURE_LOADED=1

# ── Azure-specific globals ─────────────────────────────────────────

AZ_SUB_ID="${AZ_SUB_ID:-b99b2264-54e6-408e-812b-2ec280c0ce7a}"
AZ_REGION="${AZ_REGION:-eastus2}"
AZ_STORAGE_RG="${AZ_STORAGE_RG:-acl-test-storage-rg}"
AZ_STORAGE_ACC="${AZ_STORAGE_ACC:-aclteststorageacc}"
BOARD="${BOARD:-amd64-usr}"
case "${BOARD}" in
    arm64-usr)
        AZ_VM_SIZE="${AZ_VM_SIZE:-Standard_D2ps_v6}"
        AZ_VM_IMAGE_DEF="${AZ_VM_IMAGE_DEF:-$(whoami)-acl-test-vm-img-arm64}"
        ;;
    *)
        AZ_VM_SIZE="${AZ_VM_SIZE:-Standard_D2s_v5}"
        AZ_VM_IMAGE_DEF="${AZ_VM_IMAGE_DEF:-$(whoami)-acl-test-vm-img}"
        ;;
esac
AZ_STORAGE_CONTAINER="${AZ_STORAGE_CONTAINER:-acl-test-vm-img}"
AZ_GALLERY_RG="${AZ_GALLERY_RG:-acl-test-gallery-rg}"
AZ_ACG="${AZ_ACG:-acltestacg}"
NO_CLEANUP="${NO_CLEANUP:-false}"
BUILD_ID="${BUILD_ID:-}"
RESOURCE_TAGS=("createdBy=$(whoami)")
VM_RG_PREFIX="${VM_RG_PREFIX:-$(whoami)-acl-test-vm-rg}"
VM_RG=""

# ── Azure console ─────────────────────────────────────────────────

connect_vm_console_azure() {
    local vm_rg_name="$1"
    local vm_name="$2"
    info "Connecting to Azure VM serial console..."
    info "Press Ctrl+] followed by 'q' to disconnect from console"
    sleep 1
    az serial-console connect \
        --resource-group "$vm_rg_name" \
        --name "$vm_name"
}

# ── Azure run-command execution ────────────────────────────────────

run_command_vm_azure() {
    local vm_rg_name="$1"
    local vm_name="$2"
    local command="$3"
    local timeout="${4:-60}"

    info "Running command on Azure VM: $command"

    local escaped_command
    escaped_command=$(printf '%s' "$command" | sed 's/\\/\\\\/g; s/"/\\"/g')

    local script_content="#!/bin/bash\nset -e\n$command\necho \"SCRIPT_EXIT_CODE:\$?\""

    local result=0
    local output
    if output=$(az vm run-command invoke \
        --resource-group "$vm_rg_name" \
        --name "$vm_name" \
        --command-id RunShellScript \
        --scripts "$script_content" \
        --query 'value[0].message' \
        --output tsv 2>&1); then
        echo "$output"
        if echo "$output" | grep -q "SCRIPT_EXIT_CODE:0"; then
            info "✓ Command completed successfully"
        else
            error "Command failed or returned non-zero exit code"
            result=1
        fi
    else
        error "Failed to execute command on Azure VM: $output"
        result=1
    fi

    return $result
}

# ── Azure infrastructure ──────────────────────────────────────────

check_azure_infra() {
    info "Checking that required Azure infrastructure exists..."

    if [[ "$(az group exists -n "$AZ_STORAGE_RG")" == "false" ]]; then
        info "Creating storage resource group: $AZ_STORAGE_RG"
        az group create --name "$AZ_STORAGE_RG" --location "$AZ_REGION"
    fi

    if [[ "$(az group exists -n "$AZ_GALLERY_RG")" == "false" ]]; then
        info "Creating gallery resource group: $AZ_GALLERY_RG"
        az group create --name "$AZ_GALLERY_RG" --location "$AZ_REGION"
    fi

    local storage_account_resource_id="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$AZ_STORAGE_RG/providers/Microsoft.Storage/storageAccounts/$AZ_STORAGE_ACC"
    if ! az storage account show --ids "$storage_account_resource_id" &>/dev/null; then
        info "Creating storage account: $AZ_STORAGE_ACC"
        if [[ "$(az storage account check-name --name "$AZ_STORAGE_ACC" --query nameAvailable)" == "false" ]]; then
            error "Storage account name $AZ_STORAGE_ACC is not available"
            exit 1
        fi
        az storage account create \
            --resource-group "$AZ_STORAGE_RG" \
            --name "$AZ_STORAGE_ACC" \
            --location "$AZ_REGION" \
            --allow-shared-key-access false \
            --sku Standard_LRS
    fi

    local container_exists
    container_exists=$(az storage container exists --account-name "$AZ_STORAGE_ACC" --name "$AZ_STORAGE_CONTAINER" --auth-mode login --query exists -o tsv)
    if [[ "$container_exists" != "true" ]]; then
        info "Creating storage container: $AZ_STORAGE_CONTAINER"
        az storage container create \
            --account-name "$AZ_STORAGE_ACC" \
            --name "$AZ_STORAGE_CONTAINER" \
            --auth-mode login
    fi

    if ! az sig show -r "$AZ_ACG" -g "$AZ_GALLERY_RG" &>/dev/null; then
        info "Creating shared image gallery: $AZ_ACG"
        az sig create \
            --resource-group "$AZ_GALLERY_RG" \
            --gallery-name "$AZ_ACG" \
            --location "$AZ_REGION"
    fi

    local image_def_exists
    local publisher="$(whoami)-ACL"
    local offer="$AZ_VM_IMAGE_DEF"
    local sku="$(whoami)-TestBase"

    image_def_exists=$(az sig image-definition list -r "$AZ_ACG" -g "$AZ_GALLERY_RG" --query "[?name=='$AZ_VM_IMAGE_DEF' && identifier.publisher=='$publisher' && identifier.offer=='$offer' && identifier.sku=='$sku'] | length(@)" -o tsv)
    if [[ "$image_def_exists" -eq 0 ]]; then
        info "Creating image definition: $AZ_VM_IMAGE_DEF"
        local create_sig_image_def_args=(
            --gallery-image-definition "$AZ_VM_IMAGE_DEF"
            --publisher "$publisher"
            --offer "$offer"
            --sku "$sku"
            --gallery-name "$AZ_ACG"
            --resource-group "$AZ_GALLERY_RG"
            --location "$AZ_REGION"
            --os-type Linux
            --features SecurityType=TrustedLaunchSupported
            --hyper-v-generation V2
        )

        if [[ $BOARD == "arm64-usr" ]]; then
            create_sig_image_def_args+=(--architecture Arm64)
        fi

        az sig image-definition create "${create_sig_image_def_args[@]}"

    else
        info "Image definition already exists: $AZ_VM_IMAGE_DEF"
    fi

    info "Azure infrastructure ready"
}

upload_vhd_to_storage() {
    local vhd_path="$1"
    local blob_name="$2"
    info "Uploading VHD to Azure storage..."
    info "  Local file:  $vhd_path"
    info "  Blob name:   $blob_name"
    info "  Storage account: $AZ_STORAGE_ACC"
    info "  Container:       $AZ_STORAGE_CONTAINER"
    az storage blob upload \
        --account-name "$AZ_STORAGE_ACC" \
        --container-name "$AZ_STORAGE_CONTAINER" \
        --name "$blob_name" \
        --file "$vhd_path" \
        --auth-mode login \
        --overwrite
    info "✓ VHD uploaded successfully"
}

get_next_image_version() {
    if [[ -n "${BUILD_ID}" ]]; then
        echo "1.0.${BUILD_ID}"
        return
    fi
    local latest_version
    latest_version=$(az sig image-version list \
        --resource-group "$AZ_GALLERY_RG" \
        --gallery-name "$AZ_ACG" \
        --gallery-image-name "$AZ_VM_IMAGE_DEF" \
        --query '[].name' -o tsv | \
        sort -t "." -k1,1n -k2,2n -k3,3n | \
        tail -1)
    if [[ -z "$latest_version" ]]; then
        echo "1.0.0"
    else
        echo "$latest_version" | awk -F. '{print $1"."$2"."$3+1}'
    fi
}

create_gallery_image_version() {
    local image_version="$1"
    local blob_name="$2"
    info "Creating gallery image version: $image_version"
    local storage_account_resource_id="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$AZ_STORAGE_RG/providers/Microsoft.Storage/storageAccounts/$AZ_STORAGE_ACC"
    local blob_url="https://$AZ_STORAGE_ACC.blob.core.windows.net/$AZ_STORAGE_CONTAINER/$blob_name"

    # The --location for az sig image-version create must match the region of
    # the source VHD blob (storage account), so the intermediate managed disk
    # is co-located.  When the storage account or gallery are in a different
    # region from AZ_REGION (the VM target), we add extra target regions and
    # switch to Full replication.
    local storage_location
    storage_location=$(az storage account show -n "$AZ_STORAGE_ACC" --query location -o tsv)
    local gallery_location
    gallery_location=$(az sig show -r "$AZ_ACG" -g "$AZ_GALLERY_RG" --query location -o tsv)

    if [[ "${storage_location,,}" != "${gallery_location,,}" ]]; then
        error "Storage account '$AZ_STORAGE_ACC' is in '${storage_location}' but gallery '$AZ_ACG' is in '${gallery_location}'. They must be in the same region."
        exit 1
    fi

    # Build unique set of target regions (gallery home + VM target).
    local image_location="$storage_location"
    local replication_mode="Shallow"
    local target_regions="$image_location"
    if [[ "${image_location,,}" != "${AZ_REGION,,}" ]]; then
        warn "Storage/gallery region '${image_location}' differs from VM target region '${AZ_REGION}'; adding '${AZ_REGION}' as extra target (Full replication, slower)"
        target_regions="$image_location $AZ_REGION"
        replication_mode="Full"
    fi

    az sig image-version create \
        --resource-group "$AZ_GALLERY_RG" \
        --gallery-name "$AZ_ACG" \
        --gallery-image-definition "$AZ_VM_IMAGE_DEF" \
        --gallery-image-version "$image_version" \
        --os-vhd-uri "$blob_url" \
        --os-vhd-storage-account "$storage_account_resource_id" \
        --location "$image_location" \
        --target-regions $target_regions \
        --replica-count 1 \
        --storage-account-type Standard_LRS \
        --replication-mode "$replication_mode"
    info "✓ Gallery image version created: $image_version"
}

# ── Azure VM creation ─────────────────────────────────────────────

create_vm_azure() {
    local vm_rg_name="$1"
    local image_version_or_id="$2"

    local all_tags=("${RESOURCE_TAGS[@]}" "purpose=VM-testing" "creationTime=$(date +%s)")

    if [[ "$(az group exists -n "$vm_rg_name")" == "false" ]]; then
        info "Creating VM RG: $vm_rg_name"
        az group create \
            --name "$vm_rg_name" \
            --location "$AZ_REGION" \
            --tags "${all_tags[@]}"
    fi

    local image_id
    if [[ -n "${ACG_IMAGE_VERSION_ID}" ]]; then
        image_id="${image_version_or_id}"
    else
        image_id="/subscriptions/$AZ_SUB_ID/resourceGroups/$AZ_GALLERY_RG/providers/Microsoft.Compute/galleries/$AZ_ACG/images/$AZ_VM_IMAGE_DEF/versions/$image_version_or_id"
    fi

    local public_ip_name="${VM_NAME}PublicIP"
    info "Creating public IP with policy-compliant tags: $public_ip_name"
    az network public-ip create \
        --name "$public_ip_name" \
        --resource-group "$vm_rg_name" \
        --location "$AZ_REGION" \
        --allocation-method Static \
        --sku Standard \
        --ip-tags FirstPartyUsage=/NonProd \
        --tags "${all_tags[@]}"

    info "Creating an Azure VM ${VM_NAME} in RG ${vm_rg_name} (without public IP)..."

    local vm_create_args=(
        --resource-group "$vm_rg_name"
        --name "$VM_NAME"
        --size "$AZ_VM_SIZE"
        --os-disk-size-gb 60
        --admin-username "$VM_SSH_USER"
        --ssh-key-values "@${VM_SSH_KEY}.pub"
        --security-type TrustedLaunch
        --enable-vtpm true
        --image "$image_id"
        --location "$AZ_REGION"
        --public-ip-address ""
        --tags "${all_tags[@]}"
    )

    if [[ "$SECURE_BOOT_ENABLED" == "true" ]]; then
        vm_create_args+=(--enable-secure-boot true)
    else
        vm_create_args+=(--enable-secure-boot false)
    fi
    az vm create "${vm_create_args[@]}"

    info "Attaching public IP to VM NIC..."
    local nic_id
    nic_id=$(az vm show -g "$vm_rg_name" -n "$VM_NAME" \
        --query 'networkProfile.networkInterfaces[0].id' -o tsv)
    local nic_name
    nic_name=$(az network nic show --ids "$nic_id" --query 'name' -o tsv)
    local ip_config_name
    ip_config_name=$(az network nic show --ids "$nic_id" \
        --query 'ipConfigurations[0].name' -o tsv)
    az network nic ip-config update \
        --nic-name "$nic_name" \
        --resource-group "$vm_rg_name" \
        --name "$ip_config_name" \
        --public-ip-address "$public_ip_name"

    info "Enabling boot diagnostics..."
    az vm boot-diagnostics enable \
        --name "$VM_NAME" \
        --resource-group "$vm_rg_name"
}

get_vm_rg_name() {
    local suffix
    suffix=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)
    printf '%s-%s\n' "$VM_RG_PREFIX" "$suffix"
}

# ── Start Azure VM ────────────────────────────────────────────────

start_vm_azure() {
    local vm_image_path="$1"
    section "Starting Azure VM for board '${BOARD}'"

    local vm_rg_name=$(get_vm_rg_name)
    VM_RG="$vm_rg_name"

    info "Azure VM Configuration:"
    info "  Subscription:      ${AZ_SUB_ID}"
    info "  Storage RG:        ${AZ_STORAGE_RG}"
    info "  Location:          ${AZ_REGION}"
    info "  VM Resource Group: ${vm_rg_name}"
    info "  VM Name:           ${VM_NAME}"
    info "  Gallery:           ${AZ_ACG}"
    info "  Image Definition:  ${AZ_VM_IMAGE_DEF}"
    info "  Board:             ${BOARD}"
    echo

    info "Setting Azure subscription..."
    az account set --subscription "$AZ_SUB_ID"

    if [[ -n "${ACG_IMAGE_VERSION_ID}" ]]; then
        info "Using pre-existing ACG image version: ${ACG_IMAGE_VERSION_ID}"
        create_vm_azure "$vm_rg_name" "${ACG_IMAGE_VERSION_ID}"
    else
        check_azure_infra
        local blob_name="$(date +%y%m%d.%H%M%S)-${BUILD_ID:+${BUILD_ID}-}${IMG_NAME}.vhd"
        upload_vhd_to_storage "$vm_image_path" "$blob_name"
        local image_version
        image_version=$(get_next_image_version)
        create_gallery_image_version "$image_version" "$blob_name"
        create_vm_azure "$vm_rg_name" "$image_version"
    fi

    export VM_IP=$(az vm show -d -g "$vm_rg_name" -n "$VM_NAME" --query "publicIps" -o tsv)
    while [ "$(az vm show -d -g "$vm_rg_name" -n "$VM_NAME" --query provisioningState -o tsv)" != "Succeeded" ]; do sleep 1; done

    info "✓ Azure VM '${VM_NAME}' started successfully!"
    info " IP Address:     ${VM_IP}"
}

# ── Remove Azure VM ───────────────────────────────────────────────

remove_vm_azure() {
    if [[ "$NO_CLEANUP" == "true" ]]; then
        info "--no-cleanup specified, so skipping cleanup of VM resources"
        return 0
    fi
    remove_vm_state
    info "Scheduling deletion of VM resources matching tags: ${RESOURCE_TAGS[*]}"
    local query_filter=""
    for tag in "${RESOURCE_TAGS[@]}"; do
        local key="${tag%%=*}"
        local value="${tag#*=}"
        [[ -n "$query_filter" ]] && query_filter+=" && "
        query_filter+="tags.${key}=='${value}'"
    done
    local matching_rgs
    matching_rgs=$(az group list --query "[?${query_filter}].name" -o tsv)

    if [[ -z "$matching_rgs" ]]; then
        info "No resource groups found for cleanup"
        return 0
    fi

    local rg_count=0
    local failed_count=0
    while IFS= read -r rg_name; do
        [[ -z "$rg_name" ]] && continue
        info "Scheduling deletion of RG: $rg_name"
        local err
        set +e
        if err=$(az group delete -n "$rg_name" -y --no-wait 2>&1 >/dev/null); then
            ((rg_count++))
        else
            warn "Failed to schedule deletion of RG: $rg_name"
            warn "  az error: $err"
            ((failed_count++))
        fi
        set -e
    done <<< "$matching_rgs"

    info "Scheduled deletion of $rg_count resource group(s)"
    if [[ $failed_count -gt 0 ]]; then
        info "$failed_count resource group(s) couldn't be scheduled (likely already deleting)"
    fi
    return 0
}

# ── Azure prerequisites ───────────────────────────────────────────

check_azure_prereqs() {
    info "Checking Azure prerequisites..."
    if ! command -v az &>/dev/null; then
        error "Azure CLI (az) not found"
        return 1
    fi
    if ! az account show &>/dev/null; then
        error "Not logged into Azure. Please run: az login"
        return 1
    fi
    if ! az group list --query "[]" -o tsv &>/dev/null; then
        error "Azure authentication token has expired or is invalid"
        return 1
    fi
    info "✓ Azure prerequisites met"
}
