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

## 4. Connect to the VM

```bash
ssh -i $DEFAULT_KEY azureuser@<public-ip-from-output>
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
