#!/usr/bin/env bash

if ((BASH_VERSINFO[0] < 4)); then
  echo "gpv2_migrate.sh needs bash 4+ (uses associative arrays); you're running ${BASH_VERSION}." >&2
  echo "macOS ships bash 3.2 as /bin/bash. Install a newer one and run with its full path, e.g.:" >&2
  echo "  brew install bash && /opt/homebrew/bin/bash gpv2_migrate.sh ..." >&2
  exit 1
fi

set -uo pipefail
# Deliberately NOT using `set -e`: one account failing to upgrade must not
# kill the whole batch. Every command that can fail is checked explicitly.

# --------------------------------------------------------------------------- #
# Defaults / options
# --------------------------------------------------------------------------- #

SUBSCRIPTIONS="all"
DEFAULT_TIER="Hot"          # account-level access tier only takes Hot or Cool
STATE_FILE="gpv2_migration_state.csv"
LOG_FILE="gpv2_migration.log"
RG_FILTER=""
DRY_RUN=false
SKIP_CONFIRM=false

usage() {
  cat <<'EOF'
gpv2_migrate.sh — upgrade GPv1 / legacy Blob Storage accounts to GPv2.

Options:
  --subscriptions <ids|all>   Comma-separated subscription IDs, or "all" (default: all)
  --tier <Hot|Cool>           Default access tier for the upgrade (default: Hot)
  --rg-filter <regex>         Only act on resource groups matching this regex
  --state-file <path>         State file location (default: gpv2_migration_state.csv)
  --log-file <path>           Log file location (default: gpv2_migration.log)
  --dry-run                   List and classify only — never call `az ... update`
  -y, --yes                   Skip the confirmation prompt (for unattended/CI runs)
  -h, --help                  Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscriptions) SUBSCRIPTIONS="${2:?--subscriptions needs a value}"; shift 2 ;;
    --tier)          DEFAULT_TIER="${2:?--tier needs a value}"; shift 2 ;;
    --rg-filter)     RG_FILTER="${2:?--rg-filter needs a value}"; shift 2 ;;
    --state-file)    STATE_FILE="${2:?--state-file needs a value}"; shift 2 ;;
    --log-file)      LOG_FILE="${2:?--log-file needs a value}"; shift 2 ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -y|--yes)        SKIP_CONFIRM=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

case "$DEFAULT_TIER" in
  Hot|Cool) ;;
  *) echo "--tier must be Hot or Cool (an account's DEFAULT tier can't be Cold/Archive — those are per-blob)." >&2; exit 1 ;;
esac

SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

# --------------------------------------------------------------------------- #
# State, keyed by Azure resource ID. Plain bash associative arrays + a TSV
# file on disk — no JSON library needed, which is the whole point of doing
# this in bash rather than Python.
# --------------------------------------------------------------------------- #

declare -a ORDER=()
declare -A NAME=() RG=() SUB=() KIND_ORIG=() SKU=() TIER=()
declare -A STATUS=() ATTEMPTS=() ERRMSG=() TS=()

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

# Loading the current state of the csv

load_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  local first=1
  local id name rg sub kind sku tier status attempts err ts
  while IFS=',' read -r name rg sub kind sku tier status attempts err ts; do
    if (( first )); then first=0; continue; fi   # skip header row
    [[ -z "$name" ]] && continue
    # Not stored in the CSV (redundant with name/rg/sub) — rebuilt here since
    # it's still needed as the associative-array key and for `az ... --ids`.
    id="/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$name"
    ORDER+=("$id")
    NAME[$id]="$name"; RG[$id]="$rg"; SUB[$id]="$sub"; KIND_ORIG[$id]="$kind"; SKU[$id]="$sku"
    TIER[$id]="$tier"; STATUS[$id]="$status"; ATTEMPTS[$id]="$attempts"; ERRMSG[$id]="$err"; TS[$id]="$ts"
  done < "$STATE_FILE"
  log "Loaded existing state: ${#ORDER[@]} account(s) previously tracked in $STATE_FILE."
}

save_state() {
  # Atomic: write to a temp file in the same directory, then rename over the
  # real one. A crash mid-write leaves the OLD state file intact — never a
  # half-written one. This is called after every single account transition.
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  {
    printf 'name,resource_group,subscription_id,kind_original,sku,target_tier,status,attempts,last_error,updated_at\n'
    local id err_clean
    for id in "${ORDER[@]}"; do
      # Strip anything that could be mistaken for the delimiter or break a line.
      err_clean="${ERRMSG[$id]//$'\n'/ }"
      err_clean="${err_clean//,/ }"
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "${NAME[$id]}" "${RG[$id]}" "${SUB[$id]}" "${KIND_ORIG[$id]}" "${SKU[$id]}" \
        "${TIER[$id]:-}" "${STATUS[$id]}" "${ATTEMPTS[$id]:-0}" \
        "$err_clean" "${TS[$id]:-}"
    done
  } > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

# --------------------------------------------------------------------------- #
# Prerequisite installers — run before anything else touches Azure.
# --------------------------------------------------------------------------- #

ensure_az_cli() {
  if command -v az >/dev/null 2>&1; then
    log "Azure CLI already installed ($(az version --query '\"azure-cli\"' -o tsv 2>/dev/null || echo present))."
    return 0
  fi
  log "Azure CLI not found — installing it now."
  if command -v apt-get >/dev/null 2>&1; then
    curl -sL https://aka.ms/InstallAzureCLIDeb | $SUDO bash
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO rpm --import https://packages.microsoft.com/keys/microsoft.asc
    $SUDO dnf install -y https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm
    $SUDO dnf install -y azure-cli
  elif command -v yum >/dev/null 2>&1; then
    $SUDO rpm --import https://packages.microsoft.com/keys/microsoft.asc
    printf '[azure-cli]\nname=Azure CLI\nbaseurl=https://packages.microsoft.com/yumrepos/azure-cli\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n' \
      | $SUDO tee /etc/yum.repos.d/azure-cli.repo >/dev/null
    $SUDO yum install -y azure-cli
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO rpm --import https://packages.microsoft.com/keys/microsoft.asc
    $SUDO zypper --non-interactive addrepo --name 'Azure CLI' --check https://packages.microsoft.com/yumrepos/azure-cli azure-cli
    $SUDO zypper --non-interactive install azure-cli
  elif command -v brew >/dev/null 2>&1; then
    brew update && brew install azure-cli
  else
    log_error "No supported package manager found (apt/dnf/yum/zypper/brew). Install manually: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
  fi
  if ! command -v az >/dev/null 2>&1; then
    log_error "Azure CLI install did not succeed."
    exit 1
  fi
  log "Azure CLI installed: $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null)"
}

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  log "jq not found — installing it (used to parse Azure CLI's JSON output safely)."
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -y && $SUDO apt-get install -y jq
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y jq
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y jq
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper --non-interactive install jq
  elif command -v brew >/dev/null 2>&1; then
    brew install jq
  else
    log_error "No supported package manager found to install jq. Install manually and re-run."
    exit 1
  fi
  command -v jq >/dev/null 2>&1 || { log_error "jq install did not succeed."; exit 1; }
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
    log_error "Not logged in to Azure CLI. Run 'az login' first (or set AZ_SP_APP_ID / AZ_SP_PASSWORD / AZ_SP_TENANT for unattended runs)."
    exit 1
  fi
}

resolve_subscriptions() {
  if [[ "$SUBSCRIPTIONS" == "all" ]]; then
    az account list --query "[].id" -o tsv
  else
    tr ',' '\n' <<< "$SUBSCRIPTIONS"
  fi
}

# --------------------------------------------------------------------------- #
# Discovery + classification — merges into the in-memory state. An account
# already tracked as "upgraded" or "skipped" is left alone. One already
# tracked as "failed" is reset to "pending" so it's retried automatically —
# no special flag needed, which is the whole point of listing fresh each run.
# --------------------------------------------------------------------------- #

upsert_account() {
  local id="$1" name="$2" rg="$3" sub="$4" kind="$5" sku="$6" tier="$7"

  if [[ -n "${STATUS[$id]:-}" ]]; then
    if [[ "${STATUS[$id]}" == "failed" ]]; then
      STATUS[$id]="pending"
      log "Re-queuing previously-failed account for retry: ${NAME[$id]} (${RG[$id]})"
    fi
    return 0
  fi

  ORDER+=("$id")
  NAME[$id]="$name"; RG[$id]="$rg"; SUB[$id]="$sub"; KIND_ORIG[$id]="$kind"; SKU[$id]="$sku"
  ATTEMPTS[$id]=0; ERRMSG[$id]=""; TS[$id]="$(now)"

  if [[ "$rg" =~ [Dd]atabricks ]] || [[ "$name" =~ ^dbstorage ]]; then
    STATUS[$id]="skipped"
    ERRMSG[$id]="Databricks-managed — Microsoft auto-migrates this account, not touched here."
    TIER[$id]=""
  elif [[ "$kind" == "Storage" && "$sku" =~ ZRS ]]; then
    STATUS[$id]="skipped"
    ERRMSG[$id]="GPv1 on standard ZRS — redundancy-conversion path is restricted; needs manual review, not automated here."
    TIER[$id]=""
  else
    STATUS[$id]="pending"
    if [[ -n "$tier" && "$tier" != "None" && "$tier" != "null" ]]; then
      TIER[$id]="$tier"     # legacy Blob Storage account already had a tier — keep it
    else
      TIER[$id]="$DEFAULT_TIER"
    fi
  fi
}

discover() {
  local sub id name rg kind sku tier listing
  while IFS= read -r sub; do
    [[ -z "$sub" ]] && continue
    log "Scanning subscription $sub for GPv1 / legacy Blob Storage accounts..."

    if ! listing=$(az storage account list --subscription "$sub" \
                     --query "[?kind=='Storage' || kind=='BlobStorage'].{id:id,name:name,rg:resourceGroup,kind:kind,sku:sku.name,tier:accessTier}" \
                     -o tsv 2>>"$LOG_FILE"); then
      log_error "Could not list storage accounts in subscription $sub — no access, or the call failed. Skipping it. See $LOG_FILE for the underlying Azure CLI error."
      continue
    fi

    # Azure CLI's -o tsv is tab-delimited, and a GPv1 (kind=Storage) account
    # always has a NULL access tier — a real, common empty field. `read`
    # collapses consecutive tabs regardless of IFS, which would silently
    # shift every column after it. Re-delimiting to "," first avoids that;
    # none of these fields (resource ID, name, RG, kind, SKU, tier) can
    # legally contain a comma under Azure's own naming rules.
    while IFS=',' read -r id name rg kind sku tier; do
      [[ -z "$id" ]] && continue
      if [[ -n "$RG_FILTER" ]] && ! [[ "$rg" =~ $RG_FILTER ]]; then
        continue
      fi
      upsert_account "$id" "$name" "$rg" "$sub" "$kind" "$sku" "$tier"
    done < <(tr '\t' ',' <<< "$listing")
  done < <(resolve_subscriptions)
  save_state
}

# --------------------------------------------------------------------------- #
# Upgrade — one account at a time, state saved after every single one.
# --------------------------------------------------------------------------- #

upgrade_pending() {
  local id name rg sub tier result
  for id in "${ORDER[@]}"; do
    [[ "${STATUS[$id]:-}" == "pending" ]] || continue
    name="${NAME[$id]}"; rg="${RG[$id]}"; sub="${SUB[$id]}"; tier="${TIER[$id]}"

    if $DRY_RUN; then
      log "[dry-run] would upgrade $name (rg=$rg, sub=$sub) -> StorageV2, tier=$tier"
      continue
    fi

    log "Upgrading $name (rg=$rg) -> StorageV2, tier=$tier ..."
    if result=$(az storage account update --ids "$id" --set kind=StorageV2 --access-tier "$tier" \
                  --query kind -o tsv 2>>"$LOG_FILE"); then
      if [[ "$result" == "StorageV2" ]]; then
        STATUS[$id]="upgraded"; ERRMSG[$id]=""; TS[$id]="$(now)"
        log "  -> upgraded OK ($name)"
      else
        STATUS[$id]="failed"
        ATTEMPTS[$id]=$(( ${ATTEMPTS[$id]:-0} + 1 ))
        ERRMSG[$id]="update call succeeded but returned kind=$result, expected StorageV2"
        log_error "  -> unexpected result for $name: kind=$result"
      fi
    else
      ATTEMPTS[$id]=$(( ${ATTEMPTS[$id]:-0} + 1 ))
      STATUS[$id]="failed"
      ERRMSG[$id]="az storage account update failed — see $LOG_FILE"
      log_error "  -> upgrade FAILED for $name (attempt ${ATTEMPTS[$id]}) — details in $LOG_FILE"
    fi
    save_state
  done
}

# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #

count_by_status() {
  local target="$1" id count=0
  for id in "${ORDER[@]:-}"; do
    [[ "${STATUS[$id]:-}" == "$target" ]] && ((count++))
  done
  echo "$count"
}

confirm_upgrade() {
  $DRY_RUN && return 0
  $SKIP_CONFIRM && return 0
  local pending id reply
  pending=$(count_by_status pending)
  (( pending == 0 )) && return 0

  echo ""
  echo "The following $pending account(s) will be upgraded to GPv2 — this is IRREVERSIBLE:"
  for id in "${ORDER[@]}"; do
    [[ "${STATUS[$id]:-}" == "pending" ]] || continue
    printf "  %-32s rg=%-24s sub=%s tier=%s\n" "${NAME[$id]}" "${RG[$id]}" "${SUB[$id]}" "${TIER[$id]}"
  done
  echo ""
  echo "Re-run with --dry-run to preview only, or --yes to skip this prompt."
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] || { log "Aborted by user at confirmation prompt — no changes made."; exit 0; }
}

print_summary() {
  local upgraded failed skipped pending total
  upgraded=$(count_by_status upgraded)
  failed=$(count_by_status failed)
  skipped=$(count_by_status skipped)
  pending=$(count_by_status pending)
  total=${#ORDER[@]}
  {
    echo "---- Run summary ($total account(s) tracked) ----"
    echo "  Upgraded            : $upgraded"
    echo "  Failed (auto-retried next run): $failed"
    echo "  Skipped (excluded)  : $skipped"
    echo "  Still pending       : $pending"
    echo "  State file: $STATE_FILE"
    echo "  Log file  : $LOG_FILE"
  } | tee -a "$LOG_FILE"
  if (( failed > 0 )); then
    echo "Some accounts failed. Check $LOG_FILE for details, then just run this exact same command again to retry them." | tee -a "$LOG_FILE"
  fi
}

print_final_report() {
  echo ""
  echo "==== MIGRATION COMPLETE — nothing left on GPv1 / legacy Blob Storage in scope ===="
  printf "%-32s %-24s %-14s %-12s %-8s\n" "NAME" "RESOURCE GROUP" "ORIGINAL KIND" "NOW" "TIER"
  local id live_kind
  for id in "${ORDER[@]}"; do
    [[ "${STATUS[$id]}" == "upgraded" || "${STATUS[$id]}" == "skipped" ]] || continue
    if [[ "${STATUS[$id]}" == "skipped" ]]; then
      live_kind="(skipped)"
    else
      live_kind=$(az storage account show --ids "$id" --query kind -o tsv 2>/dev/null || echo "?")
    fi
    printf "%-32s %-24s %-14s %-12s %-8s\n" \
      "${NAME[$id]}" "${RG[$id]}" "${KIND_ORIG[$id]}" "$live_kind" "${TIER[$id]:-N/A}"
  done
  echo "===================================================================================="
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

main() {
  : > /dev/null  # no-op, keeps shellcheck quiet about an empty function body on some versions
  trap print_summary EXIT

  ensure_az_cli
  ensure_jq
  ensure_login

  load_state
  discover
  confirm_upgrade
  upgrade_pending

  local pending failed
  pending=$(count_by_status pending)
  failed=$(count_by_status failed)
  if ! $DRY_RUN && (( pending == 0 && failed == 0 )); then
    print_final_report
  fi
}

main "$@"
