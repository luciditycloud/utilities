# Lucidity onboarding script for Azure

`lucidity-onboarding.sh` onboards your Azure subscriptions to Lucidity. It:

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

Download the script, review it, and run it with the [options](#options) you
need:

```bash
curl -fsSLO https://raw.githubusercontent.com/luciditycloud/utilities/refs/heads/main/onboarding-script/lucidity-onboarding.sh
bash lucidity-onboarding.sh --mode visibility
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

| Option | What it does |
|---|---|
| `-y`, `--auto-approve` | Answer yes to every prompt, for runs without a terminal |
| `--blob-setup script` | The script sets up blob inventory on your storage accounts with your credentials, instead of giving Lucidity's role those permissions. Storage accounts created later need a rerun |
| `--no-guest-insights` | Don't grant VM Run Command |
| `-h`, `--help` | Show all options |

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
| `lucidity-guest-insights-role-<id>` | Run the Lucidity collector inside VMs and scale-set instances (Run Command); manage blob inventory policies, create the inventory container and turn on last access time tracking (unless `--blob-setup script`), and read blob data | ✅ | ✅ |
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
  as Cloud Shell, or add `--auto-approve`.
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

Lucidity's team: see [maintaining.md](docs/maintaining.md) for testing and
maintaining this script.
