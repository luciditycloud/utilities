# read-only.sh

A bash + Azure CLI script that onboards Azure subscriptions to Lucidity.
It assigns built-in and custom roles to Lucidity's service principal, checks
whether your storage firewalls will let Lucidity read blob inventory, and
writes a report for you to send to Lucidity.

You choose **where** to onboard:

- **Subscriptions**: one or more subscription IDs.
- **Management groups**: one or more management group IDs. Every enabled
  subscription under each group is onboarded, including those in nested
  groups.

And **what** Lucidity gets:

- **Optimization** (default): read access, plus write and delete
  permissions on resources such as disks, snapshots and VMs, so Lucidity can
  act on its recommendations. The script asks you to approve this before it
  changes anything.
- **Visibility**: read access, plus the data collection Lucidity needs to
  project your savings. No write or delete permissions on your resources,
  and no approval prompt.

See [What it grants](#what-it-grants) for the details.

## Before you run it

- **Azure CLI**, logged in (`az login`), and **jq**. Azure Cloud Shell has
  both.
- Your account needs:
  - **Subscriptions:** Owner on each subscription, or User Access
    Administrator plus permission to create custom role definitions.
  - **Management groups:** the same, **at the management group**.
    Subscription-level Owner isn't enough to create a role at a management
    group. You also need to be able to see the group's subscriptions.
  - **Owner or Contributor** on storage accounts, if you approve storage
    firewall changes.
- **Optional:** assigning *Reservations Reader* needs tenant-level rights
  (a Global Administrator with elevated access). Without them the script
  warns and carries on; Lucidity just won't see your Azure reservations.
- **Lucidity's service principal:** the script finds it in your tenant
  from Lucidity's application ID, so your account needs to be able to read
  service principals in Microsoft Entra ID. If it isn't in your tenant yet,
  the script creates it, which needs permission to create service
  principals (for example, Application Administrator). Without that, ask an
  Entra administrator to run
  `az ad sp create --id 4f2c2c1f-372a-4904-b13d-11e2467679f2`, then run the
  script.

## Running it

Download the script:

```bash
wget https://raw.githubusercontent.com/luciditycloud/utilities/refs/heads/main/onboarding-script/read-only.sh
chmod +x read-only.sh
```

Edit the settings at the top of the file. At minimum, set where to onboard:

```bash
# Subscriptions
SCOPE_TYPE="subscription"
SCOPE_IDS="<subscription-id-1>, <subscription-id-2>"

# or management groups
SCOPE_TYPE="management_group"
SCOPE_IDS="<management-group-id>"
```

Leave `SP_OBJECT_ID` empty unless Lucidity gives you an object ID.

For visibility mode, also set:

```bash
MODE="visibility"
```

Then run it:

```bash
./read-only.sh
```

The script first lists the subscriptions it found and which it will skip.
In optimization mode it then lists the optimization features and asks
`Grant optimization access? [y/N]`. Only `y` or `yes` continues; anything
else stops the script before it changes anything. A run asks at most two
questions, this one and the [storage accounts](#storage-accounts) one,
whatever the number of subscriptions. For unattended runs, set
`AUTO_APPROVE_OPTIMIZATION=true` and `AUTO_APPROVE_STORAGE_CHANGES=true`.

Rerunning is safe: existing roles and assignments are updated in place.

- **Moving from visibility to optimization:** rerun with
  `MODE="optimization"`. Rerunning in visibility mode does not remove
  optimization access granted earlier; the script reports it instead.
- **New subscriptions under a management group** aren't onboarded
  automatically. Rerun the script after adding them.

Output is coloured in a terminal. Set `NO_COLOR=1` to turn colours off;
they're off automatically when the output isn't a terminal.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `SCOPE_TYPE` | `subscription` | `subscription` or `management_group` |
| `SCOPE_IDS` | — | Subscription or management group IDs, comma- or space-separated (required) |
| `SP_OBJECT_ID` | empty | Lucidity's service principal object ID. Empty: found from Lucidity's application ID, and created if missing |
| `MODE` | `optimization` | `optimization` or `visibility` |
| `AUTO_APPROVE_OPTIMIZATION` | `false` | Grant optimization access without asking |
| `AUTOSCALER` | `true` | Disk autoscaling permissions (optimization only) |
| `IDLE_DISK` | `false` | Idle disk permissions (optimization only) |
| `DISK_TIERING` | `false` | Disk tiering permissions (optimization only) |
| `BLOBS` | `true` | Blob optimization permissions (optimization only) |
| `GUEST_INSIGHTS` | `true` | VM Run Command, so Lucidity can collect data inside VMs (both modes) |
| `BLOB_VISIBILITY` | `true` | Blob inventory permissions, so Lucidity can see your blob storage (both modes) |
| `BLOB_SETUP` | `lucidity` | Who creates the inventory container and turns on last access time tracking: `lucidity` or `script` (see [Blob visibility setup](#blob-visibility-setup)) |
| `STORAGE_NETWORK_CHECK` | `true` | Check storage firewalls (when `BLOBS` or `BLOB_VISIBILITY` is on) |
| `AUTO_APPROVE_STORAGE_CHANGES` | `false` | Make the storage account changes (firewall rules, blob setup) without asking |
| `STORAGE_ACCOUNTS` | empty | Limit the firewall check to these accounts (comma- or space-separated); empty means all in the target subscriptions |

The settings under *Lucidity network details* are provided by Lucidity.
Don't change them unless Lucidity asks you to.

## What it grants

| Role | Purpose | Visibility | Optimization |
|---|---|---|---|
| **Reader** (built-in) | Read all resource configuration | ✅ | ✅ |
| **Reservations Reader** (built-in), at `/providers/Microsoft.Capacity` | Read Azure reservations (optional, tenant-wide) | ✅ attempted | ✅ attempted |
| `lucidity-guest-insights-role-<id>` | With `GUEST_INSIGHTS`: run the Lucidity collector inside VMs and scale-set instances (Run Command). With `BLOB_VISIBILITY`: manage blob inventory policies and read blob data; with `BLOB_SETUP=lucidity`, also create the inventory container and turn on last access time tracking | ✅ | ✅ |
| `lucidity-optimize-role-<id>` | Write and delete permissions for the selected optimization features | ❌ | ✅ when any of `AUTOSCALER`, `IDLE_DISK`, `DISK_TIERING`, `BLOBS` is on |

**Where the roles live:**

- **Subscriptions:** each subscription gets its own custom roles, named
  after the subscription ID.
- **Management groups:** the custom roles are created once at each
  management group and named after it. They're assigned on every enabled
  subscription under it; Azure doesn't allow roles with blob data
  permissions to be assigned at the management group itself.
- **A subscription that already has its own Lucidity roles** (from an
  earlier subscription-level run) keeps them in a management group run.
  They're updated in place and the management group's roles aren't added
  there, so nothing is removed or duplicated.
- All assignments are on subscriptions, except Reservations Reader.

**Updates only ever add permissions.** On a rerun, permissions missing from
an existing role are added; permissions already in it are kept, even ones
the current settings don't ask for. For example, setting
`GUEST_INSIGHTS=false` on a rerun doesn't take Run Command away. To remove
access, do it deliberately in Azure. The report lists what was added and
kept.

The guest insights role isn't created if both `GUEST_INSIGHTS` and
`BLOB_VISIBILITY` are off. It's for inspection; the optimize role is for
changing resources. Keeping them apart lets you grant one without the
other.

**Blob data reads are limited to the `lucidity-inventory` container.**
Azure's blob inventory, set up by Lucidity, writes reports listing each
blob's properties, including its last access time, into that container.
Each custom role assignment that includes blob read carries an Azure ABAC
condition that denies blob reads in any other container. The role's other
permissions are unaffected.

**Skipped subscriptions:** subscriptions that aren't enabled (for example
disabled or warned), or that your account can't see, are skipped and
listed in the report.

## Blob visibility setup

For blob visibility, each storage account needs the `lucidity-inventory`
container and **last access time tracking** turned on. `BLOB_SETUP` decides
who does that:

- **`lucidity`** (default): Lucidity does it, so its role gets
  `blobServices/write` (last access time tracking) and `containers/write`
  (the container) on every storage account. Storage accounts created later
  are set up by Lucidity automatically.
- **`script`**: this script does it now, with **your** credentials, and
  Lucidity's role doesn't get those two permissions. **Storage accounts
  created later aren't set up until you rerun the script.**

In both cases Lucidity keeps the inventory policy permissions
(`inventoryPolicies/write` and `delete`): it manages the inventory policy
itself.

Things to know about `script`:

- The setup is part of the [storage accounts](#storage-accounts) step and
  its single approval prompt.
- It applies to account kinds that support blob inventory: StorageV2,
  BlobStorage and BlockBlobStorage. Other kinds are reported as
  `not_supported`.
- Setup changes aren't blocked by storage firewalls, but Lucidity still
  needs network access to read the reports.
- Blob optimization (`BLOBS`, optimization mode) has its own container and
  blob service write permissions, whatever `BLOB_SETUP` is.
- Switching an existing customer from `lucidity` to `script` doesn't take
  the two permissions away (updates only ever add). The script highlights
  them instead.

## Storage accounts

The script checks every storage account in the target subscriptions (or
those in `STORAGE_ACCOUNTS`) for two things:

- **Firewall** (`STORAGE_NETWORK_CHECK`): Lucidity reads the blob inventory
  reports over the network. If a storage account's firewall allows only
  selected networks, Lucidity needs rules allowing its traffic: an **IP
  rule** for Lucidity's outbound IP, and a **subnet rule** for Lucidity's
  subnet. Which one Azure uses depends on the account's region, and Azure
  only accepts a subnet rule for accounts in the regions Lucidity's subnet
  endpoint covers (currently East US, West US and West US 3). So every such
  account gets the IP rule, and accounts in those three regions also get the
  subnet rule. The script says which accounts get what while it runs.
- **Blob setup** (`BLOB_SETUP=script`): the container and last access time
  tracking (see [Blob visibility setup](#blob-visibility-setup)).

Firewall status:

| Status | Meaning | What happens |
|---|---|---|
| `open` | Firewall allows all networks | Nothing needed |
| `already_allowed` | Lucidity's rules are already in place | Nothing needed |
| `needs_rule` | Firewall allows selected networks and a Lucidity rule is missing | The missing rules are added, after your approval |
| `public_access_disabled` | Public network access is disabled | Manual: allow selected networks and rerun, or ask Lucidity about a private endpoint |
| `network_perimeter` | Secured by a network security perimeter | Manual: add Lucidity to the perimeter's access rules |
| `not_applicable` | File-share-only account | Nothing needed |
| `not_found` | A name in `STORAGE_ACCOUNTS` doesn't exist | Check the name |
| `not_checked` | `STORAGE_NETWORK_CHECK=false` | Nothing |

Blob setup status (with `BLOB_SETUP=script`):

| Status | Meaning | What happens |
|---|---|---|
| `ready` | Container exists and tracking is on | Nothing needed |
| `needs_setup` | Container missing or tracking off | Set up, after your approval |
| `not_supported` | Account kind doesn't support blob inventory | Nothing |
| `check_failed` | The script couldn't read the account's settings | Check your access; the report has Azure's error |
| `not_requested` | `BLOB_SETUP=lucidity` | Lucidity does it |

**Approval.** The script lists the planned changes for all target
subscriptions and asks once: `Apply these changes on N storage account(s)?
[y/N]`. Only `y` or `yes` applies them. With
`AUTO_APPROVE_STORAGE_CHANGES=true` it applies them without asking. If
there's no terminal to ask (for example, in a pipeline) and auto-approve is
off, nothing is changed and the accounts are reported as
`pending_approval`.

**What it changes.** Only Lucidity's own firewall rules are added (or, after
an IP change, the old Lucidity IP removed), plus the container and tracking
with `BLOB_SETUP=script`. The script never changes an account's default
action or public network access, and never touches your own rules. Changes
are made with your credentials.

Storage account problems never fail the onboarding: the roles are already in
place by then. They make the run finish as `completed_with_warnings`
instead.

## The report

Every run, including one that fails, ends with a summary and writes
`lucidity-onboarding-report-<timestamp>.json` to the folder you ran it
from. **Please send this file to your Lucidity contact.** It contains:

- tenant ID and Lucidity's service principal object ID (and whether it was
  found or created)
- the scope type and IDs, the mode, and which features were switched on
- whether Reservations Reader was assigned (`reservationsReader`), and
  `blobSetup`
- every subscription found: onboarded, failed or skipped (and why), and
  whether it uses its own roles or the management group's
- the overall status:
  - `completed`: everything worked
  - `completed_with_warnings`: onboarded, with something to look at
  - `completed_with_errors`: some subscriptions or management groups
    failed; the others were onboarded
  - `failed`: the run stopped before onboarding anything (or partway)
- each step's result, with Azure's error message if it failed
- each storage account's firewall and blob setup status, and what was
  changed (under `storage`)

The report contains no secrets.

## Troubleshooting

- **"set SCOPE_IDS"**: edit the value at the top of the script.
- **"your account cannot read service principals"**: ask an administrator
  for directory read access, then rerun.
- **"your account cannot create Lucidity's service principal"**: ask an
  Entra administrator (for example, an Application Administrator) to run
  the `az ad sp create` command the script prints, then rerun.
- **"couldn't verify SP_OBJECT_ID"**: the script uses the object ID as
  given. If role assignments then fail, empty `SP_OBJECT_ID` and rerun.
- **"not logged in to Azure CLI"**: run `az login`, then rerun.
- **"… must be true or false"**, **"MODE must be …"**, **"SCOPE_TYPE must
  be …"** or **"BLOB_SETUP must be …"**: fix that setting at the top of the
  script.
- **"Optimization access not approved"**: nothing was changed. Rerun and
  answer `y`, or set `MODE="visibility"`.
- **"management group … not found"**: check the management group ID (not
  its display name) and that your account can see it.
- **A subscription is skipped as "not found, or your account can't access
  it"**: your account can't see it in this tenant. Check your access, or
  that you're logged in to the right tenant.
- **Reservations Reader warning**: expected unless you have tenant-level
  rights. Everything else works. A tenant administrator with elevated access
  can rerun the script to add it.
- **A step fails with `AuthorizationFailed`**: your account lacks the
  permissions listed in [Before you run it](#before-you-run-it).
- **"Lucidity's outbound IP was due to change"**: get the latest script
  from Lucidity before approving firewall rules.
- **Storage account reported `failed`**: often an Azure Policy blocking
  network rule or storage changes. The report has Azure's error.
- **Blob setup `check_failed`**: your account couldn't read that storage
  account's settings. The report has Azure's error.

## For Lucidity: testing

[testing-guide.md](testing-guide.md) walks through testing the script end to
end in a test subscription. Run it after every change to the script, and
update it alongside this README whenever the script changes.

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
  load-balancer outbound, accounts in the regions the endpoint covers see the
  subnet, and accounts elsewhere see the public IP. Azure rejects a subnet
  rule on an account outside those regions (tested: "Only resources in
  eastus, westus, westus3 can be ACL-ed to virtual networks in eastus").
  `LUCIDITY_SUBNET_REGIONS` lists the covered regions: accounts there get
  both rules, accounts elsewhere get the IP rule only. If Azure changes the
  covered regions, update that list.
- **Global service endpoint goes live:** every region then sees the subnet,
  and IP rules stop working. Set `LUCIDITY_SUBNET_REGIONS="*"`, set
  `LUCIDITY_EGRESS_IPS=""` and move its IPs to
  `LUCIDITY_RETIRED_EGRESS_IPS`. A customer rerun then adds the subnet rule
  everywhere and removes the IP rules. No code change is needed.

## Open items

As of 2026-10-24.

**Scheduled changes**
- Lucidity's outbound IP changes around 2026-11-16: update
  `LUCIDITY_EGRESS_IPS`, move the old IP to `LUCIDITY_RETIRED_EGRESS_IPS`,
  and update `LUCIDITY_EGRESS_IPS_VALID_UNTIL`.
- Global service endpoint: switch over as described above.

**Not yet tested in real Azure** (see the test log in
[testing-guide.md](testing-guide.md))
- Management group scope, several subscriptions per run, and skipping
  subscriptions that aren't enabled.
- Add-only role updates that actually add permissions (rerunning with
  nothing to add is tested), and `GUEST_INSIGHTS=false`.
- Subnet rules for a customer storage account in a **different tenant**
  from Lucidity's subnet. Tested only within one tenant, on an East US
  account; Azure's region restriction was found in that test.
- The region-aware subnet rules (`LUCIDITY_SUBNET_REGIONS`): the script's
  planning is tested, but not yet against real accounts in several regions.
- `BLOB_SETUP=script`: creating the container and turning on last access
  time tracking with the customer's credentials.
- Finding Lucidity's service principal from its application ID, and
  creating it when it's missing.
- Running without a terminal, `AUTO_APPROVE_STORAGE_CHANGES=true` and
  `AUTO_APPROVE_OPTIMIZATION=true`.

## Previous version

The earlier read-only assessment script, its `teardown.sh` and README are in
[`legacy/`](legacy/). There is no teardown script for this version.
