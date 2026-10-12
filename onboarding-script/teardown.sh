#!/bin/bash
# =============================================================================
# Lucidity - remove read-only assessment access
# -----------------------------------------------------------------------------
# Reverses read-only.sh. At each scope given, finds every custom role whose
# name starts with the prefix, and Lucidity's assignments to it. It then asks
# for approval before each step:
#   1. Remove Lucidity's role assignments.
#   2. Delete the role definitions.
# Answering "no" at a step skips it. Nothing changes before the first approval.
#
#   -m "<mgIds>"   management group(s); assignments are looked up on every
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
  echo "  -y, --yes     approve every step without prompting"
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

oneline() { echo "$1" | tr '\n' ' ' | sed 's/  */ /g'; }

# Approval gate: returns 0 if approved (always, with -y).
approve() {  # $1=question
  [ "$ASSUME_YES" = "true" ] && return 0
  local r
  printf "%s [y/N] " "$1"; read -r r
  case "$r" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---- Azure CLI + login + SP ------------------------------------------------
command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found. Install it, or run this script in Azure Cloud Shell."; exit 1; }
echo ">> Ensuring Azure CLI login..."
az account show >/dev/null 2>&1 || az login --only-show-errors >/dev/null || { echo "ERROR: Azure CLI login failed."; exit 1; }

# Look up (never create) Lucidity's service principal to find its assignments.
echo ">> Looking up Lucidity service principal..."
if ! servicePrincipalId=$(az ad sp list --filter "appId eq '${LUCIDITYAPPID}'" --query "[0].id" -o tsv --only-show-errors 2>&1); then
  echo "ERROR: your account cannot read service principals in Microsoft Entra ID."
  echo "  Azure CLI: $(oneline "$servicePrincipalId")"
  echo "  Ask an administrator for directory read access, then rerun."
  exit 1
fi
if [ -n "$servicePrincipalId" ]; then
  echo "   Service Principal Id: $servicePrincipalId"
else
  echo "   Not found in this tenant; there are no Lucidity assignments to remove."
fi

# ---- Discovery (no changes) ------------------------------------------------
# Parallel lists of what was found: roles, and Lucidity's assignments to them.
R_ID=(); R_NAME=(); R_SCOPE=()
A_ID=(); A_ROLE=(); A_SUB=()
warn=0

echo ">> Finding roles with prefix '${ROLE_PREFIX}' and Lucidity's assignments to them..."
for id in "${SCOPE_LIST[@]}"; do
  scope="$(scope_path "$MODE" "$id")"
  if [ "$MODE" = "mg" ]; then
    subs="$(subs_under_mg "$id")"
    [ -z "$subs" ] && { echo "   WARN: no child subscriptions enumerated for $id - check management-group Reader access."; warn=1; }
  else
    subs="$id"
  fi

  if ! roles=$(az role definition list --scope "$scope" --custom-role-only true \
         --query "[?starts_with(roleName, '${ROLE_PREFIX}')].[roleName,name]" -o tsv --only-show-errors 2>&1); then
    echo "   WARN: could not list roles at $scope: $(oneline "$roles")"; warn=1; continue
  fi

  while IFS=$'\t' read -r rname rid; do
    [ -z "$rid" ] && continue
    R_ID+=("$rid"); R_NAME+=("$rname"); R_SCOPE+=("$scope")
    [ -z "$servicePrincipalId" ] && continue
    for sub in $subs; do
      if ! asgs=$(az role assignment list --all --subscription "$sub" --assignee "$servicePrincipalId" \
             --role "$rid" --query "[].id" -o tsv --only-show-errors 2>&1); then
        echo "   WARN: could not list assignments of $rname in subscription $sub: $(oneline "$asgs")"; warn=1; continue
      fi
      for asg in $asgs; do A_ID+=("$asg"); A_ROLE+=("$rname"); A_SUB+=("$sub"); done
    done
  done <<< "$roles"
done

echo ""
echo "=============================================================="
echo " Found (scope mode: ${MODE}, targets: ${SCOPE_LIST[*]})"
echo "   Roles       : ${#R_ID[@]}"
for i in "${!R_ID[@]}"; do echo "     - ${R_NAME[$i]}  (${R_SCOPE[$i]})"; done
echo "   Assignments : ${#A_ID[@]}"
for i in "${!A_ID[@]}"; do echo "     - ${A_ROLE[$i]}  in subscription ${A_SUB[$i]}"; done
echo "=============================================================="
[ "$warn" -ne 0 ] && echo "WARNING: some lookups failed (see WARN lines above); this list may be incomplete."

if [ "${#R_ID[@]}" -eq 0 ]; then
  echo ">> Nothing to remove."
  exit "$warn"
fi

fail=0

# ---- Step 1: role assignments ----------------------------------------------
remaining=${#A_ID[@]}   # assignments still in place after this step
if [ "$remaining" -gt 0 ]; then
  echo ""
  if approve "Step 1/2: remove ${#A_ID[@]} Lucidity role assignment(s)?"; then
    for i in "${!A_ID[@]}"; do
      if out=$(az role assignment delete --ids "${A_ID[$i]}" --only-show-errors 2>&1); then
        echo "   removed: ${A_ROLE[$i]} in subscription ${A_SUB[$i]}"
        remaining=$((remaining - 1))
      else
        echo "   FAILED: ${A_ROLE[$i]} in subscription ${A_SUB[$i]}: $(oneline "$out")"; fail=1
      fi
    done
  else
    echo "   Step 1 skipped."
  fi
fi

# ---- Step 2: role definitions ----------------------------------------------
# Azure refuses to delete a role that is still assigned.
echo ""
[ "$remaining" -gt 0 ] &&
  echo "Note: $remaining Lucidity assignment(s) are still in place; deleting their roles will fail."
if approve "Step 2/2: delete ${#R_ID[@]} role definition(s)?"; then
  for i in "${!R_ID[@]}"; do
    if out=$(az role definition delete --name "${R_ID[$i]}" --scope "${R_SCOPE[$i]}" 2>&1); then
      echo "   deleted: ${R_NAME[$i]}"
    else
      echo "   FAILED: ${R_NAME[$i]}: $(oneline "$out")"; fail=1
    fi
  done
else
  echo "   Step 2 skipped."
fi

echo ""
if [ "$fail" -eq 0 ] && [ "$warn" -eq 0 ]; then echo ">> Teardown complete."
else echo ">> Teardown finished with errors or warnings - review above."; fi
[ "$fail" -eq 0 ] && [ "$warn" -eq 0 ]
