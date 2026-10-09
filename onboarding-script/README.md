# Lucidity Azure assessment onboarding

`read-only.sh` version **2.2.0** performs the Lucidity assessment onboarding
workflow for an Azure management group. It supports a controlled pilot against
one child subscription before wider rollout. It is designed for Azure Cloud
Shell using Bash and is safe to rerun after a network interruption.

## What it does

1. Validates the target management group and enumerates all child subscriptions.
2. Checks for Lucidity's enterprise application in the customer tenant.
   - Existing: validates and reuses it.
   - Missing: creates it from Lucidity's existing multi-tenant app registration.
3. Checks for the `LUCIDITY_PLATFORM` custom role.
   - Compliant: reuses it without modification.
   - Missing permissions: merges them while retaining the role ID and existing permissions.
   - Missing role: creates it at management-group scope.
4. Assigns the role to the Lucidity service principal on either one selected
   child subscription or every child subscription beneath the management group.
5. Restricts Blob data read to the `lucidity-inventory` container using ABAC.
6. Skips subscriptions that already have the correct assignment and condition.

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
- **Role Based Access Control Administrator** and **Reader** at the target management group.

It must also be able to read service principals in Microsoft Entra ID. If the
Lucidity enterprise application is missing, it must be permitted to create it.
If tenant policy prevents this, an Entra administrator can create it once and
the script can then be rerun.

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
  --subscription <TEST_SUBSCRIPTION_ID> \
  --role-name <CUSTOM_ROLE_NAME>
```

The script verifies that the selected subscription is a child of the management
group. After reviewing the plan, apply it only to that subscription:

```bash
./read-only.sh --management-group <MANAGEMENT_GROUP_ID> \
  --subscription <TEST_SUBSCRIPTION_ID> \
  --role-name <CUSTOM_ROLE_NAME> \
  --execute
```

### Roll out to all remaining subscriptions

After the pilot is validated, preview the management-group rollout:

```bash
./read-only.sh --management-group <MANAGEMENT_GROUP_ID> \
  --role-name <CUSTOM_ROLE_NAME>
```

Review the tenant, management group, subscription count, enterprise-application
status and custom-role status. Then execute:

```bash
./read-only.sh --management-group <MANAGEMENT_GROUP_ID> \
  --role-name <CUSTOM_ROLE_NAME> \
  --execute
```

The successful pilot assignment is detected as compliant and skipped.

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
Customers can review the embedded `ACTIONS` and `DATA_ACTIONS` arrays in the
script if their security process requires the exact permission manifest.
