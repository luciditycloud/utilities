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

- **Where to run it:** Azure Cloud Shell (Bash) is easiest: you're already
  logged in, and everything the script needs is installed. To run it
  elsewhere, see [Running it outside Cloud Shell](#running-it-outside-cloud-shell).
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
bash lucidity-onboarding.sh --scope-ids="<mg-id-1>,<mg-id-2>" --mode=visibility     # pass comma-separated management group IDs
```

### Running it outside Cloud Shell

Install the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
and [jq](https://jqlang.org/download/), then log in to your tenant and check
you're in the right one before running the script:

```bash
az login --tenant <tenant-id>
az account show --query "{tenant: tenantId, user: user.name}" -o table
```

## Options

Each option has a short form, and takes its value either way:
`--mode=visibility`, `--mode visibility` or `-m visibility`.

### Access scope: where Lucidity gets access

| Option | Default | What it does |
|---|---|---|
| `-t`, `--scope-type` | `management-group` | `management-group` or `subscription` |
| `-s`, `--scope-ids` | everything you can access | **Management groups:** these management group IDs. Without it, the top management groups you can access (the tenant root group, if you can access it), after you confirm the list. **Subscriptions:** these subscription IDs. Without it, every enabled subscription you can access, after you confirm the list |
| `-x`, `--exclude-ids` | none | Subscriptions to leave out, or nested management groups, which leaves out every subscription under them |

IDs are comma-separated, for example `--exclude-ids="<id-1>,<id-2>"`.

- **Management groups:** the roles are created once at each management
  group, and assigned on every enabled subscription under it, including
  those in nested groups.
- **Subscriptions** each get their own Lucidity roles.
- **Skipped:** disabled or warned subscriptions, and those your account
  can't see, are skipped and listed in the report.

### Permission scope: what Lucidity can do

| Option | Default | What it does |
|---|---|---|
| `-m`, `--mode` | `optimization` | **`optimization`:** read access, plus write and delete permissions so Lucidity can act on its recommendations. You approve this at a prompt. **`visibility`:** read access, plus the data collection Lucidity needs to project your savings. No write or delete permissions on your resources |
| `-f`, `--feature-modules` | `autoscaler,blobs` | Optimization mode only: which feature modules get write and delete permissions. Any of `autoscaler`, `blobs`, `idle-disk`, `disk-tiering`, comma-separated |

See [What it grants](#what-it-grants) for the details.

### Other options

| Option | What it does |
|---|---|
| `-y`, `--auto-approve` | Answer yes to every prompt, for runs without a terminal |
| `--network-check-only` | Only check storage account firewalls and add Lucidity's rules, for when Lucidity's roles are already in place. Grants no roles. Can't be combined with the permission scope options |
| `--blob-setup script` | The script sets up blob inventory on your storage accounts with your credentials, instead of giving Lucidity's role those permissions. Storage accounts created later need a rerun |
| `--no-guest-insights` | Don't grant VM Run Command |
| `-h`, `--help` | Show all options |

## What happens when you run it

1. **Targets.** The script lists the subscriptions it found: which it will
   onboard and which it skips (and why). A management group that can't be
   found is reported, and the others are still onboarded.
2. **Approval.** Nothing is changed before this point.
   - **Optimization mode:** it lists the feature modules and asks
     `Grant optimization access? [y/N]`.
   - **No `--scope-ids`:** it asks you to confirm the subscription list. In
     optimization mode that's the same question.
   - Only `y` or `yes` continues. Anything else stops the script, with
     nothing changed.
3. **Roles.** It creates the roles and assigns them on each subscription.
4. **Storage accounts.** It shows how many accounts need Lucidity's firewall
   rules and asks `Apply these changes on N storage account(s)? [y/N]`. Saying no leaves
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
| `lucidity-optimize-role-<id>` | Write and delete permissions for the selected `--feature-modules` | ❌ | ✅ |

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

Lucidity reads the blob inventory reports over the network, so what an
account needs depends on its public network access setting:

| Public network access | What Lucidity needs |
|---|---|
| Enabled from all networks | Nothing |
| Enabled from selected networks | Lucidity's firewall rules, by region (below) |
| Disabled | Lucidity can't reach the account: only a private endpoint could, and Lucidity doesn't offer one. Out of scope unless you allow selected networks |

For selected networks, the rules depend on where the account is:

| Account region | Rules added | Why |
|---|---|---|
| East US, West US, West US 3 | Subnet rule and IP rule | Lucidity's traffic arrives through its subnet's service endpoint, so the subnet rule is the one that lets it in. The IP rule has no effect there |
| Any other region | IP rule only | Lucidity's traffic arrives from its outbound IP. Azure rejects the subnet rule in these regions |

The script checks every storage account in the onboarded subscriptions,
shows how many need each rule, and asks once before adding them. The report
lists each account's status and what was changed.

Already onboarded, and only need the firewall rules (for example, after
adding storage accounts)? Run with `--network-check-only`.

| Status | Meaning | What happens |
|---|---|---|
| `open` | Firewall allows all networks | Nothing needed |
| `already_allowed` | Lucidity's rules are already in place | Nothing needed |
| `needs_rule` | Firewall allows selected networks and a Lucidity rule is missing | The missing rules are added, after your approval |
| `public_access_disabled` | Public network access is disabled | Out of scope: Lucidity can't reach it. To include it, allow selected networks and rerun |
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
- the scope, exclusions, mode and feature modules,
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
- **"management group '…' not found"**: check the ID (not the display
  name; the script prints the command that lists them), and that you're
  logged in to the right tenant and your account can see the group. The
  other management groups are still onboarded. Run with `-h` to see the
  options, or contact your Lucidity representative.
- **"not under a management group your account can access"** (without
  `--scope-ids`): that subscription isn't onboarded. Ask someone with access
  to its management group to run the script.
- **"some subscriptions weren't found"** (with `--scope-type subscription`):
  check the IDs and that you're logged in to the right tenant.
- **"--exclude-ids: '…' matched no target subscription"**: probably a typo;
  nothing was excluded for that ID.
- **"not approved. Nothing was changed."**: rerun and answer `y`, or use
  `--mode visibility`.
- **"no terminal to ask for approval"**: run the script in a terminal, such
  as Cloud Shell, or add `--auto-approve`.
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
