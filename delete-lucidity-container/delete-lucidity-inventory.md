# delete_lucidity_inventory_rule.sh

A bash + Azure CLI script that finds and removes the `lucidity-blob-inventory-policy`
rule from every storage account's blob inventory policy across an Azure
estate — one subscription, a list of subscriptions, or every subscription
you can see. 


## Prerequisites

- **Azure CLI installed and on PATH.** If not, it checks and
  exits with a link to the install docs if it's missing.
- **Logged in**, or able to log in: if `az account show` fails, the script
  runs `az login` for you. For unattended runs (a pipeline, a scheduled
  job), set these three environment variables instead and it will log in
  with a service principal automatically:

  ```bash
  export AZ_SP_APP_ID="<app-id>"
  export AZ_SP_PASSWORD="<client-secret>"
  export AZ_SP_TENANT="<tenant-id>"
  ```

  Also pass `--yes` for unattended runs — without it, the confirmation
  prompt (see below) will hang forever waiting for input that will never
  come, since nothing is reading from stdin.

## Execution

Get the script and take it for a dry run first — this only lists what it
found, it never changes anything:

```bash
wget https://raw.githubusercontent.com/luciditycloud/utilities/refs/heads/main/delete-lucidity-container/delete_lucidity_inventory_rule.sh
chmod +x delete_lucidity_inventory_rule.sh
./delete_lucidity_inventory_rule.sh --dry-run
```

`-s` is optional — pass nothing and it scans every subscription the
logged-in identity can see (same as `-s all`); pass one or more to scope
down. See *Options* below.

Once the dry-run output looks right, drop `--dry-run` to make the real,
irreversible change. The script lists exactly what it's about to do (remove
a rule, or delete a whole policy) per account and asks `Proceed? [y/N]`
before touching anything:

```bash
./delete_lucidity_inventory_rule.sh -s "<sub-id>"
```

## Usage

```bash
chmod +x delete_lucidity_inventory_rule.sh

# No scope flag at all — every subscription the logged-in identity can see.
# Same as `-s all`.
./delete_lucidity_inventory_rule.sh

# Single subscription — lists first, asks for confirmation before deleting.
./delete_lucidity_inventory_rule.sh -s "<sub-id>"

# Multiple subscriptions in one run (comma- or space-separated).
./delete_lucidity_inventory_rule.sh -s "<sub-id-1>,<sub-id-2>"

# Every subscription the logged-in identity can see (explicit form).
./delete_lucidity_inventory_rule.sh -s all

# Preview only — never calls update/delete.
./delete_lucidity_inventory_rule.sh -s "<sub-id>" --dry-run

# Skip the confirmation prompt — for unattended/CI runs.
./delete_lucidity_inventory_rule.sh -s "<sub-id>" --yes

# Custom log file location.
./delete_lucidity_inventory_rule.sh -s "<sub-id>" -l "/tmp/inventory-cleanup.log"
```

### Options

| Flag | Default | Meaning |
|---|---|---|
| `-s "<subIds\|all>"` | `all` | Subscription id(s), comma- or space-separated, or `all` for every subscription the caller can see. |
| `-l <path>` | `delete_lucidity_inventory_rule.log` | Log file location. |
| `-n`, `--dry-run` | off | List what would be removed/deleted; calls no `update`/`delete`. |
| `-y`, `--yes` | off | Skip the `Proceed? [y/N]` confirmation prompt — required for unattended/CI runs, since nothing there can answer it. |
| `-h`, `--help` | — | Show usage. |

The rule name (`lucidity-blob-inventory-policy`) is fixed — this script is
purpose-built for that one rule, not a generic rule-removal tool.

## Auth Details

- **A service principal login is scoped to one tenant per run.** `-s all`
  (or no `-s` at all) only enumerates subscriptions inside the
  currently-logged-in tenant. If you manage several tenants, run the
  script once per tenant.
- Whichever identity ends up logged in needs, on every subscription/account
  in scope:
  - **Read** access to list storage accounts and show their inventory
    policy (e.g. Reader).
  - **Write** access to update the policy — the
    `Microsoft.Storage/storageAccounts/inventoryPolicies/write` RBAC
    action — for accounts where the rule is removed but the policy stays.
  - **Delete** access — the
    `Microsoft.Storage/storageAccounts/inventoryPolicies/delete` RBAC
    action — for accounts where the target rule is the only one, so the
    whole policy gets deleted.
  - Contributor or Storage Account Contributor covers all of the above.
- **No resource lock** (`CanNotDelete` or `ReadOnly`) on the storage
  account or its resource group — a lock blocks both the update and the
  delete path and shows up in the log as `ScopeLocked`. Check with:
  ```bash
  az lock list --resource-group "<rg>" --resource-name "<account>" --namespace "Microsoft.Storage" --resource-type "storageAccounts" --subscription "<sub-id>" -o table
  ```
- No `jq`/`python` dependency — pure bash + `az` CLI TSV parsing. Plain
  indexed arrays only (no bash 4 associative arrays), so it runs fine under
  macOS's default `/bin/bash` (3.2) with no version gate needed.
- **Removal is irreversible** through this script — there's no soft-delete
  for inventory policies the way there is for containers. Always dry-run
  first and review the accounts it lists before confirming.

## What it actually does

1. **Ensures prerequisites**: checks the Azure CLI is installed (exits with
   install instructions if not), and logs in (interactively, or via a
   service principal from `AZ_SP_*` env vars) if not already authenticated.
2. **Resolves scope** — either the subscription IDs you passed directly, or
   every subscription visible to the caller (`-s all` / no `-s` at all).
3. **Lists storage accounts** in each subscription in scope.
4. **Checks each account's blob inventory policy** (`blob-inventory-policy
   show`) for a rule named `lucidity-blob-inventory-policy`, and records
   both its position (index) in the `rules` array and the total rule
   count. Accounts with no inventory policy at all are skipped silently —
   that's the normal case for most accounts.
5. **Confirms** before touching anything real: prints every account it
   found, labelled either `remove rule (index X of Y)` or
   `DELETE WHOLE POLICY (sole rule)`, and asks `Proceed? [y/N]`. Skipped
   automatically under `--dry-run` (nothing to confirm) or `--yes`
   (for unattended/CI runs).
6. **Acts per account**, branching on whether the target rule is the only
   one:
   - **Multiple rules** → `blob-inventory-policy update --remove
     policy.rules <index>` — removes only that array element. Every other
     rule and the policy's `enabled`/`destination` settings are untouched.
   - **Sole rule** → `blob-inventory-policy delete` — removes the whole
     policy resource, since an empty `rules` array isn't a valid state for
     Azure's API to leave it in.
   Failures (RBAC gap, resource lock, etc.) are logged per account and the
   run continues through the rest of the batch rather than aborting.
7. **Prints a summary**: subscriptions scanned (and skipped for lack of
   access), storage accounts scanned, rules found to act on, and — on a
   real run — how many were handled by rule-removal vs. whole-policy
   deletion, plus how many failed, and where the log file is.

The script is not idempotent-with-state — there's no state file to resume
from, because there's nothing to resume: an account whose rule (or whole
policy) is already gone simply won't show up as "found" on the next run, so
re-running is always safe.

## Troubleshooting

- **`InvalidValuesForRequestParameters: rules`** (from a plain `update
  --remove` outside this script) — this means you tried to remove the only
  rule in a policy via `update`, which leaves an empty `rules[]` that
  Azure's API rejects. The script itself avoids this by detecting the
  sole-rule case and calling `delete` instead — if you're doing this by
  hand, do the same.
- **`ScopeLocked`** — a `CanNotDelete` or `ReadOnly` resource lock is on the
  storage account (or its resource group), blocking the operation. Find it
  with `az lock list` (see *Prerequisites*) and get sign-off before
  removing or adjusting it — it's very likely intentional protection,
  especially on production resource groups.
- **"Could not list storage accounts in subscription \<id\>"** — no access
  to that subscription (or the call failed for another reason). The
  script logs this and moves to the next subscription rather than
  aborting the whole run.
- **A removal/delete keeps failing for another reason** — check the log
  file for the actual Azure CLI error; the most common causes besides
  locks are a missing `.../inventoryPolicies/write` (for rule removal) or
  `.../inventoryPolicies/delete` (for whole-policy deletion) RBAC action.
- **You need to verify a change actually happened** — re-run
  `az storage account blob-inventory-policy show --account-name <acct>
  --resource-group <rg>`. `BlobInventoryPolicyNotFound` means the whole
  policy is gone; a policy JSON with `lucidity-blob-inventory-policy` no
  longer in `policy.rules[].name` means just the rule was removed and
  everything else in the policy is intact.
