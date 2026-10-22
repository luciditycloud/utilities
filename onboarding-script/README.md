# read-only.sh

A bash + Azure CLI script that onboards an Azure subscription to Lucidity.
It assigns built-in and custom roles to Lucidity's service principal, checks
whether your storage firewalls will let Lucidity read blob inventory, and
writes a report for you to send to Lucidity.

It has two modes:

- **Optimization** (default): read access, plus write and delete
  permissions on resources such as disks, snapshots and VMs, so Lucidity can
  act on its recommendations. The script asks you to approve this before it
  changes anything.
- **Assessment**: read access, plus the data collection Lucidity needs to
  project your savings. No write or delete permissions on your resources,
  and no approval prompt.

See [What it grants](#what-it-grants) for the details.

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

For assessment mode, also set:

```bash
MODE="assessment"
```

Then run it:

```bash
./read-only.sh
```

In optimization mode, the script first lists the optimization features and
asks `Grant optimization access? [y/N]`. Only `y` or `yes` continues;
anything else stops the script before it changes anything. For unattended
runs, set `AUTO_APPROVE_OPTIMIZATION=true`.

You can move from assessment to optimization later by rerunning with
`MODE="optimization"`. Rerunning in assessment mode does not remove
optimization access granted earlier; the script reports it instead.

The script handles one subscription per run. For several subscriptions,
change `SUBSCRIPTION_ID` and run it again for each. Rerunning on the same
subscription is safe: roles are updated in place.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `SUBSCRIPTION_ID` | — | Subscription to onboard (required) |
| `SP_OBJECT_ID` | — | Lucidity's service principal object ID (required) |
| `MODE` | `optimization` | `optimization` or `assessment` |
| `AUTO_APPROVE_OPTIMIZATION` | `false` | Grant optimization access without asking |
| `AUTOSCALER` | `true` | Disk autoscaling permissions (optimization only) |
| `IDLE_DISK` | `false` | Idle disk permissions (optimization only) |
| `DISK_TIERING` | `false` | Disk tiering permissions (optimization only) |
| `BLOBS` | `true` | Blob optimization permissions (optimization only) |
| `GUEST_INSIGHTS` | `true` | VM Run Command, so Lucidity can collect data inside VMs (both modes) |
| `BLOB_VISIBILITY` | `true` | Blob inventory permissions, so Lucidity can see your blob storage (both modes) |
| `STORAGE_NETWORK_CHECK` | `true` | Check storage firewalls (when `BLOBS` or `BLOB_VISIBILITY` is on) |
| `AUTO_APPROVE_NETWORK_CHANGES` | `false` | Add the firewall rules without asking |
| `STORAGE_ACCOUNTS` | empty | Limit the firewall check to these accounts (comma- or space-separated); empty means all |

The settings under *Lucidity network details* are provided by Lucidity.
Don't change them unless Lucidity asks you to.

## What it grants

All assignments are on the subscription, except Reservations Reader.

| Role | Purpose | Assessment | Optimization |
|---|---|---|---|
| **Reader** (built-in) | Read all resource configuration | ✅ | ✅ |
| **Reservations Reader** (built-in), at `/providers/Microsoft.Capacity` | Read Azure reservations (optional) | ✅ attempted | ✅ attempted |
| `lucidity-guest-insights-role-<sub>` | With `GUEST_INSIGHTS`: run the Lucidity collector inside VMs and scale-set instances (Run Command). With `BLOB_VISIBILITY`: manage blob inventory policies, the inventory container and last-access tracking; read blob data | ✅ | ✅ |
| `lucidity-optimize-role-<sub>` | Write and delete permissions for the selected optimization features | ❌ | ✅ when any of `AUTOSCALER`, `IDLE_DISK`, `DISK_TIERING`, `BLOBS` is on |

The guest insights role isn't created if both `GUEST_INSIGHTS` and
`BLOB_VISIBILITY` are off.

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
account's firewall allows only selected networks, Lucidity needs rules
allowing its traffic: a **subnet rule** for Lucidity's subnet and an **IP
rule** for Lucidity's outbound IP. Which one Azure uses depends on the
account's region, so both are added to every such account.

The script checks every storage account (or those in `STORAGE_ACCOUNTS`) and
gives each one a status:

| Status | Meaning | What happens |
|---|---|---|
| `open` | Firewall allows all networks | Nothing needed |
| `already_allowed` | Lucidity's rules are already in place | Nothing needed |
| `needs_rule` | Firewall allows selected networks and a Lucidity rule is missing | The missing rules are added, after your approval |
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
- the mode, and which features were switched on
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
- **Service endpoint:** Lucidity's subnet (`LUCIDITY_SUBNET_IDS`) has a
  Regional `Microsoft.Storage` service endpoint. With Lucidity's
  load-balancer outbound, accounts in Lucidity's region (and possibly its
  paired region) see the subnet, and accounts elsewhere see the public IP.
  So every firewalled account gets both rules.
- **Global service endpoint goes live:** every region then sees the subnet,
  and IP rules stop working. Set `LUCIDITY_EGRESS_IPS=""` and move its IPs to
  `LUCIDITY_RETIRED_EGRESS_IPS`. A customer rerun then removes the IP rules
  and keeps the subnet rule. No code change is needed.

## Open items

Known gaps and decisions still pending (as of 2026-10-22):

**Decisions**
- Whether the inventory policy write/delete permissions belong in
  assessment mode.
- Support for management groups and several subscriptions per run; the
  script handles one subscription.
- Whether disabled or warned subscriptions should be skipped.

**Backend team**
- Confirm nothing in Lucidity needs to read or list blobs outside
  `lucidity-inventory`; the condition on the assignments blocks it.
- Detect a missing Reservations Reader on Lucidity's side (for example, a
  403 from the reservations API), rather than relying on customers sending
  the report.

**Scheduled changes**
- Lucidity's outbound IP changes around 2026-11-16: update
  `LUCIDITY_EGRESS_IPS`, move the old IP to `LUCIDITY_RETIRED_EGRESS_IPS`,
  and update `LUCIDITY_EGRESS_IPS_VALID_UNTIL`.
- Global service endpoint: switch over as described above.

**Script gaps**
- Customers onboarded by an earlier version have assignments without the
  `lucidity-inventory` condition, and a rerun doesn't add it.
- No teardown script for this version.

**Not yet tested in real Azure**
- Subnet rules, including a customer storage account in a different tenant
  from Lucidity's subnet.
- Running without a terminal, `AUTO_APPROVE_NETWORK_CHANGES=true` and
  `AUTO_APPROVE_OPTIMIZATION=true`.
- The shorter console output for a failed Reservations Reader assignment.
- Assessment mode, the optimization approval prompt, `GUEST_INSIGHTS=false`,
  and detecting optimization access left from an earlier run.

## Previous version

The earlier read-only assessment script, its `teardown.sh` and README are in
[`legacy/`](legacy/). There is no teardown script for this version yet.
