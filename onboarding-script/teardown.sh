#!/bin/bash
# =============================================================================
# Lucidity - remove read-only assessment access
# -----------------------------------------------------------------------------
# Reverses read-only.sh. At each scope given, deletes every custom role whose
# name starts with the prefix, after first removing Lucidity's assignments to it.
#
#   -m "<mgIds>"   management group(s); assignments are removed from every
#                  subscription under each group
#   -s "<subIds>"  subscription(s)
#   IDs may be comma- or space-separated. Provide exactly one of -m / -s.
#
# Not removed: 'lucidity-inventory' containers, Last Access Time tracking, Blob
# inventory policies, and Lucidity's service principal.
#
# Flags: -m | -s | -p <prefix> | -y | -h
# Requires: Azure CLI (logged in) and bash. No jq/python dependency.
# =============================================================================

# ---- Config ----------------------------------------------------------------
# Must match the values used by read-only.sh.
LUCIDITYAPPID="4f2c2c1f-372a-4904-b13d-11e2467679f2"
ROLE_PREFIX="lucidity-permissions-readonly"

# ---- Long-opt translation --------------------------------------------------
args=()
for a in "$@"; do
  case "$a" in
    --yes)  args+=("-y") ;;
    --help) args+=("-h") ;;
    *)      args+=("$a") ;;
  esac
done
set -- "${args[@]}"

# ---- Arg parsing -----------------------------------------------------------
MG_INPUT=""; SUB_INPUT=""; ASSUME_YES="false"
usage() {
  echo "Usage:"
  echo "  $0 (-m \"<mgIds>\" | -s \"<subIds>\") [-p <prefix>] [-y]"
  echo "  -m  management group ids"
  echo "  -s  subscription ids"
  echo "  -p  role-name prefix used at onboarding (default: ${ROLE_PREFIX})"
  echo "  -y, --yes     skip confirmation"
  echo "  IDs may be comma- or space-separated. Provide exactly one of -m / -s."
  exit 1
}
while getopts ":m:s:p:yh" opt; do
  case "$opt" in
    m) MG_INPUT="$OPTARG" ;;
    s) SUB_INPUT="$OPTARG" ;;
    p) ROLE_PREFIX="$OPTARG" ;;
    y) ASSUME_YES="true" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if { [ -n "$MG_INPUT" ] && [ -n "$SUB_INPUT" ]; } || { [ -z "$MG_INPUT" ] && [ -z "$SUB_INPUT" ]; }; then
  echo "ERROR: provide exactly one of -m or -s."; usage
fi

# Accept IDs separated by commas and/or spaces.
normalize() { echo "$1" | tr ',' ' ' | xargs; }
MODE=""; SCOPE_LIST=()
if [ -n "$MG_INPUT" ]; then MODE="mg"; read -ra SCOPE_LIST <<< "$(normalize "$MG_INPUT")"
else MODE="sub"; read -ra SCOPE_LIST <<< "$(normalize "$SUB_INPUT")"; fi

# ---- Helpers ---------------------------------------------------------------
scope_path() {  # $1=mg|sub  $2=id
  if [ "$1" = "mg" ]; then echo "/providers/Microsoft.Management/managementGroups/$2"; else echo "/subscriptions/$2"; fi
}

# Subscriptions under the management group, including nested groups.
subs_under_mg() {  # $1=mgId
  az account management-group entities list \
    --query "[?type=='/subscriptions' && contains(parentNameChain, '$1')].name" -o tsv --only-show-errors 2>/dev/null
}

fail=0

# Remove Lucidity's assignments of one role anywhere in one subscription.
remove_assignments() {  # $1=roleId $2=subId
  local rid="$1" sub="$2" asg
  for asg in $(az role assignment list --all --subscription "$sub" --assignee "$servicePrincipalId" \
                 --role "$rid" --query "[].id" -o tsv --only-show-errors 2>/dev/null); do
    if az role assignment delete --ids "$asg" --only-show-errors >/dev/null; then
      echo "         removed assignment in subscription $sub"
    else
      echo "         FAILED to remove assignment in subscription $sub"; fail=1
    fi
  done
}

# Delete every prefix-matching custom role at one scope, after removing
# Lucidity's assignments to it. Azure refuses to delete a role still assigned.
clear_scope() {  # $1=mg|sub  $2=id
  local scope line rname rid delerr subs sub n=0
  scope="$(scope_path "$1" "$2")"
  if [ "$1" = "mg" ]; then
    subs="$(subs_under_mg "$2")"
    [ -z "$subs" ] && echo "   (no child subscriptions enumerated for $2 - check management-group Reader access)"
  else
    subs="$2"
  fi
  echo "   scope: $scope  (prefix '${ROLE_PREFIX}')"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rname="${line%%:::*}"; rid="${line##*:::}"
    n=$((n+1))
    echo "     - ${rname}"
    if [ -n "$servicePrincipalId" ]; then
      for sub in $subs; do remove_assignments "$rid" "$sub"; done
    fi
    if delerr=$(az role definition delete --name "$rid" --scope "$scope" 2>&1); then
      echo "         deleted role definition"
    else
      echo "         DELETE FAILED: $(echo "$delerr" | tr '\n' ' ' | sed 's/  */ /g')"; fail=1
    fi
  done < <(az role definition list --scope "$scope" --custom-role-only true \
            --query "[?starts_with(roleName, '${ROLE_PREFIX}')].[roleName,name]" -o tsv --only-show-errors 2>/dev/null | sed 's/\t/:::/')
  [ "$n" -eq 0 ] && echo "     (no matching roles found at this scope)"
}

# ---- Azure CLI + login + SP ------------------------------------------------
command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found. Install it, or run this script in Azure Cloud Shell."; exit 1; }
echo ">> Ensuring Azure CLI login..."
az account show >/dev/null 2>&1 || az login --only-show-errors >/dev/null || { echo "ERROR: Azure CLI login failed."; exit 1; }

# Look up (never create) Lucidity's service principal to find its assignments.
echo ">> Looking up Lucidity service principal..."
if ! servicePrincipalId=$(az ad sp list --filter "appId eq '${LUCIDITYAPPID}'" --query "[0].id" -o tsv --only-show-errors 2>&1); then
  echo "ERROR: your account cannot read service principals in Microsoft Entra ID."
  echo "  Azure CLI: $(echo "$servicePrincipalId" | tr '\n' ' ')"
  echo "  Ask an administrator for directory read access, then rerun."
  exit 1
fi
if [ -n "$servicePrincipalId" ]; then
  echo "   Service Principal Id: $servicePrincipalId"
else
  echo "   Not found in this tenant; only role definitions will be deleted."
fi

# ---- Confirm + clear -------------------------------------------------------
echo ""
echo "=============================================================="
echo " Remove Lucidity custom roles with prefix '${ROLE_PREFIX}'"
echo "   Scope mode : ${MODE}   targets: ${SCOPE_LIST[*]}"
echo "   Lucidity's assignments to these roles are removed first"
echo "=============================================================="
if [ "$ASSUME_YES" != "true" ]; then printf "Proceed with deletion? [y/N] "; read -r r; case "$r" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac; fi
for id in "${SCOPE_LIST[@]}"; do clear_scope "$MODE" "$id"; done
[ "$fail" -eq 0 ] && echo ">> Teardown complete." || echo ">> Teardown completed with errors - review above."
exit $fail
