#!/usr/bin/env bash
set -euo pipefail

# ---------- Inputs ----------
# Where to onboard:
#   subscription      SCOPE_IDS are subscription IDs. Each gets its own roles.
#   management_group  SCOPE_IDS are management group IDs. Roles are created at
#                     each management group and assigned on every enabled
#                     subscription under it, nested groups included.
SCOPE_TYPE="subscription"
SCOPE_IDS="<scope-id>"   # one or more, comma- or space-separated
# Lucidity's service principal in your tenant. Leave empty: the script finds
# it from Lucidity's application ID, and creates it in your tenant if it isn't
# there yet. Set it only if Lucidity gives you an object ID.
SP_OBJECT_ID=""

# Mode:
#   optimization  Lucidity gets read access plus write and delete permissions
#                 for the optimization features below. You approve this at a
#                 prompt, or AUTO_APPROVE_OPTIMIZATION=true skips it.
#   visibility    Read access, guest insights and blob visibility only: what
#                 Lucidity needs to project your savings. No approval needed.
MODE="optimization"
AUTO_APPROVE_OPTIMIZATION=false

# Optimization features (optimization mode only; ignored in visibility).
AUTOSCALER=true
IDLE_DISK=false
DISK_TIERING=false
BLOBS=true

# Visibility data (both modes).
GUEST_INSIGHTS=true    # VM Run Command, so Lucidity can collect data inside VMs
BLOB_VISIBILITY=true   # blob inventory, read only in the lucidity-inventory container

# Who sets up blob visibility on each storage account: the lucidity-inventory
# container and last access time tracking (used when BLOB_VISIBILITY is on).
#   lucidity  Lucidity does it, so its role gets container and blob service
#             write permissions.
#   script    This script does it now, with your credentials, and Lucidity's
#             role doesn't get those two permissions. Storage accounts created
#             later need a rerun.
BLOB_SETUP="lucidity"

# Storage changes: firewall rules (used when BLOBS or BLOB_VISIBILITY is on)
# and, with BLOB_SETUP=script, the container and last access time tracking.
# The script lists what each storage account needs and makes the changes only
# after you approve them at the prompt, or without asking when
# AUTO_APPROVE_STORAGE_CHANGES=true.
STORAGE_NETWORK_CHECK=true
AUTO_APPROVE_STORAGE_CHANGES=false
STORAGE_ACCOUNTS=""   # names, comma- or space-separated; empty = all in the target subscriptions

# ---------- Lucidity details (provided by Lucidity) ----------
# Lucidity's application ID; its service principal in your tenant gets the
# roles.
LUCIDITY_APP_ID="4f2c2c1f-372a-4904-b13d-11e2467679f2"

# ---------- Lucidity network details (provided by Lucidity) ----------
# Every storage account whose firewall allows only selected networks gets an
# IP rule for Lucidity, and also a subnet rule when Lucidity's subnet can reach
# its region (LUCIDITY_SUBNET_REGIONS).

# Lucidity's outbound public IP(s). SUBJECT TO CHANGE: the current IP is
# expected to change around LUCIDITY_EGRESS_IPS_VALID_UNTIL. When it changes,
# put the new IP here and move the old one to LUCIDITY_RETIRED_EGRESS_IPS, so
# a rerun replaces it on customer storage accounts.
LUCIDITY_EGRESS_IPS="4.157.111.90"
LUCIDITY_EGRESS_IPS_VALID_UNTIL="2026-11-16"
LUCIDITY_RETIRED_EGRESS_IPS=""

# Lucidity's AKS subnet. It has a Regional Microsoft.Storage service endpoint,
# which Azure only lets storage accounts in LUCIDITY_SUBNET_REGIONS use: a
# subnet rule on an account in any other region is rejected. Those accounts
# get the IP rule only.
# Once the Global endpoint replaces the Regional one, subnet rules cover every
# region: set LUCIDITY_SUBNET_REGIONS="*", empty LUCIDITY_EGRESS_IPS and move
# its IPs to LUCIDITY_RETIRED_EGRESS_IPS, so a rerun removes the IP rules.
LUCIDITY_SUBNET_IDS="/subscriptions/3511ac94-c2ef-4644-8147-55f5f9a27a9e/resourceGroups/azurepls-rg/providers/Microsoft.Network/virtualNetworks/azurepls-vnet/subnets/aks-subnet"
LUCIDITY_SUBNET_REGIONS="eastus westus westus3"

# ---------- Output ----------
# Colours only when both outputs are a terminal and NO_COLOR isn't set.
if [[ -t 1 && -t 2 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

# Messages go to stderr, since some functions' stdout is captured.
progress() { echo "${BOLD}>> $*${RESET}" >&2; }
error() { echo "${RED}ERROR: $*${RESET}" >&2; }
# First argument is the headline; any others are indented lines below it.
warn() {
  echo "${YELLOW}WARNING: $1" >&2
  shift
  local line
  for line in "$@"; do echo "  $line" >&2; done
  printf '%s' "$RESET" >&2
}

# ---------- Preflight ----------
for cmd in az jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    error "'$cmd' not found. Install it, or run this script in Azure Cloud Shell."
    exit 1
  }
done

if [[ "$SCOPE_IDS" == "<"* || -z "${SCOPE_IDS//[ ,]/}" ]]; then
  error "set SCOPE_IDS at the top of this script."
  exit 1
fi
[[ "$SP_OBJECT_ID" == "<"* ]] && SP_OBJECT_ID=""

case "$SCOPE_TYPE" in
  subscription|management_group) ;;
  *)
    error "SCOPE_TYPE must be subscription or management_group. Got: '$SCOPE_TYPE'"
    exit 1 ;;
esac

case "$MODE" in
  optimization|visibility) ;;
  *)
    error "MODE must be optimization or visibility. Got: '$MODE'"
    exit 1 ;;
esac

case "$BLOB_SETUP" in
  lucidity|script) ;;
  *)
    error "BLOB_SETUP must be lucidity or script. Got: '$BLOB_SETUP'"
    exit 1 ;;
esac

for setting in AUTO_APPROVE_OPTIMIZATION AUTOSCALER IDLE_DISK DISK_TIERING BLOBS \
    GUEST_INSIGHTS BLOB_VISIBILITY STORAGE_NETWORK_CHECK AUTO_APPROVE_STORAGE_CHANGES; do
  case "${!setting}" in
    true|false) ;;
    *)
      error "$setting must be true or false. Got: '${!setting}'"
      exit 1 ;;
  esac
done

read -ra SCOPE_ID_LIST <<< "$(tr ',' ' ' <<< "$SCOPE_IDS")"

# Visibility mode never grants optimization permissions.
OPTIMIZATION_FEATURES_IGNORED=false
if [[ "$MODE" == visibility ]]; then
  if [[ "$AUTOSCALER" == true || "$IDLE_DISK" == true ||
        "$DISK_TIERING" == true || "$BLOBS" == true ]]; then
    OPTIMIZATION_FEATURES_IGNORED=true
  fi
  AUTOSCALER=false
  IDLE_DISK=false
  DISK_TIERING=false
  BLOBS=false
fi

FEATURES=()
[[ "$AUTOSCALER" == true ]] && FEATURES+=("autoscaler")
[[ "$IDLE_DISK" == true ]] && FEATURES+=("idle disk")
[[ "$DISK_TIERING" == true ]] && FEATURES+=("disk tiering")
[[ "$BLOBS" == true ]] && FEATURES+=("blobs")
FEATURE_LIST=$(IFS=,; echo "${FEATURES[*]:-}" | sed 's/,/, /g')

az account show >/dev/null 2>&1 || {
  error "not logged in to Azure CLI. Run 'az login', then rerun."
  exit 1
}

RETRY_ATTEMPTS=6
RETRY_DELAY=10

# Blob data reads are limited to this container by a condition on each role
# assignment that grants blobs/read. Other permissions are unaffected.
INVENTORY_CONTAINER="lucidity-inventory"
BLOB_READ="Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read"
BLOB_READ_CONDITION="((!(ActionMatches{'$BLOB_READ'})) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEqualsIgnoreCase '$INVENTORY_CONTAINER'))"

# ---------- Run report ----------
# Every run, including a failed one, writes a report for the customer to send
# to Lucidity. Working files go in WORK_DIR, removed on exit.
WORK_DIR=$(mktemp -d)
STEPS_FILE="$WORK_DIR/steps.jsonl"          # one line per step
TARGETS_FILE="$WORK_DIR/targets.jsonl"      # one line per subscription found
RESULTS_FILE="$WORK_DIR/results.jsonl"      # one line per subscription onboarded
STORAGE_FILE="$WORK_DIR/storage.jsonl"      # one line per storage account
STORAGE_CHECKED_FILE="$WORK_DIR/storage-checked"
: > "$STEPS_FILE"; : > "$TARGETS_FILE"; : > "$RESULTS_FILE"; : > "$STORAGE_FILE"
REPORT_FILE="$PWD/lucidity-onboarding-report-$(date -u +%Y%m%dT%H%M%SZ).json"
TENANT_ID=""
RESERVATIONS_READER="not_attempted"

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

to_json_list() {
  jq -nc --arg s "$1" '$s | split("[ ,]+"; null) | map(select(length > 0))'
}

finish() {
  local rc=$?
  local report status storage_checked=false st step detail colour

  [[ -f "$STORAGE_CHECKED_FILE" ]] && storage_checked=true
  report=$(jq -s \
    --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg tenantId "$TENANT_ID" \
    --arg spObjectId "$SP_OBJECT_ID" \
    --argjson rc "$rc" \
    --arg scopeType "$SCOPE_TYPE" \
    --argjson scopeIds "$(to_json_list "$SCOPE_IDS")" \
    --arg mode "$MODE" \
    --arg reservationsReader "$RESERVATIONS_READER" \
    --argjson guestInsights "$GUEST_INSIGHTS" \
    --argjson autoscaler "$AUTOSCALER" \
    --argjson idleDisk "$IDLE_DISK" \
    --argjson diskTiering "$DISK_TIERING" \
    --argjson blobs "$BLOBS" \
    --argjson blobVisibility "$BLOB_VISIBILITY" \
    --arg blobSetup "$BLOB_SETUP" \
    --slurpfile targets "$TARGETS_FILE" \
    --slurpfile results "$RESULTS_FILE" \
    --argjson storageChecked "$storage_checked" \
    --argjson networkCheck "$STORAGE_NETWORK_CHECK" \
    --argjson egressIps "$(to_json_list "$LUCIDITY_EGRESS_IPS")" \
    --argjson retiredEgressIps "$(to_json_list "$LUCIDITY_RETIRED_EGRESS_IPS")" \
    --argjson subnetIds "$(to_json_list "$LUCIDITY_SUBNET_IDS")" \
    --argjson subnetRegions "$(to_json_list "$LUCIDITY_SUBNET_REGIONS")" \
    --slurpfile storage "$STORAGE_FILE" \
    '{
      generatedAt: $generatedAt,
      tenantId: $tenantId,
      servicePrincipalObjectId: $spObjectId,
      scopeType: $scopeType,
      scopeIds: $scopeIds,
      mode: $mode,
      features: {
        guestInsights: $guestInsights,
        autoscaler: $autoscaler,
        idleDisk: $idleDisk,
        diskTiering: $diskTiering,
        blobs: $blobs,
        blobVisibility: $blobVisibility
      },
      blobSetup: $blobSetup,
      reservationsReader: $reservationsReader,
      status: (if $rc != 0 then "failed"
               elif any(.[]; .required and .status == "failed") then "completed_with_errors"
               elif any(.[]; .status != "ok") then "completed_with_warnings"
               else "completed" end),
      subscriptions: [$targets[] | . as $t
        | . + ([$results[] | select(.subscriptionId == $t.subscriptionId)][0] // {})],
      steps: .,
      storage: (if $storageChecked then {
        networkChecked: $networkCheck,
        blobSetup: $blobSetup,
        lucidityEgressIps: $egressIps,
        retiredEgressIps: $retiredEgressIps,
        luciditySubnetIds: $subnetIds,
        luciditySubnetRegions: $subnetRegions,
        accounts: $storage
      } else null end)
    }' "$STEPS_FILE")
  status=$(jq -r .status <<< "$report")

  case "$status" in
    completed) colour="$GREEN" ;;
    completed_with_warnings) colour="$YELLOW" ;;
    *) colour="$RED" ;;
  esac

  echo ""
  echo "=============================================================="
  echo " Lucidity onboarding: ${colour}${BOLD}${status}${RESET}"
  # Console shows the first line of each detail; the report keeps all of it.
  while IFS=$'\t' read -r st step detail; do
    case "$st" in
      ok) colour="$GREEN" ;;
      warning) colour="$YELLOW" ;;
      *) colour="$RED" ;;
    esac
    echo "   ${colour}[$st]${RESET} $step"
    [[ -n "$detail" ]] && echo "      $detail"
  done < <(jq -r '.steps[] | [.status, .step, (.detail | split("\n")[0])] | @tsv' <<< "$report")

  if [[ "$RESERVATIONS_READER" == missing ]]; then
    echo ""
    echo "${YELLOW}${BOLD} Reservations Reader is missing.${RESET}${YELLOW} Lucidity can't see your Azure"
    echo " reservations or include them in savings. Ask a tenant administrator"
    echo " with elevated access to rerun this script.${RESET}"
  fi

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
  # Some subscriptions failed: the run finished, but not cleanly.
  [[ "$status" == completed_with_errors && "$rc" -eq 0 ]] && rc=1
  exit "$rc"
}
trap finish EXIT

TENANT_ID=$(az account show --query tenantId -o tsv)

# ---------- Lucidity's service principal ----------
# Find Lucidity's service principal in your tenant, creating it from
# Lucidity's application if it's missing. Each failure reports its actual
# cause.
resolve_sp() {
  local out

  # 1. An object ID was given: use it if it exists in this tenant.
  if [[ -n "$SP_OBJECT_ID" ]]; then
    if out=$(az ad sp show --id "$SP_OBJECT_ID" --query id -o tsv --only-show-errors 2>&1); then
      record_step "Lucidity service principal" "ok" true "using the given object ID"
      return 0
    fi
    if [[ "$out" != *ResourceNotFound* && "$out" != *"does not exist"* ]]; then
      # Can't check (for example, no directory read access): trust the value.
      warn "couldn't verify SP_OBJECT_ID $SP_OBJECT_ID; using it as given." \
        "Azure CLI: $(tr '\n' ' ' <<< "$out")"
      record_step "Lucidity service principal" "warning" false \
        "using the given object ID without verifying it: $out"
      return 0
    fi
    warn "SP_OBJECT_ID $SP_OBJECT_ID doesn't exist in this tenant." \
      "Looking up Lucidity's service principal from its application ID instead."
  fi

  # 2. Look it up from Lucidity's application ID.
  if ! out=$(az ad sp list --filter "appId eq '$LUCIDITY_APP_ID'" --query "[0].id" -o tsv \
      --only-show-errors 2>&1); then
    record_step "Lucidity service principal" "failed" true "can't read service principals: $out"
    error "your account cannot read service principals in Microsoft Entra ID."
    echo "  Azure CLI: $(tr '\n' ' ' <<< "$out")" >&2
    echo "  Ask an administrator for directory read access, then rerun." >&2
    exit 1
  fi
  if [[ -n "$out" ]]; then
    SP_OBJECT_ID="$out"
    record_step "Lucidity service principal" "ok" true "found from Lucidity's application ID"
    return 0
  fi

  # 3. Not in this tenant yet: create it from Lucidity's application.
  progress "Lucidity's service principal isn't in this tenant yet; creating it..."
  if ! out=$(az ad sp create --id "$LUCIDITY_APP_ID" --query id -o tsv --only-show-errors 2>&1); then
    record_step "Lucidity service principal" "failed" true "can't create it: $out"
    error "your account cannot create Lucidity's service principal."
    echo "  Azure CLI: $(tr '\n' ' ' <<< "$out")" >&2
    echo "  Ask an Entra administrator (for example, an Application Administrator) to run:" >&2
    echo "    az ad sp create --id $LUCIDITY_APP_ID" >&2
    echo "  then rerun this script." >&2
    exit 1
  fi
  if [[ -z "$out" ]]; then
    record_step "Lucidity service principal" "failed" true "created, but no object ID returned"
    error "could not resolve Lucidity's service principal. Contact Lucidity."
    exit 1
  fi
  SP_OBJECT_ID="$out"
  record_step "Lucidity service principal" "ok" true "created in this tenant"
}

progress "Resolving Lucidity's service principal..."
resolve_sp
echo "   Service principal object ID: $SP_OBJECT_ID" >&2

# ---------- Helpers ----------
json_array() {
  sed '/^[[:space:]]*$/d' | jq -Rsc \
    'split("\n") | map(select(length > 0)) | unique'
}

# Runs a function in a subshell with set -e active, without stopping the
# script when it fails. The exit status is left in CONTAINED_RC.
run_contained() {
  set +e
  ( set -e; "$@" ) </dev/null
  CONTAINED_RC=$?
  set -e
}

make_role_definition() {
  local role_name="$1"
  local description="$2"
  local actions_json="$3"
  local data_actions_json="$4"
  local not_actions_json="$5"
  local not_data_actions_json="$6"
  local scopes_json="$7"

  jq -n \
    --arg name "$role_name" \
    --arg description "$description" \
    --argjson actions "$actions_json" \
    --argjson dataActions "$data_actions_json" \
    --argjson notActions "$not_actions_json" \
    --argjson notDataActions "$not_data_actions_json" \
    --argjson scopes "$scopes_json" \
    '{
      Name: $name,
      IsCustom: true,
      Description: $description,
      Actions: $actions,
      NotActions: $notActions,
      DataActions: $dataActions,
      NotDataActions: $notDataActions,
      AssignableScopes: $scopes
    }'
}

# Creates a custom role at home_scope, or adds missing permissions to an
# existing one. Updates only ever add: permissions already in the role are
# kept, even ones this run didn't ask for. Prints the role's ID.
# Results are cached per role, so a management-group role is set up once.
ensure_role() {
  local role_name="$1"
  local home_scope="$2"
  local description="$3"
  local actions="$4"
  local data_actions="$5"
  local cache="$WORK_DIR/role-$role_name"
  local existing merged definition err action detail added=0 kept=0 role_id="" attempt

  [[ -f "$cache.failed" ]] && return 1
  if [[ -f "$cache.id" ]]; then
    cat "$cache.id"
    return 0
  fi

  if ! existing=$(az role definition list --name "$role_name" --scope "$home_scope" \
      --query "[0]" -o json --only-show-errors 2>"$WORK_DIR/err"); then
    err=$(cat "$WORK_DIR/err")
    record_step "Role definition $role_name" "failed" true "could not look up the role: $err"
    error "could not look up role '$role_name': $err"
    touch "$cache.failed"
    return 1
  fi

  if [[ -z "$existing" || "$existing" == "null" ]]; then
    action="create"
    definition=$(make_role_definition "$role_name" "$description" "$actions" \
      "$data_actions" "[]" "[]" "$(jq -nc --arg s "$home_scope" '[$s]')")
    jq -c '.DataActions' <<< "$definition" > "$cache.data"
    jq -c '.Actions' <<< "$definition" > "$cache.actions"
    detail="created"
  else
    merged=$(jq -c --argjson a "$actions" --argjson d "$data_actions" '
      (.permissions[0] // {}) as $p
      | {actions: ((($p.actions // []) + $a) | unique),
         dataActions: ((($p.dataActions // []) + $d) | unique),
         notActions: ($p.notActions // []),
         notDataActions: ($p.notDataActions // []),
         scopes: .assignableScopes,
         added: (($a - ($p.actions // [])) + ($d - ($p.dataActions // []))),
         kept: ((($p.actions // []) - $a) + (($p.dataActions // []) - $d))}' <<< "$existing")
    added=$(jq '.added | length' <<< "$merged")
    kept=$(jq '.kept | length' <<< "$merged")
    role_id=$(jq -r '.name' <<< "$existing")
    jq -c '.dataActions' <<< "$merged" > "$cache.data"
    jq -c '.actions' <<< "$merged" > "$cache.actions"

    if [[ "$added" -eq 0 ]]; then
      action="none"
      detail="unchanged"
    else
      action="update"
      detail="updated: added $added permission(s)"
      [[ "$kept" -gt 0 ]] && description="$description Also keeps permissions granted by earlier runs."
      definition=$(make_role_definition "$role_name" "$description" \
        "$(jq -c .actions <<< "$merged")" "$(jq -c .dataActions <<< "$merged")" \
        "$(jq -c .notActions <<< "$merged")" "$(jq -c .notDataActions <<< "$merged")" \
        "$(jq -c .scopes <<< "$merged")")
    fi
    [[ "$kept" -gt 0 ]] &&
      detail="$detail; kept $kept permission(s) this run didn't ask for (the script never removes permissions)"
  fi

  if [[ "$action" != none ]]; then
    if [[ "$action" == create ]]; then
      progress "Creating role $role_name..."
    else
      progress "Updating role $role_name..."
    fi
    printf '%s\n' "$definition" > "$WORK_DIR/definition.json"
    if ! err=$(az role definition "$action" \
        --role-definition "$WORK_DIR/definition.json" 2>&1 >/dev/null); then
      record_step "Role definition $role_name" "failed" true "$action failed: $err"
      error "could not $action role '$role_name': $err"
      touch "$cache.failed"
      return 1
    fi
  fi

  # A new role can take a short while to become visible (replication delay).
  if [[ -z "$role_id" ]]; then
    for attempt in $(seq 1 "$RETRY_ATTEMPTS"); do
      role_id=$(az role definition list --name "$role_name" --scope "$home_scope" \
        --query '[0].name' -o tsv 2>/dev/null || true)
      [[ -n "$role_id" ]] && break
      echo "   Waiting for the role to appear in Azure ($attempt/$RETRY_ATTEMPTS)..." >&2
      sleep "$RETRY_DELAY"
    done
  fi

  if [[ -z "$role_id" ]]; then
    record_step "Role definition $role_name" "failed" true "not found after $action"
    error "role '$role_name' was not found after creating it."
    touch "$cache.failed"
    return 1
  fi
  record_step "Role definition $role_name" "ok" true "$detail"
  echo "$role_id" > "$cache.id"
  echo "$role_id"
}

# True if the role (already set up this run) grants blob data reads.
role_reads_blobs() {
  jq -e --arg r "$BLOB_READ" 'index($r) != null' "$WORK_DIR/role-$1.data" >/dev/null
}

# The two permissions Lucidity needs only when it sets up blob visibility
# itself (BLOB_SETUP=lucidity).
BLOB_SETUP_ACTIONS='["Microsoft.Storage/storageAccounts/blobServices/write","Microsoft.Storage/storageAccounts/blobServices/containers/write"]'

# True if the role (already set up this run) has either of them.
role_has_blob_setup_actions() {
  jq -e --argjson s "$BLOB_SETUP_ACTIONS" 'any(.[]; . as $a | $s | index($a) != null)' \
    "$WORK_DIR/role-$1.actions" >/dev/null
}

# Assigns a role to Lucidity's service principal and records the result.
# An optional fifth argument adds an ABAC condition to the assignment.
# Returns 1 on failure.
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
    error "could not assign role '$label' at '$scope': $err"
  else
    record_step "$label assignment at $scope" "warning" "$required" "$err"
  fi
  return 1
}

# ---------- Permissions ----------
GUEST_ACTIONS=$(
  {
    if [[ "$GUEST_INSIGHTS" == true ]]; then
      cat <<'EOF'
Microsoft.Compute/virtualMachines/runCommand/action
Microsoft.Compute/virtualMachineScaleSets/virtualMachines/runCommand/action
EOF
    fi

    if [[ "$BLOB_VISIBILITY" == true ]]; then
      cat <<'EOF'
Microsoft.Storage/storageAccounts/inventoryPolicies/write
Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action
Microsoft.Storage/storageAccounts/inventoryPolicies/delete
EOF
      # Container and last access time tracking, unless this script sets
      # them up (BLOB_SETUP=script).
      if [[ "$BLOB_SETUP" == lucidity ]]; then
        jq -r '.[]' <<< "$BLOB_SETUP_ACTIONS"
      fi
    fi
  } | json_array
)

if [[ "$BLOB_VISIBILITY" == true ]]; then
  GUEST_DATA_ACTIONS=$(printf '%s\n' "$BLOB_READ" | json_array)
else
  GUEST_DATA_ACTIONS='[]'
fi

GUEST_DESCRIPTION="Lucidity guest insights."
if [[ "$GUEST_INSIGHTS" == true ]]; then
  GUEST_DESCRIPTION="$GUEST_DESCRIPTION Runs the Lucidity collector inside virtual machines via Run Command."
fi
if [[ "$BLOB_VISIBILITY" == true && "$BLOB_SETUP" == lucidity ]]; then
  GUEST_DESCRIPTION="$GUEST_DESCRIPTION Blob visibility: manages blob inventory policies, the inventory container and last-access tracking, and reads blob data."
elif [[ "$BLOB_VISIBILITY" == true ]]; then
  GUEST_DESCRIPTION="$GUEST_DESCRIPTION Blob visibility: manages blob inventory policies and reads blob data; the inventory container and last-access tracking are set up by the onboarding script."
fi

# ---------- Optimization selections ----------
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
  OPTIMIZATION_DATA_ACTIONS=$(printf '%s\n' "$BLOB_READ" | json_array)
else
  OPTIMIZATION_DATA_ACTIONS='[]'
fi

OPTIMIZATION_DESCRIPTION="Lucidity optimization: write and delete permissions for $FEATURE_LIST."

# ---------- Targets ----------
# Every subscription this run onboards, with the scope it came from.
# Subscriptions that aren't enabled, or that your account can't see, are
# skipped and reported.
add_target() {
  local scope_id="$1"
  local sub="$2"
  local all_subs="$3"
  local info status reason="" details

  if jq -e --arg s "$sub" 'select((.subscriptionId | ascii_downcase) == ($s | ascii_downcase))' \
      "$TARGETS_FILE" >/dev/null 2>&1; then
    return 0   # already listed under an earlier scope
  fi

  info=$(jq -c --arg s "$sub" \
    '[.[] | select((.id | ascii_downcase) == ($s | ascii_downcase))][0] // empty' <<< "$all_subs")
  if [[ -z "$info" ]]; then
    status="skipped"
    reason="not found, or your account can't access it"
  elif [[ "$(jq -r .state <<< "$info")" != Enabled ]]; then
    status="skipped"
    reason="subscription is $(jq -r .state <<< "$info")"
  else
    status="eligible"
  fi

  details="${info:-}"
  [[ -z "$details" ]] && details='{}'
  jq -nc \
    --arg scopeId "$scope_id" \
    --arg sub "$sub" \
    --arg name "$(jq -r '.name // ""' <<< "$details")" \
    --arg state "$(jq -r '.state // "unknown"' <<< "$details")" \
    --arg status "$status" \
    --arg reason "$reason" \
    '{scopeId: $scopeId, subscriptionId: $sub, name: $name, state: $state, status: $status}
     + (if $reason != "" then {reason: $reason} else {} end)' >> "$TARGETS_FILE"

  if [[ "$status" == skipped ]]; then
    record_step "Subscription $sub" "warning" false "skipped: $reason"
  fi
}

progress "Finding target subscriptions..."
if ! ALL_SUBS=$(az account list --all \
    --query "[?tenantId=='$TENANT_ID'].{id: id, name: name, state: state}" \
    -o json --only-show-errors 2>"$WORK_DIR/err"); then
  error "could not list subscriptions: $(cat "$WORK_DIR/err")"
  exit 1
fi

if [[ "$SCOPE_TYPE" == subscription ]]; then
  for id in "${SCOPE_ID_LIST[@]}"; do
    add_target "$id" "$id" "$ALL_SUBS"
  done
else
  if ! ENTITIES=$(az account management-group entities list -o json \
      --only-show-errors 2>"$WORK_DIR/err"); then
    error "could not list management groups: $(cat "$WORK_DIR/err")"
    exit 1
  fi
  for id in "${SCOPE_ID_LIST[@]}"; do
    if ! jq -e --arg mg "$id" \
        'any(.[]; .type == "Microsoft.Management/managementGroups" and .name == $mg)' \
        <<< "$ENTITIES" >/dev/null; then
      record_step "Management group $id" "failed" true \
        "not found, or your account can't access it"
      error "management group '$id' not found, or your account can't access it."
      continue
    fi
    subs=$(jq -r --arg mg "$id" '.[]
      | select(.type == "/subscriptions" and any((.parentNameChain // [])[]; . == $mg))
      | .name' <<< "$ENTITIES")
    if [[ -z "$subs" ]]; then
      record_step "Management group $id" "warning" false "no subscriptions found under it"
      continue
    fi
    for sub in $subs; do
      add_target "$id" "$sub" "$ALL_SUBS"
    done
  done
fi

ELIGIBLE=$(jq -s '[.[] | select(.status == "eligible")] | length' "$TARGETS_FILE")

echo "" >&2
progress "Targets ($SCOPE_TYPE):"
jq -r '"   \(.subscriptionId) \(if .name != "" then "(\(.name)) " else "" end)under \(.scopeId): "
  + (if .status == "eligible" then "onboard" else "skip, \(.reason)" end)' \
  "$TARGETS_FILE" >&2

if [[ "$ELIGIBLE" -eq 0 ]]; then
  error "no subscriptions to onboard."
  exit 1
fi

# ---------- Mode ----------
if [[ "$MODE" == visibility ]]; then
  progress "Mode: visibility (read access, guest insights and blob visibility only)"
  if [[ "$OPTIMIZATION_FEATURES_IGNORED" == true ]]; then
    echo "   Optimization features are ignored in visibility mode." >&2
  fi
elif [[ ${#FEATURES[@]} -eq 0 ]]; then
  progress "Mode: optimization, but no optimization features are selected"
else
  # Approval gate: nothing has been changed yet.
  echo "" >&2
  echo "${BOLD}==============================================================" >&2
  echo " Mode: optimization${RESET}" >&2
  echo " Lucidity will get write and delete permissions on $ELIGIBLE subscription(s)" >&2
  echo " for: $FEATURE_LIST." >&2
  echo " These cover resources such as disks, snapshots, virtual machines," >&2
  echo " resource locks and storage accounts. The full list is in this script," >&2
  echo " under 'Optimization selections'." >&2
  if [[ "$BLOB_SETUP" == script && "$BLOBS" == true ]]; then
    echo " Blob optimization (BLOBS) includes container and blob service write" >&2
    echo " permissions, even with BLOB_SETUP=script." >&2
  fi
  echo " For read-only visibility instead, set MODE=\"visibility\" and rerun." >&2
  echo "${BOLD}==============================================================${RESET}" >&2
  approved=false
  if [[ "$AUTO_APPROVE_OPTIMIZATION" == true ]]; then
    approved=true
    echo "   Auto-approved (AUTO_APPROVE_OPTIMIZATION=true)." >&2
  elif [[ -t 0 ]]; then
    printf "   Grant optimization access? [y/N] " >&2
    read -r answer || answer=""
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] && approved=true
  else
    echo "   No terminal to ask for approval." >&2
  fi

  if [[ "$approved" != true ]]; then
    record_step "Optimization mode approval" "failed" true \
      "not approved; nothing was changed. Approve at the prompt, set AUTO_APPROVE_OPTIMIZATION=true, or use MODE=visibility"
    error "optimization access not approved. Nothing was changed."
    exit 1
  fi
  record_step "Optimization mode approval" "ok" true "approved for: $FEATURE_LIST"
fi

# ---------- Reservations Reader ----------
# Optional: without it, Lucidity loses only Azure reservation visibility
# (reservation inventory and reservation-aware cost and savings reporting).
# It is tenant-wide, so it's assigned once per run. Assigning it requires
# tenant-level permission, so a failure is a warning and the script continues.
# It is passed by name: az doesn't recognize a role ID starting with /providers/.
if assign_role "Reservations Reader" "Reservations Reader" \
    "/providers/Microsoft.Capacity" false; then
  RESERVATIONS_READER="assigned"
else
  RESERVATIONS_READER="missing"
  warn "Reservations Reader was not assigned." \
    "Lucidity will not see your Azure reservations or include them in savings." \
    "Everything else works. Ask a tenant administrator with elevated access" \
    "to rerun this script to add it. (Full Azure error is in the report.)"
fi

# ---------- Subscriptions ----------
# True if Lucidity's own subscription-level roles already exist on this
# subscription (from an earlier subscription-level run).
has_subscription_roles() {
  local sub="$1"
  local count

  count=$(az role definition list --custom-role-only true --scope "/subscriptions/$sub" \
    --query "length([?roleName=='lucidity-guest-insights-role-$sub' || roleName=='lucidity-optimize-role-$sub'])" \
    -o tsv --only-show-errors)
  [[ "$count" -gt 0 ]]
}

onboard_subscription() {
  local scope_id="$1"
  local sub="$2"
  local sub_scope="/subscriptions/$2"
  local home suffix roles_at role_name role_id condition names

  assign_role "Reader" "Reader" "$sub_scope" true

  # In management-group runs, a subscription that already has its own
  # Lucidity roles keeps them: they are updated in place and the management
  # group's roles are not added, so nothing is removed or duplicated.
  if [[ "$SCOPE_TYPE" == subscription ]]; then
    home="$sub_scope"; suffix="$sub"; roles_at="subscription"
  elif has_subscription_roles "$sub"; then
    home="$sub_scope"; suffix="$sub"; roles_at="subscription"
    progress "$sub already has subscription-level Lucidity roles; keeping and updating them"
  else
    home="/providers/Microsoft.Management/managementGroups/$scope_id"
    suffix="$scope_id"; roles_at="management_group"
  fi
  jq -nc --arg sub "$sub" --arg rolesAt "$roles_at" \
    '{subscriptionId: $sub, rolesAt: $rolesAt}' > "$WORK_DIR/roles-at-$sub.json"

  # Azure rejects a role with no permissions, so the guest role is skipped
  # when guest insights and blob visibility are both off.
  if [[ "$GUEST_ACTIONS" != "[]" ]]; then
    role_name="lucidity-guest-insights-role-$suffix"
    role_id=$(ensure_role "$role_name" "$home" "$GUEST_DESCRIPTION" \
      "$GUEST_ACTIONS" "$GUEST_DATA_ACTIONS")
    condition=""
    role_reads_blobs "$role_name" && condition="$BLOB_READ_CONDITION"
    assign_role "$role_name" \
      "$sub_scope/providers/Microsoft.Authorization/roleDefinitions/$role_id" \
      "$sub_scope" true "$condition"

    # Switching to BLOB_SETUP=script doesn't take away the write permissions
    # an earlier run granted; the script reports them once per role.
    if [[ "$BLOB_SETUP" == script && ! -f "$WORK_DIR/role-$role_name.noted" ]] &&
        role_has_blob_setup_actions "$role_name"; then
      touch "$WORK_DIR/role-$role_name.noted"
      record_step "Blob setup permissions in $role_name" "ok" false \
        "still has container and blob service write permissions from an earlier run; BLOB_SETUP=script does not remove them"
      echo "" >&2
      echo "${YELLOW}NOTE: $role_name still has container and blob service write" >&2
      echo "  permissions from an earlier run. BLOB_SETUP=script does not remove them.${RESET}" >&2
    fi
  fi

  if [[ ${#FEATURES[@]} -gt 0 ]]; then
    role_name="lucidity-optimize-role-$suffix"
    role_id=$(ensure_role "$role_name" "$home" "$OPTIMIZATION_DESCRIPTION" \
      "$OPTIMIZATION_ACTIONS" "$OPTIMIZATION_DATA_ACTIONS")
    condition=""
    role_reads_blobs "$role_name" && condition="$BLOB_READ_CONDITION"
    assign_role "$role_name" \
      "$sub_scope/providers/Microsoft.Authorization/roleDefinitions/$role_id" \
      "$sub_scope" true "$condition"
  fi

  # Visibility mode never removes optimization access granted by an earlier
  # run; it only reports it. Filtered by principal ID: --assignee would need
  # directory read access.
  if [[ "$MODE" == visibility ]]; then
    names=$(az role assignment list --scope "$sub_scope" \
      --query "[?principalId=='$SP_OBJECT_ID'].roleDefinitionName" -o tsv 2>/dev/null || true)
    if grep -q '^lucidity-optimize-role-' <<< "$names"; then
      record_step "Existing optimization access on $sub" "ok" false \
        "still assigned from an earlier run; visibility mode does not remove it"
      echo "" >&2
      echo "${YELLOW}NOTE: Lucidity already has optimization access on $sub." >&2
      echo "  Visibility mode does not remove it.${RESET}" >&2
    fi
  fi
}

while IFS=$'\t' read -r scope_id sub; do
  echo "" >&2
  progress "Subscription $sub"
  run_contained onboard_subscription "$scope_id" "$sub"
  if [[ "$CONTAINED_RC" -eq 0 ]]; then
    result="onboarded"
  else
    result="failed"
  fi
  jq -c --arg result "$result" '. + {result: $result}' \
    "$WORK_DIR/roles-at-$sub.json" 2>/dev/null >> "$RESULTS_FILE" ||
    jq -nc --arg sub "$sub" --arg result "$result" \
      '{subscriptionId: $sub, result: $result}' >> "$RESULTS_FILE"
done < <(jq -r 'select(.status == "eligible") | [.scopeId, .subscriptionId] | @tsv' "$TARGETS_FILE")


# ---------- Storage accounts ----------
# Two things can be needed on each storage account in the target
# subscriptions.
#
# Firewall rules (STORAGE_NETWORK_CHECK). Lucidity reads blob inventory over
# the storage data plane, which a storage firewall can block. Lucidity's
# network tests (outbound via load balancer, Regional service endpoint):
#   - Accounts in Lucidity's region (and possibly its paired region) see
#     Lucidity's subnet, so the subnet rule applies.
#   - Accounts in other regions see Lucidity's public IP, so the IP rule
#     applies.
# Adding both to every firewalled account covers either case. Only Lucidity's
# own rules are added or removed; defaultAction and publicNetworkAccess are
# never changed.
#
# Blob setup (BLOB_SETUP=script): the lucidity-inventory container and last
# access time tracking. These are management operations, so a storage
# firewall doesn't block them.
#
# Changes use your credentials, not Lucidity's.

# Storage account kinds that support blob inventory and last access time
# tracking.
BLOB_SETUP_KINDS='["StorageV2","BlobStorage","BlockBlobStorage"]'

# What the customer should do about an account that needs attention.
storage_note() {
  local status="$1"
  local setup_status="$2"
  local result="$3"
  local notes=()

  case "$status" in
    public_access_disabled)
      notes+=("Public network access is disabled. Allow selected networks and rerun, or ask Lucidity about a private endpoint.") ;;
    network_perimeter)
      notes+=("Secured by a network security perimeter. Add Lucidity to the perimeter's access rules.") ;;
    not_found)
      notes+=("Not found in the target subscriptions. Check the name in STORAGE_ACCOUNTS.") ;;
  esac
  [[ "$setup_status" == check_failed ]] &&
    notes+=("Couldn't check the container or last access time tracking; see the report.")
  case "$result" in
    pending_approval)
      notes+=("Changes not made. Rerun and approve, or set AUTO_APPROVE_STORAGE_CHANGES=true.") ;;
    failed)
      notes+=("Some changes failed; see the report for the error.") ;;
  esac
  echo "${notes[*]:-}"
}

# Runs one planned change on a storage account. Prints Azure's error on
# failure.
apply_storage_action() {
  local sub="$1"
  local rg="$2"
  local name="$3"
  local op="$4"
  local type="$5"
  local value="$6"

  case "$type" in
    ip|subnet)
      local flag="--ip-address"
      [[ "$type" == subnet ]] && flag="--subnet"
      progress "${name}: ${op} ${type} rule ${value}..."
      az storage account network-rule "$op" --subscription "$sub" \
        -g "$rg" --account-name "$name" "$flag" "$value" \
        --only-show-errors 2>&1 >/dev/null </dev/null ;;
    container)
      progress "${name}: creating container ${value}..."
      az storage container-rm create --subscription "$sub" -g "$rg" \
        --storage-account "$name" -n "$value" \
        --only-show-errors 2>&1 >/dev/null </dev/null ;;
    last_access_tracking)
      progress "${name}: enabling last access time tracking..."
      az storage account blob-service-properties update --subscription "$sub" \
        -g "$rg" -n "$name" --enable-last-access-tracking true \
        --only-show-errors 2>&1 >/dev/null </dev/null ;;
  esac
}

check_storage() {
  local network="$STORAGE_NETWORK_CHECK" setup=false
  local accounts_file="$WORK_DIR/accounts.jsonl"
  local checked_file="$WORK_DIR/accounts-checked.jsonl"
  local listed plan pending answer apply=false sub record name rg
  local op type value err failures attention total lat exists check_err

  [[ "$BLOB_VISIBILITY" == true && "$BLOB_SETUP" == script ]] && setup=true

  if [[ "$network" == true &&
        "$(date -u +%Y-%m-%d)" > "$LUCIDITY_EGRESS_IPS_VALID_UNTIL" ]]; then
    record_step "Lucidity egress IP check" "warning" false \
      "LUCIDITY_EGRESS_IPS was due to change on $LUCIDITY_EGRESS_IPS_VALID_UNTIL; IP rules may be outdated."
    warn "Lucidity's outbound IP was due to change on $LUCIDITY_EGRESS_IPS_VALID_UNTIL." \
      "Get the latest script from Lucidity before approving IP rules."
  fi

  echo "" >&2
  : > "$accounts_file"
  for sub in $(jq -r 'select(.status == "eligible") | .subscriptionId' "$TARGETS_FILE"); do
    progress "Listing storage accounts in $sub..."
    if ! listed=$(az storage account list --subscription "$sub" \
        --query "[].{name: name, resourceGroup: resourceGroup, location: location, kind: kind,
          publicNetworkAccess: publicNetworkAccess,
          defaultAction: networkRuleSet.defaultAction,
          ipRules: networkRuleSet.ipRules[].ipAddressOrRange,
          vnetRules: networkRuleSet.virtualNetworkRules[].virtualNetworkResourceId}" \
        -o json --only-show-errors 2>"$WORK_DIR/storage-list.err"); then
      record_step "Storage check in $sub" "warning" false \
        "could not list storage accounts: $(tr '\n' ' ' < "$WORK_DIR/storage-list.err")"
      continue
    fi
    jq -c --arg sub "$sub" --argjson wanted "$(to_json_list "$STORAGE_ACCOUNTS")" \
      '.[] | select($wanted == [] or (.name as $n | any($wanted[]; . == $n)))
       | . + {subscriptionId: $sub}' <<< "$listed" >> "$accounts_file"
  done
  : > "$STORAGE_CHECKED_FILE"

  # Blob setup needs each account's current container and tracking state.
  : > "$checked_file"
  while IFS= read -r record; do
    if [[ "$setup" == true ]] &&
        jq -e --argjson k "$BLOB_SETUP_KINDS" '.kind as $kind | any($k[]; . == $kind)' \
          <<< "$record" >/dev/null; then
      sub=$(jq -r .subscriptionId <<< "$record")
      name=$(jq -r .name <<< "$record")
      rg=$(jq -r .resourceGroup <<< "$record")
      progress "Checking blob setup on $name..."
      check_err=""
      if ! lat=$(az storage account blob-service-properties show --subscription "$sub" \
          -g "$rg" -n "$name" --query "lastAccessTimeTrackingPolicy.enable" -o tsv \
          --only-show-errors 2>"$WORK_DIR/err" </dev/null); then
        check_err="last access time tracking: $(tr '\n' ' ' < "$WORK_DIR/err")"
      fi
      if ! exists=$(az storage container-rm exists --subscription "$sub" -g "$rg" \
          --storage-account "$name" -n "$INVENTORY_CONTAINER" --query exists -o tsv \
          --only-show-errors 2>"$WORK_DIR/err" </dev/null); then
        check_err="${check_err:+$check_err; }container: $(tr '\n' ' ' < "$WORK_DIR/err")"
      fi
      jq -c --arg lat "${lat:-}" --arg exists "${exists:-}" --arg err "$check_err" \
        '. + {latEnabled: ($lat == "true"), containerExists: ($exists == "true")}
         + (if $err != "" then {setupCheckError: $err} else {} end)' \
        <<< "$record" >> "$checked_file"
    else
      echo "$record" >> "$checked_file"
    fi
  done < "$accounts_file"

  # One entry per account: its firewall status, its blob setup status, and
  # the changes it needs (actions).
  plan=$(jq -sc \
    --argjson wanted "$(to_json_list "$STORAGE_ACCOUNTS")" \
    --argjson ips "$(to_json_list "$LUCIDITY_EGRESS_IPS")" \
    --argjson retired "$(to_json_list "$LUCIDITY_RETIRED_EGRESS_IPS")" \
    --argjson subnets "$(to_json_list "$LUCIDITY_SUBNET_IDS")" \
    --argjson subnetRegions "$(to_json_list "$LUCIDITY_SUBNET_REGIONS")" \
    --argjson network "$network" \
    --argjson setup "$setup" \
    --argjson kinds "$BLOB_SETUP_KINDS" \
    --arg container "$INVENTORY_CONTAINER" '
    def has_ip($a; $ip): ($a.ipRules // []) | any(. == $ip or . == ($ip + "/32"));
    def has_subnet($a; $s): ($a.vnetRules // []) | any(ascii_downcase == ($s | ascii_downcase));
    def ip_adds($a): [$ips[] | select(has_ip($a; .) | not) | {op: "add", type: "ip", value: .}];
    def ip_removals($a): [$retired[] | select(has_ip($a; .)) | {op: "remove", type: "ip", value: .}];
    # Azure rejects a subnet rule on an account outside the regions Lucidity'"'"'s
    # subnet endpoint covers; "*" means every region.
    def subnet_covers($a):
      any($subnetRegions[]; . == "*" or ascii_downcase == (($a.location // "") | ascii_downcase));
    def subnet_adds($a):
      if subnet_covers($a) then
        [$subnets[] | select(has_subnet($a; .) | not) | {op: "add", type: "subnet", value: .}]
      else [] end;
    def network_part($a; $base):
      if ($network | not) then {status: "not_checked", actions: []}
      elif $a.kind == "FileStorage" then {status: "not_applicable", actions: []}
      elif $base.publicNetworkAccess == "Disabled" then {status: "public_access_disabled", actions: []}
      elif $base.publicNetworkAccess == "SecuredByPerimeter" then {status: "network_perimeter", actions: []}
      elif $base.defaultAction == "Allow" then {status: "open", actions: []}
      else
        (subnet_adds($a) + ip_adds($a) + ip_removals($a)) as $actions
        | {status: (if $actions == [] then "already_allowed" else "needs_rule" end), actions: $actions}
      end;
    def setup_part($a):
      if ($setup | not) then {setupStatus: "not_requested", actions: []}
      elif (any($kinds[]; . == $a.kind) | not) then {setupStatus: "not_supported", actions: []}
      elif $a.setupCheckError then
        {setupStatus: "check_failed", actions: [], setupDetail: $a.setupCheckError}
      else
        ([if $a.containerExists then empty else {op: "create", type: "container", value: $container} end]
         + [if $a.latEnabled then empty else {op: "enable", type: "last_access_tracking", value: "true"} end]) as $s
        | {setupStatus: (if $s == [] then "ready" else "needs_setup" end), actions: $s}
      end;
    def classify:
      . as $a
      | {subscriptionId, name, resourceGroup, location, kind,
         publicNetworkAccess: (.publicNetworkAccess // "Enabled"),
         defaultAction: (.defaultAction // "Allow")} as $base
      | network_part($a; $base) as $n
      | setup_part($a) as $s
      | $base + {status: $n.status, setupStatus: $s.setupStatus, actions: ($n.actions + $s.actions),
                 subnetRuleApplies: (($subnets | length) > 0 and subnet_covers($a)),
                 ipOnly: (($subnets | length) > 0 and ($ips | length) > 0 and (subnet_covers($a) | not))}
        + (if $s.setupDetail then {setupDetail: $s.setupDetail} else {} end);
    . as $all
    | [$all[] | classify]
      + [$wanted[] | . as $w | select($all | all(.name != $w))
         | {name: $w, status: "not_found", setupStatus: "not_found", actions: []}]' "$checked_file")

  total=$(jq length <<< "$plan")
  pending=$(jq '[.[] | select(.actions != [])] | length' <<< "$plan")

  echo ""
  echo "${BOLD}>> Storage accounts: $total${RESET}"
  if [[ "$network" == true ]]; then
    echo "   Firewall rules for Lucidity, on accounts whose firewall allows only selected networks:"
    if [[ -n "${LUCIDITY_EGRESS_IPS//[ ,]/}" ]]; then
      echo "   - IP rule (Lucidity's outbound IP) on every such account"
    fi
    if [[ -z "${LUCIDITY_SUBNET_IDS//[ ,]/}" || -z "${LUCIDITY_SUBNET_REGIONS//[ ,]/}" ]]; then
      :
    elif [[ "$LUCIDITY_SUBNET_REGIONS" == *"*"* ]]; then
      echo "   - subnet rule (Lucidity's subnet) on every such account"
    else
      echo "   - subnet rule (Lucidity's subnet) where its service endpoint reaches:"
      echo "     $(tr -s ' ,' ' ' <<< "$LUCIDITY_SUBNET_REGIONS")"
      echo "     (Azure rejects a subnet rule on accounts in other regions, so they get the IP rule only)"
    fi
  fi
  jq -r --argjson network "$network" --argjson setup "$setup" '.[]
    | "   \(.name) [\(.location // "-")] in \(.subscriptionId // "-"): "
      + ([(if $network or .status == "not_found" then "firewall \(.status)"
             + (if (.status == "needs_rule" or .status == "already_allowed") and .ipOnly
                then " (IP rule only: \(.location) is outside the subnet endpoint'"'"'s regions)" else "" end)
           else empty end),
          (if $setup and .status != "not_found" then "blob setup \(.setupStatus)" else empty end)]
         | join(", ")),
      (.actions[] | "      will "
        + (if .type == "container" then "create container \(.value)"
           elif .type == "last_access_tracking" then "enable last access time tracking"
           else "\(.op) \(.type) rule \(.value)" end))' <<< "$plan"

  if [[ "$pending" -gt 0 ]]; then
    if [[ "$AUTO_APPROVE_STORAGE_CHANGES" == true ]]; then
      apply=true
      echo "   Auto-approved (AUTO_APPROVE_STORAGE_CHANGES=true)."
    elif [[ -t 0 ]]; then
      printf "   Apply these changes on %s storage account(s)? [y/N] " "$pending"
      read -r answer || answer=""
      [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] && apply=true
    else
      echo "   No terminal to ask for approval, so nothing was changed."
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

    sub=$(jq -r .subscriptionId <<< "$record")
    name=$(jq -r .name <<< "$record")
    rg=$(jq -r .resourceGroup <<< "$record")
    failures=""
    while IFS=$'\t' read -r op type value; do
      if ! err=$(apply_storage_action "$sub" "$rg" "$name" "$op" "$type" "$value"); then
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
      or .setupStatus == "check_failed"
      or (.result | IN("pending_approval", "failed")))]' "$STORAGE_FILE")

  if [[ "$(jq length <<< "$attention")" -eq 0 ]]; then
    record_step "Storage check" "ok" false \
      "$total account(s) checked; none need attention"
    return 0
  fi

  record_step "Storage check" "warning" false \
    "$(jq length <<< "$attention") of $total account(s) need attention (see storage in the report)"
  echo ""
  echo "${YELLOW}   Storage accounts that need attention:"
  while IFS=$'\t' read -r name status setup_status result; do
    echo "   - $name: $(storage_note "$status" "$setup_status" "$result")"
  done < <(jq -r '.[] | [.name, .status, .setupStatus, .result] | @tsv' <<< "$attention")
  printf '%s' "$RESET"
}

# The roles are in place by now, so a problem here is a warning, never a
# failed onboarding. The check reads stdin for its prompt, so it isn't run
# through run_contained.
RUN_STORAGE=false
if [[ "$STORAGE_NETWORK_CHECK" == true &&
      ( "$BLOBS" == true || "$BLOB_VISIBILITY" == true ) ]]; then
  RUN_STORAGE=true
fi
if [[ "$BLOB_VISIBILITY" == true && "$BLOB_SETUP" == script ]]; then
  RUN_STORAGE=true
fi

if [[ "$RUN_STORAGE" == true ]]; then
  set +e
  ( set -e; check_storage )
  storage_rc=$?
  set -e
  if [[ "$storage_rc" -ne 0 ]]; then
    record_step "Storage check" "warning" false \
      "the check stopped unexpectedly; see the console output above"
  fi
fi
