# Azure Container Apps with Private Blob Storage Access Using Workload Identity

This guide walks through deploying an Azure Container Apps (ACA) environment that securely accesses Azure Blob Storage over a private endpoint, authenticated via Workload Identity — no shared keys, no secrets in code.

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────┐
│                     ACA Environment (VNet-integrated)                   │
│                                                                        │
│  ┌────────────────────────┐         ┌──────────────────────────────┐  │
│  │  Container App         │         │  Private Endpoint (blob)     │  │
│  │  (Workload Identity)   │────────▶│  privatelink.blob.core...    │  │
│  │  + Ingress (ext/int)   │  HTTPS  │  10.0.2.x                   │  │
│  └────────────────────────┘         └──────────┬───────────────────┘  │
│            │                                    │                      │
└────────────┼────────────────────────────────────┼──────────────────────┘
             │                                    │
             ▼                                    ▼
    ┌─────────────────┐         ┌────────────────────────────────┐
    │  External Users  │         │  Azure Blob Storage            │
    │  (if ext ingress)│         │  publicNetworkAccess: Disabled │
    └─────────────────┘         │  Workload Identity auth (RBAC) │
                                └────────────────────────────────┘
```

**Key principles:**
- No shared keys or connection strings — authentication via federated Workload Identity
- No public network access to storage — traffic flows over a private endpoint within the VNet
- Private DNS zone resolves the storage FQDN to the private IP inside the VNet
- ACA environment supports both internal-only and external ingress modes (the storage remains private regardless)

## Prerequisites

- Azure CLI ≥ 2.60.0
- The `containerapp` extension: `az extension add --name containerapp`
- A subscription with the `Microsoft.App` resource provider registered
- Permissions to create role assignments and managed identities

## Create the Environment

1. Create a placeholder directory:

```bash
mkdir -p ~/clusters/aca-blob-private && cd ~/clusters/aca-blob-private
```

2. Set environment variables:

```bash
cat <<EOF> .envrc
export RESOURCE_GROUP="rg-aca-blob-private"
export LOCATION="westus3"
export ACA_ENV_NAME="aca-env-blob"
export ACA_APP_NAME="ca-blob-test"
export STORAGE_ACCOUNT="stacablob${RANDOM}"
export STORAGE_CONTAINER="data"
export IDENTITY_NAME="id-aca-blob"
export VNET_NAME="vnet-aca"
export SUBNET_ACA="snet-aca"
export SUBNET_PE="snet-pe"
EOF
```

3. Load the environment:

```bash
source .envrc
```

4. Create the resource group:

```bash
az group create --name ${RESOURCE_GROUP} --location ${LOCATION}
```

## Create the Virtual Network

ACA needs a dedicated subnet (minimum /23) for VNet integration, and we'll use a separate subnet for the private endpoint:

```bash
az network vnet create \
  --name ${VNET_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --location ${LOCATION} \
  --address-prefix 10.0.0.0/16

# ACA infrastructure subnet (minimum /23, must be delegated)
az network vnet subnet create \
  --name ${SUBNET_ACA} \
  --resource-group ${RESOURCE_GROUP} \
  --vnet-name ${VNET_NAME} \
  --address-prefix 10.0.0.0/23 \
  --delegations Microsoft.App/environments

# Private endpoint subnet
az network vnet subnet create \
  --name ${SUBNET_PE} \
  --resource-group ${RESOURCE_GROUP} \
  --vnet-name ${VNET_NAME} \
  --address-prefix 10.0.2.0/24
```

> **Important:** The ACA infrastructure subnet must be delegated to `Microsoft.App/environments`. Without this delegation, environment creation will fail with `ManagedEnvironmentSubnetDelegationError`.

## Create the Storage Account

Create the storage account with public access disabled and shared key access disabled — enforcing Entra ID (RBAC) auth only:

```bash
az storage account create \
  --name ${STORAGE_ACCOUNT} \
  --resource-group ${RESOURCE_GROUP} \
  --location ${LOCATION} \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-shared-key-access false \
  --public-network-access Disabled
```

Create the blob container (this requires your identity to have Storage Blob Data Contributor on the account — we'll run this via the private endpoint later, or temporarily allow your IP):

> **Note:** Since public access is disabled, you may need to temporarily allow your client IP or use Cloud Shell inside the VNet. Alternatively, create the container after the private endpoint is established.

## Create the Private Endpoint for Blob Storage

1. Create the private endpoint on the PE subnet:

```bash
STORAGE_ID=$(az storage account show \
  --name ${STORAGE_ACCOUNT} \
  --query "id" -o tsv)

PE_SUBNET_ID=$(az network vnet subnet show \
  --resource-group ${RESOURCE_GROUP} \
  --vnet-name ${VNET_NAME} \
  --name ${SUBNET_PE} \
  --query "id" -o tsv)

az network private-endpoint create \
  --name pe-${STORAGE_ACCOUNT}-blob \
  --resource-group ${RESOURCE_GROUP} \
  --subnet ${PE_SUBNET_ID} \
  --private-connection-resource-id ${STORAGE_ID} \
  --group-id blob \
  --connection-name pec-blob \
  --location ${LOCATION}
```

2. Create the private DNS zone and link it to the VNet:

```bash
az network private-dns zone create \
  --resource-group ${RESOURCE_GROUP} \
  --name privatelink.blob.core.windows.net

az network private-dns link vnet create \
  --resource-group ${RESOURCE_GROUP} \
  --zone-name privatelink.blob.core.windows.net \
  --name link-aca-vnet \
  --virtual-network ${VNET_NAME} \
  --registration-enabled false
```

3. Register the private endpoint with the DNS zone:

```bash
az network private-endpoint dns-zone-group create \
  --resource-group ${RESOURCE_GROUP} \
  --endpoint-name pe-${STORAGE_ACCOUNT}-blob \
  --name blob-dns-group \
  --private-dns-zone privatelink.blob.core.windows.net \
  --zone-name privatelink-blob
```

4. Verify the DNS record was created:

```bash
az network private-dns record-set a list \
  --resource-group ${RESOURCE_GROUP} \
  --zone-name privatelink.blob.core.windows.net \
  --query "[].{name:name, ip:aRecords[0].ipv4Address}" -o table
```

## Create the Blob Container

Now that the private endpoint is in place, create the container. Since public access is disabled, use a machine with VNet access or temporarily add your IP:

```bash
# Option A: Temporarily allow your IP (remove after)
MY_IP=$(curl -s ifconfig.me)
az storage account network-rule add \
  --account-name ${STORAGE_ACCOUNT} \
  --ip-address ${MY_IP}

# Wait a moment for propagation, then create the container
sleep 30
az storage container create \
  --name ${STORAGE_CONTAINER} \
  --account-name ${STORAGE_ACCOUNT} \
  --auth-mode login

# Remove the IP rule
az storage account network-rule remove \
  --account-name ${STORAGE_ACCOUNT} \
  --ip-address ${MY_IP}
```

> **Option B:** If your subscription policy prevents any public access changes, use Azure Cloud Shell or a jump box inside the VNet.

## Configure Workload Identity

Container Apps use User-Assigned Managed Identity federated with the ACA environment to authenticate to Azure services without secrets.

1. Create the managed identity:

```bash
az identity create \
  --name ${IDENTITY_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --location ${LOCATION}
```

2. Retrieve the identity properties:

```bash
export IDENTITY_CLIENT_ID=$(az identity show \
  --name ${IDENTITY_NAME} -g ${RESOURCE_GROUP} \
  --query clientId -o tsv)

export IDENTITY_RESOURCE_ID=$(az identity show \
  --name ${IDENTITY_NAME} -g ${RESOURCE_GROUP} \
  --query id -o tsv)

export IDENTITY_PRINCIPAL_ID=$(az identity show \
  --name ${IDENTITY_NAME} -g ${RESOURCE_GROUP} \
  --query principalId -o tsv)
```

3. Assign the **Storage Blob Data Contributor** role to the identity:

```bash
az role assignment create \
  --assignee ${IDENTITY_PRINCIPAL_ID} \
  --role "Storage Blob Data Contributor" \
  --scope ${STORAGE_ID}
```

## Create the Container Apps Environment

Create a VNet-integrated ACA environment using the infrastructure subnet:

```bash
ACA_SUBNET_ID=$(az network vnet subnet show \
  --resource-group ${RESOURCE_GROUP} \
  --vnet-name ${VNET_NAME} \
  --name ${SUBNET_ACA} \
  --query "id" -o tsv)

az containerapp env create \
  --name ${ACA_ENV_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --location ${LOCATION} \
  --infrastructure-subnet-resource-id ${ACA_SUBNET_ID}
```

> **Note:** By default, the environment allows external ingress. Add `--internal-only true` if apps should only be accessible from within the VNet. Note that `--internal-only` cannot be changed after creation — you must recreate the environment to switch modes.

> **Important:** `az containerapp exec` requires ingress to be enabled on the container app. Without ingress, you'll get `ClusterExecFailure` errors.

## Deploy the Container App

Deploy a container app that uses the managed identity to access blob storage. We use a YAML template to correctly pass multi-argument commands:

```bash
cat <<EOF > container-app.yaml
properties:
  template:
    containers:
      - name: ${ACA_APP_NAME}
        image: mcr.microsoft.com/azure-cli:latest
        resources:
          cpu: 0.5
          memory: 1Gi
        env:
          - name: AZURE_CLIENT_ID
            value: "${IDENTITY_CLIENT_ID}"
          - name: STORAGE_ACCOUNT_NAME
            value: "${STORAGE_ACCOUNT}"
          - name: STORAGE_CONTAINER_NAME
            value: "${STORAGE_CONTAINER}"
        command:
          - /bin/bash
          - -c
          - |
            echo "Container started"
            sleep infinity
    scale:
      minReplicas: 1
      maxReplicas: 1
EOF

az containerapp create \
  --name ${ACA_APP_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --environment ${ACA_ENV_NAME} \
  --yaml container-app.yaml
```

Assign the managed identity to the container app:

```bash
az containerapp identity assign \
  --resource-group ${RESOURCE_GROUP} \
  --name ${ACA_APP_NAME} \
  --user-assigned ${IDENTITY_RESOURCE_ID}
```

Enable ingress (required for `az containerapp exec` and for service-to-service communication):

```bash
az containerapp ingress enable \
  --resource-group ${RESOURCE_GROUP} \
  --name ${ACA_APP_NAME} \
  --type external \
  --target-port 8080 \
  --transport auto
```

> **Note:** Use `--type internal` if the app should only be reachable from within the VNet.

> **Tip:** Replace the image and command with your actual application. The example above uses the Azure CLI image for testing. Your app should use an Azure SDK that supports `DefaultAzureCredential` or `ManagedIdentityCredential`.

> **Note on YAML vs CLI flags:** When using `--yaml`, any additional CLI flags (like `--user-assigned`) are ignored. Assign the identity separately after creation, or include it in the YAML under `properties.identity`.

## Verify Connectivity

### Option A: Using `az containerapp exec` (requires ingress)

> **Important:** `az containerapp exec` requires ingress to be enabled on the container app. Without ingress, you'll get `ClusterExecFailure` errors. Enable ingress first (see the "Enable internal ingress" step above), then exec will work.

```bash
az containerapp exec \
  --name ${ACA_APP_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --command /bin/bash
```

From inside the container, verify DNS resolution and test blob access:

```bash
# Verify private DNS resolves to private IP
# (nslookup/dig are not available in the azure-cli image; use Python instead)
python3 -c "import socket; print(socket.getaddrinfo('${STORAGE_ACCOUNT_NAME}.blob.core.windows.net', 443))"
# Expected: 10.0.2.x (private endpoint IP), not a public IP

# Login with managed identity
az login --identity --client-id ${AZURE_CLIENT_ID}

# Upload a test file
echo "hello from ACA" > /tmp/test.txt
az storage blob upload \
  --account-name ${STORAGE_ACCOUNT_NAME} \
  --container-name ${STORAGE_CONTAINER_NAME} \
  --name test.txt \
  --file /tmp/test.txt \
  --auth-mode login

# List blobs
az storage blob list \
  --account-name ${STORAGE_ACCOUNT_NAME} \
  --container-name ${STORAGE_CONTAINER_NAME} \
  --auth-mode login \
  --output table

exit
```

### Option B: Bake test into startup command (alternative)

If you prefer not to use interactive `exec`, or if you need automated validation in a CI/CD pipeline, embed the test script in the container's startup command and read the results from logs:

```bash
cat <<EOF > container-app-test.yaml
properties:
  template:
    containers:
      - name: ${ACA_APP_NAME}
        image: mcr.microsoft.com/azure-cli:latest
        resources:
          cpu: 0.5
          memory: 1Gi
        env:
          - name: AZURE_CLIENT_ID
            value: "${IDENTITY_CLIENT_ID}"
          - name: STORAGE_ACCOUNT_NAME
            value: "${STORAGE_ACCOUNT}"
          - name: STORAGE_CONTAINER_NAME
            value: "${STORAGE_CONTAINER}"
        command:
          - /bin/bash
          - -c
          - |
            az login --identity --client-id \$AZURE_CLIENT_ID
            az storage container create --account-name \$STORAGE_ACCOUNT_NAME --name \$STORAGE_CONTAINER_NAME --auth-mode login
            echo "HELLO_FROM_ACA" > /tmp/test.txt
            az storage blob upload --account-name \$STORAGE_ACCOUNT_NAME --container-name \$STORAGE_CONTAINER_NAME --name test.txt --file /tmp/test.txt --auth-mode login --overwrite
            echo "=== TEST RESULT: SUCCESS ==="
            sleep infinity
    scale:
      minReplicas: 1
      maxReplicas: 1
EOF

az containerapp update \
  --name ${ACA_APP_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --yaml container-app-test.yaml
```

Then check the console logs:

```bash
az containerapp logs show \
  --resource-group ${RESOURCE_GROUP} \
  --name ${ACA_APP_NAME} \
  --type console \
  --follow false
```

You should see `=== TEST RESULT: SUCCESS ===` in the output, confirming the entire chain works: managed identity → private DNS → private endpoint → blob storage.

## Using the Azure SDK (Application Code)

For production applications, use the Azure Identity SDK with `DefaultAzureCredential`. Here's a Go example:

```go
package main

import (
    "context"
    "fmt"
    "os"

    "github.com/Azure/azure-sdk-for-go/sdk/azidentity"
    "github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
)

func main() {
    accountName := os.Getenv("STORAGE_ACCOUNT_NAME")
    containerName := os.Getenv("STORAGE_CONTAINER_NAME")

    cred, err := azidentity.NewDefaultAzureCredential(nil)
    if err != nil {
        panic(err)
    }

    serviceURL := fmt.Sprintf("https://%s.blob.core.windows.net", accountName)
    client, err := azblob.NewClient(serviceURL, cred, nil)
    if err != nil {
        panic(err)
    }

    // List blobs
    pager := client.NewListBlobsFlatPager(containerName, nil)
    for pager.More() {
        resp, err := pager.NextPage(context.Background())
        if err != nil {
            panic(err)
        }
        for _, blob := range resp.Segment.BlobItems {
            fmt.Printf("Blob: %s\n", *blob.Name)
        }
    }
}
```

The `DefaultAzureCredential` automatically picks up the `AZURE_CLIENT_ID` environment variable and uses the managed identity token endpoint available in the ACA environment.

## Production Considerations

| Concern | Recommendation |
| - | - |
| Network isolation | Add `--internal-only true` at environment creation if apps should not be publicly reachable (cannot be changed later) |
| DNS resolution | Ensure the private DNS zone is linked to the ACA VNet; verify with `python3 socket.getaddrinfo()` from inside the container (`nslookup`/`dig` are not available in the azure-cli image) |
| Identity scope | Use a dedicated managed identity per app with least-privilege RBAC (e.g., `Storage Blob Data Reader` if write isn't needed) |
| Storage redundancy | Use `Standard_ZRS` or `Standard_GRS` for production workloads |
| Scaling | Configure `--min-replicas` and `--max-replicas` based on workload; each replica shares the same identity |
| Key access | Keep `--allow-shared-key-access false` to enforce Entra ID auth only |
| Policy compliance | If Azure Policy enforces `publicNetworkAccess: Disabled`, the private endpoint is mandatory — plan for it from day one |
| Container image | Store images in Azure Container Registry (ACR) with a private endpoint if your environment requires it |

## Cleanup

```bash
az group delete --name ${RESOURCE_GROUP} --yes --no-wait
```

## Conclusion

Azure Container Apps with VNet integration, private endpoints, and Workload Identity provides a secure path to Azure Blob Storage. No shared keys rotate, no secrets to manage in your application code. Storage traffic stays on the private network via the private endpoint (public access to storage remains disabled), while the ACA app itself can be exposed externally or kept internal depending on your needs. The Azure SDK's `DefaultAzureCredential` handles token acquisition transparently, making the developer experience identical to running locally with `az login`.

## References

- [Azure Container Apps VNet integration](https://learn.microsoft.com/en-us/azure/container-apps/vnet-custom)
- [Managed Identity in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/managed-identity)
- [Azure Blob Storage private endpoints](https://learn.microsoft.com/en-us/azure/storage/common/storage-private-endpoints)
- [Private DNS zones for Azure services](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns)
- [DefaultAzureCredential — Azure Identity SDK](https://learn.microsoft.com/en-us/azure/developer/go/azure-sdk-authentication)
- [Azure Container Apps networking overview](https://learn.microsoft.com/en-us/azure/container-apps/networking)
