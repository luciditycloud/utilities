#!/usr/bin/env bash
# No 'set -e': one failed deletion must not stop the rest of the teardown.
# Failures are counted and reported, and the script exits non-zero at the end.
set -uo pipefail

# Lucidity Azure teardown: removes what read-only.sh (v1 and v2) set up.
# Default is plan-only. Add --execute to make changes.
# Requires Azure Cloud Shell Bash (bash 4.4+), Azure CLI and jq.
#
# Removes, in this order (each part can be skipped, see --help):
#   1. Lucidity's role assignments on the target subscriptions (and on the
#      management group with -m).
#   2. Lucidity's custom roles (LUCIDITY_PLATFORM and v1
#      lucidity-permissions-readonly-*), unless still assignable outside the
#      target scope.
#   3. Lucidity's Blob firewall rules (collector IP and subnet).
#   4. Lucidity's Blob inventory rules (before the container they write to).
#   5. The 'lucidity-inventory' containers, including their reports.
#   6. Last Access Time tracking, only on accounts you name, since your own
#      lifecycle rules may depend on it.
#   7. Lucidity's enterprise application. This affects the whole tenant, so it
#      is the default with -m only, and is done last.

SCRIPT_VERSION="1.0.0"
# Must match what read-only.sh set up.
APP_ID="4f2c2c1f-372a-4904-b13d-11e2467679f2"
ROLE_NAME="LUCIDITY_PLATFORM"
LEGACY_PREFIX="lucidity-permissions-readonly"
CONTAINER="lucidity-inventory"
INVENTORY_RULE="lucidity-blob-inventory-policy"
LUCIDITY_BLOB_EGRESS_IP="4.157.111.90"
LUCIDITY_BACKEND_SUBNET="/subscriptions/3511ac94-c2ef-4644-8147-55f5f9a27a9e/resourceGroups/azurepls-rg/providers/Microsoft.Network/virtualNetworks/azurepls-vnet/subnets/aks-subnet"

MG_ID=""
SUB_INPUT=""
LAT_INPUT=""
LAT_FILE=""
SKIP_ACCESS="false"
SKIP_LEGACY="false"
SKIP_NETWORK="false"
SKIP_STORAGE="false"
APP_CHOICE=""   # keep | delete | "" (default depends on scope mode)
EXECUTE="false"
ASSUME_YES="false"

usage() {
  cat <<'EOF'
Usage:
  ./teardown.sh --management-group <MG_ID> [options] [--execute] [--yes]
  ./teardown.sh --subscription "<SUB_ID>[,<SUB_ID>...]" [options] [--execute] [--yes]

Scope (exactly one):
  -m, --management-group <id>  Every subscription under this MG (nested included),
                               plus Lucidity's MG-level assignments and MG-homed roles
  -s, --subscription <ids>     Only these subscriptions (comma- or space-separated)

What to remove (default: everything except LAT):
      --skip-access            Keep role assignments and custom roles
      --skip-legacy            Ignore v1 roles (lucidity-permissions-readonly-*)
      --skip-network           Keep the Lucidity Blob firewall rules
      --skip-storage           Keep inventory rules, containers and LAT
      --lat-accounts "<names>" Also turn off LAT on these storage accounts
      --lat-file <file>        ...or on the accounts listed in this file
                               (one name per line; blank lines and # comments ignored)
      --keep-app               Keep Lucidity's enterprise application (default with -s)
      --delete-app             Delete it (default with -m)

Other:
  -r, --role-name <name>       Role name used at onboarding (default: LUCIDITY_PLATFORM)
  -a, --app-id <app-id>        Lucidity application ID
      --legacy-prefix <prefix> v1 role-name prefix (default: lucidity-permissions-readonly)
      --execute                Apply the plan; otherwise make no changes
  -y, --yes                    Skip confirmation in execute mode
      --version                Show script version
  -h, --help                   Show help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
normalize() { tr ',' ' ' <<<"$1" | xargs; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--management-group) MG_ID="${2:-}"; shift 2 ;;
    -s|--subscription) SUB_INPUT="${2:-}"; shift 2 ;;
    -r|--role-name) ROLE_NAME="${2:-}"; shift 2 ;;
    -a|--app-id) APP_ID="${2:-}"; shift 2 ;;
    --legacy-prefix) LEGACY_PREFIX="${2:-}"; shift 2 ;;
    --lat-accounts) LAT_INPUT="${2:-}"; shift 2 ;;
    --lat-file) LAT_FILE="${2:-}"; shift 2 ;;
    --skip-access) SKIP_ACCESS="true"; shift ;;
    --skip-legacy) SKIP_LEGACY="true"; shift ;;
    --skip-network) SKIP_NETWORK="true"; shift ;;
    --skip-storage) SKIP_STORAGE="true"; shift ;;
    --keep-app)
      [[ "$APP_CHOICE" != "delete" ]] || die "Use only one of --keep-app / --delete-app."
      APP_CHOICE="keep"; shift ;;
    --delete-app)
      [[ "$APP_CHOICE" != "keep" ]] || die "Use only one of --keep-app / --delete-app."
      APP_CHOICE="delete"; shift ;;
    --execute) EXECUTE="true"; shift ;;
    -y|--yes) ASSUME_YES="true"; shift ;;
    --version) echo "teardown.sh ${SCRIPT_VERSION}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) ||
  die "bash 4.4+ is required (Azure Cloud Shell has it; macOS's /bin/bash 3.2 does not)."
if [[ -n "$MG_ID" && -n "$SUB_INPUT" ]] || [[ -z "$MG_ID" && -z "$SUB_INPUT" ]]; then
  usage; die "Provide exactly one of --management-group or --subscription."
fi
[[ -z "$LAT_FILE" || -f "$LAT_FILE" ]] || die "--lat-file not found: $LAT_FILE"
need az
need jq

# Deleting the SP removes Lucidity tenant-wide, so it is the default only when
# tearing down a whole management group.
if [[ -z "$APP_CHOICE" ]]; then
  [[ -n "$MG_ID" ]] && APP_CHOICE="delete" || APP_CHOICE="keep"
fi
[[ "$SKIP_LEGACY" == "true" ]] && LEGACY_PREFIX=""

# Storage accounts to turn LAT off on (names are lowercase in Azure).
declare -A LAT_WANTED=()
for NAME in $(normalize "$LAT_INPUT"); do LAT_WANTED["${NAME,,}"]=1; done
if [[ -n "$LAT_FILE" ]]; then
  while IFS= read -r LINE; do
    LINE="$(xargs <<<"${LINE%%#*}")"
    [[ -n "$LINE" ]] && LAT_WANTED["${LINE,,}"]=1
  done <"$LAT_FILE"
fi

# Run an az command, retrying transient failures; prints its stdout on success.
retry() {
  local attempt out
  for attempt in 1 2 3; do
    if out="$("$@" 2>/dev/null)"; then printf '%s' "$out"; return 0; fi
    sleep 5
  done
  return 1
}

# ---- Login check and scope resolution ----------------------------------------
az account show >/dev/null 2>&1 || die "Azure CLI is not logged in. Open Cloud Shell or run: az login"
TENANT_ID="$(az account show --query tenantId -o tsv --only-show-errors)"
SIGNED_IN_AS="$(az account show --query user.name -o tsv --only-show-errors)"

MG_SCOPE=""
if [[ -n "$MG_ID" ]]; then
  MG_SCOPE="/providers/Microsoft.Management/managementGroups/${MG_ID}"
  az account management-group show --name "$MG_ID" --only-show-errors >/dev/null ||
    die "Cannot read management group '$MG_ID'. Check the ID and your access."
  mapfile -t SUBSCRIPTIONS < <(
    az account management-group entities list --only-show-errors \
      --query "[?type=='/subscriptions' && contains(parentNameChain, '${MG_ID}')].name" -o tsv | sort -u
  )
  SELECTION_MODE="MANAGEMENT GROUP ($MG_ID)"
else
  read -ra SUBSCRIPTIONS <<<"$(normalize "$SUB_INPUT")"
  SELECTION_MODE="SUBSCRIPTIONS"
fi

# Every scope being torn down (lowercased). A custom role is deleted only if
# all of its assignable scopes are in this set.
declare -A TEARDOWN_SCOPES=()
[[ -n "$MG_SCOPE" ]] && TEARDOWN_SCOPES["${MG_SCOPE,,}"]=1
for SUB_ID in "${SUBSCRIPTIONS[@]}"; do TEARDOWN_SCOPES["/subscriptions/${SUB_ID,,}"]=1; done

# Lucidity's SP in this tenant, if it still exists.
SP_OBJECT_ID="$(az ad sp list --all --filter "appId eq '${APP_ID}'" --query '[0].id' -o tsv --only-show-errors 2>/dev/null || true)"

# ---- Discovery (read-only) ---------------------------------------------------
# Each list holds one entry per planned change; '|' separates fields.
ASSIGNMENTS=()      # id|role name|scope
ROLES_DELETE=()     # role GUID|scope to delete it at|role name
ROLES_KEPT=()       # description of a matching role that is kept
NETWORK_RULES=()    # sub|rg|account|ip present|subnet present
INVENTORY_RULES=()  # sub|rg|account|matching rule indices (comma-separated)|total rules
CONTAINERS=()       # sub|rg|account
LAT_TARGETS=()      # sub|rg|account
declare -A LAT_FOUND=()
DISCOVERY_FAILED=0

discovery_failed() { echo "   WARN: $*"; DISCOVERY_FAILED=$((DISCOVERY_FAILED + 1)); }

# Lucidity's assignments directly at $1 (MG), or anywhere in subscription $2.
collect_assignments() {
  local scope="$1" sub="$2" json
  if [[ -n "$sub" ]]; then
    json="$(retry az role assignment list --all --subscription "$sub" -o json --only-show-errors)" ||
      { discovery_failed "could not list role assignments in $sub"; return; }
  else
    json="$(retry az role assignment list --scope "$scope" -o json --only-show-errors)" ||
      { discovery_failed "could not list role assignments at $scope"; return; }
  fi
  mapfile -t -O "${#ASSIGNMENTS[@]}" ASSIGNMENTS < <(
    jq -r --arg sp "${SP_OBJECT_ID,,}" --arg scope "${scope,,}" '
      .[] | select((.principalId // "" | ascii_downcase) == $sp)
      | select($scope == "" or (.scope // "" | ascii_downcase) == $scope)
      | "\(.id)|\(.roleDefinitionName // "?")|\(.scope)"' <<<"$json"
  )
}

# Lucidity custom roles visible at $1: the v2 role by name and, unless
# --skip-legacy, v1 roles by prefix.
declare -A ROLE_SEEN=()
collect_roles() {
  local scope="$1" json rid rname scopes s outside first
  json="$(retry az role definition list --custom-role-only true --scope "$scope" -o json --only-show-errors)" ||
    { discovery_failed "could not list custom roles at $scope"; return; }
  while IFS=$'\t' read -r rid rname scopes; do
    [[ -n "$rid" && -z "${ROLE_SEEN[$rid]:-}" ]] || continue
    ROLE_SEEN[$rid]=1
    outside=""; first=""
    for s in $scopes; do
      [[ -n "$first" ]] || first="$s"
      [[ -n "${TEARDOWN_SCOPES[${s,,}]:-}" ]] || outside="$s"
    done
    if [[ -z "$outside" ]]; then
      ROLES_DELETE+=("$rid|$first|$rname")
    else
      ROLES_KEPT+=("$rname (still assignable at $outside)")
    fi
  done < <(jq -r --arg name "${ROLE_NAME,,}" --arg legacy "${LEGACY_PREFIX,,}" '
      .[] | select((.roleName | ascii_downcase) as $n
                   | $n == $name or ($legacy != "" and ($n | startswith($legacy))))
      | [.name, .roleName, (.assignableScopes | join(" "))] | @tsv' <<<"$json")
}

# Lucidity's footprint in each storage account of subscription $1.
collect_storage() {
  local sub="$1" json name rg ip subnet inv idx total exists lat
  json="$(retry az storage account list --subscription "$sub" -o json --only-show-errors)" ||
    { discovery_failed "could not list storage accounts in $sub"; return; }
  while IFS=$'\t' read -r name rg ip subnet; do
    [[ -n "$name" ]] || continue

    if [[ "$SKIP_NETWORK" != "true" && ( "$ip" == "true" || "$subnet" == "true" ) ]]; then
      NETWORK_RULES+=("$sub|$rg|$name|$ip|$subnet")
    fi
    [[ "$SKIP_STORAGE" == "true" ]] && continue

    # Lucidity's inventory rules: matched by name or by writing into
    # 'lucidity-inventory'. An account without a policy is skipped.
    if inv="$(az storage account blob-inventory-policy show --subscription "$sub" \
          --resource-group "$rg" --account-name "$name" -o json --only-show-errors 2>/dev/null)"; then
      # '|' rather than a tab: read would drop an empty leading tab-field.
      IFS='|' read -r idx total < <(jq -r --arg rule "$INVENTORY_RULE" --arg c "$CONTAINER" '
        (.policy.rules // []) as $r
        | ((.policy.destination // "") == $c) as $all
        | [ $r | to_entries[]
            | select($all or .value.name == $rule or (.value.destination // "") == $c) | .key ]
        | "\(map(tostring) | join(","))|\($r | length)"' <<<"$inv")
      [[ -n "$idx" ]] && INVENTORY_RULES+=("$sub|$rg|$name|$idx|$total")
    fi

    if exists="$(retry az storage container-rm exists --subscription "$sub" --resource-group "$rg" \
          --storage-account "$name" --name "$CONTAINER" --query exists -o tsv --only-show-errors)"; then
      [[ "$exists" == "true" ]] && CONTAINERS+=("$sub|$rg|$name")
    else
      discovery_failed "could not check for '$CONTAINER' in $name"
    fi

    if [[ -n "${LAT_WANTED[${name,,}]:-}" ]]; then
      LAT_FOUND["${name,,}"]=1
      if lat="$(retry az storage account blob-service-properties show --subscription "$sub" \
            --resource-group "$rg" --account-name "$name" \
            --query "lastAccessTimeTrackingPolicy.enable" -o tsv --only-show-errors)"; then
        [[ "$lat" == "true" ]] && LAT_TARGETS+=("$sub|$rg|$name")
      else
        discovery_failed "could not read LAT setting on $name"
      fi
    fi
  done < <(jq -r --arg ip "$LUCIDITY_BLOB_EGRESS_IP" --arg subnet "${LUCIDITY_BACKEND_SUBNET,,}" '
      .[] | [ .name, .resourceGroup,
              any(.networkRuleSet.ipRules[]?; (.ipAddressOrRange // .value // "") == $ip),
              any(.networkRuleSet.virtualNetworkRules[]?;
                  ((.virtualNetworkResourceId // .id // "") | ascii_downcase) == $subnet) ]
      | @tsv' <<<"$json")
}

echo ">> Discovering Lucidity resources in ${#SUBSCRIPTIONS[@]} subscription(s)..."
[[ -z "$MG_SCOPE" || "${#SUBSCRIPTIONS[@]}" -gt 0 ]] ||
  discovery_failed "no child subscriptions found under '$MG_ID' (check management-group Reader access)"
if [[ "$SKIP_ACCESS" != "true" ]]; then
  if [[ -n "$MG_SCOPE" ]]; then
    [[ -n "$SP_OBJECT_ID" ]] && collect_assignments "$MG_SCOPE" ""
    collect_roles "$MG_SCOPE"
  fi
fi
for SUB_ID in "${SUBSCRIPTIONS[@]}"; do
  echo "   subscription $SUB_ID"
  if [[ "$SKIP_ACCESS" != "true" ]]; then
    [[ -n "$SP_OBJECT_ID" ]] && collect_assignments "" "$SUB_ID"
    collect_roles "/subscriptions/$SUB_ID"
  fi
  if [[ "$SKIP_NETWORK" != "true" || "$SKIP_STORAGE" != "true" ]]; then
    collect_storage "$SUB_ID"
  fi
done

LAT_MISSING=()
for NAME in "${!LAT_WANTED[@]}"; do
  [[ -n "${LAT_FOUND[$NAME]:-}" ]] || LAT_MISSING+=("$NAME")
done

# ---- Plan --------------------------------------------------------------------
# Print a section's count and entries, showing the given '|'-separated fields.
show() {
  local label="$1" fields="$2"; shift 2
  echo "  $label: $#"
  local entry
  for entry in "$@"; do
    echo "     - $(awk -F'|' -v f="$fields" 'BEGIN{n=split(f,k,",")} {s=""; for(i=1;i<=n;i++) s=s (i>1?"  ":"") $k[i]; print s}' <<<"$entry")"
  done
}

DELETE_APP="false"
[[ "$APP_CHOICE" == "delete" && -n "$SP_OBJECT_ID" ]] && DELETE_APP="true"

echo "=============================================================="
echo "Lucidity Azure teardown plan"
echo "  Script version   : $SCRIPT_VERSION"
echo "  Tenant           : $TENANT_ID"
echo "  Signed in as     : $SIGNED_IN_AS"
echo "  Scope            : $SELECTION_MODE"
echo "  Subscriptions    : ${#SUBSCRIPTIONS[@]}"
echo "  Enterprise app   : $([[ -n "$SP_OBJECT_ID" ]] && echo "$SP_OBJECT_ID" || echo "not found in this tenant")"
echo "  Mode             : $([[ "$EXECUTE" == "true" ]] && echo EXECUTE || echo PLAN-ONLY)"
echo "--------------------------------------------------------------"
if [[ "$SKIP_ACCESS" == "true" ]]; then
  echo "  Role assignments / custom roles: skipped (--skip-access)"
else
  show "1. Role assignments to remove" "2,3" "${ASSIGNMENTS[@]}"
  show "2. Custom roles to delete" "3,2" "${ROLES_DELETE[@]}"
  for KEPT in "${ROLES_KEPT[@]}"; do echo "     (kept) $KEPT"; done
fi
if [[ "$SKIP_NETWORK" == "true" ]]; then
  echo "  Blob firewall rules: skipped (--skip-network)"
else
  show "3. Storage accounts with Lucidity firewall rules" "3,2,1" "${NETWORK_RULES[@]}"
fi
if [[ "$SKIP_STORAGE" == "true" ]]; then
  echo "  Inventory rules / containers / LAT: skipped (--skip-storage)"
else
  show "4. Accounts with Lucidity inventory rules" "3,2,1" "${INVENTORY_RULES[@]}"
  show "5. '$CONTAINER' containers to delete" "3,2,1" "${CONTAINERS[@]}"
  if [[ "${#LAT_WANTED[@]}" -eq 0 ]]; then
    echo "  6. LAT: not requested (use --lat-accounts / --lat-file)"
  else
    show "6. Accounts to turn LAT off on" "3,2,1" "${LAT_TARGETS[@]}"
    [[ "${#LAT_MISSING[@]}" -eq 0 ]] || echo "     (not found in scope: ${LAT_MISSING[*]})"
  fi
fi
if [[ -z "$SP_OBJECT_ID" ]]; then
  echo "  7. Enterprise application: not present"
elif [[ "$DELETE_APP" == "true" ]]; then
  echo "  7. Enterprise application: DELETE (removes Lucidity from the whole tenant,"
  echo "     including any other management group it was onboarded to)"
else
  echo "  7. Enterprise application: keep (pass --delete-app to remove it)"
fi
echo "=============================================================="
[[ "$DISCOVERY_FAILED" -eq 0 ]] ||
  echo "WARNING: $DISCOVERY_FAILED discovery step(s) failed (see WARN lines); the plan may be incomplete."

if [[ "$EXECUTE" != "true" ]]; then
  echo
  echo "No changes made. Review the plan, then rerun with --execute."
  [[ "$DISCOVERY_FAILED" -eq 0 ]] || exit 1
  exit 0
fi
if [[ "$ASSUME_YES" != "true" ]]; then
  echo "Container deletion is permanent unless container soft-delete is enabled on the account."
  read -r -p "Proceed with teardown? [y/N] " REPLY
  [[ "$REPLY" =~ ^([yY]|[yY][eE][sS])$ ]] || { echo "Aborted."; exit 0; }
fi

# ---- Execute -----------------------------------------------------------------
DONE=0; FAILED=0; ACCESS_FAILED=0
ok() { echo "   done: $*"; DONE=$((DONE + 1)); }
fail() { echo "   FAILED: $*"; FAILED=$((FAILED + 1)); }

echo ">> 1. Removing role assignments..."
for ENTRY in "${ASSIGNMENTS[@]}"; do
  IFS='|' read -r ID ROLE SCOPE <<<"$ENTRY"
  if az role assignment delete --ids "$ID" --only-show-errors >/dev/null; then
    ok "$ROLE @ $SCOPE"
  else
    fail "$ROLE @ $SCOPE"; ACCESS_FAILED=$((ACCESS_FAILED + 1))
  fi
done

# A role can only be deleted once nothing is assigned to it; retry to allow the
# assignment deletions above to replicate.
echo ">> 2. Deleting custom roles..."
for ENTRY in "${ROLES_DELETE[@]}"; do
  IFS='|' read -r RID SCOPE RNAME <<<"$ENTRY"
  DELETED="false"
  for ATTEMPT in 1 2 3 4; do
    if ERR="$(az role definition delete --name "$RID" --scope "$SCOPE" --only-show-errors 2>&1)"; then
      DELETED="true"; break
    fi
    sleep 10
  done
  if [[ "$DELETED" == "true" ]]; then
    ok "$RNAME"
  else
    fail "$RNAME: $(tr '\n' ' ' <<<"$ERR")"; ACCESS_FAILED=$((ACCESS_FAILED + 1))
  fi
done

echo ">> 3. Removing Lucidity Blob firewall rules..."
for ENTRY in "${NETWORK_RULES[@]}"; do
  IFS='|' read -r SUB RG ACCOUNT IP SUBNET <<<"$ENTRY"
  ACCOUNT_OK="true"
  if [[ "$IP" == "true" ]]; then
    az storage account network-rule remove --subscription "$SUB" --resource-group "$RG" \
      --account-name "$ACCOUNT" --ip-address "$LUCIDITY_BLOB_EGRESS_IP" --only-show-errors >/dev/null ||
      ACCOUNT_OK="false"
  fi
  if [[ "$SUBNET" == "true" ]]; then
    az storage account network-rule remove --subscription "$SUB" --resource-group "$RG" \
      --account-name "$ACCOUNT" --subnet "$LUCIDITY_BACKEND_SUBNET" --only-show-errors >/dev/null ||
      ACCOUNT_OK="false"
  fi
  [[ "$ACCOUNT_OK" == "true" ]] && ok "$ACCOUNT" || fail "$ACCOUNT"
done

# Remove matching rules from the highest index down so earlier indices stay
# valid. If every rule matches, delete the policy: Azure rejects an empty one.
echo ">> 4. Removing Lucidity blob inventory rules..."
for ENTRY in "${INVENTORY_RULES[@]}"; do
  IFS='|' read -r SUB RG ACCOUNT IDX TOTAL <<<"$ENTRY"
  IFS=',' read -ra INDICES <<<"$IDX"
  if [[ "${#INDICES[@]}" -eq "$TOTAL" ]]; then
    az storage account blob-inventory-policy delete --subscription "$SUB" --resource-group "$RG" \
      --account-name "$ACCOUNT" --yes --only-show-errors >/dev/null &&
      ok "$ACCOUNT (whole policy deleted)" || fail "$ACCOUNT"
  else
    ACCOUNT_OK="true"
    for INDEX in $(printf '%s\n' "${INDICES[@]}" | sort -rn); do
      az storage account blob-inventory-policy update --subscription "$SUB" --resource-group "$RG" \
        --account-name "$ACCOUNT" --remove policy.rules "$INDEX" --only-show-errors >/dev/null ||
        { ACCOUNT_OK="false"; break; }
    done
    [[ "$ACCOUNT_OK" == "true" ]] && ok "$ACCOUNT (${#INDICES[@]} rule(s) removed)" || fail "$ACCOUNT"
  fi
done

echo ">> 5. Deleting '$CONTAINER' containers..."
for ENTRY in "${CONTAINERS[@]}"; do
  IFS='|' read -r SUB RG ACCOUNT <<<"$ENTRY"
  az storage container-rm delete --subscription "$SUB" --resource-group "$RG" \
    --storage-account "$ACCOUNT" --name "$CONTAINER" --yes --only-show-errors >/dev/null &&
    ok "$ACCOUNT" || fail "$ACCOUNT"
done

echo ">> 6. Turning off Last Access Time tracking..."
for ENTRY in "${LAT_TARGETS[@]}"; do
  IFS='|' read -r SUB RG ACCOUNT <<<"$ENTRY"
  az storage account blob-service-properties update --subscription "$SUB" --resource-group "$RG" \
    --account-name "$ACCOUNT" --enable-last-access-tracking false --only-show-errors >/dev/null &&
    ok "$ACCOUNT" || fail "$ACCOUNT"
done

# Skipped if any access removal failed, to avoid leaving orphaned assignments.
echo ">> 7. Enterprise application..."
if [[ "$DELETE_APP" != "true" ]]; then
  echo "   kept"
elif [[ "$ACCESS_FAILED" -gt 0 ]]; then
  fail "not deleted: $ACCESS_FAILED role assignment/definition removal(s) failed; fix them and rerun"
elif az ad sp delete --id "$SP_OBJECT_ID" --only-show-errors >/dev/null; then
  ok "enterprise application $SP_OBJECT_ID deleted"
else
  fail "could not delete $SP_OBJECT_ID (needs Entra rights such as Cloud Application Administrator)"
fi

echo "=============================================================="
echo "Teardown summary"
echo "  Changes made        : $DONE"
echo "  Failed              : $FAILED"
echo "  Discovery failures  : $DISCOVERY_FAILED"
echo "=============================================================="
[[ "$FAILED" -eq 0 && "$DISCOVERY_FAILED" -eq 0 ]] || exit 1
