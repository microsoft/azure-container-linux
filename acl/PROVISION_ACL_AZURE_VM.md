# Provisioning an ACL VM from the Official Gallery

## Prerequisites

- Azure CLI installed and logged in (`az login`).
- An SSH public key at `~/.ssh/id_rsa.pub`. If you don't have one, generate it:
  ```bash
  ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
  ```

## 1. Set Variables

```bash
export DEFAULT_RG="my-acl-vm-rg"
export DEFAULT_KEY="$HOME/.ssh/id_rsa"
export DEFAULT_PUBKEY="${DEFAULT_KEY}.pub"
```

## 2. Create a Resource Group

```bash
az group create --name $DEFAULT_RG --location "westus2"
```

## 3. Create the VM

```bash
az vm create \
  --resource-group $DEFAULT_RG \
  --name "my-acl-vm" \
  --image "/subscriptions/035db282-f1c8-4ce7-b78f-2a7265d5398c/resourceGroups/acl/providers/Microsoft.Compute/galleries/acldevel/images/acl/versions/latest" \
  --location "westus2" \
  --size "Standard_D2s_v5" \
  --admin-username "azureuser" \
  --ssh-key-values $DEFAULT_PUBKEY \
  --security-type TrustedLaunch \
  --enable-vtpm true \
  --enable-secure-boot false \
  --public-ip-sku Standard
```

> **Important:** The gallery is replicated to `westus2` only. Create your VM in `westus2`.

### 3a. Create a GPU VM

To create a VM with an NVIDIA GPU (e.g., for CUDA workloads), use a GPU-enabled VM size (below example uses NC A100 VM SKU):

```bash
az vm create \
  --resource-group $DEFAULT_RG \
  --name "my-acl-gpu-vm" \
  --image "/subscriptions/035db282-f1c8-4ce7-b78f-2a7265d5398c/resourceGroups/acl/providers/Microsoft.Compute/galleries/acldevel/images/acl-gpu/versions/latest" \
  --location $GPU_VM_REGION \
  --size "Standard_NC24ads_A100_v4" \
  --admin-username "azureuser" \
  --ssh-key-values $DEFAULT_PUBKEY \
  --security-type TrustedLaunch \
  --enable-vtpm true \
  --enable-secure-boot false \
  --public-ip-sku Standard
```

> **Note:** GPU VM sizes (e.g., `Standard_NC24ads_A100_v4`) require quota in your subscription. Ensure to update $GPU_VM_REGION with a qualified region that has sufficient GPU quotas for deployment. 

## 4. Connect to the VM

```bash
ssh -i $DEFAULT_KEY azureuser@<public-ip-from-output>
```

### 4a. Install GPU Sysexts on the VM

GPU sysext images are published to ACR as OCI artifacts. To enable GPU support on the immutable ACL image, you need to deploy one or more GPU sysexts (refer to the instruction below):

```bash
  # Install oras (if not already present)
  VERSION="1.3.0"
  sudo mkdir -p /opt/oras-install/
  sudo curl -L -o /opt/oras-install/oras_${VERSION}_linux_amd64.tar.gz \
    "https://github.com/oras-project/oras/releases/download/v${VERSION}/oras_${VERSION}_linux_amd64.tar.gz"
  
  sudo tar -zxf /opt/oras-install/oras_${VERSION}_*.tar.gz -C /opt/oras-install/
  export PATH="/opt/oras-install:$PATH"
  sudo rm /opt/oras-install/oras_${VERSION}_*.tar.gz

  # Pull GPU sysext images
  ACL_OS_VERSION="4459.2.2"
  ACL_GPU_REPO="maritimusstaging.azurecr.io/acl/nvidia-gpu"

  # Mandatory: contains the NVIDIA GPU driver
  oras pull -o /tmp/sysext ${ACL_GPU_REPO}/cuda-open:${ACL_OS_VERSION}

  # Optional: required for GPU container usage
  oras pull -o /tmp/sysext ${ACL_GPU_REPO}/nvidia-container-toolkit:${ACL_OS_VERSION}

  # Optional: required for multi-GPU environments
  oras pull -o /tmp/sysext ${ACL_GPU_REPO}/nvidia-fabric-manager:${ACL_OS_VERSION}

  sudo find /tmp/sysext -name '*.raw' -exec mv {} /etc/extensions/ \;
  rm -rf /tmp/sysext

  # Refresh sysext
  sudo systemd-sysext refresh

  # Verify GPU status
  sudo nvidia-smi

  # Optional: start nvidia-fabricmanager service in multi-GPU environments
  sudo systemctl enable nvidia-fabricmanager
  sudo systemctl start nvidia-fabricmanager
```

## 5. Cleanup

```bash
az group delete --name $DEFAULT_RG --yes --no-wait
```

## Access

If you get a permissions error querying the gallery, ask a gallery admin (Chris Co, chrco@microsoft.com OR Henry Beberman, hebeberm@microsoft.com) to grant you Reader access:

```bash
az role assignment create \
  --assignee "<your-user-or-sp-object-id>" \
  --role "Reader" \
  --scope "/subscriptions/035db282-f1c8-4ce7-b78f-2a7265d5398c/resourceGroups/acl/providers/Microsoft.Compute/galleries/acldevel"
```
