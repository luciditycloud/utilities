# Testing read-only.sh

How to test [`read-only.sh`](read-only.sh) end to end in a test Azure
tenant. Run through it after every change to the script, and update this
guide alongside the [README](README.md) and [maintaining.md](maintaining.md)
whenever the script changes.

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
- **Azure Cloud Shell in Bash mode** (not PowerShell). It has `az`, `jq`,
  `curl` and `setsid`.
- The version of `read-only.sh` you want to test.

Keep the same Cloud Shell session for the whole test: the steps share shell
variables. If the session restarts, redo [Setup step 1](#1-variables),
reload the service principal details from `sp.json`
([step 2](#2-throwaway-service-principal)) and redefine `run`
([step 5](#5-point-the-script-at-the-test-service-principal)).

**Never run the script without `--scope-ids` and answer `y`, except as
[scenario L](#l-all-subscriptions-and-exclusions) describes.** Without
`--scope-ids` it targets every subscription you can access in the tenant.

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
BRANCH=<branch>
curl -fsSLo read-only.sh https://raw.githubusercontent.com/luciditycloud/utilities/refs/heads/$BRANCH/onboarding-script/read-only.sh
bash read-only.sh --help | head -1     # shows the script version
```

### 5. Point the script at the test service principal

Two settings have no option, so they're edited in the file. `setv` changes
one setting in place and prints the result:

```bash
setv() { sed -i "s|^$1=.*|$1=$2|" read-only.sh; grep "^$1=" read-only.sh; }

setv SP_OBJECT_ID "\"$SP_OBJECT_ID\""
setv STORAGE_ACCOUNTS "\"luctopen$SFX luctuk$SFX lucteast$SFX luctoff$SFX\""
```

- `SP_OBJECT_ID` makes the script use the test service principal. Always
  keep it set (or, in scenario K, `LUCIDITY_APP_ID` set to the test app).
  With both left as shipped, the script looks up **Lucidity's real**
  service principal, creates it in the test tenant if needed, and gives it
  the roles.
- `STORAGE_ACCOUNTS` keeps the storage check to the test accounts, so the
  script never touches other storage accounts in the subscription.

Re-uploading or re-downloading the script resets both: redo this step
afterwards.

Most scenarios run the script on the test subscription. `run` does that,
passing any further options:

```bash
run() { bash read-only.sh --scope-ids "$SUB" "$@"; }
```

### 6. Test management group (optional)

Only for [scenario I](#i-management-group-scope). Skip this if you already
have a test management group with only test subscriptions in it; set
`MG=<its ID>` instead.

Moving a subscription into a management group changes which policies and
role assignments it inherits. The commands below create the test group
**under the subscription's current parent**, so the subscription still
inherits everything it does today, and move the subscription back during
cleanup. Still, only do this with a test subscription: if other people use
it, tell them first.

```bash
MG=lucidity-test-mg-$SFX
ORIGINAL_PARENT=$(az account management-group entities list \
  --query "[?name=='$SUB'].parent.id | [0]" -o tsv)
echo "ORIGINAL_PARENT=$ORIGINAL_PARENT"     # note it down: cleanup moves the subscription back here
az account management-group create --name $MG --parent "$ORIGINAL_PARENT" -o none
az account management-group subscription add --name $MG --subscription $SUB
```

Creating a management group needs permission on the parent (for example
Management Group Contributor). The creator becomes Owner of the new group,
which is what the script needs to create roles at it.

A new management group, or a subscription just moved into one, can take a
few minutes to appear in `az account management-group entities list`. If
scenario I lists no subscriptions, wait and rerun.

## Scenarios

Run them in order: later scenarios build on the state earlier ones leave.
After each run, compare with the expected result and note anything
different. All runs should show coloured output in Cloud Shell, and start
with `>> Lucidity onboarding script, version …`.

### A. Visibility mode

```bash
run --mode visibility
```

Expected:
- `>> Targets (subscription):` listing the test subscription as `onboard`,
  and no approval prompt.
- `>> Resolving Lucidity's service principal...` with the test service
  principal's object ID, then a progress line for each step.
- Reader: `[ok]`. Reservations Reader: either `[ok]`, or `[warning]` with a
  yellow warning block, repeated as "Reservations Reader is missing" in the
  final summary (expected unless you have tenant-level rights).
- Guest insights role created and assigned, with "blob reads limited to
  'lucidity-inventory'". No optimize role.
- `>> Storage accounts: 4`, then a note on which firewall rules go where
  (the IP rule on every firewalled account; the subnet rule where
  Lucidity's service endpoint reaches: `eastus westus westus3`), and no blob
  setup status (blob setup is `lucidity`):
  - `luctopen…`: `firewall open`
  - `lucteast…` (East US): `firewall needs_rule`, with "will add subnet
    rule …" and "will add ip rule 4.157.111.90"
  - `luctuk…` (UK South): `firewall needs_rule (IP rule only: uksouth is
    outside the subnet endpoint's regions)`, with only "will add ip rule
    4.157.111.90"
  - `luctoff…`: `firewall public_access_disabled`
- Prompt `Apply these changes on 2 storage account(s)?`: answer `y`.
  Both accounts become `applied`. A `failed` on `lucteast…` means the
  subnet rule didn't work: record Azure's error.
- Final status: `completed_with_warnings` (`luctoff…`, and Reservations
  Reader if it failed).

Then check the rules (both accounts):

```bash
for a in luctuk$SFX lucteast$SFX; do
  az storage account network-rule list -g $RG --account-name $a \
    --query "{ip: ipRules[].ipAddressOrRange, subnet: virtualNetworkRules[].{id: virtualNetworkResourceId, state: state}}"
done
```

Expected: `lucteast…` has the IP `4.157.111.90` and Lucidity's subnet with
state `Succeeded`; `luctuk…` has the IP and **no** subnet rule.

Rerun the same command: both accounts are `already_allowed` (`luctuk…`
still with the "IP rule only" note), the summary shows no storage account
needing attention beyond `luctoff…`, and there is **no** storage prompt.

**A note on the subnet rule.** Lucidity's subnet is in a different
subscription from the test subscription, but in the **same tenant** as the
test subscription when you use Lucidity's AKS subscription as the shipped
script does (confirmed 2026-10-24). So this tests a cross-subscription
rule, not a cross-tenant one. To test cross-tenant, use a test tenant
different from the one that owns `LUCIDITY_SUBNET_IDS`, or point
`LUCIDITY_SUBNET_IDS` at a subnet in another tenant that has a
`Microsoft.Storage` service endpoint.

### B. Optimization mode, declined

```bash
run       # answer n
```

Expected: the approval banner says "1 subscription(s)" and lists
"autoscaler, blobs"; after `n`, a red "not approved. Nothing was changed."
with "Approve at the prompt, or rerun with --mode visibility.", and status
`failed` with `[failed] Optimization mode approval`. No role was changed,
and the run didn't get as far as resolving the service principal.

### C. Optimization mode, approved

```bash
run       # answer y
```

Expected:
- Guest insights role: `unchanged` (nothing to add); optimize role:
  "Creating role …".
- Both custom role assignments `[ok]`, each with "blob reads limited to
  'lucidity-inventory'".
- Storage accounts from scenario A: `already_allowed`, no storage prompt.
- Status: `completed_with_warnings`.

### D. Rerun, nothing to change

```bash
run       # answer y
```

Expected: both roles `unchanged`, all assignments `[ok]` on the first
attempt (no "retrying" lines), storage accounts `already_allowed`.

### E. Visibility after optimization

```bash
run --mode visibility --features autoscaler
```

Expected: "--features applies to optimization mode only, so it's ignored.",
then a yellow **NOTE: Lucidity already has optimization access on …**, and
`[ok] Existing optimization access on …` in the summary. The optimize role
is still assigned (check in [Verify](#verify)).

### F. Updates only add: Run Command off

```bash
run --mode visibility --no-guest-insights
az role definition list --name lucidity-guest-insights-role-$SUB --scope /subscriptions/$SUB \
  --query "[0].{description: description, runCommand: contains(permissions[0].actions, 'Microsoft.Compute/virtualMachines/runCommand/action')}"
```

Expected: the guest role is `unchanged; kept 2 permission(s) this run
didn't ask for (the script never removes permissions)`, and `runCommand` is
still `true`.

### G. Prompts without a terminal on stdin

**G1. stdin redirected, terminal still there.** The prompt is read from the
terminal instead:

```bash
run < /dev/null       # answer n
```

Expected: the `Grant optimization access? [y/N]` prompt still appears and
takes your answer.

**G2. No terminal at all.** `setsid` detaches the run from the terminal;
`| cat` makes the output a pipe:

```bash
setsid -w bash read-only.sh --scope-ids "$SUB" < /dev/null 2>&1 | cat
```

Expected: "No terminal to ask for approval.", then "Rerun in a terminal,
or add --auto-approve …", nothing changed, status `failed`, and no colours.

```bash
setsid -w bash read-only.sh --scope-ids "$SUB" --auto-approve < /dev/null 2>&1 | cat
```

Expected: "Auto-approved (--auto-approve)." for optimization, run completes
(`completed_with_warnings`), and the report has `"autoApprove": true`.

### H. Invalid options

```bash
run --features autoscaler,foo
run --mode full
run --scope-type tenant
run --mode=visibility --bogus
bash read-only.sh --scope-ids
bash read-only.sh --scope-type management_group
```

Expected, each before anything is changed and followed by the usage text
(exit code 2, `echo $?`):
- "unknown feature in --features: 'foo' …"
- "--mode must be optimization or visibility. Got: 'full'"
- "--scope-type must be subscription or management_group. Got: 'tenant'"
- "unknown option: --bogus"
- "--scope-ids needs a value."
- "--scope-type management_group needs --scope-ids …"

Then check that the usage lists only the access and permission scope
options, and `--help` adds "Other options":

```bash
bash read-only.sh --help
```

### I. Management group scope

Needs [Setup step 6](#6-test-management-group-optional).

**I1. A subscription with its own roles keeps them.** The test subscription
has subscription-level roles from the scenarios above.

```bash
bash read-only.sh --scope-type management_group --scope-ids "$MG"    # answer y
```

Expected:
- `>> Targets (management_group):` listing the test subscription under the
  management group (and any other subscriptions in it).
- "… already has subscription-level Lucidity roles; keeping and updating
  them", and no "Creating role lucidity-…-role-$MG".
- In the report, the subscription has `"rolesAt": "subscription"`.

**I2. A subscription without its own roles gets the management group's.**
Remove the subscription-level roles first (same steps as cleanup). Filter
by principal ID: assignments of a deleted service principal (for example
`OLD_SP_OBJECT_ID` after K3) have no name to match.

```bash
for p in "$SP_OBJECT_ID" "${OLD_SP_OBJECT_ID:-none}"; do
  az role assignment list --scope "/subscriptions/$SUB" \
    --query "[?principalId=='$p'].id" -o tsv | xargs -r az role assignment delete --ids
done
sleep 60
for r in lucidity-guest-insights-role-$SUB lucidity-optimize-role-$SUB; do
  az role definition delete --name "$r" --scope "/subscriptions/$SUB"
done
```

Azure's role listings lag behind deletes, sometimes by several minutes.
Wait until this prints nothing before going on; if the roles still show,
wait and rerun the deletes. Running the script too early can make it
believe the subscription still has its own roles.

```bash
az role definition list --custom-role-only true --scope "/subscriptions/$SUB" \
  --query "[?starts_with(roleName,'lucidity-guest-insights-role-$SUB') || starts_with(roleName,'lucidity-optimize-role-$SUB')].roleName" -o tsv
bash read-only.sh --scope-type management_group --scope-ids "$MG"    # answer y
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
bash read-only.sh --scope-type management_group --scope-ids "no-such-mg,$MG"   # answer y
```

Expected: "management group 'no-such-mg' not found …", the real management
group still onboarded, status `completed_with_errors`, exit code 1
(`echo $?`).

Run this some minutes after I2, once the role listings have settled. On
2026-10-24 it was run too soon after deleting the subscription's roles: the
script created a new subscription-level guest role but assigned the *deleted*
role's ID, which it had looked up by name, and failed with
`RoleDefinitionDoesNotExist`. The script now takes the ID from the creation
command's own output.

**I4. Excluding a subscription under the group.** If the test subscription
is the only one in the group, nothing is left to onboard:

```bash
bash read-only.sh --scope-type management_group --scope-ids "$MG" --exclude-ids "$SUB"
```

Expected: the test subscription listed as `skip, excluded by
--exclude-ids`, then "ERROR: no subscriptions to onboard." and status
`failed`, with nothing changed. With other subscriptions in the group, they
are onboarded and the test subscription isn't (answer `n` to stop instead).

### J. Blob setup by the script

Back at subscription scope. What you see first depends on scenario I:

- **Skipped I (or ran only I1):** the subscription's guest role from the
  earlier `--blob-setup lucidity` runs still has the container and blob
  service write permissions, so the run highlights them.
- **Ran I2:** the subscription's own roles were deleted, so this run
  creates a new guest role without those two permissions (no NOTE). The
  management group's guest role, still assigned from I2, keeps its own.

```bash
run --mode visibility --blob-setup script      # answer y at the storage prompt
```

Expected:
- Skipped I: a yellow **NOTE: lucidity-guest-insights-role-… still has
  container and blob service write permissions from an earlier run.
  --blob-setup script does not remove them**, and
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

### K. Finding and creating the service principal

The script normally finds Lucidity's service principal from Lucidity's
application ID. To test that without involving Lucidity's real one, point
`LUCIDITY_APP_ID` at the test app. Run this after A–J: K3 deletes and
recreates the test service principal.

**K1. Found from the application ID.**

```bash
setv LUCIDITY_APP_ID "\"$APP_ID\""
setv SP_OBJECT_ID '""'
run       # answer y
```

Expected: `>> Resolving Lucidity's service principal...`, then "Service
principal object ID:" showing `$SP_OBJECT_ID`, and
`[ok] Lucidity service principal` with "found from Lucidity's application
ID".

**K2. A wrong object ID falls back to the lookup.**

```bash
setv SP_OBJECT_ID '"00000000-0000-0000-0000-000000000000"'
run       # answer y
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
run       # answer y
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

### L. All subscriptions and exclusions

Without `--scope-ids` the script targets every subscription you can access
in the tenant. To test that without touching other subscriptions, exclude
all of them. A made-up ID is excluded too, to check the typo warning.

```bash
OTHERS=$(az account list --query "[?tenantId=='$(az account show --query tenantId -o tsv)' && id!='$SUB'].id" -o tsv | paste -sd,)
echo "excluding: ${OTHERS:-none}"
bash read-only.sh --mode visibility --exclude-ids "${OTHERS:+$OTHERS,}no-such-sub"
```

Expected:
- `>> Targets: every subscription you can access in tenant …`, with the
  test subscription as `onboard` and every other one as `skip, excluded by
  --exclude-ids` (or `skip, subscription is …` if it isn't enabled).
- A yellow warning: "--exclude-ids: 'no-such-sub' matched no target
  subscription …".
- "No --scope-ids given, so this onboards every subscription listed
  above." and `Onboard these 1 subscription(s)? [y/N]`. Check the list
  shows only the test subscription as `onboard`, then answer `y`.
- The run continues as in A's rerun. In the report: `"allSubscriptions":
  true`, the `excludeIds`, the other subscriptions with status `excluded`,
  and the options under `arguments`.

In optimization mode the same confirmation is folded into the optimization
question:

```bash
bash read-only.sh --exclude-ids "${OTHERS:+$OTHERS,}no-such-sub"      # answer n
```

Expected: `Grant optimization access on these 1 subscription(s)? [y/N]`,
and after `n`, nothing changed.

A management group ID given as a subscription:

```bash
run --scope-ids "$SUB,${MG:-some-mg}" --mode visibility
```

Expected: the second ID as `skip, not found …`, and a warning "some
subscriptions weren't found. If those are management group IDs, rerun with
--scope-type management_group." The test subscription is still onboarded.

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
  jq -c '{file: input_filename, scriptVersion, arguments, mode, blobSetup, status, reservationsReader,
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

Record each real-Azure test run here. Runs before 2026-10-28 edited the
settings in the file; the scenarios are otherwise the same.

| Date | Script commit | Tester | Scenarios | Result |
|---|---|---|---|---|
| 2026-10-22 | `475addc` and earlier | Swapnesh | Optimization (before modes and scopes existed): roles, rerun, condition, blob-read limit, Reservations Reader warning, IP rule, network prompt, report | Passed. Found and fixed: Reservations Reader role ID not recognized by `az`, no progress output |
| 2026-10-24 | `3d44c68` | Swapnesh | A (visibility), B (optimization declined), C (approved), rerun over existing assignments, E (leftover optimization access), blob-read limit as the service principal; given `SP_OBJECT_ID` only | Passed, except: Azure rejects a subnet rule on a storage account outside East US, West US and West US 3 (UK South tried), so that account showed `failed` and was offered again on every run. Fixed with `LUCIDITY_SUBNET_REGIONS` (retested in the next row) |
| 2026-10-24 | `3fd3325` | Swapnesh | Storage step retest (IP rule only outside the subnet regions, no prompt on rerun); K1 (service principal found from the application ID, using a test app); K3 (created when missing); J (`BLOB_SETUP=script` on 4 accounts, including one with public access disabled; rerun clean); I1 (management group: subscription's own roles kept); I2 (role created at the group with data actions, assigned on the subscription with the condition); I3 (missing group: `completed_with_errors`, exit 1) | Passed, except: after deleting a role and recreating it within minutes, the script assigned the deleted role's ID (looked up by name from a lagging listing) and failed with `RoleDefinitionDoesNotExist`. Fixed by using the ID from the creation command; not retested in real Azure (the stale case is hard to reproduce). Subnet rule tested within one tenant only. Not run: cross-tenant subnet rule, several subscriptions or nested groups, `GUEST_INSIGHTS=false`, add-only updates that add permissions, no-terminal runs |
