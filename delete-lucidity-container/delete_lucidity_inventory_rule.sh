#!/bin/bash

set -uo pipefail

# ---- Config -----------------------------------------------------------------
RULE_NAME="lucidity-blob-inventory-policy"
LOG_FILE="delete_lucidity_inventory_rule.log"
DRY_RUN="false"
ASSUME_YES="false"
SUB_INPUT=""

# ---- Long-opt translation ---------------------------------------------------
args=()
for a in "$@"; do
  case "$a" in
    --dry-run) args+=("-n") ;;
    --yes)     args+=("-y") ;;
    --help)    args+=("-h") ;;
    *)         args+=("$a") ;;
  esac
done
set -- "${args[@]}"

# ---- Arg parsing --------------------------------------------------------------
usage() {
  echo "Usage:"
  echo "  $0 [-s \"<subIds|all>\"] [-l <logfile>] [-n] [-y]"
  echo ""
  echo "  -s  subscription id(s), comma/space-separated, or \"all\" for every"
  echo "      subscription the caller can see (default: all)"
  echo "  -l  log file path (default: ${LOG_FILE})"
  echo "  -n, --dry-run   list what would be removed; changes nothing"
  echo "  -y, --yes       skip the confirmation prompt (for unattended/CI runs)"
  echo "  -h, --help      show this help"
  echo ""
  echo "  Removes only the rule named '${RULE_NAME}' from each account's blob"
  echo "  inventory policy (via 'blob-inventory-policy update --remove"
  echo "  policy.rules <index>'). Every other rule, the policy's enabled flag,"
  echo "  and its destination are left untouched."
  echo ""
  echo "  Exception: if '${RULE_NAME}' is the ONLY rule in an account's policy,"
  echo "  removing it would leave an empty rules list, which Azure's API"
  echo "  rejects — so for those accounts the script deletes the whole"
  echo "  inventory policy resource instead (there'd be nothing left in it"
  echo "  anyway)."
  exit 1
}
while getopts ":s:l:nyh" opt; do
  case "$opt" in
    s) SUB_INPUT="$OPTARG" ;;
    l) LOG_FILE="$OPTARG" ;;
    n) DRY_RUN="true" ;;
    y) ASSUME_YES="true" ;;
    h) usage ;;
    *) usage ;;
  esac
done

[ -z "$SUB_INPUT" ] && SUB_INPUT="all"   # no scope given -> every subscription the caller can see

normalize() { echo "$1" | tr ',' ' ' | xargs; }

# ---- Logging ------------------------------------------------------------
now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() {
  local msg
  msg="[$(now)] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}
log_error() {
  local msg
  msg="[$(now)] ERROR: $*"
  echo "$msg" >&2
  echo "$msg" >> "$LOG_FILE"
}

# ---- Prerequisites: Azure CLI + login --------------------------------------
ensure_az_cli() {
  if command -v az >/dev/null 2>&1; then
    log "Azure CLI already installed ($(az version --query '\"azure-cli\"' -o tsv 2>/dev/null || echo present))."
    return 0
  fi
  log_error "Azure CLI not found. Install it: https://learn.microsoft.com/cli/azure/install-azure-cli"
  exit 1
}

ensure_login() {
  if az account show >/dev/null 2>&1; then
    return 0
  fi
  if [[ -n "${AZ_SP_APP_ID:-}" && -n "${AZ_SP_PASSWORD:-}" && -n "${AZ_SP_TENANT:-}" ]]; then
    log "Not logged in — authenticating with the service principal from the environment."
    az login --service-principal -u "$AZ_SP_APP_ID" -p "$AZ_SP_PASSWORD" --tenant "$AZ_SP_TENANT" -o none \
      || { log_error "Service-principal login failed."; exit 1; }
  else
    log "Not logged in — attempting 'az login'..."
    az login --only-show-errors >/dev/null \
      || { log_error "az login failed. Log in manually (or set AZ_SP_APP_ID / AZ_SP_PASSWORD / AZ_SP_TENANT for unattended runs) and re-run."; exit 1; }
  fi
}

# ---- Scope resolution -----------------------------------------------------
resolve_subscriptions() {
  if [ "$(normalize "$SUB_INPUT")" = "all" ]; then
    az account list --query "[].id" -o tsv --only-show-errors 2>/dev/null
    return 0
  fi
  normalize "$SUB_INPUT" | tr ' ' '\n'
}

# ---- Discovery ------------------------------------------------------------
# Parallel indexed arrays (kept bash-3.2-compatible on purpose, so this runs
# with macOS's default /bin/bash without any version gate).
F_SUB=(); F_RG=(); F_ACCT=(); F_IDX=(); F_TOTAL=()

SUB_COUNT=0
SUB_SKIPPED=0
ACCTS_SCANNED=0

discover() {
  local sub listing name rg
  while IFS= read -r sub; do
    [ -z "$sub" ] && continue
    SUB_COUNT=$((SUB_COUNT + 1))
    log "Scanning subscription $sub for a '$RULE_NAME' blob inventory policy rule..."

    if ! listing=$(az storage account list --subscription "$sub" \
           --query "[].[name,resourceGroup]" -o tsv --only-show-errors 2>>"$LOG_FILE"); then
      log_error "Could not list storage accounts in subscription $sub — no access, or the call failed. Skipping it. See $LOG_FILE."
      SUB_SKIPPED=$((SUB_SKIPPED + 1))
      continue
    fi
    [ -z "$listing" ] && continue

    while IFS=$'\t' read -r name rg; do
      [ -z "$name" ] && continue
      ACCTS_SCANNED=$((ACCTS_SCANNED + 1))

      local rule_names idx i n total
      rule_names=$(az storage account blob-inventory-policy show --account-name "$name" --resource-group "$rg" \
                     --subscription "$sub" --query "policy.rules[].name" -o tsv --only-show-errors 2>>"$LOG_FILE") \
        || continue   # no inventory policy on this account — normal, nothing to do
      [ -z "$rule_names" ] && continue

      idx=-1; i=0; total=0
      while IFS= read -r n; do
        [ -z "$n" ] && continue
        if [ "$n" = "$RULE_NAME" ]; then idx=$i; fi
        i=$((i + 1))
        total=$((total + 1))
      done <<< "$rule_names"

      if [ "$idx" -ge 0 ]; then
        F_SUB+=("$sub"); F_RG+=("$rg"); F_ACCT+=("$name"); F_IDX+=("$idx"); F_TOTAL+=("$total")
        log "  found: $name (rg=$rg, sub=$sub) — rule at index $idx (of $total total rule(s))"
      fi
    done <<< "$listing"
  done < <(resolve_subscriptions)
}

# ---- Confirm + delete -------------------------------------------------------
confirm_delete() {
  $DRY_RUN && return 0
  local n="${#F_SUB[@]}"
  (( n == 0 )) && return 0
  $ASSUME_YES && return 0

  echo ""
  echo "The following $n rule(s) named '$RULE_NAME' will be PERMANENTLY REMOVED. Accounts where"
  echo "it is the only rule will have their whole inventory policy deleted instead (an empty"
  echo "rules list isn't valid); everywhere else, only this one rule is removed — no other rule"
  echo "or policy setting is touched:"
  local i action
  for ((i=0; i<n; i++)); do
    if [ "${F_TOTAL[$i]}" -eq 1 ]; then action="DELETE WHOLE POLICY (sole rule)"; else action="remove rule (index ${F_IDX[$i]} of ${F_TOTAL[$i]})"; fi
    printf "  %-32s rg=%-24s sub=%-38s %s\n" "${F_ACCT[$i]}" "${F_RG[$i]}" "${F_SUB[$i]}" "$action"
  done
  echo ""
  echo "Re-run with --dry-run to preview only, or --yes to skip this prompt."
  local reply
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] || { log "Aborted by user at confirmation prompt — no changes made."; exit 0; }
}

DELETED=0
FAILED=0
POLICY_DELETES=0
RULE_REMOVALS=0

delete_found() {
  local n="${#F_SUB[@]}" i sub rg acct idx total
  for ((i=0; i<n; i++)); do
    sub="${F_SUB[$i]}"; rg="${F_RG[$i]}"; acct="${F_ACCT[$i]}"; idx="${F_IDX[$i]}"; total="${F_TOTAL[$i]}"

    if [ "$total" -eq 1 ]; then
      # Sole rule — removing it would leave an empty rules[] which the API rejects,
      # so delete the whole (now-pointless) inventory policy resource instead.
      if $DRY_RUN; then
        log "[dry-run] would DELETE the whole blob inventory policy on $acct (rg=$rg, sub=$sub) — '$RULE_NAME' is its only rule"
        continue
      fi
      log "Deleting the whole blob inventory policy on $acct (rg=$rg, sub=$sub) — '$RULE_NAME' is its only rule..."
      if az storage account blob-inventory-policy delete --account-name "$acct" --resource-group "$rg" --subscription "$sub" \
           --yes --only-show-errors -o none 2>>"$LOG_FILE"; then
        log "  -> policy deleted OK"
        DELETED=$((DELETED + 1)); POLICY_DELETES=$((POLICY_DELETES + 1))
      else
        log_error "  -> policy delete FAILED for $acct (rg=$rg, sub=$sub) — details in $LOG_FILE (often a missing '.../storageAccounts/inventoryPolicies/delete' RBAC action, or a resource lock)"
        FAILED=$((FAILED + 1))
      fi
    else
      if $DRY_RUN; then
        log "[dry-run] would remove rule '$RULE_NAME' (index $idx of $total) from $acct's blob inventory policy (rg=$rg, sub=$sub)"
        continue
      fi
      log "Removing rule '$RULE_NAME' (index $idx of $total) from $acct's blob inventory policy (rg=$rg, sub=$sub)..."
      if az storage account blob-inventory-policy update --account-name "$acct" --resource-group "$rg" --subscription "$sub" \
           --remove policy.rules "$idx" --only-show-errors -o none 2>>"$LOG_FILE"; then
        log "  -> removed OK"
        DELETED=$((DELETED + 1)); RULE_REMOVALS=$((RULE_REMOVALS + 1))
      else
        log_error "  -> removal FAILED for $acct (rg=$rg, sub=$sub) — details in $LOG_FILE (often a missing '.../storageAccounts/inventoryPolicies/write' RBAC action, or a resource lock)"
        FAILED=$((FAILED + 1))
      fi
    fi
  done
}

print_summary() {
  local found="${#F_SUB[@]}"
  echo ""
  echo "==============================================================" | tee -a "$LOG_FILE"
  echo " Run summary" | tee -a "$LOG_FILE"
  echo "   Rule targeted            : $RULE_NAME" | tee -a "$LOG_FILE"
  echo "   Subscription(s) scanned  : $SUB_COUNT" | tee -a "$LOG_FILE"
  (( SUB_SKIPPED > 0 )) && echo "   Subscriptions skipped (no access) : $SUB_SKIPPED" | tee -a "$LOG_FILE"
  echo "   Storage accounts scanned : $ACCTS_SCANNED" | tee -a "$LOG_FILE"
  echo "   Rules to delete found    : $found" | tee -a "$LOG_FILE"
  if $DRY_RUN; then
    echo "   Mode                     : dry-run — nothing changed" | tee -a "$LOG_FILE"
  else
    echo "   Rules removed (policy kept)   : $RULE_REMOVALS" | tee -a "$LOG_FILE"
    echo "   Whole policies deleted (sole rule) : $POLICY_DELETES" | tee -a "$LOG_FILE"
    echo "   Total processed          : $DELETED" | tee -a "$LOG_FILE"
    echo "   Failed                   : $FAILED" | tee -a "$LOG_FILE"
  fi
  echo "   Log file                 : $LOG_FILE" | tee -a "$LOG_FILE"
  echo "==============================================================" | tee -a "$LOG_FILE"
  (( FAILED > 0 )) && echo "Some removals failed. Check $LOG_FILE, fix access/locks, then re-run — rules already removed are simply not found again."
}

# ---- Main ---------------------------------------------------------------
main() {
  trap print_summary EXIT

  ensure_az_cli
  ensure_login
  discover

  if (( ${#F_SUB[@]} == 0 )); then
    log "No '$RULE_NAME' rule found in scope. Nothing to do."
    exit 0
  fi

  confirm_delete
  delete_found

  (( FAILED > 0 )) && exit 1
  exit 0
}

main
