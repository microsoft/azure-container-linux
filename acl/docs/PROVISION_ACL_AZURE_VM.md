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
az group create --name "$DEFAULT_RG" --location "westus2"
```

## 3. Create the VM

```bash
az vm create \
  --resource-group "$DEFAULT_RG" \
  --name "my-acl-vm" \
  --image "/subscriptions/b3e01d89-bd55-414f-bbb4-cdfeb2628caa/resourceGroups/acl-images/providers/Microsoft.Compute/galleries/acl/images/acl/versions/3.0.20260401" \
  --location "westus2" \
  --size "Standard_D2s_v5" \
  --admin-username "azureuser" \
  --ssh-key-values "$DEFAULT_PUBKEY" \
  --security-type TrustedLaunch \
  --enable-vtpm true \
  --public-ip-sku Standard
```

To create GPU-enabled VMs, use GPU VM SKUs (e.g., `Standard_NC24ads_A100_v4`) and ensure to deploy in a region with sufficient GPU quotas. 

## 4. Connect to the VM

```bash
ssh -i $DEFAULT_KEY azureuser@<public-ip-from-output>
```

### 4a. Install GPU Sysexts on the VM

To enable GPU support on the immutable ACL image, you need to deploy one or more
GPU sysexts (refer to the instruction below). GPU sysext images are published to
ACR as OCI artifacts. Follow the instructions below to pull and install the GPU sysexts on the ACL VM.

> **Tip:** For automated GPU smoke testing (including sysext delivery and verification),
> see the [GPU Smoke Testing](BUILD_RPM_IMAGE_README.md#gpu-smoke-testing-azure-only) section
> in the BUILD_RPM_IMAGE_README.

> **Note:** The Azure GPU pipeline (`acl-pipelines`, stages `publish_sysexts` and
> `test_kola_azure_gpu`) installs `oras` the same way — `tdnf install -y oras` on
> the 1ES Azure Linux agent, with a retried-curl tarball fallback for non-AzL
> agents. The manual instructions and the pipeline are deliberately aligned so
> you can reproduce a pipeline failure locally by running the same steps.

```bash
# Install oras (if not already present)
# Option A: Azure Linux (tdnf) — matches what the pipeline does
sudo tdnf install -y oras

# Option B: Manual install (any Linux)
ORAS_VERSION="1.3.0"
curl -fsSL -o /tmp/oras.tar.gz \
  "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz"
sudo tar -zxf /tmp/oras.tar.gz -C /usr/local/bin/ oras
rm -f /tmp/oras.tar.gz

# Pull GPU sysext images
source /etc/os-release
ACL_GPU_REPO="mcr.microsoft.com/azurelinux/3.0/azure-container-linux"

# Mandatory: contains the NVIDIA GPU driver
oras pull -o /tmp/sysext ${ACL_GPU_REPO}/nvidia-driver-cuda-open:${VERSION_ID}

# Optional: required for GPU container usage
oras pull -o /tmp/sysext ${ACL_GPU_REPO}/nvidia-container-toolkit:${VERSION_ID}

# Optional: required for multi-GPU environments
oras pull -o /tmp/sysext ${ACL_GPU_REPO}/nvidia-fabric-manager:${VERSION_ID}

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
