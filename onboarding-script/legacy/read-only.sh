#!/bin/bash
# =============================================================================
# Lucidity - read-only assessment onboarding for Azure
# -----------------------------------------------------------------------------
# Grants Lucidity's service principal a custom, mostly read-only role so it can
# assess your Azure estate. One role is created per scope:
#
#   -m "<mgIds>"   role <prefix>-mg-<mgId>, defined at the management group and
#                  assigned on each subscription under it.
#   -s "<subIds>"  role <prefix>-sub-<subId>, defined and assigned at the
#                  subscription.
#   IDs may be comma- or space-separated. Provide exactly one of -m / -s.
#
# Blob data read is limited to the 'lucidity-inventory' container by a
# condition on each role assignment.
#
# Enablement mode (-e) decides who creates 'lucidity-inventory' and turns on
# Last Access Time (LAT) tracking on your storage accounts:
#   lucidity_self          Lucidity does it (default). The role includes the
#                          container and Blob-service write permissions.
#   setup_now              This script does it now, with your credentials.
#                          The role omits those two write permissions.
#   customer_preprovision  You do it separately. The role omits those two
#                          write permissions.
#
# To remove the roles and assignments again, use teardown.sh.
#
# Flags: -m | -s | -e <mode> | -a "<accts>" (setup_now) | -p <prefix> | -y | -h
# Requires: Azure CLI (logged in) and bash. No jq/python dependency.
# =============================================================================

# ---- Config ----------------------------------------------------------------
# Lucidity's application ID; its service principal in your tenant gets the role.
LUCIDITYAPPID="4f2c2c1f-372a-4904-b13d-11e2467679f2"
ROLE_PREFIX="lucidity-permissions-readonly"
INVENTORY_CONTAINER="lucidity-inventory"
ENABLEMENT_MODE="lucidity_self"
# Allows Blob reads only in 'lucidity-inventory'; other permissions are unaffected.
LUCIDITY_READ_CONDITION="((!(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'})) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEquals '${INVENTORY_CONTAINER}'))"

# Permissions granted to Lucidity. Mostly read-only; the exceptions are marked.
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
  # Run Command (VMs and scale-set instances): lets Lucidity run collection
  # scripts inside the guest OS.
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
  # Write: turn on LAT tracking (lucidity_self mode only).
  "Microsoft.Storage/storageAccounts/blobServices/write"
  "Microsoft.Storage/storageAccounts/blobServices/containers/read"
  # Write: create 'lucidity-inventory' (lucidity_self mode only).
  "Microsoft.Storage/storageAccounts/blobServices/containers/write"
  "Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action"
  "Microsoft.Storage/storageAccounts/fileServices/read"
  "Microsoft.Storage/storageAccounts/fileServices/shares/read"
  "Microsoft.Storage/storageAccounts/inventoryPolicies/read"
  # Write/delete: manage the Blob inventory policy that reports into
  # 'lucidity-inventory' (all modes).
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
# Blob data read, limited to 'lucidity-inventory' by LUCIDITY_READ_CONDITION.
DATA_ACTIONS=( "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read" )
# Removed from the role unless the mode is lucidity_self.
ENABLEMENT_WRITES=(
  "Microsoft.Storage/storageAccounts/blobServices/containers/write"
  "Microsoft.Storage/storageAccounts/blobServices/write"
)

# ---- Long-opt translation --------------------------------------------------
args=()
for a in "$@"; do
  case "$a" in
    -c|--clear) echo "ERROR: --clear has moved to teardown.sh (same -m / -s / -p / -y flags)."; exit 1 ;;
    --yes)   args+=("-y") ;;
    --help)  args+=("-h") ;;
    *)       args+=("$a") ;;
  esac
done
set -- "${args[@]}"

# ---- Arg parsing -----------------------------------------------------------
MG_INPUT=""; SUB_INPUT=""; ACCT_INPUT=""; ASSUME_YES="false"; MODE_INPUT=""; PREFIX_INPUT=""
usage() {
  echo "Usage:"
  echo "  $0 (-m \"<mgIds>\" | -s \"<subIds>\") [-e <mode>] [-a \"<accts>\"] [-p <prefix>] [-y]"
  echo "  -m  management group ids (per-MG role, assigned on each child subscription)"
  echo "  -s  subscription ids     (per-sub role, assigned at the subscription)"
  echo "  -e  mode: lucidity_self | setup_now | customer_preprovision (default: ${ENABLEMENT_MODE})"
  echo "  -a  (setup_now) limit provisioning to these storage accounts"
  echo "  -p  role-name prefix (default: ${ROLE_PREFIX})"
  echo "  -y, --yes     skip confirmation"
  echo "  IDs may be comma- or space-separated. Provide exactly one of -m / -s."
  echo "  To remove the roles and assignments, use teardown.sh."
  exit 1
}
while getopts ":m:s:a:e:p:yh" opt; do
  case "$opt" in
    m) MG_INPUT="$OPTARG" ;;
    s) SUB_INPUT="$OPTARG" ;;
    a) ACCT_INPUT="$OPTARG" ;;
    e) MODE_INPUT="$OPTARG" ;;
    p) PREFIX_INPUT="$OPTARG" ;;
    y) ASSUME_YES="true" ;;
    h) usage ;;
    *) usage ;;
  esac
done

[ -n "$MODE_INPUT" ]   && ENABLEMENT_MODE="$MODE_INPUT"
[ -n "$PREFIX_INPUT" ] && ROLE_PREFIX="$PREFIX_INPUT"

case "$ENABLEMENT_MODE" in lucidity_self|setup_now|customer_preprovision) ;; *) echo "ERROR: -e must be lucidity_self | setup_now | customer_preprovision. Got: '${ENABLEMENT_MODE}'"; exit 1 ;; esac
if { [ -n "$MG_INPUT" ] && [ -n "$SUB_INPUT" ]; } || { [ -z "$MG_INPUT" ] && [ -z "$SUB_INPUT" ]; }; then
  echo "ERROR: provide exactly one of -m or -s."; usage
fi

# Accept IDs separated by commas and/or spaces.
normalize() { echo "$1" | tr ',' ' ' | xargs; }
MODE=""; SCOPE_LIST=()
if [ -n "$MG_INPUT" ]; then MODE="mg"; read -ra SCOPE_LIST <<< "$(normalize "$MG_INPUT")"
else MODE="sub"; read -ra SCOPE_LIST <<< "$(normalize "$SUB_INPUT")"; fi
ACCT_FILTER="$(normalize "$ACCT_INPUT")"

# ---- Drop storage writes unless SP self-provisions -------------------------
# In setup_now / customer_preprovision Lucidity doesn't create the container or
# enable LAT, so it doesn't get those two write permissions.
if [ "$ENABLEMENT_MODE" != "lucidity_self" ]; then
  tmp=(); for a in "${ACTIONS[@]}"; do
    skip=0; for w in "${ENABLEMENT_WRITES[@]}"; do [ "$a" = "$w" ] && skip=1 && break; done
    [ "$skip" -eq 0 ] && tmp+=("$a")
  done; ACTIONS=("${tmp[@]}")
fi

# ---- Helpers ---------------------------------------------------------------
json_array() { local first=1 out="["; for x in "$@"; do [ $first -eq 1 ] && first=0 || out="${out},"; out="${out}\"${x}\""; done; printf '%s]' "$out"; }

scope_path() {  # $1=mg|sub  $2=id
  if [ "$1" = "mg" ]; then echo "/providers/Microsoft.Management/managementGroups/$2"; else echo "/subscriptions/$2"; fi
}
role_name_for() { echo "${ROLE_PREFIX}-$1-$2"; }   # $1=mg|sub $2=id

# Find Lucidity's service principal in your tenant, creating it if missing.
# Each failure reports its actual cause; the generic message is the last resort.
resolve_sp() {
  local out
  # 1. Can your account read service principals in Microsoft Entra ID?
  if ! out=$(az ad sp list --filter "appId eq '${LUCIDITYAPPID}'" --query "[0].id" -o tsv --only-show-errors 2>&1); then
    echo "ERROR: your account cannot read service principals in Microsoft Entra ID."
    echo "  Azure CLI: $(echo "$out" | tr '\n' ' ')"
    echo "  Ask an administrator for directory read access, then rerun."
    exit 1
  fi
  servicePrincipalId="$out"
  [ -n "$servicePrincipalId" ] && return 0

  # 2. Not in your tenant yet: create it from Lucidity's application.
  echo "   Lucidity's service principal not found in this tenant; creating it..."
  if ! out=$(az ad sp create --id "$LUCIDITYAPPID" --query id -o tsv --only-show-errors 2>&1); then
    echo "ERROR: your account cannot create Lucidity's service principal."
    echo "  Azure CLI: $(echo "$out" | tr '\n' ' ')"
    echo "  Ask an Entra administrator (e.g. Application Administrator) to run:"
    echo "    az ad sp create --id ${LUCIDITYAPPID}"
    echo "  then rerun this script."
    exit 1
  fi
  servicePrincipalId="$out"

  # 3. Last resort: commands succeeded but returned no ID.
  [ -z "$servicePrincipalId" ] && { echo "ERROR: could not resolve Lucidity SP. Contact Lucidity."; exit 1; }
}

# Create the role at the scope, or update it in place if it already exists.
create_or_update_role() {  # $1=roleName $2=scopePath ; echoes roleId on stdout, "" on failure (diagnostics to stderr)
  local rname="$1" scope="$2" rfile rid rerr existing
  rfile="$(mktemp)"
  cat > "$rfile" <<EOF
{
  "Name": "${rname}",
  "IsCustom": true,
  "Description": "Lucidity read-only assessment role (mode: ${ENABLEMENT_MODE}). Blob DATA read limited to '${INVENTORY_CONTAINER}' via ABAC on the assignment.",
  "Actions": $(json_array "${ACTIONS[@]}"),
  "NotActions": [],
  "DataActions": $(json_array "${DATA_ACTIONS[@]}"),
  "NotDataActions": [],
  "AssignableScopes": $(json_array "$scope")
}
EOF
  existing=$(az role definition list --name "$rname" --scope "$scope" --query "[0].name" -o tsv --only-show-errors 2>/dev/null)
  if [ -z "$existing" ]; then
    rid=$(az role definition create --role-definition "$rfile" --query name -o tsv 2>/tmp/.lucidity_re); [ -z "$rid" ] && {
      echo "     create failed: $(tr '\n' ' ' </tmp/.lucidity_re | sed 's/  */ /g')" >&2
      rid=$(az role definition update --role-definition "$rfile" --query name -o tsv 2>/tmp/.lucidity_re)
      [ -z "$rid" ] && echo "     update also failed: $(tr '\n' ' ' </tmp/.lucidity_re | sed 's/  */ /g')" >&2
    }
  else
    rid=$(az role definition update --role-definition "$rfile" --query name -o tsv 2>/tmp/.lucidity_re)
    [ -z "$rid" ] && { echo "     update failed: $(tr '\n' ' ' </tmp/.lucidity_re | sed 's/  */ /g')" >&2; rid="$existing"; }
  fi
  rm -f "$rfile" /tmp/.lucidity_re
  if [ -z "$rid" ]; then
    for _ in 1 2 3 4 5 6; do rid=$(az role definition list --name "$rname" --scope "$scope" --query "[0].name" -o tsv --only-show-errors 2>/dev/null); [ -n "$rid" ] && break; sleep 5; done
  fi
  echo "$rid"
}

# Assign the role to Lucidity with the Blob read condition, replacing any earlier
# assignment. Retries allow for Azure replication delays after role creation.
assign_role() {  # $1=roleId $2=scope ; returns 0 ok / 1 fail
  local rid="$1" scope="$2" prior out lasterr
  prior=$(az role assignment list --assignee "$servicePrincipalId" --role "$rid" --scope "$scope" --query "[0].id" -o tsv --only-show-errors 2>/dev/null)
  [ -n "$prior" ] && { az role assignment delete --ids "$prior" --only-show-errors >/dev/null 2>&1; echo "       removed prior assignment"; }
  for _ in 1 2 3 4 5 6; do
    out=$(az role assignment create --assignee-object-id "$servicePrincipalId" --assignee-principal-type ServicePrincipal \
          --role "$rid" --scope "$scope" --condition "$LUCIDITY_READ_CONDITION" --condition-version "2.0" \
          --query name -o tsv 2>&1)
    if [ $? -eq 0 ] && [ -n "$out" ]; then echo "       assigned (ABAC read-condition applied)"; return 0; fi
    lasterr="$out"; sleep 5
  done
  echo "       ASSIGNMENT FAILED: $(echo "$lasterr" | tr '\n' ' ' | sed 's/  */ /g')"
  return 1
}

# setup_now only: with your credentials, create 'lucidity-inventory' and turn on
# LAT on each storage account (or those given with -a). Changes your default
# az subscription as it goes.
provision_sub() {  # $1=subId ; provisions container + LAT (operator creds). returns 0/1
  local sub="$1" accounts line acct rg exists lat rc=0
  az account set --subscription "$sub" --only-show-errors 2>/dev/null || { echo "     ($sub) WARN: cannot select subscription"; return 1; }
  if [ -n "$ACCT_FILTER" ]; then
    accounts=""
    for a in $ACCT_FILTER; do
      rg=$(az storage account list --query "[?name=='$a'].resourceGroup | [0]" -o tsv --only-show-errors 2>/dev/null)
      [ -n "$rg" ] && accounts="${accounts}${a}:::${rg}"$'\n'
    done
  else
    accounts=$(az storage account list --query "[].[name,resourceGroup]" -o tsv --only-show-errors 2>/dev/null | sed 's/\t/:::/')
  fi
  [ -z "$accounts" ] && { echo "     ($sub) no storage accounts in scope"; return 0; }
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    acct="${line%%:::*}"; rg="${line##*:::}"
    exists=$(az storage container-rm exists -g "$rg" --storage-account "$acct" -n "$INVENTORY_CONTAINER" --query exists -o tsv --only-show-errors 2>/dev/null)
    if [ "$exists" = "true" ]; then echo "     ($sub) $acct: container OK"
    else az storage container-rm create -g "$rg" --storage-account "$acct" -n "$INVENTORY_CONTAINER" --only-show-errors >/dev/null 2>&1 \
         && echo "     ($sub) $acct: container created" || { echo "     ($sub) $acct: container create FAILED"; rc=1; }; fi
    lat=$(az storage account blob-service-properties show -g "$rg" -n "$acct" --query "lastAccessTimeTrackingPolicy.enable" -o tsv --only-show-errors 2>/dev/null)
    if [ "$lat" = "true" ]; then echo "     ($sub) $acct: LAT OK"
    else az storage account blob-service-properties update -g "$rg" -n "$acct" --enable-last-access-tracking true --only-show-errors >/dev/null 2>&1 \
         && echo "     ($sub) $acct: LAT enabled" || { echo "     ($sub) $acct: LAT enable FAILED"; rc=1; }; fi
  done <<< "$accounts"
  return $rc
}

# Subscriptions under the management group, including nested groups.
subs_under_mg() {  # $1=mgId ; prints child subscription ids (nested included)
  az account management-group entities list \
    --query "[?type=='/subscriptions' && contains(parentNameChain, '$1')].name" -o tsv --only-show-errors 2>/dev/null
}

# ---- Azure CLI + login + SP ------------------------------------------------
command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found. Install it, or run this script in Azure Cloud Shell."; exit 1; }
echo ">> Ensuring Azure CLI login..."
az account show >/dev/null 2>&1 || az login --only-show-errors >/dev/null || { echo "ERROR: Azure CLI login failed."; exit 1; }
tenantId=$(az account show --query tenantId -o tsv --only-show-errors)
echo ">> Resolving Lucidity service principal..."
resolve_sp
echo "   Service Principal Id: $servicePrincipalId"

# ---- Consequence banner + confirm ------------------------------------------
# Shows what will change and asks before proceeding (-y skips the prompt).
echo ""
echo "=============================================================="
echo " About to apply (mode: ${ENABLEMENT_MODE})"
echo "   Scope mode  : ${MODE}   targets: ${SCOPE_LIST[*]}"
echo "   Roles       : one per ${MODE} -> ${ROLE_PREFIX}-${MODE}-<id> (${#ACTIONS[@]} actions each)"
echo "   Assigned to : Lucidity SP ${servicePrincipalId} (always at SUBSCRIPTION scope)"
echo "   ABAC gate   : blobs/read -> container '${INVENTORY_CONTAINER}'"
[ "$MODE" = "mg" ] && echo "                 (MG mode: role homed at the MG; assignments fan out to each child subscription)"
case "$ENABLEMENT_MODE" in
  lucidity_self) echo "   Storage wr. : YES to SP (containers/write + blobServices/write, subscription-wide)"; echo "   Provisions  : nothing (SP self-enables container + LAT)";;
  setup_now) echo "   Storage wr. : NONE to SP"; if [ -n "$ACCT_FILTER" ]; then echo "   Provisions  : container + LAT on accounts [${ACCT_FILTER}] using YOUR creds"; else echo "   Provisions  : container + LAT on EVERY storage account in scope using YOUR creds"; fi;;
  customer_preprovision) echo "   Storage wr. : NONE to SP"; echo "   Provisions  : nothing (you create container + enable LAT yourself)";;
esac
echo "=============================================================="
if [ "$ASSUME_YES" != "true" ]; then printf "Proceed? [y/N] "; read -r r; case "$r" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac; fi

# ---- Main loop -------------------------------------------------------------
# Per scope: create/update the role, then assign it on each subscription. A
# failure is reported and the run continues; the exit code is non-zero at the end.
fail=0
for id in "${SCOPE_LIST[@]}"; do
  scope="$(scope_path "$MODE" "$id")"
  rname="$(role_name_for "$MODE" "$id")"
  echo ""
  echo ">> [${MODE}: ${id}] role '${rname}' (${#ACTIONS[@]} actions)..."
  roleId="$(create_or_update_role "$rname" "$scope")"
  if [ -z "$roleId" ]; then
    echo "   ERROR: could not create/retrieve role '${rname}' at ${scope}."
    [ "$MODE" = "mg" ] && echo "   (MG-scoped roles need roleDefinitions/write AT the MG - subscription Owner is not enough.)"
    fail=1; continue
  fi
  echo "   role id: $roleId"

  # Assignments are always at subscription scope: Azure doesn't allow a role with
  # Blob data permissions to be assigned at a management group.
  if [ "$MODE" = "mg" ]; then
    target_subs="$(subs_under_mg "$id")"
    [ -z "$target_subs" ] && echo "   (no child subscriptions enumerated - check MG-reader access)"
  else
    target_subs="$id"
  fi

  for sub in $target_subs; do
    echo "   --- subscription ${sub} ---"
    echo "     assigning at /subscriptions/${sub} ..."
    assign_role "$roleId" "/subscriptions/${sub}" || fail=1
    if [ "$ENABLEMENT_MODE" = "setup_now" ]; then
      echo "     provisioning container + LAT..."
      provision_sub "$sub" || fail=1
    fi
  done
done

if [ "$ENABLEMENT_MODE" = "customer_preprovision" ]; then
  echo ""
  echo ">> Reminder (customer_preprovision): for each target storage account run -"
  echo "     az storage container-rm create -g <rg> --storage-account <acct> -n ${INVENTORY_CONTAINER}"
  echo "     az storage account blob-service-properties update -g <rg> -n <acct> --enable-last-access-tracking true"
fi

# ---- Summary ---------------------------------------------------------------
echo ""
echo "=============================================================="
echo " Setup summary"
echo "   Mode        : ${ENABLEMENT_MODE}"
echo "   Scope mode  : ${MODE}   targets: ${SCOPE_LIST[*]}"
echo "   Role naming : ${ROLE_PREFIX}-${MODE}-<id>  (${#ACTIONS[@]} actions each)"
echo "   ABAC gate   : blobs/read -> '${INVENTORY_CONTAINER}'"
echo "   TenantId    : ${tenantId}"
[ "$fail" -eq 0 ] && echo " Status       : COMPLETE" || echo " Status       : COMPLETED WITH ERRORS - review above"
echo "=============================================================="
exit $fail
