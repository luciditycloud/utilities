#!/usr/bin/env bash
set -Eeuo pipefail

# Lucidity Azure read-only onboarding (management-group workflow).
# Default is plan-only. Add --execute to make changes.
# Requires Azure Cloud Shell Bash, Azure CLI and jq.

SCRIPT_VERSION="2.2.0"
APP_ID="4f2c2c1f-372a-4904-b13d-11e2467679f2"
ROLE_NAME="LUCIDITY_PLATFORM"
CONTAINER="lucidity-inventory"
LUCIDITY_BLOB_EGRESS_IP="4.157.111.90"
LUCIDITY_BACKEND_SUBNET="/subscriptions/3511ac94-c2ef-4644-8147-55f5f9a27a9e/resourceGroups/azurepls-rg/providers/Microsoft.Network/virtualNetworks/azurepls-vnet/subnets/aks-subnet"
MG_ID=""
SUBSCRIPTION_ID=""
NETWORK_MODE=""
EXECUTE="false"
ASSUME_YES="false"

ACTIONS=(
  "Microsoft.Compute/availabilitySets/read"
  "Microsoft.Compute/diskEncryptionSets/read"
  "Microsoft.Compute/disks/read"
  "Microsoft.Compute/galleries/images/read"
  "Microsoft.Compute/galleries/images/versions/read"
  "Microsoft.Compute/images/read"
  "Microsoft.Compute/locations/communityGalleries/images/read"
  "Microsoft.Compute/locations/communityGalleries/images/versions/read"
  "Microsoft.Compute/locations/sharedGalleries/images/read"
  "Microsoft.Compute/locations/sharedGalleries/images/versions/read"
  "Microsoft.Compute/locations/vmSizes/read"
  "Microsoft.Compute/snapshots/read"
  "Microsoft.Compute/virtualMachines/read"
  "Microsoft.Compute/virtualMachines/extensions/read"
  "Microsoft.Compute/virtualMachines/instanceView/read"
  "Microsoft.Compute/virtualMachines/runCommand/action"
  "Microsoft.Compute/virtualMachines/runCommands/read"
  "Microsoft.Compute/virtualMachines/runCommands/write"
  "Microsoft.Compute/virtualMachineScaleSets/read"
  "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/read"
  "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/runCommand/action"
  "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/runCommands/read"
  "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/runCommands/write"
  "Microsoft.Network/networkInterfaces/read"
  "Microsoft.Network/publicIPAddresses/read"
  "Microsoft.Network/virtualNetworks/read"
  "Microsoft.Network/virtualNetworks/subnets/read"
  "Microsoft.Network/networkSecurityGroups/read"
  "Microsoft.Network/loadBalancers/read"
  "Microsoft.RecoveryServices/vaults/read"
  "Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems/read"
  "Microsoft.RecoveryServices/vaults/backupJobs/read"
  "Microsoft.RecoveryServices/vaults/backupPolicies/read"
  "Microsoft.RecoveryServices/vaults/replicationProtectedItems/read"
  "Microsoft.Storage/storageAccounts/read"
  "Microsoft.Storage/storageAccounts/blobServices/read"
  "Microsoft.Storage/storageAccounts/blobServices/write"
  "Microsoft.Storage/storageAccounts/blobServices/containers/read"
  "Microsoft.Storage/storageAccounts/blobServices/containers/write"
  "Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action"
  "Microsoft.Storage/storageAccounts/fileServices/read"
  "Microsoft.Storage/storageAccounts/fileServices/shares/read"
  "Microsoft.Storage/storageAccounts/inventoryPolicies/read"
  "Microsoft.Storage/storageAccounts/inventoryPolicies/write"
  "Microsoft.Storage/storageAccounts/inventoryPolicies/delete"
  "Microsoft.Storage/storageAccounts/managementPolicies/read"
  "Microsoft.Storage/storageAccounts/localUsers/read"
  "Microsoft.Insights/DataCollectionRuleAssociations/Read"
  "Microsoft.Insights/DataCollectionRules/Read"
  "Microsoft.Insights/Logs/Read"
  "Microsoft.Insights/MetricBaselines/Read"
  "Microsoft.Insights/MetricDefinitions/Read"
  "Microsoft.Insights/Metricnamespaces/Read"
  "Microsoft.Insights/Metrics/Read"
  "Microsoft.OperationalInsights/workspaces/read"
  "Microsoft.OperationalInsights/workspaces/query/read"
  "Microsoft.OperationalInsights/workspaces/query/InsightsMetrics/read"
  "Microsoft.Resources/deployments/read"
  "Microsoft.Resources/deployments/operations/read"
  "Microsoft.Resources/deployments/operationstatuses/read"
  "Microsoft.Resources/subscriptions/resourceGroups/read"
  "Microsoft.ResourceGraph/resources/read"
  "Microsoft.ContainerService/managedClusters/read"
  "Microsoft.ContainerService/managedClusters/agentPools/machines/read"
  "Microsoft.Capacity/resourceProviders/locations/serviceLimits/read"
  "Microsoft.CostManagement/query/read"
  "Microsoft.Authorization/locks/read"
  "Microsoft.Authorization/roleAssignments/read"
  "Microsoft.Authorization/roleDefinitions/read"
)
DATA_ACTIONS=("Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read")

usage() {
  cat <<'EOF'
Usage:
  ./read-only.sh --management-group <MG_ID> [--subscription <SUB_ID>] [--execute] [--yes]
  ./read-only.sh --management-group <MG_ID> [--subscription <SUB_ID>] --network-audit
  ./read-only.sh --management-group <MG_ID> [--subscription <SUB_ID>] --network-config [--execute] [--yes]

Options:
  -m, --management-group <id>  Target management group (required)
  -s, --subscription <id>      Pilot one child subscription only
  -r, --role-name <name>       Custom role name (default: LUCIDITY_PLATFORM)
  -a, --app-id <app-id>        Lucidity application ID
      --network-audit          Audit Blob network rules; never makes changes
      --network-config         Preview/add required Blob network rules
      --execute                Apply the plan; otherwise make no changes
  -y, --yes                    Skip confirmation in execute mode
      --version                Show script version
  -h, --help                   Show help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--management-group) MG_ID="${2:-}"; shift 2 ;;
    -s|--subscription) SUBSCRIPTION_ID="${2:-}"; shift 2 ;;
    -r|--role-name) ROLE_NAME="${2:-}"; shift 2 ;;
    -a|--app-id) APP_ID="${2:-}"; shift 2 ;;
    --network-audit)
      [[ -z "$NETWORK_MODE" ]] || die "Use only one network mode."
      NETWORK_MODE="audit"; shift ;;
    --network-config)
      [[ -z "$NETWORK_MODE" ]] || die "Use only one network mode."
      NETWORK_MODE="config"; shift ;;
    --execute) EXECUTE="true"; shift ;;
    -y|--yes) ASSUME_YES="true"; shift ;;
    --version) echo "read-only.sh ${SCRIPT_VERSION}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$MG_ID" ]] || { usage; die "--management-group is required"; }
[[ "$NETWORK_MODE" != "audit" || "$EXECUTE" != "true" ]] ||
  die "--network-audit is always read-only; remove --execute."
need az
need jq

MG_SCOPE="/providers/Microsoft.Management/managementGroups/${MG_ID}"
CONDITION="((!(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'})) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEquals '${CONTAINER}'))"
DESCRIPTION="Lucidity assessment role with discovery reads, Run Command collection and limited storage enablement actions. Blob data read is limited to '${CONTAINER}' by each subscription assignment."
ACTIONS_JSON="$(printf '%s\n' "${ACTIONS[@]}" | jq -R . | jq -s 'unique')"
DATA_ACTIONS_JSON="$(printf '%s\n' "${DATA_ACTIONS[@]}" | jq -R . | jq -s 'unique')"

az account show >/dev/null 2>&1 || die "Azure CLI is not logged in. Open Cloud Shell or run: az login"
TENANT_ID="$(az account show --query tenantId -o tsv --only-show-errors)"
SIGNED_IN_AS="$(az account show --query user.name -o tsv --only-show-errors)"
az account management-group show --name "$MG_ID" --only-show-errors >/dev/null ||
  die "Cannot read management group '$MG_ID'. Check the ID and your access."

mapfile -t ALL_SUBSCRIPTIONS < <(
  az account management-group entities list --only-show-errors \
    --query "[?type=='/subscriptions' && contains(parentNameChain, '${MG_ID}')].name" -o tsv | sort -u
)
[[ "${#ALL_SUBSCRIPTIONS[@]}" -gt 0 ]] ||
  die "No child subscriptions found. Check management-group Reader access."

SELECTION_MODE="ALL CHILD SUBSCRIPTIONS"
if [[ -n "$SUBSCRIPTION_ID" ]]; then
  MATCHED_SUBSCRIPTION=""
  for CHILD_SUBSCRIPTION in "${ALL_SUBSCRIPTIONS[@]}"; do
    if [[ "${CHILD_SUBSCRIPTION,,}" == "${SUBSCRIPTION_ID,,}" ]]; then
      MATCHED_SUBSCRIPTION="$CHILD_SUBSCRIPTION"
      break
    fi
  done
  [[ -n "$MATCHED_SUBSCRIPTION" ]] ||
    die "Subscription '$SUBSCRIPTION_ID' is not beneath management group '$MG_ID'. No changes made."
  SUBSCRIPTIONS=("$MATCHED_SUBSCRIPTION")
  SELECTION_MODE="SINGLE-SUBSCRIPTION PILOT"
else
  SUBSCRIPTIONS=("${ALL_SUBSCRIPTIONS[@]}")
fi

if [[ -n "$NETWORK_MODE" ]]; then
  echo "=============================================================="
  echo "Lucidity Blob network $([[ "$NETWORK_MODE" == "audit" ]] && echo audit || echo configuration)"
  echo "  Script version        : $SCRIPT_VERSION"
  echo "  Tenant               : $TENANT_ID"
  echo "  Signed in as          : $SIGNED_IN_AS"
  echo "  Management group     : $MG_ID"
  echo "  Selection mode       : $SELECTION_MODE"
  echo "  Selected subscriptions: ${#SUBSCRIPTIONS[@]}"
  echo "  Lucidity collector IP: $LUCIDITY_BLOB_EGRESS_IP"
  echo "  Lucidity subnet      : $LUCIDITY_BACKEND_SUBNET"
  echo "  Mode                 : $([[ "$NETWORK_MODE" == "audit" ]] && echo READ-ONLY || { [[ "$EXECUTE" == "true" ]] && echo EXECUTE || echo PLAN-ONLY; })"
  echo "=============================================================="

  SCANNED=0; COMPLIANT=0; REQUIRED=0; MANUAL=0; INSPECTION_FAILED=0
  NETWORK_TARGETS=()

  for SUB_ID in "${SUBSCRIPTIONS[@]}"; do
    echo ">> Discovering storage accounts in subscription: $SUB_ID"
    if ! ACCOUNTS_JSON="$(az storage account list --subscription "$SUB_ID" -o json --only-show-errors 2>/dev/null)"; then
      echo "   FAILED to list storage accounts."
      INSPECTION_FAILED=$((INSPECTION_FAILED + 1))
      continue
    fi

    mapfile -t STORAGE_ACCOUNTS < <(jq -r '.[] | [.name, .resourceGroup] | @tsv' <<<"$ACCOUNTS_JSON")
    if [[ "${#STORAGE_ACCOUNTS[@]}" -eq 0 ]]; then
      echo "   No storage accounts found."
      continue
    fi

    for ACCOUNT_ROW in "${STORAGE_ACCOUNTS[@]}"; do
      IFS=$'\t' read -r STORAGE_ACCOUNT RESOURCE_GROUP <<<"$ACCOUNT_ROW"
      SCANNED=$((SCANNED + 1))

      if ! ACCOUNT_JSON="$(az storage account show \
        --subscription "$SUB_ID" --resource-group "$RESOURCE_GROUP" \
        --name "$STORAGE_ACCOUNT" -o json --only-show-errors 2>/dev/null)"; then
        echo "   [$STORAGE_ACCOUNT] INSPECTION FAILED"
        INSPECTION_FAILED=$((INSPECTION_FAILED + 1))
        continue
      fi

      PUBLIC_ACCESS="$(jq -r '.publicNetworkAccess // "Enabled"' <<<"$ACCOUNT_JSON")"
      DEFAULT_ACTION="$(jq -r '.networkRuleSet.defaultAction // "Allow"' <<<"$ACCOUNT_JSON")"
      PRIVATE_ENDPOINTS="$(jq '[.privateEndpointConnections[]? | select((.properties.privateLinkServiceConnectionState.status // "") == "Approved")] | length' <<<"$ACCOUNT_JSON")"
      IP_PRESENT="$(jq -r --arg ip "$LUCIDITY_BLOB_EGRESS_IP" \
        'any(.networkRuleSet.ipRules[]?; (.ipAddressOrRange // .value // "") == $ip)' <<<"$ACCOUNT_JSON")"
      SUBNET_PRESENT="$(jq -r --arg subnet "${LUCIDITY_BACKEND_SUBNET,,}" \
        'any(.networkRuleSet.virtualNetworkRules[]?; ((.virtualNetworkResourceId // .id // "") | ascii_downcase) == $subnet)' <<<"$ACCOUNT_JSON")"

      IP_STATUS="$([[ "$IP_PRESENT" == "true" ]] && echo PRESENT || echo MISSING)"
      SUBNET_STATUS="$([[ "$SUBNET_PRESENT" == "true" ]] && echo PRESENT || echo MISSING)"

      if [[ "${PUBLIC_ACCESS,,}" == "disabled" ]]; then
        RESULT="MANUAL REVIEW - public network access is disabled"
        MANUAL=$((MANUAL + 1))
      elif [[ "$IP_PRESENT" == "true" && "$SUBNET_PRESENT" == "true" ]]; then
        RESULT="COMPLIANT"
        COMPLIANT=$((COMPLIANT + 1))
      else
        RESULT="CONFIGURATION REQUIRED"
        REQUIRED=$((REQUIRED + 1))
        [[ "$NETWORK_MODE" == "config" ]] &&
          NETWORK_TARGETS+=("${SUB_ID}|${RESOURCE_GROUP}|${STORAGE_ACCOUNT}|${IP_PRESENT}|${SUBNET_PRESENT}")
      fi

      echo "   [$STORAGE_ACCOUNT] $RESULT"
      echo "      Resource group : $RESOURCE_GROUP"
      echo "      Public access  : $PUBLIC_ACCESS"
      echo "      Default action : $DEFAULT_ACTION"
      echo "      Private endpoints: $PRIVATE_ENDPOINTS"
      echo "      Lucidity IP    : $IP_STATUS"
      echo "      Lucidity subnet: $SUBNET_STATUS"
    done
  done

  echo "=============================================================="
  echo "Blob network assessment summary"
  echo "  Subscriptions selected : ${#SUBSCRIPTIONS[@]}"
  echo "  Storage accounts scanned: $SCANNED"
  echo "  Compliant              : $COMPLIANT"
  echo "  Configuration required : $REQUIRED"
  echo "  Manual review          : $MANUAL"
  echo "  Inspection failures    : $INSPECTION_FAILED"
  echo "=============================================================="

  if [[ "$NETWORK_MODE" == "audit" ]]; then
    echo "No changes made. --network-audit is always read-only."
    [[ "$INSPECTION_FAILED" -eq 0 ]] || exit 1
    exit 0
  fi

  if [[ "${#NETWORK_TARGETS[@]}" -eq 0 ]]; then
    echo "No eligible storage-account network changes are required."
    [[ "$INSPECTION_FAILED" -eq 0 ]] || exit 1
    exit 0
  fi

  echo
  echo "Proposed changes for ${#NETWORK_TARGETS[@]} storage account(s):"
  for TARGET in "${NETWORK_TARGETS[@]}"; do
    IFS='|' read -r TARGET_SUB TARGET_RG TARGET_ACCOUNT TARGET_IP_PRESENT TARGET_SUBNET_PRESENT <<<"$TARGET"
    echo "  - $TARGET_ACCOUNT ($TARGET_SUB / $TARGET_RG)"
    [[ "$TARGET_IP_PRESENT" == "true" ]] || echo "      add IP rule: $LUCIDITY_BLOB_EGRESS_IP"
    [[ "$TARGET_SUBNET_PRESENT" == "true" ]] || echo "      add subnet rule: $LUCIDITY_BACKEND_SUBNET"
  done

  if [[ "$EXECUTE" != "true" ]]; then
    echo
    echo "No changes made. Review the plan, then rerun with --network-config --execute."
    exit 0
  fi

  if [[ "$ASSUME_YES" != "true" ]]; then
    read -r -p "Apply these storage-account network rules? [y/N] " REPLY
    [[ "$REPLY" =~ ^([yY]|[yY][eE][sS])$ ]] || { echo "Aborted."; exit 0; }
  fi

  UPDATED=0; CONFIG_FAILED=0
  for TARGET in "${NETWORK_TARGETS[@]}"; do
    IFS='|' read -r TARGET_SUB TARGET_RG TARGET_ACCOUNT TARGET_IP_PRESENT TARGET_SUBNET_PRESENT <<<"$TARGET"
    echo ">> Configuring storage account: $TARGET_ACCOUNT"
    ACCOUNT_FAILED="false"

    if [[ "$TARGET_IP_PRESENT" != "true" ]]; then
      echo "   Adding Lucidity Blob collector IP rule..."
      if ! az storage account network-rule add \
        --subscription "$TARGET_SUB" --resource-group "$TARGET_RG" \
        --account-name "$TARGET_ACCOUNT" --ip-address "$LUCIDITY_BLOB_EGRESS_IP" \
        --only-show-errors >/dev/null; then
        echo "   FAILED to add the IP rule."
        ACCOUNT_FAILED="true"
      fi
    fi

    if [[ "$TARGET_SUBNET_PRESENT" != "true" ]]; then
      echo "   Adding Lucidity backend subnet rule..."
      if ! az storage account network-rule add \
        --subscription "$TARGET_SUB" --resource-group "$TARGET_RG" \
        --account-name "$TARGET_ACCOUNT" --subnet "$LUCIDITY_BACKEND_SUBNET" \
        --only-show-errors >/dev/null; then
        echo "   FAILED to add the subnet rule."
        ACCOUNT_FAILED="true"
      fi
    fi

    if [[ "$ACCOUNT_FAILED" == "false" ]]; then
      if VERIFY_JSON="$(az storage account show \
        --subscription "$TARGET_SUB" --resource-group "$TARGET_RG" \
        --name "$TARGET_ACCOUNT" -o json --only-show-errors 2>/dev/null)"; then
        VERIFY_IP="$(jq -r --arg ip "$LUCIDITY_BLOB_EGRESS_IP" \
          'any(.networkRuleSet.ipRules[]?; (.ipAddressOrRange // .value // "") == $ip)' <<<"$VERIFY_JSON")"
        VERIFY_SUBNET="$(jq -r --arg subnet "${LUCIDITY_BACKEND_SUBNET,,}" \
          'any(.networkRuleSet.virtualNetworkRules[]?; ((.virtualNetworkResourceId // .id // "") | ascii_downcase) == $subnet)' <<<"$VERIFY_JSON")"
        if [[ "$VERIFY_IP" == "true" && "$VERIFY_SUBNET" == "true" ]]; then
          echo "   VERIFIED - both Lucidity network rules are present."
          UPDATED=$((UPDATED + 1))
        else
          echo "   FAILED verification after the update."
          CONFIG_FAILED=$((CONFIG_FAILED + 1))
        fi
      else
        echo "   FAILED to verify the storage account after the update."
        CONFIG_FAILED=$((CONFIG_FAILED + 1))
      fi
    else
      CONFIG_FAILED=$((CONFIG_FAILED + 1))
    fi
  done

  echo "=============================================================="
  echo "Blob network configuration summary"
  echo "  Storage accounts targeted: ${#NETWORK_TARGETS[@]}"
  echo "  Updated and verified      : $UPDATED"
  echo "  Manual review             : $MANUAL"
  echo "  Failed                    : $CONFIG_FAILED"
  echo "=============================================================="
  [[ "$CONFIG_FAILED" -eq 0 ]] || exit 1
  exit 0
fi

SP_OBJECT_ID="$(az ad sp list --all --filter "appId eq '${APP_ID}'" --query '[0].id' -o tsv --only-show-errors 2>/dev/null || true)"
[[ -n "$SP_OBJECT_ID" ]] &&
  SP_STATUS="EXISTS - will validate and reuse" ||
  SP_STATUS="MISSING - will create the enterprise application"

ROLE_MATCHES="$(az role definition list --name "$ROLE_NAME" --custom-role-only true -o json --only-show-errors 2>/dev/null || printf '[]')"
ROLE_COUNT="$(jq 'length' <<<"$ROLE_MATCHES")"
[[ "$ROLE_COUNT" -le 1 ]] ||
  die "Found multiple custom roles named '$ROLE_NAME'. Use --role-name with an unambiguous name."

ROLE_EXISTS="false"
ROLE_ID=""
ROLE_COMPLIANT="false"
ROLE_STATUS="MISSING - will create"
EXISTING_ROLE="{}"
if [[ "$ROLE_COUNT" -eq 1 ]]; then
  ROLE_EXISTS="true"
  EXISTING_ROLE="$(jq '.[0]' <<<"$ROLE_MATCHES")"
  ROLE_ID="$(jq -r '.name' <<<"$EXISTING_ROLE")"
  ROLE_COMPLIANT="$(
    jq -n --argjson role "$EXISTING_ROLE" \
      --argjson requiredActions "$ACTIONS_JSON" \
      --argjson requiredDataActions "$DATA_ACTIONS_JSON" \
      --arg scope "$MG_SCOPE" '
        (($requiredActions - ($role.permissions | map(.actions // []) | add)) | length) == 0 and
        (($requiredDataActions - ($role.permissions | map(.dataActions // []) | add)) | length) == 0 and
        ($role.assignableScopes == [$scope])
      '
  )"
  [[ "$ROLE_COMPLIANT" == "true" ]] &&
    ROLE_STATUS="EXISTS - permissions and scope are compliant" ||
    ROLE_STATUS="EXISTS - will merge missing permissions and set the MG scope"
fi

echo "=============================================================="
echo "Lucidity Azure assessment onboarding plan"
echo "  Script version       : $SCRIPT_VERSION"
echo "  Tenant              : $TENANT_ID"
echo "  Signed in as         : $SIGNED_IN_AS"
echo "  Management group    : $MG_ID"
echo "  Selection mode      : $SELECTION_MODE"
echo "  MG child subscriptions: ${#ALL_SUBSCRIPTIONS[@]}"
echo "  Selected subscriptions: ${#SUBSCRIPTIONS[@]}"
[[ -n "$SUBSCRIPTION_ID" ]] && echo "  Pilot subscription  : ${SUBSCRIPTIONS[0]}"
echo "  Enterprise app      : $SP_STATUS"
echo "  Custom role         : $ROLE_NAME"
echo "  Role status         : $ROLE_STATUS"
echo "  Role assignment     : subscription-level fan-out"
echo "  Blob read condition : container '$CONTAINER' only"
echo "  Permission profile  : discovery reads + Run Command + storage enablement"
echo "  Mode                : $([[ "$EXECUTE" == "true" ]] && echo EXECUTE || echo PLAN-ONLY)"
echo "=============================================================="

if [[ "$EXECUTE" != "true" ]]; then
  echo
  echo "No changes made. Review the plan, then rerun with --execute."
  exit 0
fi
if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Proceed with onboarding? [y/N] " REPLY
  [[ "$REPLY" =~ ^([yY]|[yY][eE][sS])$ ]] || { echo "Aborted."; exit 0; }
fi

if [[ -z "$SP_OBJECT_ID" ]]; then
  echo ">> Creating the Lucidity enterprise application in this tenant..."
  SP_OBJECT_ID="$(az ad sp create --id "$APP_ID" --query id -o tsv --only-show-errors)"
  [[ -n "$SP_OBJECT_ID" ]] ||
    die "Enterprise application creation failed. Ask an Entra administrator to create it, then rerun."
else
  echo ">> Enterprise application already exists; reusing $SP_OBJECT_ID."
fi

if [[ "$ROLE_EXISTS" == "true" ]]; then
  MG_ASSIGNMENTS="$(az role assignment list --scope "$MG_SCOPE" --role "$ROLE_ID" -o json --only-show-errors)"
  FOREIGN_COUNT="$(
    jq --arg sp "${SP_OBJECT_ID,,}" --arg scope "${MG_SCOPE,,}" '
      [.[] | select(
        (.scope // "" | ascii_downcase) == $scope and
        (.principalId // "" | ascii_downcase) != $sp
      )] | length' <<<"$MG_ASSIGNMENTS"
  )"
  [[ "$FOREIGN_COUNT" -eq 0 ]] ||
    die "The existing role has a direct MG assignment for another principal. Remove or redesign it before continuing."

  mapfile -t LUCIDITY_MG_IDS < <(
    jq -r --arg sp "${SP_OBJECT_ID,,}" --arg scope "${MG_SCOPE,,}" '
      .[] | select(
        (.scope // "" | ascii_downcase) == $scope and
        (.principalId // "" | ascii_downcase) == $sp
      ) | .id' <<<"$MG_ASSIGNMENTS"
  )
  for ASSIGNMENT_ID in "${LUCIDITY_MG_IDS[@]}"; do
    [[ -n "$ASSIGNMENT_ID" ]] || continue
    echo ">> Removing incompatible Lucidity assignment at management-group scope..."
    az role assignment delete --ids "$ASSIGNMENT_ID" --only-show-errors
  done

  if [[ "$ROLE_COMPLIANT" == "true" ]]; then
    echo ">> Custom role is already compliant; no definition update required."
  else
    UPDATED_ROLE="$(
      jq -n --argjson role "$EXISTING_ROLE" \
        --argjson requiredActions "$ACTIONS_JSON" \
        --argjson requiredDataActions "$DATA_ACTIONS_JSON" \
        --arg scope "$MG_SCOPE" --arg description "$DESCRIPTION" '
          $role
          | .description = $description
          | .permissions = [{
              actions: (((.permissions | map(.actions // []) | add) + $requiredActions) | unique),
              notActions: ((.permissions | map(.notActions // []) | add) | unique),
              dataActions: (((.permissions | map(.dataActions // []) | add) + $requiredDataActions) | unique),
              notDataActions: ((.permissions | map(.notDataActions // []) | add) | unique)
            }]
          | .assignableScopes = [$scope]
          | del(.createdOn, .updatedOn, .createdBy, .updatedBy, .type)
        '
    )"
    ROLE_FILE="$(mktemp)"
    trap 'rm -f "${ROLE_FILE:-}"' EXIT
    printf '%s\n' "$UPDATED_ROLE" >"$ROLE_FILE"
    echo ">> Updating the existing custom role; its role-definition ID is preserved..."
    ROLE_ID="$(az role definition update --role-definition "$ROLE_FILE" --query name -o tsv --only-show-errors)"
  fi
else
  ROLE_FILE="$(mktemp)"
  trap 'rm -f "${ROLE_FILE:-}"' EXIT
  jq -n --arg name "$ROLE_NAME" --arg description "$DESCRIPTION" \
    --arg scope "$MG_SCOPE" --argjson actions "$ACTIONS_JSON" \
    --argjson dataActions "$DATA_ACTIONS_JSON" \
    '{Name:$name, IsCustom:true, Description:$description, Actions:$actions,
      NotActions:[], DataActions:$dataActions, NotDataActions:[],
      AssignableScopes:[$scope]}' >"$ROLE_FILE"
  echo ">> Creating the custom role at management-group scope..."
  ROLE_ID="$(az role definition create --role-definition "$ROLE_FILE" --query name -o tsv --only-show-errors)"
fi
[[ -n "$ROLE_ID" ]] || die "Could not resolve the custom role-definition ID."

direct_assignments() {
  local scope="$1" output attempt
  for attempt in 1 2 3 4 5 6; do
    if output="$(az role assignment list --scope "$scope" -o json --only-show-errors 2>/dev/null)"; then
      jq --arg scope "${scope,,}" --arg principal "${SP_OBJECT_ID,,}" \
        --arg role "${ROLE_ID,,}" '
          [.[] | select((.scope // "" | ascii_downcase) == $scope)
            | select((.principalId // "" | ascii_downcase) == $principal)
            | select((.roleDefinitionId // "" | split("/")[-1] | ascii_downcase) == $role)]' <<<"$output"
      return 0
    fi
    sleep 5
  done
  return 1
}

condition_is_compliant() {
  jq -e --arg condition "$CONDITION" '
    any(.[]; (.conditionVersion // "") == "2.0" and
      (((.condition // "") | gsub("\\s"; "")) == ($condition | gsub("\\s"; ""))))' >/dev/null
}

CREATED=0; REPLACED=0; SKIPPED=0; FAILED=0
for SUB_ID in "${SUBSCRIPTIONS[@]}"; do
  SUB_SCOPE="/subscriptions/${SUB_ID}"
  echo ">> Subscription: $SUB_ID"
  if ! EXISTING_ASSIGNMENTS="$(direct_assignments "$SUB_SCOPE")"; then
    echo "   FAILED to check existing assignments after retries; no change made."
    FAILED=$((FAILED + 1))
    continue
  fi
  if condition_is_compliant <<<"$EXISTING_ASSIGNMENTS"; then
    echo "   Assignment already compliant; skipped."
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  mapfile -t OLD_IDS < <(jq -r '.[].id' <<<"$EXISTING_ASSIGNMENTS")
  HAD_OLD="false"; DELETE_FAILED="false"
  for OLD_ID in "${OLD_IDS[@]}"; do
    [[ -n "$OLD_ID" ]] || continue
    HAD_OLD="true"
    echo "   Replacing existing assignment to apply the Blob read condition..."
    if ! az role assignment delete --ids "$OLD_ID" --only-show-errors; then
      echo "   FAILED to replace the existing assignment."
      FAILED=$((FAILED + 1)); DELETE_FAILED="true"; break
    fi
  done
  [[ "$DELETE_FAILED" == "false" ]] || continue

  CREATED_OK="false"; ALREADY_EXISTS="false"; LAST_ERROR=""
  for ATTEMPT in 1 2 3 4 5 6; do
    if CREATE_OUTPUT="$(az role assignment create \
      --assignee-object-id "$SP_OBJECT_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "$ROLE_ID" --scope "$SUB_SCOPE" \
      --condition "$CONDITION" --condition-version "2.0" \
      --only-show-errors 2>&1)"; then
      CREATED_OK="true"; break
    fi
    LAST_ERROR="$CREATE_OUTPUT"
    [[ "$CREATE_OUTPUT" == *"RoleAssignmentExists"* ]] &&
      { ALREADY_EXISTS="true"; break; }
    sleep 5
  done

  if [[ "$CREATED_OK" == "true" ]]; then
    echo "   Assigned with Blob read restricted to '$CONTAINER'."
    [[ "$HAD_OLD" == "true" ]] &&
      REPLACED=$((REPLACED + 1)) || CREATED=$((CREATED + 1))
  elif [[ "$ALREADY_EXISTS" == "true" ]]; then
    echo "   Assignment already exists in Azure; skipped."
    SKIPPED=$((SKIPPED + 1))
  else
    echo "   FAILED: $(tr '\n' ' ' <<<"$LAST_ERROR" | sed 's/  */ /g')"
    FAILED=$((FAILED + 1))
  fi
done

echo "=============================================================="
echo "Onboarding summary"
echo "  Enterprise app : validated ($SP_OBJECT_ID)"
echo "  Custom role    : validated ($ROLE_NAME / $ROLE_ID)"
echo "  Subscriptions  : ${#SUBSCRIPTIONS[@]}"
echo "  Created        : $CREATED"
echo "  Replaced       : $REPLACED"
echo "  Skipped        : $SKIPPED"
echo "  Failed         : $FAILED"
echo "=============================================================="
[[ "$FAILED" -eq 0 ]] || exit 1
