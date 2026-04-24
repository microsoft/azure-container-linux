# Azure Container Linux (ACL) Bug Bash Guide

Azure Container Linux (ACL) is an immutable, container-optimized Linux distribution set to GA at Build 2026.

This guide will walk you through deploying and testing Azure Container Linux (ACL) on AKS.

## ACL Image Versions

There are currently **two ACL image versions** available for testing
> **Note**: Please pick to focus on either the Alpha or Beta image scenarios. If time permits, you may explore both.

### Alpha Version (Older)
- **Availability**: Rolled out in AKS RP
- **Access**: Available in all Microsoft and AME tenant subscriptions.
- **Testing Focus**: AKS CRUD operations

### Beta Version (Newer) 
- **Availability**: Only available via AKS BYOI (Bring Your Own Image)
- **Access**: Requires AKS BYOI preview feature enabled
- **Testing Focus**: Application, agent, and extension capabilities

#### What's New in Beta

**Security**
- **SELinux set to enforcing** — SELinux is now enforcing by default

**Platform & Image**
- **UKI is now the default boot mode**
- **ARM64 support** — New multi-arch build pipeline and `acl-aks-arm64` image definition for ARM64-based AKS node pools
- **waagent (Azure Linux Agent) support** — Initial waagent integration for ACL, with SSH fix for the waagent service
- **Afterburn refresh** — Updated afterburn based on Azure Linux upstream
- **Ignition refresh** — Updated ignition based on Azure Linux upstream
- **Disabled azure-ephemeral-disk-setup service** via systemd preset
- **Removed flatcar.autologin** from Azure OEM config
- **Fixed os-release** — Corrected VARIANT_ID and ID_LIKE fields
- **Kernel config availability** for kubeadm ensured

**Sysexts**
- **Sysext SBOM generation** — Sysexts now include software bill of materials
- **Custom docker sysext unblocked**
- **fuse2/fuse3 libs added** to azure sysext
- **etcd-wrapper cert mount fix**

### Resources to learn more about ACL: 
- [ACL PRD](https://github.com/azure-management-and-platforms/aks-handbook/blob/main/prd/security/azure-container-linux.md)
- [ACL Design Doc](https://github.com/azure-management-and-platforms/aks-handbook/pull/87)


## Bug Filing
If you discover a bug while validating the ACL Beta Release Candidate, please file it using the following process:

**Bug Tracker**: [Bug Template](https://dev.azure.com/mariner-org/70814062-73d6-4295-8e5f-b224172b9c69/_workitems/create/Bug?templateId=7ef97670-eb30-4a01-a4da-e94970a684ff&ownerId=26763cae-4d2d-4f0e-b438-dadf2ae7ad46)

**Bug Title Prefix**: ACL Beta RC Bugbash: 

Include in bug description:  

- Scenario name 

- Image version / build ID 

- Azure region / VM SKU / architecture (if applicable) 

- Logs or repro steps 

## Environment Setup
Logged into Azure CLI 
```bash
az login
```
An SSH public key at ~/.ssh/id_rsa.pub. 

If you don't have one, generate it:
```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```
### Set Variables
```bash
export DEFAULT_RG="<your-resource-group>"
export DEFAULT_KEY="$HOME/.ssh/id_rsa" 
export DEFAULT_PUBKEY="${DEFAULT_KEY}.pub"
```
### Create a Resource Group
```bash
az group create --name $DEFAULT_RG --location "westus2"
```

# Bug Bash Scenarios

Please select either the Alpha or Beta scenario to focus on during the bug bash. If time permits, you’re welcome to explore both.

Be sure to complete the appropriate tab (Alpha or Beta) in the tracking sheet based on the image you are testing: [ACL Bug Bash.xlsx](https://microsoft-my.sharepoint.com/:x:/p/florataagen/cQpFrZAvkaI1R6s8m3-GrojPEgUCinERElb4atK-XDTUGBJOMg)


### Known Limitations / Considerations across Alpha and Beta

- Features not currently supported in the ACL Beta Release include: 
    - Artifact Streaming, 
    - FIPS enabled images, 
    - Non-TL enabled images (Gen 1 VMs),
    - CVM images
- Only node image upgrade channels supported are `NodeImage` and `None`.

## Alpha Bug Bash Scenarios

Please aim to complete scenarios A through D (sequentially) and at least one scenario from the Ideas for Further Testing section. Please track your progress in the following sheet (Alpha tab): [ACL Bug Bash.xlsx](https://microsoft-my.sharepoint.com/:x:/p/florataagen/cQpFrZAvkaI1R6s8m3-GrojPEgUCinERElb4atK-XDTUGBJOMg)
-	Mark the scenarios you completed with ‘Done’
-	If you completed further testing please describe the scenario you tested 

### Alpha Prerequisites
- The Azure CLI tool installed, updated, and configured
- The Kubernetes CLI tool (kubectl) installed, updated, and configured
- The aks-preview extension installed, updated, and configured. To install the aks-preview extension, run the following command:
```bash
az extension add --name aks-preview
```
Then, run the following command to update to the latest version of the extension released:
```bash
az extension update --name aks-preview
```

## Scenario A [Alpha]: Provisioning ACL on AKS

In scenario A we will deploy a new ACL cluster on AKS. 


**Available Regions**

The alpha image is available as part of the v20260402 AKS RP release. 

**Available regions include**: Australia Central, Australia East, Brazil South, Canada Central, Central India, China East 2, China East 3, China North 2, China North 3, East Asia, East US, East US 2, France Central, Germany West Central, Italy North, Japan East, Jio India West, Korea Central, Malaysia South, Mexico Central, North Central US, North Europe, Norway East, South Africa North, Sweden Central, Switzerland North, Taiwan North, UK South, UK West, US Gov Arizona, US Gov Texas, US Gov Virginia, West Central US, West US 2 

See [all available regions here](https://releases.aks.azure.com/AKSRelease).

Choose to provision either an **amd64 (1a)** or **arm64 (1b)** ACL node on AKS. Please note, ACL on Arm64 requires Cobalt-based (v6) SKUs to enable Trusted Launch compatibility.


1a. Create an AKS Cluster (amd64)
```bash
az aks create \
    --resource-group $DEFAULT_RG \
    --name "acl-cluster" \
    --location "westus2" \
    --ssh-key-value $DEFAULT_PUBKEY \
    --os-sku AzureContainerLinux \
    --node-vm-size <<amd64 VM size>>
```

1b. Create an AKS Cluster (arm64)
```bash
az aks create \
    --resource-group $DEFAULT_RG \
    --name "acl-cluster" \
    --location "westus2" \
    --ssh-key-value $DEFAULT_PUBKEY \
    --os-sku AzureContainerLinux \
    --node-vm-size <<arm64 VM size>>
```

2. Verify the AKS cluster is running with the ACL node image. 

Fetch kubectl credentials for the AKS cluster:
```bash
az aks get-credentials --resource-group $DEFAULT_RG --name "acl-cluster"
```

Verify the node image:
```bash
kubectl get nodes -o wide
``` 
**Expected Results:**
- The `OS-IMAGE` column should show the ACL image on all nodes.
- All nodes should be in `Ready` state

## Scenario B [Alpha]: Mixed Node Pools - ACL Coexistence with Other OS Types

In scenario B we will verify that ACL nodes can coexist with other node types (Azure Linux, Ubuntu) within the same AKS cluster.

**Prerequisites**: Complete Scenario A to have an existing ACL cluster running.

### 1. Add an Azure Linux Node Pool

Add a new node pool running Azure Linux to your existing ACL cluster, ensure that the node VM size is Gen2 (i.e. TL compatible):

```bash
az aks nodepool add \
    --resource-group $DEFAULT_RG \
    --cluster-name "acl-cluster" \
    --name "azurelinux" \
    --node-count 1 \
    --os-sku AzureLinux 
```

### 2. Verify Mixed Node Pool Deployment

Fetch kubectl credentials if not already configured:

```bash
az aks get-credentials --resource-group $DEFAULT_RG --name "acl-cluster"
```

Verify that both ACL and Azure Linux nodes are running in the same cluster:

```bash
kubectl get nodes -o wide
```

**Expected Results:**
- The `OS-IMAGE` column should show ACL image for the original nodes
- The `OS-IMAGE` column should show `azl 3.0` for the newly added Azure Linux node
- All nodes should be in `Ready` state
- Different OS types should be visible in the same cluster output

## Scenario C [Alpha]: OS SKU Migration - Azure Linux to Azure Container Linux

In scenario C we will perform an OS SKU migration to convert the Azure Linux node pool (created in Scenario B) back to Azure Container Linux.

**Prerequisites**: Complete Scenario B to have an Azure Linux node pool running alongside ACL nodes.

### 1. Perform OS SKU Migration

Migrate the Azure Linux node pool to use Azure Container Linux OS SKU (*Note: unless the nodepool you created in scenario B explicitly enabled secure boot and vTPM, you will need to enable them during the migration*):

```bash
az aks nodepool update \
    --resource-group $DEFAULT_RG \
    --cluster-name "acl-cluster" \
    --name "azurelinux" \
    --os-sku "AzureContainerLinux" \
    --enable-secure-boot \
    --enable-vtpm 
```

### 2. Verify Migration Completion

After the migration completes, verify that the node pool has been successfully migrated:

```bash
# Verify all nodes now show ACL OS image
kubectl get nodes -o wide
```

**Expected Results After Migration:**
- All nodes (including the migrated `azurelinux` node pool) should show ACL image in the `OS-IMAGE` column
- All nodes should be in `Ready` state

## Scenario D [Alpha]: Node Image Upgrades and Scale Operations

In scenario D we will test node image upgrades on ACL nodes.

**Prerequisites**: Complete Scenario A to have an existing ACL cluster running.

### 1. Enable Node Image Upgrade Channel

Configure the cluster to use NodeImage upgrade channel for automatic node image updates:

```bash
az aks update \
    --resource-group $DEFAULT_RG \
    --name "acl-cluster" \
    --node-os-upgrade-channel NodeImage
```

### 2. Trigger Node Image Upgrade

Manually trigger a node image upgrade to test the upgrade process:

```bash
# Trigger node image upgrade
az aks nodepool upgrade \
    --resource-group $DEFAULT_RG \
    --cluster-name "acl-cluster" \
    --name "nodepool1" \
    --node-image-only
```

### 3. Test Cluster Scaling Operations

Test that ACL node pools can be scaled up and down properly:

```bash
# Scale up the node pool
az aks nodepool scale \
    --resource-group $DEFAULT_RG \
    --cluster-name "acl-cluster" \
    --name "nodepool1" \
    --node-count 4

# Verify scaling completed
kubectl get nodes

# Scale back down
az aks nodepool scale \
    --resource-group $DEFAULT_RG \
    --cluster-name "acl-cluster" \
    --name "nodepool1" \
    --node-count 3
```

### 4. Verify Post-Upgrade Functionality

After upgrades and scaling operations, verify that ACL nodes are functioning correctly:

```bash
# Check final node status and versions
kubectl get nodes -o wide
```

**Expected Results:**
- Node image upgrades complete successfully without errors
- ACL nodes maintain functionality after upgrades
- Scaling operations work correctly with ACL node pools
- All nodes remain in `Ready` state throughout operations


## [Alpha] Ideas for Further Testing
-   Test ACL for different node pool sizes such as small, medium, and large
-   Test ACL for NVIDIA amd64 GPU nodepools
-   Test ACL with Node Auto Provisioner (NAP)
-   Test ACL for different cluster configurations such as RBAC, network policies, etc. 
-   Test ACL for different cluster addons, such as monitoring, logging, etc. 
-   Test ACL for different customer applications and workloads, such as web servers, databases, etc. 
-   Test ACL for different customer requirements and expectations, such as security, performance, availability, etc. 
-   Test ACL on any other customer scenarios you can envision


## Beta Bug Bash Scenarios

Please aim to complete scenarios A and B. Please track your progress in the following sheet (Beta tab): [ACL Bug Bash.xlsx](https://microsoft-my.sharepoint.com/:x:/p/florataagen/cQpFrZAvkaI1R6s8m3-GrojPEgUCinERElb4atK-XDTUGBJOMg)
-	Mark the scenarios you completed with ‘Done’
-   Add the specific Add-ons and Extensions you tested (please mark the number and/or name in the sheet).


## Beta Prerequisites
> **IMPORTANT** To gain access to the gallery containing the beta image, enroll in [AzureLinux-Reader](https://coreidentity.microsoft.com/manage/Entitlement/entitlement/azlreaderent-otvb)

> **IMPORTANT** To test the beta image your subscription must have the AKS BYOI (Bring Your Own Image) preview feature enabled. 
> If your subscription does not have AKS BYOI enabled, please request Guest-Contributor access to [Azure-Linux-Platform Core Identity](https://coreidentity.microsoft.com/manage/Entitlement/entitlement/azurelinuxco-3z0j) and use subscription `EdgeOS_Mariner_Platform_dev` for the following scenarios.
- The Azure CLI tool installed, updated, and configured
- The Kubernetes CLI tool (kubectl) installed, updated, and configured
- The aks-preview extension installed, updated, and configured

## Scenario A [Beta]: Provisioning ACL on AKS

In scenario A we will deploy a new ACL cluster on AKS. 

**Available regions**: 
-   eastus
-   westus2

Choose to provision either an **amd64 (1a)** or **arm64 (1b)** ACL node on AKS. Please note, ACL on Arm64 requires Cobalt-based (v6) SKUs to enable Trusted Launch compatibility.

1a. Create an AKS Cluster (amd64)
```bash
az aks create \
    --resource-group $DEFAULT_RG \
    --name "acl-cluster" \
    --location "westus2" \
    --ssh-key-value $DEFAULT_PUBKEY \
    --enable-secure-boot \
    --enable-vtpm \
    --aks-custom-headers \
AKSHTTPCustomFeatures=Microsoft.ContainerService/UseCustomizedOSImage,\
OSImageSubscriptionID=b3e01d89-bd55-414f-bbb4-cdfeb2628caa,\
OSImageResourceGroup=ACL-IMAGES,\
OSImageGallery=acl,\
OSImageName=acl-aks,\
OSImageVersion=1.1775601122.6691,\
OSSKU=AzureContainerLinux,\
OSDistro=CustomizedImageLinuxGuard \
    --nodepool-tags AzSecPackAutoConfigReady=true \
    --node-os-upgrade-channel None
```

1b. Create an AKS Cluster (arm64)
```bash
az aks create \
    --resource-group $DEFAULT_RG \
    --name "acl-cluster" \
    --location "westus2" \
    --ssh-key-value $DEFAULT_PUBKEY \
    --node-vm-size Standard_D2pds_v6 \
    --enable-secure-boot \
    --enable-vtpm \
    --aks-custom-headers \
AKSHTTPCustomFeatures=Microsoft.ContainerService/UseCustomizedOSImage,\
OSImageSubscriptionID=b3e01d89-bd55-414f-bbb4-cdfeb2628caa,\
OSImageResourceGroup=ACL-IMAGES,\
OSImageGallery=acl,\
OSImageName=acl-aks-arm64,\
OSImageVersion=1.1776195556.10516,\
OSSKU=AzureContainerLinux,\
OSDistro=CustomizedImageLinuxGuard \
    --nodepool-tags AzSecPackAutoConfigReady=true \
    --node-os-upgrade-channel None
```
2. Verify the AKS cluster is running with the ACL node image. 

Fetch kubectl credentials for the AKS cluster:
```bash
az aks get-credentials --resource-group $DEFAULT_RG --name "acl-cluster"
```

Verify the node image:
```bash
kubectl get nodes -o wide
``` 
**Expected Results:**
- The `OS-IMAGE` column should show the ACL image on all nodes.
- All nodes should be in `Ready` state

## Scenario B [Beta]: AKS Add-ons and Extensions Testing Matrix

Please pick **three** scenarios from below and test them out on the ACL node you created in Scenario A. Please mark the number and/or name of the Add-ons/Extensions you tested in the sheet: : [ACL Bug Bash.xlsx](https://microsoft-my.sharepoint.com/:x:/p/florataagen/cQpFrZAvkaI1R6s8m3-GrojPEgUCinERElb4atK-XDTUGBJOMg)

| Name | Type | Description | Documentation Link |
|------|------|-------------|-------------------|
| 1. Application Gateway Ingress | Add-on | Ingress controller using Azure Application Gateway | https://learn.microsoft.com/en-us/azure/application-gateway/ingress-controller-overview |
| 2. KEDA | Add-on | Event-driven autoscaling | [Kubernetes Event-driven Autoscaling](https://keda.sh/) |
| 3. Container Insights & Prometheus | Add-on | Monitoring via Azure Monitor and Prometheus | [Container insights overview](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-overview) [Managed Prometheus overview](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/prometheus-metrics-overview) |
| 4. Key Vault CSI Driver | Add-on | Mount secrets from Azure Key Vault | https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-driver |
| 5. Virtual Nodes | Add-on | Burst workloads into Azure Container Instances | https://learn.microsoft.com/en-us/azure/aks/virtual-nodes |
| 6. Node Auto Provisioner (NAP) | Add-on | Automatically provisions optimal node pools | https://learn.microsoft.com/en-us/azure/aks/node-autoprovision |
| 7. Azure Policy Add-on | Add-on | Governance and compliance enforcement | https://learn.microsoft.com/en-us/azure/aks/use-azure-policy |
| 8. Web Application Routing | Add-on | Modern ingress with nginx and external-dns | https://learn.microsoft.com/en-us/azure/aks/web-app-routing |
| 9. Azure Workload Identity | Add-on | Secure pod-to-Azure resource authentication | https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview |
| 10. Azure Files CSI Driver | Add-on | File share storage for pods | https://learn.microsoft.com/en-us/azure/aks/azure-files-csi |
| 11. Azure Disk CSI Driver | Add-on | Block storage for pods | https://learn.microsoft.com/en-us/azure/aks/azure-disk-csi |
| 12. Vertical Pod Autoscaler | Add-on | Automatically adjust pod resource requests | https://learn.microsoft.com/en-us/azure/aks/vertical-pod-autoscaler |
| 13. Azure CNI Powered by Cilium | Add-on | Advanced networking with eBPF | https://learn.microsoft.com/en-us/azure/aks/azure-cni-powered-by-cilium |
| 14. Azure App Configuration | Extension | Centralized app settings and feature flags | https://learn.microsoft.com/en-us/azure/aks/azure-app-configuration-quickstart |
| 15. Azure Machine Learning | Extension | Train and deploy ML models on AKS | https://learn.microsoft.com/en-us/azure/machine-learning/how-to-attach-kubernetes-anywhere |
| 16. GitOps (Flux) | Extension | Declarative deployment via GitOps | https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/conceptual-gitops-flux2 |
| 17. Azure Container Storage | Extension | Persistent block storage for containers | https://learn.microsoft.com/en-us/azure/storage/container-storage/container-storage-introduction |
| 18. Dapr | Extension | Microservice building blocks (state, pub/sub, etc.) | https://learn.microsoft.com/en-us/azure/aks/dapr |
| 19. Azure Service Operator (ASO) | Extension | Manage Azure resources from Kubernetes | https://learn.microsoft.com/en-us/azure/service-operator/ |
| 20. Istio Service Mesh | Add-on | Advanced networking and security for services | [Istio-based service mesh add-on for Azure Kubernetes Service](https://learn.microsoft.com/en-us/azure/aks/istio-about) |
| 21. Deploy a sample application | Application | Quickstart | [Quickstart: Deploy an Azure Kubernetes Service](https://learn.microsoft.com/en-us/azure/aks/learn/quick-kubernetes-deploy-cli) | 

## Useful Diagnostic Commands

```bash
# View deployment status
az deployment group show --resource-group $DEFAULT_RG --name osguard-deployment -o table

# Get cluster details
az aks show --resource-group $DEFAULT_RG --name "acl-cluster" -o yaml

# Check node logs
kubectl logs -n kube-system -l component=kube-proxy --tail=50

# Describe problematic pods
kubectl describe pod <pod-name> -n <namespace>

# Get cluster diagnostic information
az aks get-credentials --resource-group $DEFAULT_RG --name "acl-cluster" --admin
kubectl cluster-info dump > cluster-info-dump.txt
```

## Cleanup
When you're done testing:

```bash
# Delete the entire resource group (this will delete the cluster and all resources)
az group delete --name $DEFAULT_RG --yes --no-wait

# Or just delete the cluster
az aks delete --resource-group $DEFAULT_RG --name "acl-cluster" --yes --no-wait

# Clean up local kubectl config
kubectl config delete-context "acl-cluster"
```