# Creating a BYOI AKS Image from acldevel Output

This guide describes how to build a custom ACL (Azure Container Linux) image using the **acldevel** pipeline and deploy it to AKS using the BYOI (Bring Your Own Image) flow. This is useful for validating in-progress changes (e.g., SELinux policy fixes) on real AKS nodes before merging.

## Prerequisites

- Access to the [acldevel pipeline](https://dev.azure.com/mariner-org/ACL/_build?definitionId=5303) in the ACL project
- Access to the [aks-image-build (MAP) pipeline](https://dev.azure.com/mariner-org/mariner/_build?definitionId=3285&_a=summary) in the mariner project
- Azure CLI installed and logged in (`az login`)
- An SSH key pair (`~/.ssh/id_rsa.pub`)
- AKS BYOI preview feature enabled on your subscription

## Overview

```
acl-scripts branch ──► acldevel pipeline ──► aks-image-build (MAP) pipeline ──► BYOI custom headers ──► az aks create
```

## Step 1: Run the acldevel Pipeline

1. Navigate to [acldevel pipeline runs](https://dev.azure.com/mariner-org/ACL/_build?definitionId=5303).
2. Click **Run pipeline**.
3. Set the **aclScriptsRef** parameter ("[Source] acl-scripts branch/commit") to your acl-scripts branch name (e.g., `satyan/shipit`).
4. Leave other parameters at their defaults (UKI boot mode, amd64 arch, etc.) unless you need to customize.
5. Click **Next: Resources** and then **Run** to start the pipeline. Wait for the build to complete.
6. Note the **build ID** from the completed run (visible in the URL or run list).

## Step 2: Run the aks-image-build (MAP) Pipeline

1. Navigate to the [aks-image-build pipeline](https://dev.azure.com/mariner-org/mariner/_build?definitionId=3285) in the mariner project.
2. Click **Run pipeline**.
3. **Important:** Select the `main` branch for the pipeline.
4. Configure the following parameters:
   - Under the **Build\*** options, select only **"Build Azure Container Linux"**.
   - Set **"(Optional) ACL upstream pipeline ID"** to `5303` (the acldevel pipeline definition ID).
   - Set **"(Optional) ACL upstream specific build ID (0 = latest)"** to your acldevel build ID from Step 1 (or `0` to use the latest successful acldevel build).
5. Click **Next: Resources** and then **Run** to start the pipeline. Wait for the build to complete (~1 hour).

> **Note:** The MAP pipeline automatically replicates the acldevel image to
> the required regions (including `westus3`) as part of its build. No manual
> replication steps are needed.

## Step 3: Extract the Custom Header Payload

Once the aks-image-build pipeline completes:

1. Open the completed build run.
2. Navigate to the **build_image_v3_core** stage → **Build Azure Container Linux** job → **Generate SIG info** task.
3. In the task log output, find the **custom_header payload**. It will look something like:

```
AKSHTTPCustomFeatures=Microsoft.ContainerService/UseCustomizedOSImage,\
OSImageSubscriptionID=<subscription-id>,\
OSImageResourceGroup=<resource-group>,\
OSImageGallery=<gallery>,\
OSImageName=<image-name>,\
OSImageVersion=<image-version>,\
OSSKU=Flatcar,\
OSDistro=CustomizedImageLinuxGuard
```

4. Copy the entire custom header string — you will use it in the next step.

## Step 4: Create an AKS Cluster with the BYOI Image

### Set Up Variables

```bash
export DEFAULT_RG="<your-resource-group>"
export DEFAULT_PUBKEY="$HOME/.ssh/id_rsa.pub"
```

### Create a Resource Group (if needed)

```bash
az group create --name $DEFAULT_RG --location "westus2"
```

### Create the AKS Cluster

Use the custom headers from Step 3:

```bash
az aks create \
    --resource-group $DEFAULT_RG \
    --name "acl-byoi-test" \
    --location "westus2" \
    --ssh-key-value $DEFAULT_PUBKEY \
    --enable-secure-boot \
    --enable-vtpm \
    --aks-custom-headers \
AKSHTTPCustomFeatures=Microsoft.ContainerService/UseCustomizedOSImage,\
OSImageSubscriptionID=<subscription-id>,\
OSImageResourceGroup=<resource-group>,\
OSImageGallery=<gallery>,\
OSImageName=<image-name>,\
OSImageVersion=<image-version>,\
OSSKU=Flatcar,\
OSDistro=CustomizedImageLinuxGuard \
    --nodepool-tags AzSecPackAutoConfigReady=true \
    --node-os-upgrade-channel None
```

> Replace the `<...>` placeholders with the actual values from the custom header payload in Step 3.

## Step 5: Verify the Cluster

### Fetch Kubeconfig

```bash
az aks get-credentials -g $DEFAULT_RG -n acl-byoi-test
```

### Verify Nodes

```bash
kubectl get nodes -o wide -A
```

The `OS-IMAGE` column should show your custom ACL image on all nodes.

## Step 6: Access a Node (Optional)

To inspect logs (e.g., `dmesg` for SELinux AVCs), use [kubectl node-shell](https://github.com/kvaps/kubectl-node-shell) to get a root shell directly on the node.

### Install node-shell

```bash
curl -LO https://github.com/kvaps/kubectl-node-shell/raw/master/kubectl-node_shell
chmod +x kubectl-node_shell
sudo mv kubectl-node_shell /usr/local/bin/kubectl-node_shell
```

### Connect to a node

1. List the nodes:

   ```bash
   kubectl get nodes -o wide
   ```

2. Open a shell on the target node:

   ```bash
   kubectl node-shell <node-name>
   ```

3. Once on the node, inspect logs:

   ```bash
   dmesg | grep -i avc
   journalctl -b | grep -i selinux
   ```

## Cleanup

```bash
az group delete --name $DEFAULT_RG --yes --no-wait
```

## Troubleshooting

| Issue | Resolution |
|---|---|
| "Next: Resources" button grayed out in pipeline UI | This can happen if pipeline variables are misconfigured. Check that all required parameters have valid defaults (e.g., version override should default to `none`). |
| `InvalidOSSKU` / `AKSFlatcarPreview` errors on `az aks create` | Register the `Microsoft.ContainerService/AKSFlatcarPreview` feature on your subscription: `az feature register --namespace Microsoft.ContainerService --name AKSFlatcarPreview` |

## References

- [acldevel pipeline](https://dev.azure.com/mariner-org/ACL/_build?definitionId=5303)
- [ACL Beta Release wiki page](https://dev.azure.com/mariner-org/mariner/_wiki/wikis/Azure%20Container%20Linux%20Plan/6560/Azure-Container-Linux-Beta)
