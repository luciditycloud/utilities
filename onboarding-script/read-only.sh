#!/usr/bin/env bash
set -euo pipefail

# ---------- Inputs ----------
SUBSCRIPTION_ID="<subscription-id>"
SP_OBJECT_ID="<service-principal-object-id>"

AUTOSCALER=true
IDLE_DISK=false
DISK_TIERING=false
BLOBS=true
BLOB_VISIBILITY=true

# Storage network access (used when BLOBS or BLOB_VISIBILITY is on).
# The script checks each storage account's firewall and lists the rules
# Lucidity needs. Rules are added only after you approve them at the prompt,
# or without asking when AUTO_APPROVE_NETWORK_CHANGES=true.
STORAGE_NETWORK_CHECK=true
AUTO_APPROVE_NETWORK_CHANGES=false
STORAGE_ACCOUNTS=""   # names, comma- or space-separated; empty = all in the subscription

# ---------- Lucidity network details (provided by Lucidity) ----------
# Every storage account whose firewall allows only selected networks gets
# both a subnet rule and an IP rule for Lucidity.

# Lucidity's outbound public IP(s). SUBJECT TO CHANGE: the current IP is
# expected to change around LUCIDITY_EGRESS_IPS_VALID_UNTIL. When it changes,
# put the new IP here and move the old one to LUCIDITY_RETIRED_EGRESS_IPS, so
# a rerun replaces it on customer storage accounts.
LUCIDITY_EGRESS_IPS="4.157.111.90"
LUCIDITY_EGRESS_IPS_VALID_UNTIL="2026-11-16"
LUCIDITY_RETIRED_EGRESS_IPS=""

# Lucidity's AKS subnet. It has a Regional Microsoft.Storage service endpoint.
# Once the Global endpoint replaces it, subnet rules cover every region: then
# empty LUCIDITY_EGRESS_IPS and move its IPs to LUCIDITY_RETIRED_EGRESS_IPS,
# so a rerun removes the IP rules.
LUCIDITY_SUBNET_IDS="/subscriptions/3511ac94-c2ef-4644-8147-55f5f9a27a9e/resourceGroups/azurepls-rg/providers/Microsoft.Network/virtualNetworks/azurepls-vnet/subnets/aks-subnet"

# ---------- Preflight ----------
for cmd in az jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: '$cmd' not found. Install it, or run this script in Azure Cloud Shell." >&2
    exit 1
  }
done

if [[ "$SUBSCRIPTION_ID" == "<"* || "$SP_OBJECT_ID" == "<"* ]]; then
  echo "ERROR: set SUBSCRIPTION_ID and SP_OBJECT_ID at the top of this script." >&2
  exit 1
fi

az account show >/dev/null 2>&1 || {
  echo "ERROR: not logged in to Azure CLI. Run 'az login', then rerun." >&2
  exit 1
}

SCOPE="/subscriptions/$SUBSCRIPTION_ID"

RETRY_ATTEMPTS=6
RETRY_DELAY=10

# Blob data reads are limited to this container by a condition on each role
# assignment that grants blobs/read. Other permissions are unaffected.
INVENTORY_CONTAINER="lucidity-inventory"
BLOB_READ_CONDITION="((!(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'})) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEqualsIgnoreCase '$INVENTORY_CONTAINER'))"

# ---------- Run report ----------
# Every run, including a failed one, writes a report for the customer to send
# to Lucidity. Role definition files go in WORK_DIR, removed on exit.
WORK_DIR=$(mktemp -d)
STEPS_FILE="$WORK_DIR/steps.jsonl"
STORAGE_FILE="$WORK_DIR/storage.jsonl"
: > "$STEPS_FILE"
: > "$STORAGE_FILE"
NETWORK_CHECKED_FILE="$WORK_DIR/network-checked"
REPORT_FILE="$PWD/lucidity-onboarding-report-$SUBSCRIPTION_ID-$(date -u +%Y%m%dT%H%M%SZ).json"
TENANT_ID=""

record_step() {
  local step="$1"
  local status="$2"
  local required="$3"
  local detail="${4:-}"

  jq -nc \
    --arg step "$step" \
    --arg status "$status" \
    --argjson required "$required" \
    --arg detail "$detail" \
    '{step: $step, status: $status, required: $required, detail: $detail}' \
    >> "$STEPS_FILE"
}

finish() {
  local rc=$?
  local report network_checked=false

  [[ -f "$NETWORK_CHECKED_FILE" ]] && network_checked=true
  report=$(jq -s \
    --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg tenantId "$TENANT_ID" \
    --arg subscriptionId "$SUBSCRIPTION_ID" \
    --arg spObjectId "$SP_OBJECT_ID" \
    --argjson rc "$rc" \
    --argjson autoscaler "$AUTOSCALER" \
    --argjson idleDisk "$IDLE_DISK" \
    --argjson diskTiering "$DISK_TIERING" \
    --argjson blobs "$BLOBS" \
    --argjson blobVisibility "$BLOB_VISIBILITY" \
    --argjson networkChecked "$network_checked" \
    --arg egressIps "$LUCIDITY_EGRESS_IPS" \
    --arg retiredEgressIps "$LUCIDITY_RETIRED_EGRESS_IPS" \
    --arg subnetIds "$LUCIDITY_SUBNET_IDS" \
    --slurpfile storage "$STORAGE_FILE" \
    'def list: split("[ ,]+"; null) | map(select(length > 0));
    {
      generatedAt: $generatedAt,
      tenantId: $tenantId,
      subscriptionId: $subscriptionId,
      servicePrincipalObjectId: $spObjectId,
      features: {
        autoscaler: $autoscaler,
        idleDisk: $idleDisk,
        diskTiering: $diskTiering,
        blobs: $blobs,
        blobVisibility: $blobVisibility
      },
      status: (if $rc != 0 then "failed"
               elif any(.[]; .status != "ok") then "completed_with_warnings"
               else "completed" end),
      steps: .,
      storageNetwork: (if $networkChecked then {
        lucidityEgressIps: ($egressIps | list),
        retiredEgressIps: ($retiredEgressIps | list),
        luciditySubnetIds: ($subnetIds | list),
        accounts: $storage
      } else null end)
    }' "$STEPS_FILE")

  echo ""
  echo "=============================================================="
  echo " Lucidity onboarding: $(jq -r .status <<< "$report")"
  # Console shows the first line of each detail; the report keeps all of it.
  jq -r '.steps[] | "   [\(.status)] \(.step)" +
    (if .detail != "" then "\n      \(.detail | split("\n")[0])" else "" end)' <<< "$report"
  if printf '%s\n' "$report" > "$REPORT_FILE"; then
    echo ""
    echo " Report: $REPORT_FILE"
    echo " Please send this file to your Lucidity contact."
  else
    echo ""
    echo " Could not write the report file. Please send this to your Lucidity contact:"
    printf '%s\n' "$report"
  fi
  echo "=============================================================="

  rm -rf "$WORK_DIR"
  exit "$rc"
}
trap finish EXIT

# Progress goes to stderr, since some functions' stdout is captured.
progress() {
  echo ">> $*" >&2
}

progress "Selecting subscription $SUBSCRIPTION_ID..."
az account set --subscription "$SUBSCRIPTION_ID"
TENANT_ID=$(az account show --query tenantId -o tsv)

# ---------- Helpers ----------
json_array() {
  sed '/^[[:space:]]*$/d' | jq -Rsc \
    'split("\n") | map(select(length > 0)) | unique'
}

# Creates or updates a custom role; prints its ID. Exits on failure.
upsert_role() {
  local role_name="$1"
  local definition_file="$2"
  local action="create" err

  if az role definition list --name "$role_name" \
      --query '[0].name' -o tsv | grep -q .; then
    action="update"
  fi

  if [[ "$action" == create ]]; then
    progress "Creating role $role_name..."
  else
    progress "Updating role $role_name..."
  fi
  if ! err=$(az role definition "$action" \
      --role-definition "$definition_file" 2>&1 >/dev/null); then
    record_step "Role definition $role_name" "failed" true "$action failed: $err"
    echo "ERROR: could not $action role '$role_name': $err" >&2
    exit 1
  fi

  # A new role can take a short while to become visible (replication delay).
  local role_id="" attempt
  for attempt in $(seq 1 "$RETRY_ATTEMPTS"); do
    role_id=$(az role definition list --name "$role_name" \
      --query '[0].name' -o tsv)
    [[ -n "$role_id" ]] && break
    echo "   Waiting for the role to appear in Azure ($attempt/$RETRY_ATTEMPTS)..." >&2
    sleep "$RETRY_DELAY"
  done

  if [[ -z "$role_id" ]]; then
    record_step "Role definition $role_name" "failed" true "not found after $action"
    echo "ERROR: role '$role_name' was not found after creating it." >&2
    exit 1
  fi
  record_step "Role definition $role_name" "ok" true "${action}d"
  echo "$role_id"
}

# Assigns a role to Lucidity's service principal and records the result.
# An optional fifth argument adds an ABAC condition to the assignment.
# Returns 1 on failure; with set -e that stops the script unless the caller
# handles it (as for optional roles).
assign_role() {
  local label="$1"
  local role="$2"
  local scope="$3"
  local required="$4"
  local condition="${5:-}"
  local attempt err="" detail=""
  local condition_args=()

  if [[ -n "$condition" ]]; then
    condition_args=(--condition "$condition" --condition-version "2.0")
    detail="blob reads limited to '$INVENTORY_CONTAINER'"
  fi

  progress "Assigning $label at $scope..."
  # Retries cover replication delay for a just-created role or principal.
  # Missing permissions won't fix themselves, so those aren't retried.
  for attempt in $(seq 1 "$RETRY_ATTEMPTS"); do
    if err=$(az role assignment create \
        --assignee-object-id "$SP_OBJECT_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "$role" \
        --scope "$scope" \
        ${condition_args[@]+"${condition_args[@]}"} \
        --only-show-errors 2>&1 >/dev/null); then
      record_step "$label assignment at $scope" "ok" "$required" "$detail"
      return 0
    fi
    [[ "$err" == *AuthorizationFailed* ]] && break
    [[ "$attempt" -lt "$RETRY_ATTEMPTS" ]] &&
      echo "   Not accepted yet, retrying in ${RETRY_DELAY}s ($attempt/$RETRY_ATTEMPTS)..." >&2
    sleep "$RETRY_DELAY"
  done

  # Optional roles are a warning, and the caller explains the impact.
  if [[ "$required" == true ]]; then
    record_step "$label assignment at $scope" "failed" "$required" "$err"
    echo "ERROR: could not assign role '$label' at '$scope': $err" >&2
  else
    record_step "$label assignment at $scope" "warning" "$required" "$err"
  fi
  return 1
}

make_role_definition() {
  local role_name="$1"
  local description="$2"
  local actions_json="$3"
  local data_actions_json="$4"
  local output="$5"

  jq -n \
    --arg name "$role_name" \
    --arg description "$description" \
    --arg scope "$SCOPE" \
    --argjson actions "$actions_json" \
    --argjson dataActions "$data_actions_json" \
    '{
      Name: $name,
      IsCustom: true,
      Description: $description,
      Actions: $actions,
      NotActions: [],
      DataActions: $dataActions,
      NotDataActions: [],
      AssignableScopes: [$scope]
    }' > "$output"
}

# ---------- Always-on built-in roles ----------
assign_role "Reader" "Reader" "$SCOPE" true

# Reservations Reader is optional: without it, Lucidity loses only Azure
# reservation visibility (reservation inventory and reservation-aware cost and
# savings reporting). Assigning it requires tenant-level permission, so a
# failure is reported as a warning and the script continues. It is passed by
# name: az doesn't recognize a role ID starting with /providers/.
if ! assign_role \
    "Reservations Reader" \
    "Reservations Reader" \
    "/providers/Microsoft.Capacity" \
    false; then
  echo "WARNING: Reservations Reader was not assigned. Lucidity will not see Azure" >&2
  echo "  reservations or reservation-aware savings. Everything else works. A tenant" >&2
  echo "  administrator with elevated access can rerun this script to add it." >&2
  echo "  (Full Azure error is in the report.)" >&2
fi

# ---------- Guest Insights / Blob Visibility ----------
GUEST_ACTIONS=$(
  {
    cat <<'EOF'
Microsoft.Compute/virtualMachines/runCommand/action
Microsoft.Compute/virtualMachineScaleSets/virtualMachines/runCommand/action
EOF

    if [[ "$BLOB_VISIBILITY" == true ]]; then
      cat <<'EOF'
Microsoft.Storage/storageAccounts/inventoryPolicies/write
Microsoft.Storage/storageAccounts/blobServices/write
Microsoft.Storage/storageAccounts/blobServices/containers/write
Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action
Microsoft.Storage/storageAccounts/inventoryPolicies/delete
Microsoft.Storage/storageAccounts/managementPolicies/delete
EOF
    fi
  } | json_array
)

if [[ "$BLOB_VISIBILITY" == true ]]; then
  GUEST_DATA_ACTIONS=$(
    printf '%s\n' \
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read" |
      json_array
  )
else
  GUEST_DATA_ACTIONS='[]'
fi

GUEST_DESCRIPTION="Lucidity guest insights: runs the Lucidity collector inside virtual machines via Run Command."
if [[ "$BLOB_VISIBILITY" == true ]]; then
  GUEST_DESCRIPTION="$GUEST_DESCRIPTION Blob visibility: manages blob inventory policies, the inventory container and last-access tracking, deletes lifecycle policies, and reads blob data."
fi

GUEST_ROLE="lucidity-guest-insights-role-$SUBSCRIPTION_ID"
make_role_definition \
  "$GUEST_ROLE" \
  "$GUEST_DESCRIPTION" \
  "$GUEST_ACTIONS" \
  "$GUEST_DATA_ACTIONS" \
  "$WORK_DIR/guest-role.json"

GUEST_ROLE_ID=$(upsert_role "$GUEST_ROLE" "$WORK_DIR/guest-role.json")
GUEST_CONDITION=""
[[ "$BLOB_VISIBILITY" == true ]] && GUEST_CONDITION="$BLOB_READ_CONDITION"
assign_role "$GUEST_ROLE" "$GUEST_ROLE_ID" "$SCOPE" true "$GUEST_CONDITION"

# ---------- Optimization selections ----------
OPTIMIZATION_SELECTED=false
if [[ "$AUTOSCALER" == true || "$IDLE_DISK" == true ||
      "$DISK_TIERING" == true || "$BLOBS" == true ]]; then
  OPTIMIZATION_SELECTED=true
fi

if [[ "$OPTIMIZATION_SELECTED" == true ]]; then
  OPTIMIZATION_ACTIONS=$(
    {
      if [[ "$AUTOSCALER" == true ]]; then
        cat <<'EOF'
Microsoft.Authorization/locks/delete
Microsoft.Authorization/locks/write
Microsoft.Compute/disks/beginGetAccess/action
Microsoft.Compute/disks/delete
Microsoft.Compute/disks/write
Microsoft.Compute/snapshots/delete
Microsoft.Compute/snapshots/write
Microsoft.Compute/virtualMachineScaleSets/virtualMachines/write
Microsoft.Compute/virtualMachines/powerOff/action
Microsoft.Compute/virtualMachines/reapply/action
Microsoft.Compute/virtualMachines/redeploy/action
Microsoft.Compute/virtualMachines/start/action
Microsoft.Compute/virtualMachines/write
Microsoft.Network/networkInterfaces/join/action
EOF
      fi

      if [[ "$IDLE_DISK" == true || "$DISK_TIERING" == true ]]; then
        cat <<'EOF'
Microsoft.Authorization/locks/delete
Microsoft.Authorization/locks/write
Microsoft.Compute/disks/beginGetAccess/action
Microsoft.Compute/disks/delete
Microsoft.Compute/disks/write
Microsoft.Compute/snapshots/delete
Microsoft.Compute/snapshots/write
Microsoft.Compute/virtualMachineScaleSets/virtualMachines/write
Microsoft.Compute/virtualMachines/extensions/delete
Microsoft.Compute/virtualMachines/extensions/write
Microsoft.Compute/virtualMachines/powerOff/action
Microsoft.Compute/virtualMachines/reapply/action
Microsoft.Compute/virtualMachines/redeploy/action
Microsoft.Compute/virtualMachines/start/action
Microsoft.Compute/virtualMachines/write
Microsoft.Insights/DataCollectionRuleAssociations/Delete
Microsoft.Insights/DataCollectionRuleAssociations/Write
Microsoft.Insights/DataCollectionRules/Delete
Microsoft.Insights/DataCollectionRules/Write
Microsoft.ManagedIdentity/userAssignedIdentities/assign/action
Microsoft.Network/networkInterfaces/join/action
Microsoft.OperationalInsights/workspaces/delete
Microsoft.OperationalInsights/workspaces/sharedKeys/action
Microsoft.OperationalInsights/workspaces/write
Microsoft.OperationsManagement/managementAssociations/delete
Microsoft.OperationsManagement/managementAssociations/write
Microsoft.OperationsManagement/managementConfigurations/delete
Microsoft.OperationsManagement/managementConfigurations/write
Microsoft.OperationsManagement/register/action
Microsoft.OperationsManagement/solutions/delete
Microsoft.OperationsManagement/solutions/write
Microsoft.Resources/deployments/delete
Microsoft.Resources/deployments/write
EOF
      fi

      if [[ "$BLOBS" == true ]]; then
        cat <<'EOF'
Microsoft.Storage/storageAccounts/blobServices/containers/write
Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action
Microsoft.Storage/storageAccounts/blobServices/write
Microsoft.Storage/storageAccounts/inventoryPolicies/delete
Microsoft.Storage/storageAccounts/managementPolicies/delete
Microsoft.Storage/storageAccounts/managementPolicies/write
Microsoft.Storage/storageAccounts/write
EOF
      fi
    } | json_array
  )

  if [[ "$BLOBS" == true ]]; then
    OPTIMIZATION_DATA_ACTIONS=$(
      printf '%s\n' \
        "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read" |
        json_array
    )
  else
    OPTIMIZATION_DATA_ACTIONS='[]'
  fi

  FEATURES=()
  [[ "$AUTOSCALER" == true ]] && FEATURES+=("autoscaler")
  [[ "$IDLE_DISK" == true ]] && FEATURES+=("idle disk")
  [[ "$DISK_TIERING" == true ]] && FEATURES+=("disk tiering")
  [[ "$BLOBS" == true ]] && FEATURES+=("blobs")
  OPTIMIZATION_DESCRIPTION="Lucidity optimization: write and delete permissions for $(IFS=,; echo "${FEATURES[*]}" | sed 's/,/, /g')."

  OPTIMIZATION_ROLE="lucidity-optimize-role-$SUBSCRIPTION_ID"
  make_role_definition \
    "$OPTIMIZATION_ROLE" \
    "$OPTIMIZATION_DESCRIPTION" \
    "$OPTIMIZATION_ACTIONS" \
    "$OPTIMIZATION_DATA_ACTIONS" \
    "$WORK_DIR/optimization-role.json"

  OPTIMIZATION_ROLE_ID=$(
    upsert_role "$OPTIMIZATION_ROLE" "$WORK_DIR/optimization-role.json"
  )
  OPTIMIZATION_CONDITION=""
  [[ "$BLOBS" == true ]] && OPTIMIZATION_CONDITION="$BLOB_READ_CONDITION"
  assign_role "$OPTIMIZATION_ROLE" "$OPTIMIZATION_ROLE_ID" "$SCOPE" true \
    "$OPTIMIZATION_CONDITION"
fi

# ---------- Storage network access ----------
# Lucidity reads blob inventory over the storage data plane, which a storage
# firewall can block. Lucidity's network tests (outbound via load balancer,
# Regional service endpoint):
#   - Accounts in Lucidity's region (and possibly its paired region) see
#     Lucidity's subnet, so the subnet rule applies.
#   - Accounts in other regions see Lucidity's public IP, so the IP rule
#     applies.
# Adding both to every firewalled account covers either case.
# Only Lucidity's own rules are added or removed. defaultAction and
# publicNetworkAccess are never changed. Uses your credentials, not Lucidity's.

to_json_list() {
  jq -nc --arg s "$1" '$s | split("[ ,]+"; null) | map(select(length > 0))'
}

# What the customer should do about an account that needs attention.
network_note() {
  local status="$1"
  local result="$2"

  case "$status" in
    public_access_disabled)
      echo "Public network access is disabled. Allow selected networks and rerun, or ask Lucidity about a private endpoint." ;;
    network_perimeter)
      echo "Secured by a network security perimeter. Add Lucidity to the perimeter's access rules." ;;
    not_found)
      echo "Not found in this subscription. Check the name in STORAGE_ACCOUNTS." ;;
    *)
      case "$result" in
        pending_approval) echo "Rules not added. Rerun and approve, or set AUTO_APPROVE_NETWORK_CHANGES=true." ;;
        failed) echo "Adding rules failed (see report for the error)." ;;
      esac ;;
  esac
}

check_storage_network() {
  local accounts plan pending answer apply=false
  local record name rg op type value flag err failures attention total

  if [[ "$(date -u +%Y-%m-%d)" > "$LUCIDITY_EGRESS_IPS_VALID_UNTIL" ]]; then
    record_step "Lucidity egress IP check" "warning" false \
      "LUCIDITY_EGRESS_IPS was due to change on $LUCIDITY_EGRESS_IPS_VALID_UNTIL; IP rules may be outdated."
    echo "WARNING: Lucidity's outbound IP was due to change on $LUCIDITY_EGRESS_IPS_VALID_UNTIL." >&2
    echo "  Get the latest script from Lucidity before approving IP rules." >&2
  fi

  progress "Listing storage accounts and their firewall settings..."
  if ! accounts=$(az storage account list \
      --query "[].{name: name, resourceGroup: resourceGroup, location: location, kind: kind,
        publicNetworkAccess: publicNetworkAccess,
        defaultAction: networkRuleSet.defaultAction,
        ipRules: networkRuleSet.ipRules[].ipAddressOrRange,
        vnetRules: networkRuleSet.virtualNetworkRules[].virtualNetworkResourceId}" \
      -o json --only-show-errors 2>"$WORK_DIR/storage-list.err" </dev/null); then
    record_step "Storage network check" "warning" false \
      "could not list storage accounts: $(tr '\n' ' ' < "$WORK_DIR/storage-list.err")"
    return 0
  fi
  : > "$NETWORK_CHECKED_FILE"

  # One entry per account: its network state, a status, and the rule changes
  # Lucidity needs (actions).
  plan=$(jq -c \
    --argjson wanted "$(to_json_list "$STORAGE_ACCOUNTS")" \
    --argjson ips "$(to_json_list "$LUCIDITY_EGRESS_IPS")" \
    --argjson retired "$(to_json_list "$LUCIDITY_RETIRED_EGRESS_IPS")" \
    --argjson subnets "$(to_json_list "$LUCIDITY_SUBNET_IDS")" '
    def has_ip($a; $ip): ($a.ipRules // []) | any(. == $ip or . == ($ip + "/32"));
    def has_subnet($a; $s): ($a.vnetRules // []) | any(ascii_downcase == ($s | ascii_downcase));
    def ip_adds($a): [$ips[] | select(has_ip($a; .) | not) | {op: "add", type: "ip", value: .}];
    def ip_removals($a): [$retired[] | select(has_ip($a; .)) | {op: "remove", type: "ip", value: .}];
    def subnet_adds($a):
      [$subnets[] | select(has_subnet($a; .) | not) | {op: "add", type: "subnet", value: .}];
    def classify:
      . as $a
      | {name, resourceGroup, location, kind,
         publicNetworkAccess: (.publicNetworkAccess // "Enabled"),
         defaultAction: (.defaultAction // "Allow")} as $base
      | if $a.kind == "FileStorage" then $base + {status: "not_applicable", actions: []}
        elif $base.publicNetworkAccess == "Disabled" then $base + {status: "public_access_disabled", actions: []}
        elif $base.publicNetworkAccess == "SecuredByPerimeter" then $base + {status: "network_perimeter", actions: []}
        elif $base.defaultAction == "Allow" then $base + {status: "open", actions: []}
        else
          (subnet_adds($a) + ip_adds($a) + ip_removals($a)) as $actions
          | $base + {status: (if $actions == [] then "already_allowed" else "needs_rule" end),
                     actions: $actions}
        end;
    . as $all
    | [$all[] | .name as $n | select($wanted == [] or any($wanted[]; . == $n)) | classify]
      + [$wanted[] | . as $w | select($all | all(.name != $w))
         | {name: $w, status: "not_found", actions: []}]' <<< "$accounts")

  total=$(jq length <<< "$plan")
  pending=$(jq '[.[] | select(.actions != [])] | length' <<< "$plan")

  echo ""
  echo ">> Storage network check: $total account(s)"
  jq -r '.[] | "   \(.name) [\(.location // "-")]: \(.status)",
    (.actions[] | "      will \(.op) \(.type) rule \(.value)")' <<< "$plan"

  if [[ "$pending" -gt 0 ]]; then
    if [[ "$AUTO_APPROVE_NETWORK_CHANGES" == true ]]; then
      apply=true
      echo "   Auto-approved (AUTO_APPROVE_NETWORK_CHANGES=true)."
    elif [[ -t 0 ]]; then
      printf "   Apply these rule changes on %s storage account(s)? [y/N] " "$pending"
      read -r answer || answer=""
      [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] && apply=true
    else
      echo "   No terminal to ask for approval, so no rules were changed."
    fi
  fi

  while IFS= read -r record; do
    if [[ "$(jq '.actions | length' <<< "$record")" -eq 0 ]]; then
      jq -c '.result = "none"' <<< "$record" >> "$STORAGE_FILE"
      continue
    fi
    if [[ "$apply" != true ]]; then
      jq -c '.result = "pending_approval"' <<< "$record" >> "$STORAGE_FILE"
      continue
    fi

    name=$(jq -r .name <<< "$record")
    rg=$(jq -r .resourceGroup <<< "$record")
    failures=""
    while IFS=$'\t' read -r op type value; do
      flag="--ip-address"
      [[ "$type" == subnet ]] && flag="--subnet"
      progress "${name}: ${op} ${type} rule ${value}..."
      if ! err=$(az storage account network-rule "$op" -g "$rg" --account-name "$name" \
          "$flag" "$value" --only-show-errors 2>&1 >/dev/null </dev/null); then
        failures="${failures}${op} ${type} ${value}: ${err}; "
      fi
    done < <(jq -r '.actions[] | [.op, .type, .value] | @tsv' <<< "$record")

    if [[ -z "$failures" ]]; then
      jq -c '.result = "applied"' <<< "$record" >> "$STORAGE_FILE"
    else
      jq -c --arg detail "$failures" '.result = "failed" | .detail = $detail' \
        <<< "$record" >> "$STORAGE_FILE"
    fi
  done < <(jq -c '.[]' <<< "$plan")

  attention=$(jq -sc '[.[] | select(
      (.status | IN("public_access_disabled", "network_perimeter", "not_found"))
      or (.result | IN("pending_approval", "failed")))]' "$STORAGE_FILE")

  if [[ "$(jq length <<< "$attention")" -eq 0 ]]; then
    record_step "Storage network check" "ok" false \
      "$total account(s) checked; none need attention"
    return 0
  fi

  record_step "Storage network check" "warning" false \
    "$(jq length <<< "$attention") of $total account(s) need attention (see storageNetwork in the report)"
  echo ""
  echo "   Storage accounts that need attention:"
  while IFS=$'\t' read -r name status result; do
    echo "   - $name: $(network_note "$status" "$result")"
  done < <(jq -r '.[] | [.name, .status, .result] | @tsv' <<< "$attention")
}

# The roles are in place by now, so a problem here is a warning, never a
# failed onboarding.
if [[ "$STORAGE_NETWORK_CHECK" == true &&
      ( "$BLOBS" == true || "$BLOB_VISIBILITY" == true ) ]]; then
  # A subshell keeps set -e active inside the check while containing its exit.
  set +e
  ( set -e; check_storage_network )
  network_rc=$?
  set -e
  if [[ "$network_rc" -ne 0 ]]; then
    record_step "Storage network check" "warning" false \
      "the check stopped unexpectedly; see the console output above"
  fi
fi