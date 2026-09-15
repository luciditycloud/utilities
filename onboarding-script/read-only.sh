#!/bin/bash
# =============================================================================
# Lucidity - PERMISSIONS_READONLY setup (per-scope roles)
# -----------------------------------------------------------------------------
# ONE custom role PER SCOPE, so a role is always welded to a single scope and
# can be managed/deleted from that scope (no cross-scope collisions):
#
#   -m "<mgIds>"    -> per MG:  <prefix>-mg-<mgId>   homed at that MG,
#                      assigned at the MG scope (inherited by all child subs).
#   -s "<subIds>"   -> per sub: <prefix>-sub-<subId> homed at that sub,
#                      assigned at that subscription scope.
#   IDs may be comma- or space-separated. Exactly one of -m / -s.
#
# ENABLEMENT_MODE (-e) decides WHO provisions 'lucidity-inventory' + LAT, and
# therefore whether the role carries storage writes:
#   lucidity_self          role KEEPS containers/write + blobServices/write; SP self-provisions.
#   setup_now  (tightest)  role has NO storage writes; THIS run provisions with YOUR creds.
#   customer_preprovision  role has NO storage writes; you provision separately.
#
# --clear (-c) with -m/-s : deletes every custom role whose name starts with the
#   prefix at the given scope(s), first removing Lucidity's assignments to them.
#   Prefix defaults to ROLE_PREFIX; override with -p.
#
# ABAC: a v2.0 condition limits blob DATA read (blobs/read) to 'lucidity-inventory'.
#   NOTE: at MG scope the condition is enforced but NOT viewable/editable in the
#   Azure portal (CLI only): az role assignment list --scope <mg> --query "[].condition".
#   Container CREATION is a control-plane action and is never ABAC-name-restrictable.
#
# Flags: -m -s | -e <mode> | -a "<accts>" (setup_now) | -p <prefix> | -c/--clear | -y | -h
# Requires: az CLI (logged in), bash. No jq/python dependency.
# =============================================================================

# ---- Config ----------------------------------------------------------------
LUCIDITYAPPID="4f2c2c1f-372a-4904-b13d-11e2467679f2"
ROLE_PREFIX="lucidity-permissions-readonly"
INVENTORY_CONTAINER="lucidity-inventory"
ENABLEMENT_MODE="lucidity_self"
LUCIDITY_READ_CONDITION="((!(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'})) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEquals '${INVENTORY_CONTAINER}'))"

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
DATA_ACTIONS=( "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read" )
ENABLEMENT_WRITES=(
  "Microsoft.Storage/storageAccounts/blobServices/containers/write"
  "Microsoft.Storage/storageAccounts/blobServices/write"
)

# ---- Long-opt translation --------------------------------------------------
args=()
for a in "$@"; do
  case "$a" in
    --clear) args+=("-c") ;;
    --yes)   args+=("-y") ;;
    --help)  args+=("-h") ;;
    *)       args+=("$a") ;;
  esac
done
set -- "${args[@]}"

# ---- Arg parsing -----------------------------------------------------------
MG_INPUT=""; SUB_INPUT=""; ACCT_INPUT=""; ASSUME_YES="false"; MODE_INPUT=""; PREFIX_INPUT=""; DO_CLEAR="false"
usage() {
  echo "Usage:"
  echo "  Setup : $0 (-m \"<mgIds>\" | -s \"<subIds>\") [-e <mode>] [-a \"<accts>\"] [-y]"
  echo "  Clear : $0 --clear (-m \"<mgIds>\" | -s \"<subIds>\") [-p <prefix>] [-y]"
  echo "  -m  management group ids (per-MG role, assigned at MG scope)"
  echo "  -s  subscription ids     (per-sub role, assigned at sub scope)"
  echo "  -e  mode: lucidity_self | setup_now | customer_preprovision (default: ${ENABLEMENT_MODE})"
  echo "  -a  (setup_now) limit provisioning to these storage accounts"
  echo "  -p  role-name prefix (default: ${ROLE_PREFIX})"
  echo "  -c, --clear   delete all roles with the prefix at the given scope(s)"
  echo "  -y, --yes     skip confirmation"
  echo "  IDs may be comma- or space-separated. Provide exactly one of -m / -s."
  exit 1
}
while getopts ":m:s:a:e:p:cyh" opt; do
  case "$opt" in
    m) MG_INPUT="$OPTARG" ;;
    s) SUB_INPUT="$OPTARG" ;;
    a) ACCT_INPUT="$OPTARG" ;;
    e) MODE_INPUT="$OPTARG" ;;
    p) PREFIX_INPUT="$OPTARG" ;;
    c) DO_CLEAR="true" ;;
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

normalize() { echo "$1" | tr ',' ' ' | xargs; }
MODE=""; SCOPE_LIST=()
if [ -n "$MG_INPUT" ]; then MODE="mg"; read -ra SCOPE_LIST <<< "$(normalize "$MG_INPUT")"
else MODE="sub"; read -ra SCOPE_LIST <<< "$(normalize "$SUB_INPUT")"; fi
ACCT_FILTER="$(normalize "$ACCT_INPUT")"

# ---- Drop storage writes unless SP self-provisions -------------------------
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

resolve_sp() {
  servicePrincipalId=$(az ad sp create --id "$LUCIDITYAPPID" --query id -o tsv --only-show-errors 2>/dev/null)
  [ -z "$servicePrincipalId" ] && servicePrincipalId=$(az ad sp list --all --query "[?appId=='${LUCIDITYAPPID}'].id" -o tsv --only-show-errors)
  [ -z "$servicePrincipalId" ] && { echo "ERROR: could not resolve Lucidity SP. Contact Lucidity."; exit 1; }
}

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

subs_under_mg() {  # $1=mgId ; prints child subscription ids (nested included)
  az account management-group entities list \
    --query "[?type=='/subscriptions' && contains(parentNameChain, '$1')].name" -o tsv --only-show-errors 2>/dev/null
}

clear_scope() {  # $1=scopePath ; deletes prefix-matching custom roles + their Lucidity assignments
  local scope="$1" line rname rid asg delerr n=0
  echo "   scope: $scope  (prefix '${ROLE_PREFIX}')"
  # list custom roles at this scope whose name starts with prefix
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rname="${line%%:::*}"; rid="${line##*:::}"
    n=$((n+1))
    echo "     - ${rname}"
    # remove Lucidity SP assignments to this role, wherever they are
    for asg in $(az role assignment list --all --assignee "$servicePrincipalId" --role "$rid" --query "[].id" -o tsv --only-show-errors 2>/dev/null); do
      az role assignment delete --ids "$asg" --only-show-errors >/dev/null 2>&1 && echo "         removed assignment"
    done
    delerr=$(az role definition delete --name "$rid" --scope "$scope" 2>&1)
    if [ $? -eq 0 ]; then echo "         deleted role definition"
    else echo "         DELETE FAILED: $(echo "$delerr" | tr '\n' ' ' | sed 's/  */ /g')"; fi
  done < <(az role definition list --scope "$scope" --custom-role-only true \
            --query "[?starts_with(roleName, '${ROLE_PREFIX}')].[roleName,name]" -o tsv --only-show-errors 2>/dev/null | sed 's/\t/:::/')
  [ "$n" -eq 0 ] && echo "     (no matching roles found at this scope)"
}

# ---- Login + SP ------------------------------------------------------------
echo ">> Ensuring Azure CLI login..."
az account show >/dev/null 2>&1 || az login --only-show-errors >/dev/null
tenantId=$(az account show --query tenantId -o tsv --only-show-errors)
echo ">> Resolving Lucidity service principal..."
resolve_sp
echo "   Service Principal Id: $servicePrincipalId"

# ---- CLEAR mode ------------------------------------------------------------
if [ "$DO_CLEAR" = "true" ]; then
  echo ""
  echo "=============================================================="
  echo " CLEAR - delete custom roles with prefix '${ROLE_PREFIX}'"
  echo "   Scope mode : ${MODE}   targets: ${SCOPE_LIST[*]}"
  echo "   Also removes Lucidity SP (${servicePrincipalId}) assignments to them"
  echo "=============================================================="
  if [ "$ASSUME_YES" != "true" ]; then printf "Proceed with deletion? [y/N] "; read -r r; case "$r" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac; fi
  for id in "${SCOPE_LIST[@]}"; do clear_scope "$(scope_path "$MODE" "$id")"; done
  echo ">> Clear complete."
  exit 0
fi

# ---- Consequence banner + confirm ------------------------------------------
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

  # Assignments are ALWAYS at subscription scope. For MG mode, fan out to child subs.
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
