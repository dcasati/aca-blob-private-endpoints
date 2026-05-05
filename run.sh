#!/usr/bin/env bash
# shfmt -i 2 -ci -w
set -Eo pipefail

trap exit SIGINT SIGTERM

################################################################################
# ACA + Blob Storage Private Endpoint Deployment
# Deploys Azure Container Apps with private Blob Storage access via Workload Identity

################################################################################
# Default configuration
LOCATION=${LOCATION:-westus3}
RESOURCE_GROUP=${RESOURCE_GROUP:-rg-aca-blob-private}
ACA_ENV_NAME=${ACA_ENV_NAME:-cae-blob-private}
ACA_APP_NAME=${ACA_APP_NAME:-ca-blob-test}
STORAGE_ACCOUNT=${STORAGE_ACCOUNT:-stacablob${RANDOM}}
STORAGE_CONTAINER=${STORAGE_CONTAINER:-data}
IDENTITY_NAME=${IDENTITY_NAME:-id-aca-blob}
VNET_NAME=${VNET_NAME:-vnet-aca}
SUBNET_ACA=${SUBNET_ACA:-snet-aca}
SUBNET_PE=${SUBNET_PE:-snet-pe}
################################################################################

__usage="
    -x  action to be executed.

Possible verbs are:
    install        Deploy all resources.
    delete         Delete all resources.
    show           Show deployment information.
    check-deps     Check required dependencies.
    test           Run connectivity test from inside the container.

Environment variables (with defaults):
    LOCATION=${LOCATION}
    RESOURCE_GROUP=${RESOURCE_GROUP}
    ACA_ENV_NAME=${ACA_ENV_NAME}
    ACA_APP_NAME=${ACA_APP_NAME}
    STORAGE_ACCOUNT=${STORAGE_ACCOUNT}
    STORAGE_CONTAINER=${STORAGE_CONTAINER}
    IDENTITY_NAME=${IDENTITY_NAME}
    VNET_NAME=${VNET_NAME}
    SUBNET_ACA=${SUBNET_ACA}
    SUBNET_PE=${SUBNET_PE}
"

usage() {
  echo "usage: ${0##*/} [options]"
  echo "${__usage/[[:space:]]/}"
  exit 1
}

print_header() {
  echo ""
  echo "ACA + Blob Storage Private Endpoint"
  echo "=========================================="
  echo ""
  echo "Location:         $LOCATION"
  echo "Resource Group:   $RESOURCE_GROUP"
  echo "ACA Environment:  $ACA_ENV_NAME"
  echo "ACA App:          $ACA_APP_NAME"
  echo "Storage Account:  $STORAGE_ACCOUNT"
  echo "Storage Container:$STORAGE_CONTAINER"
  echo "Identity:         $IDENTITY_NAME"
  echo "VNet:             $VNET_NAME"
  echo ""
}

log() {
  echo "[$(date +"%r")] $*"
}

check_dependencies() {
  log "Checking dependencies..."
  local _NEEDED="az jq"
  local _DEP_FLAG=false

  for i in ${_NEEDED}; do
    if hash "$i" 2>/dev/null; then
      log "  $i: OK"
    else
      log "  $i: NOT FOUND"
      _DEP_FLAG=true
    fi
  done

  if [[ "${_DEP_FLAG}" == "true" ]]; then
    log "Dependencies missing. Please install them before proceeding"
    exit 1
  fi

  # Check az extensions
  if ! az extension show --name containerapp >/dev/null 2>&1; then
    log "  containerapp extension: NOT FOUND (installing...)"
    az extension add --name containerapp --upgrade --yes
  else
    log "  containerapp extension: OK"
  fi

  log "All dependencies satisfied"
}

create_resource_group() {
  log "Creating resource group $RESOURCE_GROUP in $LOCATION..."

  if az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
    log "  Resource group already exists"
  else
    az group create --location "$LOCATION" --name "$RESOURCE_GROUP" -o none
    log "  Resource group created"
  fi
}

create_vnet() {
  log "Creating virtual network $VNET_NAME..."

  if az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" >/dev/null 2>&1; then
    log "  VNet already exists"
  else
    az network vnet create \
      --name "$VNET_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION" \
      --address-prefix 10.0.0.0/16 \
      -o none
    log "  VNet created"
  fi

  # ACA subnet (min /23, delegated)
  if az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_ACA" >/dev/null 2>&1; then
    log "  Subnet $SUBNET_ACA already exists"
  else
    log "  Creating subnet $SUBNET_ACA (10.0.0.0/23, delegated to Microsoft.App/environments)..."
    az network vnet subnet create \
      --name "$SUBNET_ACA" \
      --resource-group "$RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --address-prefix 10.0.0.0/23 \
      --delegations Microsoft.App/environments \
      -o none
    log "  Subnet $SUBNET_ACA created"
  fi

  # Private endpoint subnet
  if az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_PE" >/dev/null 2>&1; then
    log "  Subnet $SUBNET_PE already exists"
  else
    log "  Creating subnet $SUBNET_PE (10.0.2.0/24)..."
    az network vnet subnet create \
      --name "$SUBNET_PE" \
      --resource-group "$RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --address-prefix 10.0.2.0/24 \
      -o none
    log "  Subnet $SUBNET_PE created"
  fi
}

create_storage() {
  log "Creating storage account $STORAGE_ACCOUNT..."

  if az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" >/dev/null 2>&1; then
    log "  Storage account already exists"
  else
    az storage account create \
      --name "$STORAGE_ACCOUNT" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION" \
      --sku Standard_ZRS \
      --kind StorageV2 \
      --allow-shared-key-access false \
      --public-network-access Disabled \
      -o none
    log "  Storage account created (ZRS, no shared keys, no public access)"
  fi
}

create_private_endpoint() {
  log "Creating private endpoint for blob storage..."

  local pe_name="pe-${STORAGE_ACCOUNT}-blob"

  if az network private-endpoint show --resource-group "$RESOURCE_GROUP" --name "$pe_name" >/dev/null 2>&1; then
    log "  Private endpoint already exists"
  else
    local storage_id
    storage_id=$(az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" --query "id" -o tsv)

    local subnet_id
    subnet_id=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_PE" --query "id" -o tsv)

    az network private-endpoint create \
      --name "$pe_name" \
      --resource-group "$RESOURCE_GROUP" \
      --subnet "$subnet_id" \
      --private-connection-resource-id "$storage_id" \
      --group-id blob \
      --connection-name pec-blob \
      --location "$LOCATION" \
      -o none
    log "  Private endpoint created"
  fi

  # Private DNS zone
  log "  Configuring private DNS zone..."
  if az network private-dns zone show --resource-group "$RESOURCE_GROUP" --name "privatelink.blob.core.windows.net" >/dev/null 2>&1; then
    log "  DNS zone already exists"
  else
    az network private-dns zone create \
      --resource-group "$RESOURCE_GROUP" \
      --name "privatelink.blob.core.windows.net" \
      -o none
    log "  DNS zone created"
  fi

  # VNet link
  if az network private-dns link vnet show --resource-group "$RESOURCE_GROUP" --zone-name "privatelink.blob.core.windows.net" --name "link-aca-vnet" >/dev/null 2>&1; then
    log "  VNet link already exists"
  else
    az network private-dns link vnet create \
      --resource-group "$RESOURCE_GROUP" \
      --zone-name "privatelink.blob.core.windows.net" \
      --name "link-aca-vnet" \
      --virtual-network "$VNET_NAME" \
      --registration-enabled false \
      -o none
    log "  VNet link created"
  fi

  # DNS zone group (always recreate to ensure correct zone linkage)
  local dns_zone_id
  dns_zone_id=$(az network private-dns zone show --resource-group "$RESOURCE_GROUP" --name "privatelink.blob.core.windows.net" --query "id" -o tsv)

  az network private-endpoint dns-zone-group delete \
    --resource-group "$RESOURCE_GROUP" \
    --endpoint-name "$pe_name" \
    --name "blob-dns-group" \
    --yes 2>/dev/null || true

  az network private-endpoint dns-zone-group create \
    --resource-group "$RESOURCE_GROUP" \
    --endpoint-name "$pe_name" \
    --name "blob-dns-group" \
    --private-dns-zone "$dns_zone_id" \
    --zone-name "privatelink-blob" \
    -o none
  log "  DNS zone group configured"
}

create_identity() {
  log "Creating managed identity $IDENTITY_NAME..."

  if az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" >/dev/null 2>&1; then
    log "  Identity already exists"
  else
    az identity create \
      --name "$IDENTITY_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION" \
      -o none
    log "  Identity created"
  fi

  # Assign Storage Blob Data Contributor
  local principal_id
  principal_id=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query "principalId" -o tsv)

  local storage_id
  storage_id=$(az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" --query "id" -o tsv)

  log "  Assigning Storage Blob Data Contributor role..."
  az role assignment create \
    --assignee-object-id "$principal_id" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Contributor" \
    --scope "$storage_id" \
    -o none 2>/dev/null || true
  log "  Role assignment complete"
}

create_aca_environment() {
  log "Creating ACA environment $ACA_ENV_NAME..."

  if az containerapp env show --resource-group "$RESOURCE_GROUP" --name "$ACA_ENV_NAME" >/dev/null 2>&1; then
    local state
    state=$(az containerapp env show --resource-group "$RESOURCE_GROUP" --name "$ACA_ENV_NAME" --query "properties.provisioningState" -o tsv)
    if [[ "$state" == "ScheduledForDelete" ]]; then
      log "  Environment is being deleted, waiting..."
      while az containerapp env show --resource-group "$RESOURCE_GROUP" --name "$ACA_ENV_NAME" >/dev/null 2>&1; do
        sleep 10
      done
      log "  Previous environment deleted"
    else
      log "  ACA environment already exists (state: $state)"
      return
    fi
  fi

  local subnet_id
  subnet_id=$(az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_ACA" --query "id" -o tsv)

  az containerapp env create \
    --name "$ACA_ENV_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --infrastructure-subnet-resource-id "$subnet_id" \
    -o none
  log "  ACA environment created"
}

deploy_container_app() {
  log "Deploying container app $ACA_APP_NAME..."

  local identity_id
  identity_id=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query "id" -o tsv)

  local identity_client_id
  identity_client_id=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query "clientId" -o tsv)

  if az containerapp show --resource-group "$RESOURCE_GROUP" --name "$ACA_APP_NAME" >/dev/null 2>&1; then
    log "  Container app already exists"
  else
    az containerapp create \
      --name "$ACA_APP_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --environment "$ACA_ENV_NAME" \
      --image mcr.microsoft.com/azure-cli:latest \
      --cpu 0.5 --memory 1.0Gi \
      --min-replicas 1 --max-replicas 1 \
      --env-vars "AZURE_CLIENT_ID=${identity_client_id}" "STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT}" "STORAGE_CONTAINER_NAME=${STORAGE_CONTAINER}" \
      -o none
    log "  Container app created"
  fi

  # Assign identity
  log "  Assigning managed identity..."
  az containerapp identity assign \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACA_APP_NAME" \
    --user-assigned "$identity_id" \
    -o none 2>/dev/null || true
  log "  Identity assigned"

  # Enable ingress
  log "  Enabling external ingress..."
  az containerapp ingress enable \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACA_APP_NAME" \
    --type external \
    --target-port 8080 \
    --transport auto \
    -o none 2>/dev/null || true
  log "  Ingress enabled"
}

do_install() {
  print_header
  check_dependencies
  create_resource_group
  create_vnet
  create_storage
  create_private_endpoint
  create_identity
  create_aca_environment
  deploy_container_app

  log ""
  log "=========================================="
  log "Deployment completed!"
  log "=========================================="
  log ""
  log "To exec into the container:"
  log "  az containerapp exec --name $ACA_APP_NAME --resource-group $RESOURCE_GROUP --command /bin/bash"
  log ""
  log "To run connectivity test:"
  log "  $0 -x test"
  log ""
  log "Run '$0 -x show' to view deployment details"
}

do_test() {
  log "Running connectivity test..."

  local identity_client_id
  identity_client_id=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query "clientId" -o tsv)

  # Update container with test script
  cat <<EOF > /tmp/aca-test.yaml
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
            value: "${identity_client_id}"
          - name: STORAGE_ACCOUNT_NAME
            value: "${STORAGE_ACCOUNT}"
          - name: STORAGE_CONTAINER_NAME
            value: "${STORAGE_CONTAINER}"
        command:
          - /bin/bash
          - -c
          - |
            echo "=== DNS Resolution Test ==="
            python3 -c "import socket; result = socket.getaddrinfo('${STORAGE_ACCOUNT}.blob.core.windows.net', 443); print(f'Resolved to: {result[0][4][0]}')"
            echo ""
            echo "=== Identity Login Test ==="
            az login --identity --client-id \$AZURE_CLIENT_ID -o none
            echo ""
            echo "=== Blob Container Create Test ==="
            az storage container create --account-name \$STORAGE_ACCOUNT_NAME --name \$STORAGE_CONTAINER_NAME --auth-mode login -o none 2>/dev/null || true
            echo ""
            echo "=== Blob Upload Test ==="
            echo "HELLO_FROM_ACA_\$(date)" > /tmp/test.txt
            az storage blob upload --account-name \$STORAGE_ACCOUNT_NAME --container-name \$STORAGE_CONTAINER_NAME --name test.txt --file /tmp/test.txt --auth-mode login --overwrite -o none
            echo ""
            echo "=== Blob List Test ==="
            az storage blob list --account-name \$STORAGE_ACCOUNT_NAME --container-name \$STORAGE_CONTAINER_NAME --auth-mode login -o table
            echo ""
            echo "=== TEST RESULT: SUCCESS ==="
            sleep infinity
    scale:
      minReplicas: 1
      maxReplicas: 1
EOF

  az containerapp update \
    --name "$ACA_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --yaml /tmp/aca-test.yaml \
    -o none

  rm -f /tmp/aca-test.yaml

  log "  Waiting 60s for test execution..."
  sleep 60

  log "  Console logs:"
  echo ""
  az containerapp logs show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACA_APP_NAME" \
    --type console \
    --follow false 2>&1 | jq -r '.Log // empty' 2>/dev/null || \
  az containerapp logs show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACA_APP_NAME" \
    --type console \
    --follow false
}

do_show() {
  log "Deployment information:"
  echo ""

  if ! az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
    log "Resource group $RESOURCE_GROUP not found"
    exit 1
  fi

  echo "Resource Group:   $RESOURCE_GROUP ($LOCATION)"
  echo ""

  echo "Storage Account:  $STORAGE_ACCOUNT"
  az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" \
    --query "{sku:sku.name,publicAccess:publicNetworkAccess,sharedKey:allowSharedKeyAccess}" -o table 2>/dev/null
  echo ""

  echo "Private Endpoint: pe-${STORAGE_ACCOUNT}-blob"
  az network private-dns record-set a list \
    --resource-group "$RESOURCE_GROUP" \
    --zone-name "privatelink.blob.core.windows.net" \
    --query "[].{name:name,ip:aRecords[0].ipv4Address}" -o table 2>/dev/null
  echo ""

  echo "ACA Environment:  $ACA_ENV_NAME"
  az containerapp env show --resource-group "$RESOURCE_GROUP" --name "$ACA_ENV_NAME" \
    --query "{staticIp:properties.staticIp,domain:properties.defaultDomain,internal:properties.vnetConfiguration.internal}" -o table 2>/dev/null
  echo ""

  echo "Container App:    $ACA_APP_NAME"
  az containerapp show --resource-group "$RESOURCE_GROUP" --name "$ACA_APP_NAME" \
    --query "{fqdn:properties.configuration.ingress.fqdn,replicas:properties.template.scale.minReplicas,revision:properties.latestRevisionName}" -o table 2>/dev/null
  echo ""
}

do_delete() {
  log "Deleting all resources..."

  if az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
    log "  Deleting resource group $RESOURCE_GROUP (async)..."
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait
    log "  Deletion initiated (--no-wait)"
  else
    log "  Resource group not found, nothing to delete"
  fi
}

exec_case() {
  local _opt=$1

  case ${_opt} in
  install)       do_install ;;
  delete)        do_delete ;;
  show)          do_show ;;
  test)          do_test ;;
  check-deps)    check_dependencies ;;
  *)             usage ;;
  esac
  unset _opt
}

################################################################################
# Entry point
main() {
  while getopts "x:" opt; do
    case $opt in
      x)
        exec_flag=true
        EXEC_OPT="${OPTARG}"
        ;;
      *) usage ;;
    esac
  done
  shift $((OPTIND - 1))

  if [ $OPTIND = 1 ]; then
    print_header
    usage
    exit 0
  fi

  # process actions
  if [[ "${exec_flag}" == "true" ]]; then
    exec_case "${EXEC_OPT}"
  fi
}

main "$@"
exit 0
