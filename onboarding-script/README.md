# read-only.sh

A bash + Azure CLI script that onboards Lucidity's read-only assessment
access onto an Azure tenant. It creates one **custom RBAC role per scope**
(management group or subscription), assigns it to Lucidity's service
principal, and — depending on the mode you pick — optionally provisions the
storage container and access-tracking setting Lucidity's inventory needs to
read from.

## Before you run it

- Needs the **Azure CLI**, logged in (`az login`) as an identity with rights
  to create custom role definitions and role assignments at the scope(s)
  you're targeting:
  - **Subscription mode (`-s`)**: Owner (or User Access Administrator +
    a custom-role-writer role) on each subscription.
  - **MG mode (`-m`)**: the same, but granted **at the management group**
    — subscription-level Owner is not sufficient to create an MG-homed role
    definition.
- No `jq`/`python` dependency — pure bash + `az` CLI JSON/TSV parsing.
- Provide **exactly one** of `-m` or `-s` — not both, not neither.
- **`setup_now` makes real changes** (creates a container, flips a storage
  setting) using your own credentials, in every account it touches. Review
  the account list (or pass `-a` to restrict it) before confirming.

## Execution

Get the script and give it execute permission:

```bash
wget https://raw.githubusercontent.com/luciditycloud/utilities/refs/heads/main/onboarding-script/read-only.sh
chmod +x read-only.sh
```

The only mandatory argument is the scope — exactly one of `-m` (management
group id) or `-s` (subscription id). Everything else has a sensible default.
Simplest possible run, against a single subscription, default mode
(`lucidity_self`):

```bash
./read-only.sh -s "<subscription-id>"
```

The script prints exactly what it's about to do (role name, scope, mode,
storage-write implications) and asks `Proceed? [y/N]` before touching
anything. Pass `-y` to skip that prompt for unattended/CI runs.

See *Usage* below for management-group scoping, the other enablement modes,
and multiple scopes at once. To remove the access again, see
[*Removing access (`teardown.sh`)*](#removing-access-teardownsh).

## Usage

```bash
chmod +x read-only.sh

# Simplest case: one subscription, default mode (lucidity_self — SP
# self-provisions storage prerequisites).
./read-only.sh -s "<sub-id>"

# Multiple subscriptions in one run (comma- or space-separated).
./read-only.sh -s "<sub-id-1>,<sub-id-2>"

# Management-group scope — role is homed at the MG, assignments fan out
# to every child subscription automatically.
./read-only.sh -m "<mg-id>"

# You provision the container + LAT yourself, right now, using this
# script and your own az login — SP gets no storage-write permissions.
./read-only.sh -s "<sub-id>" -e setup_now

# Same as above, but restrict provisioning to specific storage accounts.
./read-only.sh -s "<sub-id>" -e setup_now -a "acct1,acct2"

# SP gets no storage-write permissions and nothing is provisioned —
# the script prints the two az commands you need to run yourself.
./read-only.sh -s "<sub-id>" -e customer_preprovision

# Skip the confirmation prompt — for unattended/CI runs.
./read-only.sh -s "<sub-id>" -y

# Override the role-name prefix (default: lucidity-permissions-readonly).
./read-only.sh -s "<sub-id>" -p my-custom-prefix
```

### Options

| Flag | Default | Meaning |
|---|---|---|
| `-m "<mgIds>"` | — | Management group id(s), comma- or space-separated. Creates a per-MG role, assigned at MG scope (fans out to every child subscription). Exactly one of `-m` / `-s` is required. |
| `-s "<subIds>"` | — | Subscription id(s), comma- or space-separated. Creates a per-subscription role, assigned at that subscription. Exactly one of `-m` / `-s` is required. |
| `-e <mode>` | `lucidity_self` | Enablement mode: `lucidity_self` \| `setup_now` \| `customer_preprovision` — see the table above. |
| `-a "<accts>"` | *(all in scope)* | Only used with `-e setup_now`. Restricts self-provisioning to these storage account names, comma- or space-separated. |
| `-p <prefix>` | `lucidity-permissions-readonly` | Override the custom role name prefix. |
| `-y`, `--yes` | off | Skip the `Proceed? [y/N]` confirmation prompt — required for unattended/CI runs. |
| `-h`, `--help` | — | Show usage. |

## What a run looks like

```
>> Ensuring Azure CLI login...
>> Resolving Lucidity service principal...
   Service Principal Id: 11111111-2222-3333-4444-555555555555

==============================================================
 About to apply (mode: lucidity_self)
   Scope mode  : sub   targets: <sub-id>
   Roles       : one per sub -> lucidity-permissions-readonly-sub-<sub-id> (65 actions each)
   Assigned to : Lucidity SP 11111111-2222-3333-4444-555555555555 (always at SUBSCRIPTION scope)
   ABAC gate   : blobs/read -> container 'lucidity-inventory'
   Storage wr. : YES to SP (containers/write + blobServices/write, subscription-wide)
   Provisions  : nothing (SP self-enables container + LAT)
==============================================================
Proceed? [y/N] y

>> [sub: <sub-id>] role 'lucidity-permissions-readonly-sub-<sub-id>' (65 actions)...
   role id: /subscriptions/<sub-id>/providers/Microsoft.Authorization/roleDefinitions/<role-guid>
   --- subscription <sub-id> ---
     assigning at /subscriptions/<sub-id> ...
       assigned (ABAC read-condition applied)

==============================================================
 Setup summary
   Mode        : lucidity_self
   Scope mode  : sub   targets: <sub-id>
   Role naming : lucidity-permissions-readonly-sub-<sub-id>  (65 actions each)
   ABAC gate   : blobs/read -> 'lucidity-inventory'
   TenantId    : <tenant-id>
 Status       : COMPLETE
==============================================================
```

## What it actually does

1. **Checks the Azure CLI is installed, logs in** (if not already) and
   resolves Lucidity's service principal (app id
   `4f2c2c1f-372a-4904-b13d-11e2467679f2`) in your tenant, creating it if it
   doesn't exist yet. If your account can't read or create it, the script
   stops and shows the Azure CLI's reason.
2. **Builds one custom role per scope you pass** — named
   `<prefix>-mg-<mgId>` or `<prefix>-sub-<subId>` — containing:
   - ~65 read-only control-plane actions across Compute, Networking,
     Recovery Services (backup), Storage, Monitor/Log Analytics, Resource
     Graph, AKS, Cost Management, and Authorization — everything Lucidity's
     inventory needs to *look at*, nothing that lets it change anything
     outside storage.
   - One data-plane action, `blobs/read`, gated by an **ABAC condition**
     that limits it to a single container named `lucidity-inventory` — so
     even the one data-read permission granted can't see any other blob
     data in the account.
3. **Assigns** that role to Lucidity's service principal — always at
   subscription scope. In MG mode, the role is homed at the management
   group (so it lives/dies with that MG) but gets fanned out into a
   separate assignment on every child subscription under it.
4. **Provisions storage prerequisites**, depending on `-e` mode (see below):
   Lucidity self-provisions, you provision now with this script using your
   own credentials, or you provision it yourself later.

To reverse steps 2–3, use [`teardown.sh`](#removing-access-teardownsh).

Re-running the setup command is safe — existing roles are updated in place,
and a prior assignment to the same role/scope is removed and recreated
rather than duplicated.

## The three enablement modes (`-e`)

| Mode | Storage writes on the role? | Who provisions the container + LAT? |
|---|---|---|
| `lucidity_self` (default) | **Yes** — `containers/write` + `blobServices/write`, subscription-wide | Lucidity's SP does it itself, no extra step from you |
| `setup_now` | No | **This script**, right now, using your own logged-in `az` credentials |
| `customer_preprovision` | No | You, separately — the script prints the exact `az` commands to run |

`lucidity_self` is the simplest (nothing else to do), but it's also the only
mode where the SP holds subscription-wide storage-write permissions — the
ABAC condition only restricts `blobs/read`, not those write actions. If you'd
rather Lucidity hold no write permissions at all, use `setup_now` or
`customer_preprovision` instead.

## Troubleshooting

- **"Azure CLI (az) not found"** / **"Azure CLI login failed"** — install
  the Azure CLI or run the script in Azure Cloud Shell, and make sure
  `az login` succeeds for the right tenant (`az account show`).
- **"your account cannot read service principals in Microsoft Entra ID"** —
  the printed Azure CLI error gives the reason. Ask an administrator for
  directory read access, then rerun.
- **"your account cannot create Lucidity's service principal"** — Lucidity's
  service principal isn't in your tenant yet and your account isn't allowed
  to create it. Ask an Entra administrator (e.g. Application Administrator)
  to run `az ad sp create --id 4f2c2c1f-372a-4904-b13d-11e2467679f2` once,
  then rerun.
- **"could not resolve Lucidity SP. Contact Lucidity."** — the Azure CLI
  commands succeeded but returned no service principal. Contact Lucidity.
- **"could not create/retrieve role... (MG-scoped roles need
  roleDefinitions/write AT the MG - subscription Owner is not enough.)"** —
  exactly what it says: grant the role-creating identity a role like Owner
  or Role Based Access Control Administrator **at the management group
  itself**, not just on subscriptions under it.
- **"(no child subscriptions enumerated - check MG-reader access)"** — in
  MG mode, the script needs Reader (or better) at the management group to
  enumerate its child subscriptions via `az account management-group
  entities list`. Without it, the role gets created but never assigned
  anywhere.
- **`ASSIGNMENT FAILED` after retries** — the script already retries role
  assignment up to 6 times (5s apart) to absorb normal AAD replication
  delay after creating a new role/SP. If it still fails, the printed error
  is the real Azure CLI error — check it for a permissions or scope issue.
- **A `setup_now` provisioning step fails on one account** — the script
  keeps going and reports it in the per-subscription output; check that
  your logged-in identity has write access to that specific storage
  account (a resource lock or a Contributor-scope gap are common causes).
- **Want to undo a run** — use `teardown.sh` with the same scope flag(s) (and
  `-p` if you used a custom prefix). See below.

## Removing access (`teardown.sh`)

`teardown.sh` replaces the old `--clear` flag of `read-only.sh`. At each scope
you give it, it deletes every custom role whose name starts with the prefix,
after first removing Lucidity's assignments to it. With `-m`, assignments are
removed from every subscription under the management group.

```bash
chmod +x teardown.sh

./teardown.sh -s "<sub-id>"
./teardown.sh -m "<mg-id>" -p my-custom-prefix -y
```

| Flag | Default | Meaning |
|---|---|---|
| `-m "<mgIds>"` | — | Management group id(s), comma- or space-separated. Exactly one of `-m` / `-s` is required. |
| `-s "<subIds>"` | — | Subscription id(s), comma- or space-separated. Exactly one of `-m` / `-s` is required. |
| `-p <prefix>` | `lucidity-permissions-readonly` | Role-name prefix used at onboarding. |
| `-y`, `--yes` | off | Skip the `Proceed with deletion? [y/N]` prompt. |
| `-h`, `--help` | — | Show usage. |

It does **not** remove the `lucidity-inventory` containers, Last Access Time
tracking, Blob inventory policies, or Lucidity's service principal. It only
looks up the service principal and never creates it. Running
`read-only.sh --clear` now prints a pointer to `teardown.sh`.
