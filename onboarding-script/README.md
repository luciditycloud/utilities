# Lucidity Azure assessment onboarding

`read-only.sh` version **2.2.0** performs the Lucidity assessment onboarding
workflow for an Azure management group. It supports a controlled pilot against
one child subscription before wider rollout. It is designed for Azure Cloud
Shell using Bash and is safe to rerun after a network interruption.

To remove Lucidity again, use [`teardown.sh`](#removing-lucidity-teardownsh).

## What it does

1. Validates the target management group and enumerates all child subscriptions.
2. Checks for Lucidity's enterprise application in the customer tenant.
   - Existing: validates and reuses it.
   - Missing: creates it from Lucidity's existing multi-tenant app registration.
3. Checks for the `LUCIDITY_PLATFORM` custom role.
   - Compliant: reuses it without modification.
   - Missing permissions or a different assignable scope: updates it in place,
     keeping the role ID and existing permissions. Its description is replaced
     and its assignable scope is set to this management group only.
   - Missing role: creates it at management-group scope.
   - If Lucidity holds a direct assignment of the role at management-group
     scope, that assignment is removed (it can't work there, see below). If
     another principal holds one, the script stops without changing anything.
4. Assigns the role to the Lucidity service principal on either one selected
   child subscription or every child subscription beneath the management group.
5. Restricts Blob data read to the `lucidity-inventory` container using ABAC.
6. Skips subscriptions that already have the correct assignment and condition.

The script does **not** create the `lucidity-inventory` container or turn on
Last Access Time tracking itself. Lucidity's service principal does that later,
using the storage write permissions in the role (see
[Important permission note](#important-permission-note)).

## Why assignments are per subscription

The role includes this Blob data-plane permission:

```text
Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read
```

Azure permits the custom role definition to use the management group as its
assignable scope, but a role containing `DataActions` cannot be assigned
directly at management-group scope. The script keeps the role definition at
the management group and creates an assignment on each child subscription.

## Required access

The executing identity requires either:

- **Owner** at the target management group; or
- **User Access Administrator** at the target management group.

**Role Based Access Control Administrator** is not sufficient: it can manage
role assignments but cannot create or update the custom role definition.

It must also be able to read service principals in Microsoft Entra ID. If the
Lucidity enterprise application is missing, it must be permitted to create it.
If tenant policy prevents this, an Entra administrator can create it once and
the script can then be rerun.

## Requirements

- **Bash 4 or later** and **`jq`**. Azure Cloud Shell has both. macOS's
  built-in `/bin/bash` (3.2) cannot run the script.
- An Azure CLI session that is already logged in. The script does not run
  `az login` for you.
- Before running, set the CLI's default subscription to one **under the target
  management group** (`az account set --subscription <id>`). The script looks
  up an existing custom role relative to that subscription; otherwise it may
  not find the role and then fail to create a duplicate.

## Run from Azure Cloud Shell

Select **Bash**, upload `read-only.sh`, and run:

```bash
chmod +x read-only.sh
```

Confirm that the expected version is being used:

```bash
./read-only.sh --version
```

Expected output:

```text
read-only.sh 2.2.0
```

### Pilot one subscription

Preview the pilot first; this performs read-only validation and makes no changes:

```bash
./read-only.sh --management-group <MANAGEMENT_GROUP_ID> \
  --subscription <TEST_SUBSCRIPTION_ID>
```

The script verifies that the selected subscription is a child of the management
group. After reviewing the plan, apply it only to that subscription:

```bash
./read-only.sh --management-group <MANAGEMENT_GROUP_ID> \
  --subscription <TEST_SUBSCRIPTION_ID> \
  --execute
```

### Roll out to all remaining subscriptions

After the pilot is validated, preview the management-group rollout:

```bash
./read-only.sh --management-group <MANAGEMENT_GROUP_ID>
```

Review the tenant, management group, subscription count, enterprise-application
status and custom-role status. Then execute:

```bash
./read-only.sh --management-group <MANAGEMENT_GROUP_ID> --execute
```

The successful pilot assignment is detected as compliant and skipped.

### Custom role name (`--role-name`)

The role is named `LUCIDITY_PLATFORM` unless you pass `--role-name`. If you
use it, pass the **same** value on every run — pilot, rollout and any `--yes`
run — or the script will create or modify a different role.

Custom role names are unique across the whole tenant. To onboard a **second
management group in the same tenant**, give it its own `--role-name`. Reusing
the first group's role name would move that role's assignable scope to the new
management group.

The script asks for confirmation. Use `--yes` only for an approved unattended run:

```bash
./read-only.sh --management-group <MANAGEMENT_GROUP_ID> --execute --yes
```

## Options

| Option | Purpose |
|---|---|
| `-m`, `--management-group <id>` | Target management group; required |
| `-s`, `--subscription <id>` | Limit preview/execution to one child subscription |
| `-r`, `--role-name <name>` | Override `LUCIDITY_PLATFORM` |
| `-a`, `--app-id <id>` | Override the Lucidity application ID |
| `--network-audit` | Read-only audit of Lucidity Blob network rules |
| `--network-config` | Preview or configure Lucidity Blob network rules |
| `--execute` | Apply the displayed plan |
| `-y`, `--yes` | Skip the execute confirmation |
| `-h`, `--help` | Display usage |
| `--version` | Display the script version |

## Blob network audit and configuration

The network modes are isolated from the identity and RBAC onboarding workflow.
They do not create or update the enterprise application, custom role or role
assignments.

The required Lucidity Blob collection paths are:

```text
Collector egress IP: 4.157.111.90
Backend subnet: /subscriptions/3511ac94-c2ef-4644-8147-55f5f9a27a9e/resourceGroups/azurepls-rg/providers/Microsoft.Network/virtualNetworks/azurepls-vnet/subnets/aks-subnet
```

Audit one pilot subscription without making changes:

```bash
./read-only.sh --management-group <MANAGEMENT_GROUP_ID> \
  --subscription <TEST_SUBSCRIPTION_ID> \
  --network-audit
```

Audit every storage account beneath the management group:

```bash
./read-only.sh --management-group <MANAGEMENT_GROUP_ID> --network-audit
```

Preview the required changes across the management group:

```bash
./read-only.sh --management-group <MANAGEMENT_GROUP_ID> --network-config
```

Apply the required rules after reviewing the preview:

```bash
./read-only.sh --management-group <MANAGEMENT_GROUP_ID> \
  --network-config --execute
```

The configuration workflow adds only missing Lucidity IP and subnet rules. It
does not remove existing rules or change the storage firewall default action.
On accounts whose default action is already `Allow`, the firewall is open and
the added rules have no effect.
Storage accounts with public network access disabled are skipped and reported
for manual review. Each changed account is re-read and verified.

`--network-audit` is always read-only and rejects `--execute`.

Network configuration requires permission to update storage accounts, such as
Owner, Contributor or Storage Account Contributor. Role Based Access Control
Administrator plus Reader is not sufficient for `--network-config`.

## Safe reruns

The script is idempotent:

- Existing enterprise application: reused
- Compliant custom role: reused
- Existing role missing permissions: updated in place
- Correct subscription assignment: skipped
- Existing assignment without the required condition: replaced
- `RoleAssignmentExists` after a network interruption: treated as completed
- Transient assignment lookup or creation errors: retried
- Pilot subscription outside the selected management group: rejected without changes

The final summary reports created, replaced, skipped and failed subscription
assignments. If interrupted, rerun the same `--execute` command.

## Expected plan output

```text
==============================================================
Lucidity Azure assessment onboarding plan
  Script version       : 2.2.0
  Tenant              : <tenant-id>
  Signed in as         : <operator>
  Management group    : <management-group-id>
  Selection mode      : SINGLE-SUBSCRIPTION PILOT
  MG child subscriptions: 384
  Selected subscriptions: 1
  Pilot subscription  : <subscription-id>
  Enterprise app      : EXISTS - will validate and reuse
  Custom role         : LUCIDITY_PLATFORM
  Role status         : EXISTS - permissions and scope are compliant
  Role assignment     : subscription-level fan-out
  Blob read condition : container 'lucidity-inventory' only
  Permission profile  : discovery reads + Run Command + storage enablement
  Mode                : PLAN-ONLY
==============================================================
```

During execution, each subscription receives an explicit result such as:

```text
Assignment already compliant; skipped.
```

or:

```text
Assigned with Blob read restricted to 'lucidity-inventory'.
```

## Important permission note

The role is predominantly read-only, but it is not a literally read-only Azure
role. Its permissions comprise:

- Discovery and query reads
- Run Command collection actions
- Storage enablement actions
- Blob data-plane read

The storage actions support creation of the `lucidity-inventory` container,
Blob service configuration and inventory-policy management. Blob data-plane
read is restricted to that container by the condition on each role assignment.
The Run Command actions let Lucidity execute scripts inside VMs and scale-set
instances.
Customers can review the embedded `ACTIONS` and `DATA_ACTIONS` arrays in the
script if their security process requires the exact permission manifest.

## Troubleshooting

- **"Cannot read management group" / "No child subscriptions found"** — the
  identity needs Reader (or better) at the management group itself, and the ID
  must be the management group's ID, not its display name.
- **"Found multiple custom roles named ..."** — more than one custom role with
  that name is visible; pass an unambiguous `--role-name`.
- **Role creation fails with a duplicate-name error** — a role with that name
  already exists elsewhere in the tenant but wasn't found. Set the CLI's
  default subscription to one under the target management group (see
  [Requirements](#requirements)) and rerun, or use a different `--role-name`.
- **"The existing role has a direct MG assignment for another principal"** —
  someone else is using the role at management-group scope. Remove that
  assignment or use a different `--role-name`.
- **"Enterprise application creation failed"** — your identity can't create
  service principals. Ask an Entra administrator to create it once
  (`az ad sp create --id <app-id>`), then rerun.
- **A subscription reports `FAILED`** — the printed error is the Azure CLI's
  own. Rerun the same `--execute` command; completed subscriptions are skipped.

## Upgrading from version 1

Version 1 created per-scope roles named `lucidity-permissions-readonly-*`.
Version 2 does not detect or remove them, so a customer who ran version 1 will
have both roles assigned. `teardown.sh` removes them along with everything
else; to remove only the old roles, delete their assignments and definitions
manually.

## Removing Lucidity (`teardown.sh`)

`teardown.sh` reverses onboarding. Like `read-only.sh` it only prints a plan
unless you add `--execute`, and asks for confirmation unless you add `--yes`.
By default it removes, in this order:

1. Every role assignment held by Lucidity's service principal on the target
   subscriptions (and directly on the management group with `-m`).
2. The custom roles: `LUCIDITY_PLATFORM` (or `--role-name`) and version 1
   `lucidity-permissions-readonly-*` roles. A role is deleted only if every
   scope it can be assigned at is being torn down.
3. The Lucidity collector IP and subnet firewall rules added by
   `--network-config`.
4. Blob inventory rules named `lucidity-blob-inventory-policy`, or writing into
   `lucidity-inventory`. If no other rules remain, the whole policy is deleted.
5. The `lucidity-inventory` container in every storage account, including the
   reports in it.
6. Last Access Time tracking — **only** on the accounts you name with
   `--lat-accounts` or `--lat-file`. The script can't tell whether Lucidity or
   you turned it on, and your own lifecycle rules may depend on it.
7. Lucidity's enterprise application. This removes Lucidity from the **whole
   tenant**, so it is the default with `-m` and off with `-s` (override with
   `--delete-app` / `--keep-app`). It is skipped if any assignment or role
   removal failed, so that no orphaned assignments are left behind.

Preview a full teardown of a management group, then apply it:

```bash
chmod +x teardown.sh
./teardown.sh --management-group <MANAGEMENT_GROUP_ID>
./teardown.sh --management-group <MANAGEMENT_GROUP_ID> --execute
```

Other examples:

```bash
# Specific subscriptions only (keeps MG-homed roles and the enterprise app).
./teardown.sh --subscription "<SUB_ID_1>,<SUB_ID_2>" --execute

# Also turn off LAT on accounts Lucidity enabled it on.
./teardown.sh --management-group <MANAGEMENT_GROUP_ID> \
  --lat-file accounts.txt --execute

# Revoke access only; leave storage and firewall changes in place.
./teardown.sh --management-group <MANAGEMENT_GROUP_ID> \
  --skip-network --skip-storage --keep-app --execute
```

| Option | Purpose |
|---|---|
| `-m`, `--management-group <id>` | Tear down every child subscription, plus MG-level assignments and roles |
| `-s`, `--subscription <ids>` | Tear down only these subscriptions (comma- or space-separated) |
| `--skip-access` | Keep role assignments and custom roles |
| `--skip-legacy` | Ignore version 1 roles |
| `--skip-network` | Keep the Lucidity firewall rules |
| `--skip-storage` | Keep inventory rules, containers and LAT |
| `--lat-accounts "<names>"` / `--lat-file <file>` | Also turn off LAT on these storage accounts |
| `--keep-app` / `--delete-app` | Override the enterprise-application default |
| `-r`, `--role-name <name>` | Role name used at onboarding (default `LUCIDITY_PLATFORM`) |
| `-a`, `--app-id <id>` | Override the Lucidity application ID |
| `--legacy-prefix <prefix>` | Version 1 role-name prefix |
| `--execute` | Apply the plan |
| `-y`, `--yes` | Skip the confirmation |
| `--version`, `-h`, `--help` | Version / usage |

Required access: Owner (or User Access Administrator plus a storage role such
as Storage Account Contributor) on the target scope, and, to delete the
enterprise application, an Entra role such as Cloud Application Administrator.
Container deletion is permanent unless container soft-delete is enabled on the
storage account. Teardown is safe to rerun: anything already removed is simply
not found again.
