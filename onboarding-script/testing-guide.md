# Testing read-only.sh

How to test [`read-only.sh`](read-only.sh) end to end in a test Azure
tenant. Run through it after every change to the script, and update this
guide alongside the [README](README.md) whenever the script changes.

The tests use a **throwaway service principal** in place of Lucidity's, so
you hold its credentials and can check what it can actually do.

## Before you start

- A **test subscription** where you are Owner. Don't use a customer or
  production subscription.
- For the management group scenarios, a **test management group** that
  contains only test subscriptions, where you are Owner. If there isn't
  one, [Setup step 6](#6-test-management-group-optional) creates one.
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

setv SCOPE_TYPE '"subscription"'
setv SCOPE_IDS "\"$SUB\""
setv SP_OBJECT_ID "\"$SP_OBJECT_ID\""
setv STORAGE_ACCOUNTS "\"luctopen$SFX luctuk$SFX lucteast$SFX luctoff$SFX\""
chmod +x read-only.sh
```

`STORAGE_ACCOUNTS` keeps the firewall check to the test accounts, so the
script never touches other storage accounts in the subscription.

Always keep `SP_OBJECT_ID` set to the test service principal (or, in
scenario K, `LUCIDITY_APP_ID` set to the test app). With both left as
shipped, the script looks up **Lucidity's real** service principal, creates
it in the test tenant if needed, and gives it the roles.

Re-uploading the script resets these settings: redo this step after every
upload.

### 6. Test management group (optional)

Only for [scenario I](#i-management-group-scope). Skip this if you already
have a test management group with only test subscriptions in it; set
`MG=<its ID>` instead.

Moving a subscription into a management group changes which policies and
role assignments it inherits. Only do this with a test subscription, and
move it back during cleanup.

```bash
MG=lucidity-test-mg-$SFX
ORIGINAL_PARENT=$(az account management-group entities list \
  --query "[?name=='$SUB'].parent.id | [0]" -o tsv)
echo "ORIGINAL_PARENT=$ORIGINAL_PARENT"     # note it down: cleanup moves the subscription back here
az account management-group create --name $MG -o none
az account management-group subscription add --name $MG --subscription $SUB
```

A new management group, or a subscription just moved into one, can take a
few minutes to appear in `az account management-group entities list`. If
scenario I lists no subscriptions, wait and rerun.

## Scenarios

Run them in order: later scenarios build on the state earlier ones leave.
After each run, compare with the expected result and note anything
different. All runs should show coloured output in Cloud Shell.

### A. Visibility mode

```bash
setv MODE '"visibility"'
./read-only.sh
```

Expected:
- `>> Targets (subscription):` listing the test subscription as `onboard`,
  then a progress line for each step, and no optimization approval prompt.
- Reader: `[ok]`. Reservations Reader: either `[ok]`, or `[warning]` with a
  yellow warning block, repeated as "Reservations Reader is missing" in the
  final summary (expected unless you have tenant-level rights).
- Guest insights role created and assigned, with "blob reads limited to
  'lucidity-inventory'". No optimize role.
- `>> Storage accounts: 4`, with no blob setup status (`BLOB_SETUP` is
  `lucidity`):
  - `luctopen…`: `firewall open`
  - `luctuk…` and `lucteast…`: `firewall needs_rule`, each with "will add
    subnet rule …" and "will add ip rule 4.157.111.90"
  - `luctoff…`: `firewall public_access_disabled`
- Prompt `Apply these changes on 2 storage account(s)?`: answer `y`.
  Both accounts become `applied`, or `failed` with Azure's error (record
  it: a failed subnet rule means the cross-tenant subnet rule doesn't work).
- Final status: `completed_with_warnings` (`luctoff…`, and Reservations
  Reader if it failed).

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

Expected: the approval banner says "1 subscription(s)" and lists
"autoscaler, blobs"; after `n`, a red "optimization access not approved.
Nothing was changed." and status `failed` with
`[failed] Optimization mode approval`. No role was changed.

### C. Optimization mode, approved

```bash
./read-only.sh       # answer y
```

Expected:
- Guest insights role: `unchanged` (nothing to add); optimize role:
  "Creating role …".
- Both custom role assignments `[ok]`, each with "blob reads limited to
  'lucidity-inventory'".
- Storage accounts from scenario A: `already_allowed`, no network prompt.
- Status: `completed_with_warnings`.

### D. Rerun, nothing to change

```bash
./read-only.sh       # answer y
```

Expected: both roles `unchanged`, all assignments `[ok]` on the first
attempt (no "retrying" lines), storage accounts `already_allowed`.

### E. Visibility after optimization

```bash
setv MODE '"visibility"'
./read-only.sh
```

Expected: "Optimization features are ignored in visibility mode", then a
yellow **NOTE: Lucidity already has optimization access on …**, and
`[ok] Existing optimization access on …` in the summary. The optimize role
is still assigned (check in [Verify](#verify)).

### F. Updates only add: Run Command off

```bash
setv GUEST_INSIGHTS false
./read-only.sh
az role definition list --name lucidity-guest-insights-role-$SUB --scope /subscriptions/$SUB \
  --query "[0].{description: description, runCommand: contains(permissions[0].actions, 'Microsoft.Compute/virtualMachines/runCommand/action')}"
setv GUEST_INSIGHTS true
```

Expected: the guest role is `unchanged; kept 2 permission(s) this run
didn't ask for (the script never removes permissions)`, and `runCommand` is
still `true`.

### G. No terminal

```bash
setv MODE '"optimization"'
./read-only.sh < /dev/null
```

Expected: "No terminal to ask for approval", nothing changed, status
`failed`, and no colours (output isn't a terminal).

```bash
setv AUTO_APPROVE_OPTIMIZATION true
setv AUTO_APPROVE_STORAGE_CHANGES true
./read-only.sh < /dev/null
setv AUTO_APPROVE_OPTIMIZATION false
setv AUTO_APPROVE_STORAGE_CHANGES false
```

Expected: "Auto-approved" for optimization, run completes
(`completed_with_warnings`).

### H. Invalid settings and no colours

```bash
setv BLOBS yes;  ./read-only.sh; setv BLOBS true
setv MODE '"full"'; ./read-only.sh; setv MODE '"optimization"'
setv SCOPE_TYPE '"tenant"'; ./read-only.sh; setv SCOPE_TYPE '"subscription"'
NO_COLOR=1 ./read-only.sh < /dev/null | head -5
```

Expected: "ERROR: BLOBS must be true or false", "ERROR: MODE must be
optimization or visibility" and "ERROR: SCOPE_TYPE must be subscription or
management_group", each before anything is changed. The last run prints no
colours.

### I. Management group scope

Needs [Setup step 6](#6-test-management-group-optional).

**I1. A subscription with its own roles keeps them.** The test subscription
has subscription-level roles from the scenarios above.

```bash
setv SCOPE_TYPE '"management_group"'
setv SCOPE_IDS "\"$MG\""
./read-only.sh       # answer y
```

Expected:
- `>> Targets (management_group):` listing the test subscription under the
  management group (and any other subscriptions in it).
- "… already has subscription-level Lucidity roles; keeping and updating
  them", and no "Creating role lucidity-…-role-$MG".
- In the report, the subscription has `"rolesAt": "subscription"`.

**I2. A subscription without its own roles gets the management group's.**
Remove the subscription-level roles first (same steps as cleanup):

```bash
az role assignment list --assignee "$SP_OBJECT_ID" --scope "/subscriptions/$SUB" --query "[?starts_with(roleDefinitionName,'lucidity-')].id" -o tsv \
  | xargs -r az role assignment delete --ids
sleep 60
for r in lucidity-guest-insights-role-$SUB lucidity-optimize-role-$SUB; do
  az role definition delete --name "$r" --scope "/subscriptions/$SUB"
done
./read-only.sh       # answer y
```

Expected:
- "Creating role lucidity-guest-insights-role-$MG…" and
  "lucidity-optimize-role-$MG…", once each, then both assigned at
  `/subscriptions/$SUB` with "blob reads limited to 'lucidity-inventory'".
- In the report, `"rolesAt": "management_group"`.
- The roles' assignable scope is the management group:

```bash
az role definition list --name lucidity-guest-insights-role-$MG \
  --scope /providers/Microsoft.Management/managementGroups/$MG --query "[0].assignableScopes"
```

**I3. Skipped and missing scopes.** If the management group has a disabled
or warned subscription, it's listed as `skip, subscription is …` and the
run continues. To check a missing management group:

```bash
setv SCOPE_IDS "\"no-such-mg $MG\""
./read-only.sh       # answer y
setv SCOPE_IDS "\"$MG\""
```

Expected: "management group 'no-such-mg' not found …", the real management
group still onboarded, status `completed_with_errors`, exit code 1
(`echo $?`).

### J. Blob setup by the script

Back at subscription scope. What you see first depends on scenario I:

- **Skipped I (or ran only I1):** the subscription's guest role from the
  earlier `BLOB_SETUP=lucidity` runs still has the container and blob
  service write permissions, so the run highlights them.
- **Ran I2:** the subscription's own roles were deleted, so this run
  creates a new guest role without those two permissions (no NOTE). The
  management group's guest role, still assigned from I2, keeps its own.

```bash
setv SCOPE_TYPE '"subscription"'
setv SCOPE_IDS "\"$SUB\""
setv MODE '"visibility"'
setv BLOB_SETUP '"script"'
./read-only.sh       # answer y at the storage prompt
```

Expected:
- Skipped I: a yellow **NOTE: lucidity-guest-insights-role-… still has
  container and blob service write permissions from an earlier run**, and
  `[ok] Blob setup permissions in …` in the summary. The permissions are
  kept. Ran I2: "Creating role lucidity-guest-insights-role-…" and no NOTE.
- `>> Checking blob setup on …` for each storage account, then each account
  shows both statuses, for example `firewall already_allowed, blob setup
  needs_setup`, with "will create container lucidity-inventory" and "will
  enable last access time tracking". `luctopen…` already has the container
  (from setup step 3), so it only needs tracking.
- `luctoff…` (public access disabled) is still set up: these are management
  operations.
- After `y`, the accounts become `applied`.

Check the result on one account:

```bash
az storage account blob-service-properties show -g $RG -n luctuk$SFX --query lastAccessTimeTrackingPolicy.enable   # expect true
az storage container-rm exists -g $RG --storage-account luctuk$SFX -n lucidity-inventory --query exists             # expect true
```

Rerun: every account shows `blob setup ready` and nothing is planned for
the setup.

**J2. A fresh role without the two permissions.** If you skipped I, remove
the subscription's roles as in I2, then rerun. (If you ran I2, the role
from J is already fresh.) The guest role's actions don't include
`blobServices/write` or `containers/write`, and its description says the
container and tracking are set up by the onboarding script:

```bash
az role definition list --name lucidity-guest-insights-role-$SUB --scope /subscriptions/$SUB \
  --query "[0].{description: description, actions: permissions[0].actions}"
```

Afterwards: `setv BLOB_SETUP '"lucidity"'`.

### K. Finding and creating the service principal

The script normally finds Lucidity's service principal from Lucidity's
application ID. To test that without involving Lucidity's real one, point
`LUCIDITY_APP_ID` at the test app. Run this scenario last: K3 deletes and
recreates the test service principal.

**K1. Found from the application ID.**

```bash
setv LUCIDITY_APP_ID "\"$APP_ID\""
setv SP_OBJECT_ID '""'
./read-only.sh       # answer y
```

Expected: `>> Resolving Lucidity's service principal...`, then "Service
principal object ID:" showing `$SP_OBJECT_ID`, and
`[ok] Lucidity service principal` with "found from Lucidity's application
ID".

**K2. A wrong object ID falls back to the lookup.**

```bash
setv SP_OBJECT_ID '"00000000-0000-0000-0000-000000000000"'
./read-only.sh       # answer y
setv SP_OBJECT_ID '""'
```

Expected: a yellow "SP_OBJECT_ID … doesn't exist in this tenant" warning,
then the same object ID as K1.

**K3. Created when it's missing.** Deleting the service principal keeps its
app registration (and the secret in `sp.json`), so the script can create it
again:

```bash
OLD_SP_OBJECT_ID=$SP_OBJECT_ID
az ad sp delete --id "$APP_ID"
sleep 30
./read-only.sh       # answer y
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv); echo "$SP_OBJECT_ID"
```

Expected: "Lucidity's service principal isn't in this tenant yet; creating
it...", a new object ID (different from `$OLD_SP_OBJECT_ID`), and the role
assignments made to it, possibly after a few "retrying" lines while Azure
catches up with the new service principal.

The assignments to the old object ID stay behind with an unknown
principal; [cleanup](#cleanup) removes them too.

Afterwards, put the defaults back:
`setv LUCIDITY_APP_ID '"4f2c2c1f-372a-4904-b13d-11e2467679f2"'` and
`setv SP_OBJECT_ID "\"$SP_OBJECT_ID\""`.

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
  jq -c '{file: input_filename, scopeType, mode, blobSetup, status, reservationsReader,
    subscriptions: [.subscriptions[] | "\(.subscriptionId) \(.status) \(.result // "") \(.rolesAt // "")"]}' "$f"
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
# Remove every assignment of the test service principal (and of the old one,
# if you ran K3), by ID. Filtering by principal ID also finds assignments
# whose service principal was deleted.
for scope in "/subscriptions/$SUB" "/providers/Microsoft.Capacity"; do
  az role assignment list --scope "$scope" \
    --query "[?principalId=='$SP_OBJECT_ID' || principalId=='${OLD_SP_OBJECT_ID:-none}'].id" -o tsv \
    | xargs -r az role assignment delete --ids
done
az role assignment list --scope "/subscriptions/$SUB" \
  --query "[?principalId=='$SP_OBJECT_ID' || principalId=='${OLD_SP_OBJECT_ID:-none}']" -o table   # expect empty

sleep 60   # role deletion fails until Azure catches up with the assignment deletes
for r in lucidity-guest-insights-role-$SUB lucidity-optimize-role-$SUB; do
  az role definition delete --name "$r" --scope "/subscriptions/$SUB"
done
# Only if you ran scenario I
for r in lucidity-guest-insights-role-$MG lucidity-optimize-role-$MG; do
  az role definition delete --name "$r" --scope "/providers/Microsoft.Management/managementGroups/$MG"
done

az group delete -n $RG --yes --no-wait
az ad app delete --id "$APP_ID"    # deletes the app registration and its service principal
rm -f sp.json t.txt lucidity-onboarding-report-*.json
```

If you created the test management group in Setup step 6, move the
subscription back and delete the group:

```bash
az account management-group subscription add --name "${ORIGINAL_PARENT##*/}" --subscription $SUB
az account management-group delete --name $MG
```

- If a role delete returns `RoleDefinitionHasAssignments`, wait another
  minute and rerun the loop. If it persists, list who still holds the role
  (`az role assignment list --role <name> --scope /subscriptions/$SUB`); stop
  if it's anything other than the test service principal.
- Delete only the roles above. The test subscription may hold other
  `lucidity-*` roles from earlier onboarding versions.

## Test log

Record each real-Azure test run here.

| Date | Script commit | Tester | Scenarios | Result |
|---|---|---|---|---|
| 2026-10-22 | `475addc` and earlier | Swapnesh | Optimization (before modes and scopes existed): roles, rerun, condition, blob-read limit, Reservations Reader warning, IP rule, network prompt, report | Passed. Found and fixed: Reservations Reader role ID not recognized by `az`, no progress output |
