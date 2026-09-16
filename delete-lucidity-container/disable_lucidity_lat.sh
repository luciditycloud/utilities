#!/bin/bash

set -uo pipefail

# Disables last-access-time (LAT) tracking (lastAccessTimeTrackingPolicy) on
# one or more storage accounts, whatever subscription each one lives in.
# No account/subscription mapping is hardcoded: every account name is
# resolved to its subscription + resource group with a single Azure Resource
# Graph query across every subscription the caller can see, so you only ever
# need to know the account name.

# ---- Config -----------------------------------------------------------------
LOG_FILE="disable_lucidity_lat.log"
DRY_RUN="false"
ASSUME_YES="false"
LIST_FILE=""

SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

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

# ---- Arg parsing -------------------------------------------------------------
usage() {
  echo "Usage:"
  echo "  $0 <account> [account2 ...]   # disable LAT on these storage accounts"
  echo "  $0 -f <file>                  # ...or read account names from a file (one per line)"
  echo ""
  echo "  The subscription each account lives in is discovered automatically"
  echo "  (via Azure Resource Graph) — you only need to know the account name."
  echo ""
  echo "  -f <file>       read storage account names from this file instead of"
  echo "                  positional arguments (one name per line, blank lines"
  echo "                  and '#' comments ignored). Ignored if account names"
  echo "                  are also given as arguments."
  echo "  -l <path>       log file path (default: ${LOG_FILE})"
  echo "  -n, --dry-run   show current state and what would change; nothing is disabled"
  echo "  -y, --yes       skip the confirmation prompt (for unattended/CI runs)"
  echo "  -h, --help      show this help"
  exit 1
}

while getopts ":f:l:nyh" opt; do
  case "$opt" in
    f) LIST_FILE="$OPTARG" ;;
    l) LOG_FILE="$OPTARG" ;;
    n) DRY_RUN="true" ;;
    y) ASSUME_YES="true" ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

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

# ---- Account list: positional args take priority over -f --------------------
RAW_ACCOUNTS=()
if (( $# > 0 )); then
  [ -n "$LIST_FILE" ] && log "Note: account names were also given as arguments — ignoring -f '$LIST_FILE'."
  RAW_ACCOUNTS=("$@")
elif [ -n "$LIST_FILE" ]; then
  [ -f "$LIST_FILE" ] || { log_error "-f file not found: $LIST_FILE"; exit 1; }
  while IFS= read -r line; do
    line="$(echo "$line" | xargs)"   # trim whitespace
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    RAW_ACCOUNTS+=("$line")
  done < "$LIST_FILE"
else
  echo "ERROR: provide at least one storage account name, or -f <file>." >&2
  usage
fi

# Validate against Azure storage account naming rules (3-24 lowercase
# alphanumeric) and de-dupe. This also guarantees every name is safe to embed
# in the Resource Graph query string built below.
declare -a ACCOUNTS=()
declare -a SEEN=()
for acct in "${RAW_ACCOUNTS[@]}"; do
  if ! [[ "$acct" =~ ^[a-z0-9]{3,24}$ ]]; then
    log_error "Skipping '$acct' — not a valid storage account name (3-24 lowercase letters/digits)."
    continue
  fi
  dup="false"
  for s in "${SEEN[@]:-}"; do [ "$s" = "$acct" ] && dup="true" && break; done
  [ "$dup" = "true" ] && continue
  SEEN+=("$acct")
  ACCOUNTS+=("$acct")
done

if (( ${#ACCOUNTS[@]} == 0 )); then
  log_error "No valid storage account names to process."
  exit 1
fi

# ---- Prerequisites: Azure CLI + resource-graph extension + login -----------
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

ensure_graph_extension() {
  if az extension show --name resource-graph >/dev/null 2>&1; then
    return 0
  fi
  log "Azure CLI 'resource-graph' extension not found — installing it (used to resolve each account's subscription in one query)."
  az extension add --name resource-graph -y --only-show-errors 2>>"$LOG_FILE" \
    || { log_error "Failed to install the 'resource-graph' extension."; exit 1; }
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

# ---- Subscription id -> display name lookup ---------------------------------
SUB_ID_TSV=""
sub_name_for_id() {  # $1=subscriptionId
  local id="$1" line
  line=$(printf '%s\n' "$SUB_ID_TSV" | awk -F'\t' -v id="$id" '$1==id{print $2; exit}')
  [ -n "$line" ] && echo "$line" || echo "$id"
}

# ---- Resolve accounts -> subscription/resource group via Resource Graph ----
# One batched query for every requested account, across every subscription
# the caller can see — no per-subscription looping needed.
F_ACCT=(); F_SUBID=(); F_SUBNAME=(); F_RG=()
ALREADY=(); NOTFOUND=()

resolve_accounts() {
  local names_quoted acct graph_out line name subid rg

  SUB_ID_TSV="$(az account list --query "[].[id,name]" -o tsv --only-show-errors 2>>"$LOG_FILE")"

  names_quoted=""
  for acct in "${ACCOUNTS[@]}"; do
    names_quoted+="'${acct}',"
  done
  names_quoted="${names_quoted%,}"

  graph_out=$(az graph query \
    -q "Resources | where type =~ 'microsoft.storage/storageaccounts' | where name in~ ($names_quoted) | project name, subscriptionId, resourceGroup" \
    --first 1000 --query "data[].[name,subscriptionId,resourceGroup]" -o tsv --only-show-errors 2>>"$LOG_FILE") \
    || { log_error "Resource Graph query failed — see $LOG_FILE."; exit 1; }

  declare -a RESOLVED=()
  while IFS=$'\t' read -r name subid rg; do
    [ -z "$name" ] && continue
    RESOLVED+=("$name")
    F_ACCT+=("$name"); F_SUBID+=("$subid"); F_SUBNAME+=("$(sub_name_for_id "$subid")"); F_RG+=("$rg")
  done <<< "$graph_out"

  for acct in "${ACCOUNTS[@]}"; do
    local found="false" r
    for r in "${RESOLVED[@]:-}"; do [ "$r" = "$acct" ] && found="true" && break; done
    if [ "$found" = "false" ]; then
      log_error "'$acct' not found in any subscription visible to the logged-in identity — skipping."
      NOTFOUND+=("$acct")
    fi
  done
}

# ---- Check current LAT state, split into already-disabled vs pending -------
PEND_ACCT=(); PEND_SUBID=(); PEND_SUBNAME=(); PEND_RG=()

check_current_state() {
  local n="${#F_ACCT[@]}" i acct subid rg current
  for ((i=0; i<n; i++)); do
    acct="${F_ACCT[$i]}"; subid="${F_SUBID[$i]}"; rg="${F_RG[$i]}"

    current=$(az storage account blob-service-properties show --account-name "$acct" --resource-group "$rg" \
                --subscription "$subid" --query "lastAccessTimeTrackingPolicy.enable" -o tsv --only-show-errors 2>>"$LOG_FILE")
    if [ "$current" != "true" ]; then
      log "  already disabled (or never enabled): $acct (sub=${F_SUBNAME[$i]})"
      ALREADY+=("$acct")
      continue
    fi

    PEND_ACCT+=("$acct"); PEND_SUBID+=("$subid"); PEND_SUBNAME+=("${F_SUBNAME[$i]}"); PEND_RG+=("$rg")
  done
}

# ---- Tabular listing --------------------------------------------------------
print_table() {  # prints ACCOUNT / SUBSCRIPTION / RESOURCE GROUP for the pending set
  local n="${#PEND_ACCT[@]}" i
  (( n == 0 )) && return 0
  printf "  %-32s %-42s %s\n" "STORAGE ACCOUNT" "SUBSCRIPTION" "RESOURCE GROUP"
  printf "  %-32s %-42s %s\n" "----------------" "------------" "--------------"
  for ((i=0; i<n; i++)); do
    printf "  %-32s %-42s %s\n" "${PEND_ACCT[$i]}" "${PEND_SUBNAME[$i]}" "${PEND_RG[$i]}"
  done
}

# ---- Confirm + apply ---------------------------------------------------------
confirm_apply() {
  $DRY_RUN && return 0
  (( ${#PEND_ACCT[@]} == 0 )) && return 0
  $ASSUME_YES && return 0

  echo ""
  echo "Last-access-time tracking will be DISABLED on the following ${#PEND_ACCT[@]} account(s):"
  print_table
  echo ""
  echo "Re-run with --dry-run to preview only, or --yes to skip this prompt."
  local reply
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] || { log "Aborted by user at confirmation prompt — no changes made."; exit 0; }
}

UPDATED=0
FAILED=0

apply_changes() {
  local n="${#PEND_ACCT[@]}" i acct subid subname rg
  for ((i=0; i<n; i++)); do
    acct="${PEND_ACCT[$i]}"; subid="${PEND_SUBID[$i]}"; subname="${PEND_SUBNAME[$i]}"; rg="${PEND_RG[$i]}"

    if $DRY_RUN; then
      log "[dry-run] would disable LAT on $acct (rg=$rg, sub=$subname)"
      continue
    fi

    log "Disabling LAT on $acct (rg=$rg, sub=$subname)..."
    if az storage account blob-service-properties update --account-name "$acct" --resource-group "$rg" \
         --subscription "$subid" --enable-last-access-tracking false --only-show-errors -o none 2>>"$LOG_FILE"; then
      log "  -> disabled OK"
      UPDATED=$((UPDATED + 1))
    else
      log_error "  -> disable FAILED for $acct (rg=$rg, sub=$subname) — details in $LOG_FILE (often a missing '.../storageAccounts/write' RBAC action, or a resource lock)"
      FAILED=$((FAILED + 1))
    fi
  done
}

print_summary() {
  echo ""
  echo "==============================================================" | tee -a "$LOG_FILE"
  echo " Run summary" | tee -a "$LOG_FILE"
  echo "   Accounts requested      : ${#ACCOUNTS[@]}" | tee -a "$LOG_FILE"
  echo "   Already disabled        : ${#ALREADY[@]}" | tee -a "$LOG_FILE"
  (( ${#NOTFOUND[@]} > 0 )) && echo "   Not found / no access   : ${#NOTFOUND[@]} (${NOTFOUND[*]})" | tee -a "$LOG_FILE"
  if $DRY_RUN; then
    echo "   Would disable           : ${#PEND_ACCT[@]}" | tee -a "$LOG_FILE"
  else
    echo "   Disabled                : $UPDATED" | tee -a "$LOG_FILE"
    echo "   Failed                  : $FAILED" | tee -a "$LOG_FILE"
  fi
  echo "==============================================================" | tee -a "$LOG_FILE"
  if (( ${#PEND_ACCT[@]} > 0 )); then
    if $DRY_RUN; then
      echo " Accounts on which LAT WOULD BE disabled:" | tee -a "$LOG_FILE"
    else
      echo " Accounts on which LAT was targeted for disabling:" | tee -a "$LOG_FILE"
    fi
    print_table | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
  fi
  echo "Log file: $LOG_FILE"
  (( FAILED > 0 )) && echo "Some updates failed. Check $LOG_FILE, fix access/locks, then re-run — accounts already disabled are simply reported as 'already disabled' next time."
}

# ---- Main ---------------------------------------------------------------
main() {
  trap print_summary EXIT

  ensure_az_cli
  ensure_graph_extension
  ensure_login

  log "Resolving ${#ACCOUNTS[@]} account name(s) to subscription/resource group via Resource Graph..."
  resolve_accounts

  log "Checking current LAT state on ${#F_ACCT[@]} resolved account(s)..."
  check_current_state

  if (( ${#PEND_ACCT[@]} == 0 )); then
    log "Nothing to disable."
    exit 0
  fi

  confirm_apply
  apply_changes

  (( FAILED > 0 )) && exit 1
  exit 0
}

main
