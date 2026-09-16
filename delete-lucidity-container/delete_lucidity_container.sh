#!/bin/bash

set -uo pipefail

# ---- Config -----------------------------------------------------------------
CONTAINER_NAME="lucidity-inventory"
LOG_FILE="delete_lucidity_container.log"
DRY_RUN="false"
ASSUME_YES="false"
RG_FILTER=""
ACCT_INPUT=""

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
MG_INPUT=""; SUB_INPUT=""
usage() {
  echo "Usage:"
  echo "  $0 [-s \"<subIds|all>\" | -m \"<mgIds>\"] [-t <container>] [-a \"<accts>\"] [-r <regex>] [-l <logfile>] [-n] [-y]"
  echo ""
  echo "  -s  subscription id(s), comma/space-separated, or \"all\" for every"
  echo "      subscription the caller can see"
  echo "  -m  management group id(s) — child subscriptions (nested included)"
  echo "      are resolved and included automatically"
  echo "  -t  container name to delete (default: ${CONTAINER_NAME})"
  echo "  -a  restrict to these storage account names, comma/space-separated"
  echo "      (default: every account in scope)"
  echo "  -r  only consider resource groups matching this regex"
  echo "  -l  log file path (default: ${LOG_FILE})"
  echo "  -n, --dry-run   list what would be deleted; deletes nothing"
  echo "  -y, --yes       skip the confirmation prompt (for unattended/CI runs)"
  echo "  -h, --help      show this help"
  echo ""
  echo "  -s / -m are both optional and mutually exclusive. Neither given ->"
  echo "  defaults to -s all (every subscription the caller can see)."
  exit 1
}
while getopts ":s:m:t:a:r:l:nyh" opt; do
  case "$opt" in
    s) SUB_INPUT="$OPTARG" ;;
    m) MG_INPUT="$OPTARG" ;;
    t) CONTAINER_NAME="$OPTARG" ;;
    a) ACCT_INPUT="$OPTARG" ;;
    r) RG_FILTER="$OPTARG" ;;
    l) LOG_FILE="$OPTARG" ;;
    n) DRY_RUN="true" ;;
    y) ASSUME_YES="true" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [ -n "$MG_INPUT" ] && [ -n "$SUB_INPUT" ]; then
  echo "ERROR: provide at most one of -s or -m." >&2
  usage
fi
if [ -z "$MG_INPUT" ] && [ -z "$SUB_INPUT" ]; then
  SUB_INPUT="all"   # no scope given -> every subscription the caller can see
fi

normalize() { echo "$1" | tr ',' ' ' | xargs; }
ACCT_FILTER="$(normalize "$ACCT_INPUT")"

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
subs_under_mg() {  # $1=mgId ; prints child subscription ids (nested included)
  az account management-group entities list \
    --query "[?type=='/subscriptions' && contains(parentNameChain, '$1')].name" -o tsv --only-show-errors 2>/dev/null
}

resolve_subscriptions() {
  local sub_list=()
  if [ -n "$SUB_INPUT" ]; then
    if [ "$(normalize "$SUB_INPUT")" = "all" ]; then
      az account list --query "[].id" -o tsv --only-show-errors 2>/dev/null
      return 0
    fi
    read -ra sub_list <<< "$(normalize "$SUB_INPUT")"
    printf '%s\n' "${sub_list[@]}"
    return 0
  fi

  local mg_list=() mg subs
  read -ra mg_list <<< "$(normalize "$MG_INPUT")"
  for mg in "${mg_list[@]}"; do
    subs="$(subs_under_mg "$mg")"
    if [ -z "$subs" ]; then
      log_error "No child subscriptions enumerated for management group '$mg' (check MG-reader access, or it has none)."
      continue
    fi
    printf '%s\n' "$subs"
  done | sort -u
}

# ---- Discovery ------------------------------------------------------------
# Parallel indexed arrays (kept bash-3.2-compatible on purpose, so this runs
# with macOS's default /bin/bash without any version gate).
F_SUB=(); F_RG=(); F_ACCT=()

list_accounts_in_sub() {  # $1=sub ; prints "name<TAB>rg" lines in scope
  local sub="$1" rg
  if [ -n "$ACCT_FILTER" ]; then
    local a
    for a in $ACCT_FILTER; do
      rg=$(az storage account list --subscription "$sub" \
             --query "[?name=='$a'].resourceGroup | [0]" -o tsv --only-show-errors 2>>"$LOG_FILE")
      [ -n "$rg" ] && printf '%s\t%s\n' "$a" "$rg"
    done
  else
    az storage account list --subscription "$sub" \
      --query "[].[name,resourceGroup]" -o tsv --only-show-errors 2>>"$LOG_FILE"
  fi
}

SUB_COUNT=0
SUB_SKIPPED=0

discover() {
  local sub name rg exists listing
  while IFS= read -r sub; do
    [ -z "$sub" ] && continue
    SUB_COUNT=$((SUB_COUNT + 1))
    log "Scanning subscription $sub for '$CONTAINER_NAME' containers..."

    if ! listing=$(list_accounts_in_sub "$sub"); then
      log_error "Could not list storage accounts in subscription $sub — no access, or the call failed. Skipping it. See $LOG_FILE."
      SUB_SKIPPED=$((SUB_SKIPPED + 1))
      continue
    fi
    [ -z "$listing" ] && continue

    while IFS=$'\t' read -r name rg; do
      [ -z "$name" ] && continue
      if [ -n "$RG_FILTER" ] && ! [[ "$rg" =~ $RG_FILTER ]]; then
        continue
      fi
      exists=$(az storage container-rm exists -g "$rg" --storage-account "$name" --subscription "$sub" \
                 -n "$CONTAINER_NAME" --query exists -o tsv --only-show-errors 2>>"$LOG_FILE")
      if [ "$exists" = "true" ]; then
        F_SUB+=("$sub"); F_RG+=("$rg"); F_ACCT+=("$name")
        log "  found: $name (rg=$rg, sub=$sub)"
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
  echo "The following $n container(s) named '$CONTAINER_NAME' will be PERMANENTLY DELETED:"
  local i
  for ((i=0; i<n; i++)); do
    printf "  %-32s rg=%-24s sub=%s\n" "${F_ACCT[$i]}" "${F_RG[$i]}" "${F_SUB[$i]}"
  done
  echo ""
  echo "Re-run with --dry-run to preview only, or --yes to skip this prompt."
  local reply
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] || { log "Aborted by user at confirmation prompt — no changes made."; exit 0; }
}

DELETED=0
FAILED=0

delete_found() {
  local n="${#F_SUB[@]}" i sub rg acct
  for ((i=0; i<n; i++)); do
    sub="${F_SUB[$i]}"; rg="${F_RG[$i]}"; acct="${F_ACCT[$i]}"

    if $DRY_RUN; then
      log "[dry-run] would delete '$CONTAINER_NAME' in $acct (rg=$rg, sub=$sub)"
      continue
    fi

    log "Deleting '$CONTAINER_NAME' in $acct (rg=$rg, sub=$sub)..."
    if az storage container-rm delete -g "$rg" --storage-account "$acct" --subscription "$sub" \
         -n "$CONTAINER_NAME" --yes --only-show-errors 2>>"$LOG_FILE"; then
      log "  -> deleted OK"
      DELETED=$((DELETED + 1))
    else
      log_error "  -> delete FAILED for $acct (rg=$rg, sub=$sub) — details in $LOG_FILE (often a missing 'containers/delete' RBAC action, or a resource lock)"
      FAILED=$((FAILED + 1))
    fi
  done
}

print_summary() {
  local found="${#F_SUB[@]}"
  echo ""
  echo "==============================================================" | tee -a "$LOG_FILE"
  echo " Run summary" | tee -a "$LOG_FILE"
  echo "   Container   : $CONTAINER_NAME" | tee -a "$LOG_FILE"
  echo "   Subscriptions scanned : $SUB_COUNT" | tee -a "$LOG_FILE"
  (( SUB_SKIPPED > 0 )) && echo "   Subscriptions skipped (no access) : $SUB_SKIPPED" | tee -a "$LOG_FILE"
  echo "   Found       : $found" | tee -a "$LOG_FILE"
  if $DRY_RUN; then
    echo "   Mode        : dry-run — nothing deleted" | tee -a "$LOG_FILE"
  else
    echo "   Deleted     : $DELETED" | tee -a "$LOG_FILE"
    echo "   Failed      : $FAILED" | tee -a "$LOG_FILE"
  fi
  echo "   Log file    : $LOG_FILE" | tee -a "$LOG_FILE"
  echo "==============================================================" | tee -a "$LOG_FILE"
  (( FAILED > 0 )) && echo "Some deletions failed. Check $LOG_FILE, fix access/locks, then re-run — accounts already deleted are simply not found again."
}

# ---- Main ---------------------------------------------------------------
main() {
  trap print_summary EXIT

  ensure_az_cli
  ensure_login
  discover

  if (( ${#F_SUB[@]} == 0 )); then
    log "No '$CONTAINER_NAME' containers found in scope. Nothing to do."
    exit 0
  fi

  confirm_delete
  delete_found

  (( FAILED > 0 )) && exit 1
  exit 0
}

main
