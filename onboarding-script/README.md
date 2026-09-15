# read-only.sh

A bash + Azure CLI script that onboards Lucidity's read-only assessment
access onto an Azure tenant. It creates one **custom RBAC role per scope**
(management group or subscription), assigns it to Lucidity's service
principal, and — depending on the mode you pick — optionally provisions the
storage container and access-tracking setting Lucidity's inventory needs to
read from.

It's fully idempotent: re-running it with the same arguments updates the
existing role/assignment in place rather than duplicating anything, and a
`--clear` mode exists to cleanly remove everything it created.

## What it actually does

1. **Logs in** (if not already) and resolves Lucidity's service principal
   (app id `4f2c2c1f-372a-4904-b13d-11e2467679f2`) in your tenant, creating
   it if it doesn't exist yet.
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
5. **`--clear`** reverses all of it: finds every custom role starting with
   the prefix at the scope(s) you give it, removes Lucidity's assignments
   to each one, then deletes the role definition.

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
multiple scopes at once, and `--clear`.

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

# Remove everything this script created at a given scope — deletes
# Lucidity's assignments first, then the role definition(s).
./read-only.sh --clear -s "<sub-id>"
./read-only.sh --clear -m "<mg-id>" -p my-custom-prefix -y
```

### Options

| Flag | Default | Meaning |
|---|---|---|
| `-m "<mgIds>"` | — | Management group id(s), comma- or space-separated. Creates a per-MG role, assigned at MG scope (fans out to every child subscription). Exactly one of `-m` / `-s` is required. |
| `-s "<subIds>"` | — | Subscription id(s), comma- or space-separated. Creates a per-subscription role, assigned at that subscription. Exactly one of `-m` / `-s` is required. |
| `-e <mode>` | `lucidity_self` | Enablement mode: `lucidity_self` \| `setup_now` \| `customer_preprovision` — see the table above. |
| `-a "<accts>"` | *(all in scope)* | Only used with `-e setup_now`. Restricts self-provisioning to these storage account names, comma- or space-separated. |
| `-p <prefix>` | `lucidity-permissions-readonly` | Override the custom role name prefix. |
| `-c`, `--clear` | off | Clear mode — deletes every custom role starting with the prefix at the given scope(s), and Lucidity's assignments to them. |
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

## Troubleshooting

- **"could not resolve Lucidity SP. Contact Lucidity."** — your identity
  can't create/read the service principal for that app id in this tenant.
  Confirm you're logged into the correct tenant (`az account show`) and
  have permission to create service principals, or ask a tenant admin to
  do it once beforehand.
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
- **Want to undo a run** — use `--clear` with the same scope flag(s) (and
  `-p` if you used a custom prefix). It removes Lucidity's assignments
  before deleting the role definitions, so nothing is left orphaned.
