# Provisioning Azure Container Linux (ACL) on AKS

## Prerequisites

- Your subscription must have the **AKS BYOI (Bring Your Own Image) preview feature** enabled.
- Azure CLI installed and logged in (`az login`).
- An SSH public key at `~/.ssh/id_rsa.pub`. If you don't have one, generate it:
  ```bash
  ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
  ```

## 1. Set Variables

```bash
export DEFAULT_RG="<your-resource-group>"
export DEFAULT_PUBKEY="$HOME/.ssh/id_rsa.pub"
```

## 2. Create the AKS Cluster

```bash
az aks create \
  -g $DEFAULT_RG \
  -n acl-cluster \
  --location westus3 \
  --ssh-key-value $DEFAULT_PUBKEY \
  --aks-custom-headers \
    AKSHTTPCustomFeatures=Microsoft.ContainerService/UseCustomizedOSImage,\
OSImageSubscriptionID=035db282-f1c8-4ce7-b78f-2a7265d5398c,\
OSImageResourceGroup=MarinerAKSTest,\
OSImageGallery=MarinerAKSSig,\
OSImageName=flatcargen2,\
OSImageVersion=1.1771631798.14161,\
OSSKU=Flatcar,\
OSDistro=CustomizedImage \
  --nodepool-tags AzSecPackAutoConfigReady=true \
  --node-os-upgrade-channel None
```

NOTE: **Flatcar name is present in the image definition due to temporary work-arounds**

## 3. Fetch Kubeconfig

```bash
az aks get-credentials -g $DEFAULT_RG -n acl-cluster
```

## 4. Verify ACL is Running

```bash
kubectl get nodes -o wide -A
```

The `OS-IMAGE` column should show the ACL image on all nodes.
