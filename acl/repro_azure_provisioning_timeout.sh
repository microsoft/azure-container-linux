#!/usr/bin/env bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Repeatedly provision a control image until OSProvisioningTimedOut occurs.
# Cleanup is attempted synchronously after successful or non-target attempts.
# Target failures and timed-out deployments with uncertain state are preserved
# for boot diagnostics and serial-console triage.

set -euo pipefail

IMAGE_ID=""
SUBSCRIPTION_ID=""
LOCATION="swedencentral"
VM_SIZE="Standard_D2ps_v6"
MAX_ATTEMPTS=20
ATTEMPT_TIMEOUT_SECONDS=1800
VM_NAME="acl-provision-repro"
ADMIN_USERNAME="azureuser"
SSH_PUBLIC_KEY_FILE=""
RG_PREFIX=""
ACCELERATED_NETWORKING=true

ACTIVE_RG=""
DEPLOYMENT_NAME=""
DEPLOY_PID=""
OUTPUT_FILE=""
TEMPLATE_FILE=""
PRESERVE_RG=false

usage() {
    cat <<'EOF'
Usage:
  ./acl/repro_azure_provisioning_timeout.sh --image-id=ID [options]

Required:
  --image-id=ID                    Full Azure Compute Gallery image version ID

Options:
  --subscription=ID                Azure subscription (defaults to the image ID subscription)
  --location=REGION                Azure region (default: swedencentral)
  --vm-size=SIZE                   Azure VM size (default: Standard_D2ps_v6)
  --max-attempts=N                 Maximum provisioning attempts (default: 20)
  --attempt-timeout-seconds=N      Maximum seconds per deployment (default: 1800)
  --vm-name=NAME                   VM name (default: acl-provision-repro)
  --admin-username=USER            VM administrator (default: azureuser)
  --ssh-public-key=PATH            SSH public key file (defaults to id_ed25519.pub or id_rsa.pub)
  --resource-group-prefix=PREFIX   Prefix for per-attempt resource groups
  --accelerated-networking=BOOL    Enable accelerated networking (default: true)
  --help, -h                       Show this help

Examples:
  # ARM v6 with Trusted Launch, Secure Boot, and vTPM
  ./acl/repro_azure_provisioning_timeout.sh \
      --image-id=/subscriptions/.../versions/1.0.0 \
      --vm-size=Standard_D2ps_v6
EOF
}

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

stop_deployment_process() {
    if [[ -n "$DEPLOY_PID" ]] && kill -0 "$DEPLOY_PID" 2>/dev/null; then
        kill -TERM "$DEPLOY_PID" 2>/dev/null || true
        wait "$DEPLOY_PID" 2>/dev/null || true
    fi
    DEPLOY_PID=""
}

delete_active_rg() {
    [[ -z "$ACTIVE_RG" ]] && return 0

    local exists
    if ! exists=$(az group exists \
      --subscription "$SUBSCRIPTION_ID" \
        --name "$ACTIVE_RG" \
        --output tsv); then
        warn "Could not determine whether resource group exists: $ACTIVE_RG"
        return 1
    fi

    if [[ "$exists" == "true" ]]; then
        log "Deleting resource group synchronously: $ACTIVE_RG"
        if ! az group delete \
          --subscription "$SUBSCRIPTION_ID" \
            --name "$ACTIVE_RG" \
            --yes; then
            warn "Failed to delete resource group: $ACTIVE_RG"
            return 1
        fi
    fi

    ACTIVE_RG=""
}

delete_active_rg_or_continue() {
    local failed_rg="$ACTIVE_RG"

    if delete_active_rg; then
        return 0
    fi

    warn "Synchronous cleanup failed for ${failed_rg}; scheduling asynchronous deletion and continuing"
    if az group delete \
      --subscription "$SUBSCRIPTION_ID" \
        --name "$failed_rg" \
        --yes \
        --no-wait; then
        log "Scheduled asynchronous deletion of resource group: $failed_rg"
    else
        warn "Could not schedule deletion of ${failed_rg}; manual cleanup may be required"
    fi
    ACTIVE_RG=""
}

print_preserved_attempt() {
    local outcome="$1"
    local summary="$2"
    local diagnostics_enabled="${3:-unknown}"

    printf '\n[%s] %s\n' "$outcome" "$summary"
    printf 'Resource group: %s\n' "$ACTIVE_RG"
    printf 'VM:             %s\n' "$VM_NAME"
    printf 'Deployment:     %s\n' "$DEPLOYMENT_NAME"
    printf 'Boot diagnostics enabled: %s\n\n' "$diagnostics_enabled"
    printf 'Inspect the preserved attempt with:\n'
    printf '  az vm get-instance-view --subscription %q --resource-group %q --name %q --output jsonc\n' \
      "$SUBSCRIPTION_ID" "$ACTIVE_RG" "$VM_NAME"
    printf '  az vm boot-diagnostics get-boot-log --subscription %q --resource-group %q --name %q\n' \
      "$SUBSCRIPTION_ID" "$ACTIVE_RG" "$VM_NAME"
    printf '  az vm boot-diagnostics get-boot-log-uris --subscription %q --resource-group %q --name %q\n' \
      "$SUBSCRIPTION_ID" "$ACTIVE_RG" "$VM_NAME"
    printf '  az serial-console connect --subscription %q --resource-group %q --name %q\n' \
      "$SUBSCRIPTION_ID" "$ACTIVE_RG" "$VM_NAME"
    printf '  az deployment group show --subscription %q --resource-group %q --name %q --output jsonc\n' \
      "$SUBSCRIPTION_ID" "$ACTIVE_RG" "$DEPLOYMENT_NAME"
    printf '\nDelete it when triage is complete:\n'
    printf '  az group delete --subscription %q --name %q --yes\n' \
      "$SUBSCRIPTION_ID" "$ACTIVE_RG"
}

cleanup() {
    local status=$?
    local output_file="$OUTPUT_FILE"
    local template_file="$TEMPLATE_FILE"
    trap - EXIT INT TERM

    stop_deployment_process
    OUTPUT_FILE=""
    TEMPLATE_FILE=""
    if [[ -n "$output_file" ]] && ! rm -f "$output_file"; then
        warn "Could not remove deployment output file: $output_file"
    fi
    if [[ -n "$template_file" ]] && ! rm -f "$template_file"; then
        warn "Could not remove deployment template file: $template_file"
    fi

    if [[ "$PRESERVE_RG" != "true" ]] && [[ -n "$ACTIVE_RG" ]]; then
        delete_active_rg_or_continue
    fi

    exit "$status"
}

on_signal() {
    local signal_name="$1"
    local status="$2"
    warn "Received ${signal_name}; cleaning the active non-repro attempt"
    stop_deployment_process
    exit "$status"
}

trap cleanup EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-id=*) IMAGE_ID="${1#*=}"; shift ;;
        --image-id) IMAGE_ID="$2"; shift 2 ;;
      --subscription=*) SUBSCRIPTION_ID="${1#*=}"; shift ;;
      --subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
        --location=*) LOCATION="${1#*=}"; shift ;;
        --location) LOCATION="$2"; shift 2 ;;
        --vm-size=*) VM_SIZE="${1#*=}"; shift ;;
        --vm-size) VM_SIZE="$2"; shift 2 ;;
        --max-attempts=*) MAX_ATTEMPTS="${1#*=}"; shift ;;
        --max-attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
        --attempt-timeout-seconds=*) ATTEMPT_TIMEOUT_SECONDS="${1#*=}"; shift ;;
        --attempt-timeout-seconds) ATTEMPT_TIMEOUT_SECONDS="$2"; shift 2 ;;
        --vm-name=*) VM_NAME="${1#*=}"; shift ;;
        --vm-name) VM_NAME="$2"; shift 2 ;;
        --admin-username=*) ADMIN_USERNAME="${1#*=}"; shift ;;
        --admin-username) ADMIN_USERNAME="$2"; shift 2 ;;
        --ssh-public-key=*) SSH_PUBLIC_KEY_FILE="${1#*=}"; shift ;;
        --ssh-public-key) SSH_PUBLIC_KEY_FILE="$2"; shift 2 ;;
        --resource-group-prefix=*) RG_PREFIX="${1#*=}"; shift ;;
        --resource-group-prefix) RG_PREFIX="$2"; shift 2 ;;
        --accelerated-networking=*) ACCELERATED_NETWORKING="${1#*=}"; shift ;;
        --accelerated-networking) ACCELERATED_NETWORKING="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$IMAGE_ID" ]] || die "--image-id is required"
[[ "$IMAGE_ID" == /subscriptions/*/resourceGroups/*/providers/Microsoft.Compute/galleries/*/images/*/versions/* ]] || \
    die "--image-id must be a full Azure Compute Gallery image version resource ID"
image_subscription_id="${IMAGE_ID#/subscriptions/}"
image_subscription_id="${image_subscription_id%%/*}"
if [[ -z "$SUBSCRIPTION_ID" ]]; then
    SUBSCRIPTION_ID="$image_subscription_id"
elif [[ "${image_subscription_id,,}" != "${SUBSCRIPTION_ID,,}" ]]; then
    die "--subscription must match the subscription embedded in --image-id"
fi
[[ "${VM_SIZE,,}" == *_v6 ]] || die "--vm-size must be an ARM v6 SKU ending in _v6"
[[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die "--max-attempts must be a positive integer"
[[ "$ATTEMPT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "--attempt-timeout-seconds must be a positive integer"
[[ ${#VM_NAME} -le 64 ]] || die "--vm-name must be at most 64 characters"

case "${ACCELERATED_NETWORKING,,}" in
    true) ACCELERATED_NETWORKING=true ;;
    false) ACCELERATED_NETWORKING=false ;;
    *) die "--accelerated-networking must be true or false" ;;
esac

owner=$(whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
owner="${owner:-user}"
if [[ -z "$RG_PREFIX" ]]; then
  RG_PREFIX="${owner}-acl-provision-repro"
fi
run_id="$(date -u +%Y%m%d%H%M%S)-$$"
rg_prefix_pattern='^[A-Za-z0-9_.()-]+$'
[[ "$RG_PREFIX" =~ $rg_prefix_pattern ]] || \
  die "--resource-group-prefix may contain only ASCII letters, numbers, underscores, parentheses, periods, and hyphens"
max_attempt_suffix="$MAX_ATTEMPTS"
if [[ ${#max_attempt_suffix} -lt 2 ]]; then
  max_attempt_suffix="0${max_attempt_suffix}"
fi
longest_rg_name="${RG_PREFIX}-${run_id}-${max_attempt_suffix}"
[[ ${#longest_rg_name} -le 90 ]] || \
  die "--resource-group-prefix is too long: final resource group names may not exceed 90 characters"

command -v az >/dev/null 2>&1 || die "Azure CLI (az) is required"
command -v timeout >/dev/null 2>&1 || die "GNU timeout is required"
if ! actual_subscription_id=$(az account show \
  --subscription "$SUBSCRIPTION_ID" \
  --query id \
  --output tsv); then
  die "Cannot access subscription ${SUBSCRIPTION_ID}"
fi
if ! actual_subscription_name=$(az account show \
  --subscription "$SUBSCRIPTION_ID" \
  --query name \
  --output tsv); then
  die "Cannot read subscription ${SUBSCRIPTION_ID}"
fi
[[ "${actual_subscription_id,,}" == "${SUBSCRIPTION_ID,,}" ]] || \
    die "Refusing to run in subscription $actual_subscription_id"

IMAGE_DEFINITION_ID="${IMAGE_ID%/versions/*}"
[[ "$IMAGE_DEFINITION_ID" != "$IMAGE_ID" ]] || die "Unable to derive image definition ID from --image-id"
if ! image_definition_tsv=$(az sig image-definition show \
  --subscription "$SUBSCRIPTION_ID" \
  --ids "$IMAGE_DEFINITION_ID" \
  --query "[architecture, hyperVGeneration, features[?name=='SecurityType'].value | [0]]" \
  --output tsv); then
  die "Could not query gallery image definition metadata for ${IMAGE_DEFINITION_ID}"
fi
IFS=$'\t' read -r image_architecture image_hyper_v_generation image_security_type <<< "$image_definition_tsv"
[[ "${image_architecture,,}" == "arm64" ]] || \
  die "Gallery image definition must be Arm64 (got: ${image_architecture:-unknown})"
[[ "${image_hyper_v_generation,,}" == "v2" ]] || \
  die "Gallery image definition must be Hyper-V generation V2 (got: ${image_hyper_v_generation:-unknown})"
[[ "${image_security_type,,}" == "trustedlaunchsupported" ]] || \
  die "Gallery image definition must support Trusted Launch (got: ${image_security_type:-unknown})"

if ! sku_capabilities=$(az vm list-skus \
  --subscription "$SUBSCRIPTION_ID" \
  --location "$LOCATION" \
  --size "$VM_SIZE" \
  --all \
  --query "[?name=='${VM_SIZE}'] | [0].capabilities[?name=='CpuArchitectureType' || name=='HyperVGenerations' || name=='TrustedLaunchDisabled'].[name,value]" \
  --output tsv); then
  die "Could not query Azure capabilities for ${VM_SIZE} in ${LOCATION}"
fi
sku_architecture=$(awk -F '\t' '$1 == "CpuArchitectureType" { print $2 }' <<< "$sku_capabilities")
sku_hyper_v_generations=$(awk -F '\t' '$1 == "HyperVGenerations" { print $2 }' <<< "$sku_capabilities")
sku_trusted_launch_disabled=$(awk -F '\t' '$1 == "TrustedLaunchDisabled" { print $2 }' <<< "$sku_capabilities")
[[ "$sku_architecture" == "Arm64" ]] || die "--vm-size must be an Azure Arm64 SKU"
[[ ",${sku_hyper_v_generations// /}," == *,V2,* ]] || die "--vm-size must support Hyper-V generation V2"
[[ "${sku_trusted_launch_disabled,,}" != "true" ]] || die "--vm-size must support Trusted Launch"

if [[ -z "$SSH_PUBLIC_KEY_FILE" ]]; then
    for candidate in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
        if [[ -f "$candidate" ]]; then
            SSH_PUBLIC_KEY_FILE="$candidate"
            break
        fi
    done
fi
[[ -n "$SSH_PUBLIC_KEY_FILE" ]] || die "No SSH public key found; use --ssh-public-key"
[[ -r "$SSH_PUBLIC_KEY_FILE" ]] || die "SSH public key is not readable: $SSH_PUBLIC_KEY_FILE"
SSH_PUBLIC_KEY=$(<"$SSH_PUBLIC_KEY_FILE")
[[ -n "$SSH_PUBLIC_KEY" ]] || die "SSH public key is empty: $SSH_PUBLIC_KEY_FILE"

if ! TEMPLATE_FILE=$(mktemp "${TMPDIR:-/tmp}/acl-provision-repro.XXXXXX.json"); then
    die "Failed to create temporary ARM template"
fi

cat > "$TEMPLATE_FILE" <<'TEMPLATE_EOF'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "imageId": { "type": "string" },
    "vmName": { "type": "string" },
    "vmSize": { "type": "string" },
    "adminUsername": { "type": "string" },
    "sshPublicKey": { "type": "secureString" },
    "acceleratedNetworking": { "type": "bool" },
    "createdBy": { "type": "string" },
    "attempt": { "type": "int" }
  },
  "variables": {
    "vnetName": "[concat(parameters('vmName'), '-vnet')]",
    "subnetName": "default",
    "nicName": "[concat(parameters('vmName'), '-nic')]",
    "resourceTags": {
      "createdBy": "[parameters('createdBy')]",
      "purpose": "acl-os-provisioning-repro",
      "attempt": "[string(parameters('attempt'))]"
    }
  },
  "resources": [
    {
      "type": "Microsoft.Network/virtualNetworks",
      "apiVersion": "2023-09-01",
      "name": "[variables('vnetName')]",
      "location": "[resourceGroup().location]",
      "tags": "[variables('resourceTags')]",
      "properties": {
        "addressSpace": { "addressPrefixes": ["10.0.0.0/16"] },
        "subnets": [
          {
            "name": "[variables('subnetName')]",
            "properties": { "addressPrefix": "10.0.0.0/24" }
          }
        ]
      }
    },
    {
      "type": "Microsoft.Network/networkInterfaces",
      "apiVersion": "2023-09-01",
      "name": "[variables('nicName')]",
      "location": "[resourceGroup().location]",
      "tags": "[variables('resourceTags')]",
      "dependsOn": ["[resourceId('Microsoft.Network/virtualNetworks', variables('vnetName'))]"],
      "properties": {
        "enableAcceleratedNetworking": "[parameters('acceleratedNetworking')]",
        "ipConfigurations": [
          {
            "name": "ipconfig1",
            "properties": {
              "privateIPAllocationMethod": "Dynamic",
              "subnet": {
                "id": "[resourceId('Microsoft.Network/virtualNetworks/subnets', variables('vnetName'), variables('subnetName'))]"
              }
            }
          }
        ]
      }
    },
    {
      "type": "Microsoft.Compute/virtualMachines",
      "apiVersion": "2023-09-01",
      "name": "[parameters('vmName')]",
      "location": "[resourceGroup().location]",
      "tags": "[variables('resourceTags')]",
      "dependsOn": ["[resourceId('Microsoft.Network/networkInterfaces', variables('nicName'))]"],
      "properties": {
        "hardwareProfile": { "vmSize": "[parameters('vmSize')]" },
        "storageProfile": {
          "imageReference": { "id": "[parameters('imageId')]" },
          "osDisk": {
            "createOption": "FromImage",
            "deleteOption": "Delete",
            "managedDisk": { "storageAccountType": "Premium_LRS" }
          }
        },
        "osProfile": {
          "computerName": "[parameters('vmName')]",
          "adminUsername": "[parameters('adminUsername')]",
          "linuxConfiguration": {
            "disablePasswordAuthentication": true,
            "provisionVMAgent": true,
            "ssh": {
              "publicKeys": [
                {
                  "path": "[format('/home/{0}/.ssh/authorized_keys', parameters('adminUsername'))]",
                  "keyData": "[parameters('sshPublicKey')]"
                }
              ]
            }
          }
        },
        "networkProfile": {
          "networkInterfaces": [
            {
              "id": "[resourceId('Microsoft.Network/networkInterfaces', variables('nicName'))]",
              "properties": { "deleteOption": "Delete" }
            }
          ]
        },
        "diagnosticsProfile": {
          "bootDiagnostics": { "enabled": true }
        },
        "securityProfile": {
          "securityType": "TrustedLaunch",
          "uefiSettings": {
            "secureBootEnabled": true,
            "vTpmEnabled": true
          }
        }
      }
    }
  ]
}
TEMPLATE_EOF

log "Subscription:           ${actual_subscription_name} (${actual_subscription_id})"
log "Image:                  $IMAGE_ID"
log "Location:               $LOCATION"
log "VM size:                $VM_SIZE"
log "Security type:          TrustedLaunch (Secure Boot and vTPM enabled)"
log "Accelerated networking: $ACCELERATED_NETWORKING"
log "Maximum attempts:       $MAX_ATTEMPTS"
log "Attempt timeout:        ${ATTEMPT_TIMEOUT_SECONDS}s"

successful_attempts=0
non_target_failures=0

for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    ACTIVE_RG="${RG_PREFIX}-${run_id}-$(printf '%02d' "$attempt")"
    DEPLOYMENT_NAME="provision-attempt-${attempt}"

    log "Attempt ${attempt}/${MAX_ATTEMPTS}: creating $ACTIVE_RG"
    az group create \
      --subscription "$SUBSCRIPTION_ID" \
        --name "$ACTIVE_RG" \
        --location "$LOCATION" \
        --tags \
            "createdBy=$owner" \
            "purpose=acl-os-provisioning-repro" \
            "attempt=$attempt" \
        --output none

    if ! OUTPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/acl-provision-attempt.XXXXXX.log"); then
        die "Failed to create deployment output file"
    fi

    timeout --signal=TERM --kill-after=30s "${ATTEMPT_TIMEOUT_SECONDS}s" \
      az deployment group create \
        --subscription "$SUBSCRIPTION_ID" \
        --resource-group "$ACTIVE_RG" \
        --name "$DEPLOYMENT_NAME" \
        --template-file "$TEMPLATE_FILE" \
        --parameters \
            "imageId=$IMAGE_ID" \
            "vmName=$VM_NAME" \
            "vmSize=$VM_SIZE" \
            "adminUsername=$ADMIN_USERNAME" \
            "sshPublicKey=$SSH_PUBLIC_KEY" \
            "acceleratedNetworking=$ACCELERATED_NETWORKING" \
            "createdBy=$owner" \
            "attempt=$attempt" \
        --only-show-errors \
        --output json >"$OUTPUT_FILE" 2>&1 &
    DEPLOY_PID=$!

    if wait "$DEPLOY_PID"; then
        deployment_rc=0
    else
        deployment_rc=$?
    fi
    DEPLOY_PID=""

    deployment_output=$(<"$OUTPUT_FILE")
    deployment_output_file="$OUTPUT_FILE"
    OUTPUT_FILE=""
    if ! rm -f "$deployment_output_file"; then
        warn "Could not remove deployment output file: $deployment_output_file"
    fi

    if [[ $deployment_rc -eq 124 || $deployment_rc -eq 137 ]]; then
        warn "Attempt ${attempt} exceeded ${ATTEMPT_TIMEOUT_SECONDS}s; querying the server-side deployment state"
        if ! grep -qi "OSProvisioningTimedOut" <<< "$deployment_output"; then
            deployment_state=""
            if ! deployment_state=$(az deployment group show \
              --subscription "$SUBSCRIPTION_ID" \
                --resource-group "$ACTIVE_RG" \
                --name "$DEPLOYMENT_NAME" \
                --query "properties.provisioningState" \
                --output tsv 2>/dev/null); then
                PRESERVE_RG=true
                print_preserved_attempt \
                    "INCONCLUSIVE" \
                    "Deployment timed out and its server-side state could not be queried on attempt ${attempt}"
                exit 2
            fi

            case "${deployment_state,,}" in
                succeeded)
                    warn "Deployment completed successfully after the local timeout fired"
                    deployment_rc=0
                    ;;
                failed)
                    deployment_error=""
                    if ! deployment_error=$(az deployment group show \
                      --subscription "$SUBSCRIPTION_ID" \
                        --resource-group "$ACTIVE_RG" \
                        --name "$DEPLOYMENT_NAME" \
                        --query "properties.error" \
                        --output json 2>/dev/null); then
                        PRESERVE_RG=true
                        print_preserved_attempt \
                            "INCONCLUSIVE" \
                            "Deployment failed after timing out, but its error could not be queried on attempt ${attempt}"
                        exit 2
                    fi
                    deployment_output+=$'\n'"$deployment_error"
                    ;;
                *)
                    PRESERVE_RG=true
                    print_preserved_attempt \
                        "INCONCLUSIVE" \
                        "Deployment remained ${deployment_state:-unknown} after timing out on attempt ${attempt}"
                    exit 2
                    ;;
            esac
        fi
    fi

    if [[ $deployment_rc -eq 0 ]]; then
        diagnostics_enabled=$(az vm show \
          --subscription "$SUBSCRIPTION_ID" \
            --resource-group "$ACTIVE_RG" \
            --name "$VM_NAME" \
            --query "diagnosticsProfile.bootDiagnostics.enabled" \
            --output tsv)
        [[ "$diagnostics_enabled" == "true" ]] || die "Managed boot diagnostics was not enabled"

        successful_attempts=$(( successful_attempts + 1 ))
        log "Attempt ${attempt} provisioned successfully"
        delete_active_rg_or_continue
        continue
    fi

    printf '%s\n' "$deployment_output" >&2
    if grep -qi "OSProvisioningTimedOut" <<< "$deployment_output"; then
        PRESERVE_RG=true
        diagnostics_enabled=$(az vm show \
          --subscription "$SUBSCRIPTION_ID" \
            --resource-group "$ACTIVE_RG" \
            --name "$VM_NAME" \
            --query "diagnosticsProfile.bootDiagnostics.enabled" \
            --output tsv 2>/dev/null || true)

        print_preserved_attempt \
            "REPRODUCED" \
            "OSProvisioningTimedOut on attempt ${attempt}" \
            "${diagnostics_enabled:-unknown}"
        exit 0
    fi

    non_target_failures=$(( non_target_failures + 1 ))
    warn "Attempt ${attempt} failed without OSProvisioningTimedOut; cleaning and continuing"
    delete_active_rg_or_continue
done

printf '\nNo OSProvisioningTimedOut reproduced in %d attempts (%d successful, %d other failures).\n' \
    "$MAX_ATTEMPTS" "$successful_attempts" "$non_target_failures"
exit 1
