# Lucidity onboarding script for Azure

`read-only.sh` onboards your Azure subscriptions to Lucidity. It:

- gives Lucidity's service principal the roles it needs on the
  subscriptions you choose,
- checks whether your storage account firewalls will let Lucidity read blob
  inventory, and offers to add Lucidity's rules,
- writes a report for you to send to Lucidity.

It shows you what it will do and asks before granting write access or
changing storage accounts. You don't need to edit the script: everything is
set with options on the command line.

## Before you run it

- **Where to run it:** Azure Cloud Shell (Bash) is easiest. Elsewhere you
  need the Azure CLI, logged in (`az login`), and `jq`.
- **Your account needs:**
  - **Subscriptions:** Owner on each subscription, or User Access
    Administrator plus permission to create custom role definitions.
  - **Management groups:** the same, **at the management group**.
    Subscription-level Owner isn't enough to create a role at a management
    group. You also need to be able to see the group's subscriptions.
  - **Owner or Contributor** on storage accounts, if you approve storage
    firewall changes.
  - **Read access to service principals** in Microsoft Entra ID, so the
    script can find Lucidity's. If Lucidity's service principal isn't in
    your tenant yet, the script creates it, which needs permission to
    create service principals (for example, Application Administrator).
    Without that, ask an Entra administrator to run
    `az ad sp create --id 4f2c2c1f-372a-4904-b13d-11e2467679f2` first.
- **Optional:** assigning *Reservations Reader* needs tenant-level rights (a
  Global Administrator with elevated access). Without them the script warns
  and carries on; Lucidity just won't see your Azure reservations.

## Running it

In Azure Cloud Shell (Bash), run the script straight from this repository,
adding the [options](#options) you need:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luciditycloud/utilities/refs/heads/main/onboarding-script/read-only.sh) --mode visibility
```

Or download it, review it, and run it:

```bash
curl -fsSLO https://raw.githubusercontent.com/luciditycloud/utilities/refs/heads/main/onboarding-script/read-only.sh
bash read-only.sh --mode visibility
```

With no options, the script onboards **every enabled subscription you can
access** in optimization mode, after showing you the list and asking you to
confirm it.

## Options

### Access scope: where Lucidity gets access

| Option | Default | What it does |
|---|---|---|
| `--scope-type` | `subscription` | `subscription` or `management_group` |
| `--scope-ids` | all subscriptions | **Subscriptions:** only these subscription IDs (optional; without it, every enabled subscription you can access). **Management groups:** the management group IDs (required) |
| `--exclude-ids` | none | Subscriptions to leave out. With management groups, also nested management groups, which leaves out every subscription under them |

IDs are comma-separated, for example `--exclude-ids "<id-1>,<id-2>"`.

- **Subscriptions** each get their own Lucidity roles.
- **Management groups:** the roles are created once at each management
  group, and assigned on every enabled subscription under it, including
  those in nested groups.
- **Skipped:** disabled or warned subscriptions, and those your account
  can't see, are skipped and listed in the report.

### Permission scope: what Lucidity can do

| Option | Default | What it does |
|---|---|---|
| `--mode` | `optimization` | **`optimization`:** read access, plus write and delete permissions so Lucidity can act on its recommendations. You approve this at a prompt. **`visibility`:** read access, plus the data collection Lucidity needs to project your savings. No write or delete permissions on your resources |
| `--features` | `autoscaler,blobs` | Optimization mode only: which optimization features get write and delete permissions. Any of `autoscaler`, `blobs`, `idle_disk`, `disk_tiering`, comma-separated |

See [What it grants](#what-it-grants) for the details.

### Other options

A few less common needs, such as running without prompts or doing the blob
inventory setup with your own credentials, are covered by further options.
Ask your Lucidity contact if you need one.

## What happens when you run it

1. **Targets.** The script lists the subscriptions it found: which it will
   onboard and which it skips (and why).
2. **Approval.** Nothing is changed before this point.
   - **Optimization mode:** it lists the features and asks
     `Grant optimization access? [y/N]`.
   - **No `--scope-ids`:** it asks you to confirm the subscription list. In
     optimization mode that's the same question.
   - Only `y` or `yes` continues. Anything else stops the script, with
     nothing changed.
3. **Roles.** It creates the roles and assigns them on each subscription.
4. **Storage accounts.** It lists the firewall rules Lucidity needs and asks
   `Apply these changes on N storage account(s)? [y/N]`. Saying no leaves
   them unchanged; the roles stay in place. See
   [Storage accounts](#storage-accounts).
5. **Report.** It prints a summary and writes the [report](#the-report).

A run asks at most two questions, whatever the number of subscriptions.

**Rerunning is safe.** Existing roles and assignments are updated in place.

- **Moving from visibility to optimization:** rerun with
  `--mode optimization`. A visibility run never removes optimization access
  granted earlier; it reports it instead.
- **New subscriptions** aren't onboarded automatically. Rerun the script
  after adding them.

Output is coloured in a terminal. Set `NO_COLOR=1` to turn colours off.

## What it grants

| Role | Purpose | Visibility | Optimization |
|---|---|---|---|
| **Reader** (built-in) | Read all resource configuration | ✅ | ✅ |
| **Reservations Reader** (built-in), at `/providers/Microsoft.Capacity` | Read Azure reservations (optional, tenant-wide) | ✅ attempted | ✅ attempted |
| `lucidity-guest-insights-role-<id>` | Run the Lucidity collector inside VMs and scale-set instances (Run Command); manage blob inventory policies, create the inventory container, turn on last access time tracking, and read blob data | ✅ | ✅ |
| `lucidity-optimize-role-<id>` | Write and delete permissions for the selected `--features` | ❌ | ✅ |

- **Where the roles live:** with subscriptions, each subscription gets its
  own custom roles, named after the subscription ID. With management
  groups, the roles are created at the group and named after it, and
  assigned on each subscription under it (Azure doesn't allow roles with
  blob data permissions to be assigned at the management group itself). A
  subscription that already has its own Lucidity roles from an earlier run
  keeps them. All assignments are on subscriptions, except Reservations
  Reader.
- **Blob data reads are limited to the `lucidity-inventory` container.**
  Azure's blob inventory writes reports listing each blob's properties,
  including its last access time, into that container. Each role
  assignment that includes blob read carries an Azure ABAC condition that
  denies blob reads in any other container.
- **Updates only ever add permissions.** On a rerun, missing permissions
  are added; permissions already granted are kept, even ones the current
  run doesn't ask for. To remove access, do it deliberately in Azure. The
  report lists what was added and kept.
- **Two roles:** the guest insights role is for inspection, the optimize
  role is for changing resources. Keeping them apart lets you grant one
  without the other.

## Storage accounts

Lucidity reads the blob inventory reports over the network. If a storage
account's firewall allows only selected networks, Lucidity needs rules
allowing its traffic:

- an **IP rule** for Lucidity's outbound IP, on every such account, and
- a **subnet rule** for Lucidity's subnet, on accounts in the regions
  Lucidity's subnet can reach (currently East US, West US and West US 3).
  Azure rejects the subnet rule elsewhere.

The script checks every storage account in the onboarded subscriptions,
lists the rules each one needs, and asks once before adding them. It says
which accounts get what while it runs.

| Status | Meaning | What happens |
|---|---|---|
| `open` | Firewall allows all networks | Nothing needed |
| `already_allowed` | Lucidity's rules are already in place | Nothing needed |
| `needs_rule` | Firewall allows selected networks and a Lucidity rule is missing | The missing rules are added, after your approval |
| `public_access_disabled` | Public network access is disabled | Manual: allow selected networks and rerun, or ask Lucidity about a private endpoint |
| `network_perimeter` | Secured by a network security perimeter | Manual: add Lucidity to the perimeter's access rules |
| `not_applicable` | File-share-only account | Nothing needed |

**What it changes:** only Lucidity's own firewall rules are added (or, after
Lucidity's IP changes, the old Lucidity IP removed). It never changes an
account's default action or public network access, and never touches your
own rules. Changes are made with your credentials.

Storage account problems never fail the onboarding: the roles are already in
place by then. The run finishes as `completed_with_warnings` instead.

## The report

Every run that gets past the initial checks ends with a summary and writes
`lucidity-onboarding-report-<timestamp>.json` to the folder you ran it from.
**Please send this file to your Lucidity contact.** It contains:

- the script version and the options you ran it with,
- the tenant ID and Lucidity's service principal object ID,
- the scope, exclusions, mode and features,
- every subscription found: onboarded, failed, skipped or excluded (and
  why),
- each step's result, with Azure's error message if it failed,
- each storage account's firewall status and what was changed,
- the overall status:
  - `completed`: everything worked
  - `completed_with_warnings`: onboarded, with something to look at
  - `completed_with_errors`: some subscriptions failed; the others were
    onboarded
  - `failed`: the run stopped before onboarding anything (or partway).

The report contains no secrets.

## Troubleshooting

- **"unknown option", "… needs a value", "--mode must be …"**: check the
  option against [Options](#options). The script prints its usage.
- **"--scope-type management_group needs --scope-ids"**: give the
  management group ID (not its display name).
- **"some subscriptions weren't found"**: check the IDs and that you're
  logged in to the right tenant. If they're management group IDs, add
  `--scope-type management_group`.
- **"--exclude-ids: '…' matched no target subscription"**: probably a typo;
  nothing was excluded for that ID.
- **"not approved. Nothing was changed."**: rerun and answer `y`, or use
  `--mode visibility`.
- **"no terminal to ask for approval"**: run the script in a terminal, such
  as Cloud Shell.
- **"management group … not found"**: check the management group ID and
  that your account can see it.
- **"your account cannot read service principals"** or **"cannot create
  Lucidity's service principal"**: see
  [Before you run it](#before-you-run-it); the script prints the command an
  administrator can run.
- **"not logged in to Azure CLI"**: run `az login`, then rerun.
- **Reservations Reader warning**: expected unless you have tenant-level
  rights. Everything else works.
- **A step fails with `AuthorizationFailed`**: your account lacks the
  permissions listed in [Before you run it](#before-you-run-it).
- **"Lucidity's outbound IP was due to change"**: get the latest script
  before approving firewall rules.
- **Storage account reported `failed`**: often an Azure Policy blocking
  network rule changes. The report has Azure's error.

---

## For Lucidity

The rest of this page is for Lucidity's team.

### Other options

Not listed above, so that customers see only what most of them need. Hand
them out when a customer asks; `--help` lists them too.

| Option | What it does |
|---|---|
| `-y`, `--auto-approve` | Answer yes to every prompt: the subscription list, optimization access and storage changes. Needed to run without a terminal |
| `--blob-setup script` | The script creates the `lucidity-inventory` container and turns on last access time tracking with the customer's credentials, instead of Lucidity's role getting those permissions (see below). Default `lucidity` |
| `--no-guest-insights` | Don't grant VM Run Command |
| `-h`, `--help` | Show all options |

Defaults that have no option, such as `SP_OBJECT_ID` (an override for
Lucidity's service principal object ID), `STORAGE_ACCOUNTS`,
`STORAGE_NETWORK_CHECK` and `BLOB_VISIBILITY`, are set at the top of the
script.

### Blob visibility setup (`--blob-setup`)

For blob visibility, each storage account needs the `lucidity-inventory`
container and **last access time tracking** turned on.

- **`lucidity`** (default): Lucidity does it, so its role gets
  `blobServices/write` (last access time tracking) and `containers/write`
  (the container). Storage accounts created later are set up by Lucidity
  automatically.
- **`script`**: the script does it now, with the customer's credentials,
  and Lucidity's role doesn't get those two permissions. **Storage accounts
  created later aren't set up until the customer reruns the script.**

In both cases Lucidity keeps `inventoryPolicies/write` and `delete`: it
manages the inventory policy itself. With `script`:

- The setup is part of the storage accounts step and its single prompt.
- It applies to StorageV2, BlobStorage and BlockBlobStorage accounts; other
  kinds are reported as `not_supported`.
- Blob optimization (`--features blobs`) has its own container and blob
  service write permissions, whatever `--blob-setup` is.
- Switching an existing customer from `lucidity` to `script` doesn't take
  the two permissions away (updates only ever add). The script highlights
  them instead.

Blob setup status in the report (`setupStatus`):

| Status | Meaning |
|---|---|
| `ready` | Container exists and tracking is on |
| `needs_setup` | Container missing or tracking off; set up after approval |
| `not_supported` | Account kind doesn't support blob inventory |
| `check_failed` | The script couldn't read the account's settings; the report has Azure's error |
| `not_requested` | `--blob-setup lucidity`: Lucidity does it |

Other report values: `not_found` (a name in `STORAGE_ACCOUNTS` doesn't
exist), `not_checked` (`STORAGE_NETWORK_CHECK=false`), and
`pending_approval` (changes not approved, or no terminal).

### Script version

`SCRIPT_VERSION` at the top of the script is printed at the start of every
run and recorded in the report. Set it to the date of each change, so a
report shows which version a customer ran. Customers using the one-line
command always get the latest version on `main`.

### Testing

[testing-guide.md](testing-guide.md) walks through testing the script end to
end in a test subscription. Run it after every change to the script, and
update it alongside this README whenever the script changes.

### Maintaining the network details

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

### Open items

As of 2026-10-28.

**Scheduled changes**
- Lucidity's outbound IP changes around 2026-11-16: update
  `LUCIDITY_EGRESS_IPS`, move the old IP to `LUCIDITY_RETIRED_EGRESS_IPS`,
  and update `LUCIDITY_EGRESS_IPS_VALID_UNTIL`.
- Global service endpoint: switch over as described above.

**Not yet tested in real Azure** (see the test log in
[testing-guide.md](testing-guide.md))
- The command-line options, the all-subscriptions default with its
  confirmation, `--exclude-ids`, and the one-line `bash <(curl …)` command
  in Cloud Shell. Tested only against a simulated Azure CLI.
- Management group scope with several subscriptions or nested groups, and
  skipping subscriptions that aren't enabled. Tested: one group with one
  subscription, a missing group, and a group role created with data
  permissions and assigned on the subscription.
- Add-only role updates that actually add permissions (rerunning with
  nothing to add is tested), and `--no-guest-insights`.
- Subnet rules for a customer storage account in a **different tenant**
  from Lucidity's subnet. Tested only within one tenant, on an East US
  account.
- The region-aware subnet rules on real accounts in covered regions other
  than East US (West US, West US 3).
- Creating Lucidity's service principal from its real application. Tested
  with a test app in the same tenant; Lucidity's multi-tenant app in a
  customer tenant is untested.
- Running without a terminal, and `--auto-approve`.

### Previous version

The earlier read-only assessment script, its `teardown.sh` and README are in
[`legacy/`](legacy/). There is no teardown script for this version.
