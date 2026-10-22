# Testing read-only.sh

How to test [`read-only.sh`](read-only.sh) end to end in a test Azure
subscription. Run through it after every change to the script, and update
this guide alongside the [README](README.md) whenever the script changes.

The tests use a **throwaway service principal** in place of Lucidity's, so
you hold its credentials and can check what it can actually do.

## Before you start

- A **test subscription** where you are Owner. Don't use a customer or
  production subscription.
- Permission to create app registrations in the tenant (most users have it
  unless an admin turned it off).
- **Azure Cloud Shell in Bash mode** (not PowerShell). It has `az` and `jq`.
- The version of `read-only.sh` you want to test.

Keep the same Cloud Shell session for the whole test: the steps share shell
variables. If the session restarts, redo [Setup step 1](#1-variables) and
reload the service principal details from `sp.json`
([step 2](#2-throwaway-service-principal)).

## Setup

### 1. Variables

```bash
SUB=$(az account show --query id -o tsv)
az account show --query "{name:name, id:id, tenant:tenantId}" -o table   # confirm it's the test subscription
SFX=${SFX:-$RANDOM}      # keeps storage account names unique
RG=lucidity-onboarding-test
echo "SFX=$SFX"          # note it down in case the session restarts
```

### 2. Throwaway service principal

```bash
az ad sp create-for-rbac -n lucidity-onboarding-test-$SFX -o json > sp.json
APP_ID=$(jq -r .appId sp.json); SECRET=$(jq -r .password sp.json); TENANT=$(jq -r .tenant sp.json)
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
echo "$SP_OBJECT_ID"
```

`sp.json` holds the service principal's secret. Delete it during
[cleanup](#cleanup).

### 3. Test storage accounts

One account per firewall case:

```bash
az group create -n $RG -l eastus -o none
az storage account create -g $RG -n luctopen$SFX -l eastus  --sku Standard_LRS -o none                                   # open
az storage account create -g $RG -n luctuk$SFX   -l uksouth --sku Standard_LRS --default-action Deny -o none             # firewalled, other region
az storage account create -g $RG -n lucteast$SFX -l eastus  --sku Standard_LRS --default-action Deny -o none             # firewalled, Lucidity's region
az storage account create -g $RG -n luctoff$SFX  -l uksouth --sku Standard_LRS --public-network-access Disabled -o none  # public access disabled
```

Test data for the blob-read check, in the open account (the firewalled ones
would block Cloud Shell too):

```bash
KEY=$(az storage account keys list -g $RG -n luctopen$SFX --query [0].value -o tsv)
for c in lucidity-inventory other; do
  az storage container create --account-name luctopen$SFX --account-key "$KEY" -n $c -o none
  echo test > t.txt
  az storage blob upload --account-name luctopen$SFX --account-key "$KEY" -c $c -n t.txt -f t.txt -o none
done
```

### 4. Get the script

Either upload it (Cloud Shell: **Manage files → Upload**), or download it
from the branch under test:

```bash
wget -O read-only.sh https://raw.githubusercontent.com/luciditycloud/utilities/refs/heads/<branch>/onboarding-script/read-only.sh
```

### 5. Fill in the settings

`setv` changes one setting in place and prints the result:

```bash
setv() { sed -i "s|^$1=.*|$1=$2|" read-only.sh; grep "^$1=" read-only.sh; }

setv SUBSCRIPTION_ID "\"$SUB\""
setv SP_OBJECT_ID "\"$SP_OBJECT_ID\""
setv STORAGE_ACCOUNTS "\"luctopen$SFX luctuk$SFX lucteast$SFX luctoff$SFX\""
chmod +x read-only.sh
```

`STORAGE_ACCOUNTS` keeps the firewall check to the test accounts, so the
script never touches other storage accounts in the subscription.

Re-uploading the script resets these settings: redo this step after every
upload.

## Scenarios

Run them in order: later scenarios build on the state earlier ones leave.
After each run, compare with the expected result and note anything
different.

### A. Assessment mode

```bash
setv MODE '"assessment"'
./read-only.sh
```

Expected:
- A progress line for each step, and no optimization approval prompt.
- Reader: `[ok]`. Reservations Reader: `[warning]` with a short warning,
  unless you have tenant-level rights.
- Guest insights role created and assigned, with "blob reads limited to
  'lucidity-inventory'". No optimize role.
- Storage network check:
  - `luctopen…`: `open`
  - `luctuk…` and `lucteast…`: `needs_rule`, each with "will add subnet
    rule …" and "will add ip rule 4.157.111.90"
  - `luctoff…`: `public_access_disabled`
- Prompt `Apply these rule changes on 2 storage account(s)?`: answer `y`.
  Both accounts become `applied`, or `failed` with Azure's error (record
  it: a failed subnet rule means the cross-tenant subnet rule doesn't work).
- Final status: `completed_with_warnings` (Reservations Reader and
  `luctoff…`).

Then check the rules (both accounts):

```bash
for a in luctuk$SFX lucteast$SFX; do
  az storage account network-rule list -g $RG --account-name $a \
    --query "{ip: ipRules[].ipAddressOrRange, subnet: virtualNetworkRules[].{id: virtualNetworkResourceId, state: state}}"
done
```

Expected: the IP `4.157.111.90`, and Lucidity's subnet with state
`Succeeded`.

### B. Optimization mode, declined

```bash
setv MODE '"optimization"'
./read-only.sh       # answer n
```

Expected: the approval banner lists "autoscaler, blobs"; after `n`,
"Optimization access not approved. Nothing was changed." and status
`failed` with `[failed] Optimization mode approval`. No role was changed.

### C. Optimization mode, approved

```bash
./read-only.sh       # answer y, then y at the network prompt if asked
```

Expected:
- Guest insights role: "Updating role …"; optimize role: "Creating role …".
- Both custom role assignments `[ok]`, each with "blob reads limited to
  'lucidity-inventory'".
- Storage accounts from scenario A: `already_allowed`, no network prompt.
- Status: `completed_with_warnings`.

### D. Rerun, nothing to change

```bash
./read-only.sh       # answer y
```

Expected: both roles "Updating role …", all assignments `[ok]` on the first
attempt (no "retrying" lines), storage accounts `already_allowed`.

### E. Assessment after optimization

```bash
setv MODE '"assessment"'
./read-only.sh
```

Expected: "Optimization features are ignored in assessment mode", then
**NOTE: Lucidity already has optimization access …**, and
`[ok] Existing optimization access` in the summary. The optimize role is
still assigned (check in [Verify](#verify)).

### F. Run Command off

```bash
setv GUEST_INSIGHTS false
./read-only.sh
az role definition list --name lucidity-guest-insights-role-$SUB --query "[0].{description: description, runCommand: contains(permissions[0].actions, 'Microsoft.Compute/virtualMachines/runCommand/action')}"
setv GUEST_INSIGHTS true
```

Expected: the description no longer mentions Run Command, and `runCommand`
is `false`.

### G. No terminal

```bash
setv MODE '"optimization"'
./read-only.sh < /dev/null
```

Expected: "No terminal to ask for approval", nothing changed, status
`failed`.

```bash
setv AUTO_APPROVE_OPTIMIZATION true
setv AUTO_APPROVE_NETWORK_CHANGES true
./read-only.sh < /dev/null
setv AUTO_APPROVE_OPTIMIZATION false
setv AUTO_APPROVE_NETWORK_CHANGES false
```

Expected: "Auto-approved" for optimization, run completes
(`completed_with_warnings`).

### H. Invalid settings

```bash
setv BLOBS yes;  ./read-only.sh; setv BLOBS true
setv MODE '"full"'; ./read-only.sh; setv MODE '"optimization"'
```

Expected: "ERROR: BLOBS must be true or false", then "ERROR: MODE must be
optimization or assessment", each before anything is changed.

## Verify

Run as yourself after the scenarios.

Assignments, with the condition on the custom roles:

```bash
az role assignment list --assignee "$SP_OBJECT_ID" --all \
  --query "[].{role: roleDefinitionName, scope: scope, condition: condition}" -o table
```

Role descriptions:

```bash
az role definition list --custom-role-only true \
  --query "[?starts_with(roleName,'lucidity-guest') || starts_with(roleName,'lucidity-optimize')].{name: roleName, description: description}" -o table
```

Reports (one per run):

```bash
for f in lucidity-onboarding-report-*.json; do
  jq -c '{file: input_filename, mode, status, steps: [.steps[] | "\(.status) \(.step)"]}' "$f"
done
```

**Blob reads are limited to `lucidity-inventory`.** Wait 2–5 minutes after
the last run, then sign in as the test service principal:

```bash
az login --service-principal -u "$APP_ID" -p "$SECRET" --tenant "$TENANT" -o none
az account show --query user -o table      # expect type servicePrincipal
az storage blob list --account-name luctopen$SFX -c lucidity-inventory --auth-mode login -o table   # expect t.txt
az storage blob list --account-name luctopen$SFX -c other --auth-mode login -o table                # expect a permissions error
az logout; az login                        # back to your own account
```

Cloud Shell says it's "automatically authenticated" when you run
`az login`; check `az account show` to see which identity is active.

## Cleanup

As yourself (`az account show --query user -o table` shows type `user`).
The service principal can't remove its own access.

```bash
# Remove every assignment of the test service principal, by ID
az role assignment list --assignee "$SP_OBJECT_ID" --all --query "[].id" -o tsv \
  | xargs -r az role assignment delete --ids
az role assignment list --assignee "$SP_OBJECT_ID" --all -o table     # expect empty

sleep 60   # role deletion fails until Azure catches up with the assignment deletes
for r in lucidity-guest-insights-role-$SUB lucidity-optimize-role-$SUB; do
  az role definition delete --name "$r" --scope "/subscriptions/$SUB"
done

az group delete -n $RG --yes --no-wait
az ad sp delete --id "$APP_ID"
rm -f sp.json t.txt lucidity-onboarding-report-*.json
```

- If the role delete returns `RoleDefinitionHasAssignments`, wait another
  minute and rerun the loop. If it persists, list who still holds the role
  (`az role assignment list --role <name> --scope /subscriptions/$SUB`); stop
  if it's anything other than the test service principal.
- Delete only the two roles above. The test subscription may hold other
  `lucidity-*` roles from earlier onboarding versions.

## Test log

Record each real-Azure test run here.

| Date | Script commit | Tester | Scenarios | Result |
|---|---|---|---|---|
| 2026-10-22 | `475addc` and earlier | Swapnesh | Optimization (before modes existed): roles, rerun, condition, blob-read limit, Reservations Reader warning, IP rule, network prompt, report | Passed. Found and fixed: Reservations Reader role ID not recognized by `az`, no progress output |
