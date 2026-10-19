# read-only.sh

A bash + Azure CLI script that onboards an Azure subscription to Lucidity.
It assigns built-in and custom roles to Lucidity's service principal, checks
whether your storage firewalls will let Lucidity read blob inventory, and
writes a report for you to send to Lucidity.

Despite the file name, the script grants **more than read access** with the
default settings: optimization features such as the autoscaler need write
and delete permissions on disks, snapshots and VMs. See
[What it grants](#what-it-grants) and switch off the features you don't want
before running it.

## Before you run it

- **Azure CLI**, logged in (`az login`), and **jq**. Azure Cloud Shell has
  both.
- Your account needs, on the subscription:
  - **Owner**, or **User Access Administrator** plus permission to create
    custom role definitions, to create the roles and assignments.
  - **Owner or Contributor** on storage accounts, if you approve storage
    firewall changes.
- **Optional:** assigning *Reservations Reader* needs tenant-level rights
  (a Global Administrator with elevated access). Without them the script
  warns and carries on; Lucidity just won't see your Azure reservations.
- From Lucidity: the **object ID of Lucidity's service principal** in your
  tenant.

## Running it

Download the script:

```bash
wget https://raw.githubusercontent.com/luciditycloud/utilities/refs/heads/main/onboarding-script/read-only.sh
chmod +x read-only.sh
```

Edit the settings at the top of the file. At minimum, set
`SUBSCRIPTION_ID` and `SP_OBJECT_ID`:

```bash
SUBSCRIPTION_ID="<subscription-id>"
SP_OBJECT_ID="<service-principal-object-id>"
```

Then run it:

```bash
./read-only.sh
```

The script handles one subscription per run. For several subscriptions,
change `SUBSCRIPTION_ID` and run it again for each. Rerunning on the same
subscription is safe: roles are updated in place.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `SUBSCRIPTION_ID` | — | Subscription to onboard (required) |
| `SP_OBJECT_ID` | — | Lucidity's service principal object ID (required) |
| `AUTOSCALER` | `true` | Disk autoscaling permissions |
| `IDLE_DISK` | `false` | Idle disk permissions |
| `DISK_TIERING` | `false` | Disk tiering permissions |
| `BLOBS` | `true` | Blob optimization permissions |
| `BLOB_VISIBILITY` | `true` | Blob inventory permissions, so Lucidity can see your blob storage |
| `STORAGE_NETWORK_CHECK` | `true` | Check storage firewalls (when `BLOBS` or `BLOB_VISIBILITY` is on) |
| `AUTO_APPROVE_NETWORK_CHANGES` | `false` | Add the firewall rules without asking |
| `STORAGE_ACCOUNTS` | empty | Limit the firewall check to these accounts (comma- or space-separated); empty means all |

The settings under *Lucidity network details* are provided by Lucidity.
Don't change them unless Lucidity asks you to.

## What it grants

All assignments are on the subscription, except Reservations Reader.

| Role | Purpose | When |
|---|---|---|
| **Reader** (built-in) | Read all resource configuration | Always |
| **Reservations Reader** (built-in), at `/providers/Microsoft.Capacity` | Read Azure reservations | Always attempted; optional |
| `lucidity-guest-insights-role-<sub>` | Run the Lucidity collector inside VMs and scale-set instances (Run Command). With `BLOB_VISIBILITY`: manage blob inventory policies, the inventory container and last-access tracking; delete lifecycle policies; read blob data | Always |
| `lucidity-optimize-role-<sub>` | Write and delete permissions for the selected optimization features | When any of `AUTOSCALER`, `IDLE_DISK`, `DISK_TIERING`, `BLOBS` is on |

The guest insights role is for inspection; the optimize role is for changing
resources. Keeping them apart lets you grant one without the other.

**Blob data reads are limited to the `lucidity-inventory` container.** Each
custom role assignment that includes blob read carries an Azure ABAC
condition that denies blob reads in any other container. The role's other
permissions are unaffected.

> **Known limitation:** if a role was assigned by an earlier version of this
> script without the condition, rerunning does not add it. Lucidity will
> help you update those assignments.

## Storage network check

Lucidity reads the blob inventory reports over the network. If a storage
account's firewall allows only selected networks, Lucidity needs a rule
allowing its traffic. The script checks every storage account (or those in
`STORAGE_ACCOUNTS`) and gives each one a status:

| Status | Meaning | What happens |
|---|---|---|
| `open` | Firewall allows all networks | Nothing needed |
| `already_allowed` | Lucidity's rule is already in place | Nothing needed |
| `needs_rule` | Firewall is on and Lucidity's rule is missing | The rule is added, after your approval |
| `unreachable_until_service_endpoint` | Firewall is on and the account is in the same region as Lucidity (East US) | Nothing you can do yet; this will start working once Lucidity enables its service endpoint |
| `public_access_disabled` | Public network access is disabled | Manual: allow selected networks and rerun, or ask Lucidity about a private endpoint |
| `network_perimeter` | Secured by a network security perimeter | Manual: add Lucidity to the perimeter's access rules |
| `not_applicable` | File-share-only account | Nothing needed |
| `not_found` | A name in `STORAGE_ACCOUNTS` doesn't exist | Check the name |

**Approval.** The script lists the planned rule changes and asks
`Apply these rule changes on N storage account(s)? [y/N]`. Only `y` or `yes`
applies them. With `AUTO_APPROVE_NETWORK_CHANGES=true` it applies them
without asking. If there's no terminal to ask (for example, in a pipeline)
and auto-approve is off, nothing is changed and the accounts are reported as
`pending_approval`.

**What it changes.** Only Lucidity's own rules are added (or, after an IP
change, the old Lucidity IP removed). The script never changes an account's
default action or public network access, and never touches your own rules.
Changes are made with your credentials.

Firewall problems never fail the onboarding: the roles are already in place
by then. They make the run finish as `completed_with_warnings` instead.

## The report

Every run, including one that fails, ends with a summary and writes
`lucidity-onboarding-report-<sub>-<timestamp>.json` to the folder you ran it
from. **Please send this file to your Lucidity contact.** It contains:

- tenant ID, subscription ID and Lucidity's service principal object ID
- which features were switched on
- the overall status: `completed`, `completed_with_warnings` or `failed`
- each step's result, with Azure's error message if it failed
- each storage account's network status and what was changed

The report contains no secrets.

## Troubleshooting

- **"set SUBSCRIPTION_ID and SP_OBJECT_ID"**: edit the values at the top of
  the script.
- **"not logged in to Azure CLI"**: run `az login`, then rerun.
- **Reservations Reader warning**: expected unless you have tenant-level
  rights. Everything else works. A tenant administrator with elevated access
  can rerun the script to add it.
- **A step fails with `AuthorizationFailed`**: your account lacks the
  permissions listed in [Before you run it](#before-you-run-it).
- **"Lucidity's outbound IP was due to change"**: get the latest script
  from Lucidity before approving firewall rules.
- **Storage account reported `failed`**: often an Azure Policy blocking
  network rule changes. The report has Azure's error.

## For Lucidity: maintaining the network details

The *Lucidity network details* block at the top of the script holds values
that change on Lucidity's side:

- **Outbound IP changes:** put the new IP in `LUCIDITY_EGRESS_IPS`, move the
  old one to `LUCIDITY_RETIRED_EGRESS_IPS`, and update
  `LUCIDITY_EGRESS_IPS_VALID_UNTIL`. A customer rerun then adds the new rule
  and removes the old one. After the valid-until date, runs warn that the IP
  may be outdated.
- **Service endpoint goes live:** set `LUCIDITY_SERVICE_ENDPOINT_ENABLED=true`.
  The script then adds the subnet rule (`LUCIDITY_SUBNET_IDS`) to every
  account with a firewall, including East US accounts, and keeps the IP rule
  for accounts in other regions. Until then, subnet rules are skipped with a
  warning.

## Previous version

The earlier read-only assessment script, its `teardown.sh` and README are in
[`legacy/`](legacy/). There is no teardown script for this version yet.
