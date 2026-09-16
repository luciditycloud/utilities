# disable_lucidity_lat.sh

A bash + Azure CLI script that disables **last-access-time (LAT) tracking**
(`lastAccessTimeTrackingPolicy`) on one or more storage accounts — whatever
subscription each one happens to live in.

No account/subscription mapping is hardcoded anywhere in the script. You
give it account names (as arguments, or in a file); it resolves each one to
its subscription and resource group itself, with a single Azure Resource
Graph query across every subscription the caller can see.

## Before you run it

- **Installs the Azure CLI for you** if it's missing, **installs the
  `resource-graph` CLI extension** if it's missing (used to resolve account
  → subscription/resource-group in one query), and **checks you're logged
  in** (or logs in via `AZ_SP_APP_ID`/`AZ_SP_PASSWORD`/`AZ_SP_TENANT` for
  unattended runs) — same behavior as the other scripts in this repo.
- The logged-in identity needs, across every subscription that might hold a
  target account: **Reader** (for the Resource Graph lookup and to read blob
  service properties) and **write** access to update them — e.g.
  Contributor, Storage Account Contributor, or a custom role with
  `Microsoft.Storage/storageAccounts/blobServices/read` and
  `Microsoft.Storage/storageAccounts/blobServices/write`.
- Disabling LAT is a **reversible** setting change (re-enable any time with
  `--enable-last-access-tracking true`) — not a destructive operation. Still,
  dry-run first if you want to see exactly what it found before changing
  anything.
- An account name that doesn't resolve in Resource Graph — wrong spelling,
  doesn't exist, or the logged-in identity has no Reader access to the
  subscription it's in — is reported as "not found" and skipped; it doesn't
  abort the run.

## Execution

Get the script and dry run it first — resolves accounts, shows current LAT
state, changes nothing:

```bash
wget https://raw.githubusercontent.com/luciditycloud/utilities/refs/heads/main/delete-lucidity-container/disable_lucidity_lat.sh
chmod +x disable_lucidity_lat.sh
./disable_lucidity_lat.sh --dry-run struksprodcommvault01 sadwmgtcentralbackups
```

Then run for real. It prints a table of exactly what it's about to disable
and asks `Proceed? [y/N]`:

```bash
./disable_lucidity_lat.sh struksprodcommvault01 sadwmgtcentralbackups
```

## Usage

```bash
chmod +x disable_lucidity_lat.sh

# Pass account names directly as arguments.
./disable_lucidity_lat.sh struksprodcommvault01 sadwmgtcentralbackups

# ...or, if no account names are given as arguments, read them from a file
# (one name per line; blank lines and '#' comments are ignored).
./disable_lucidity_lat.sh -f accounts.txt

# Preview only — never calls `blob-service-properties update`.
./disable_lucidity_lat.sh --dry-run -f accounts.txt

# Skip the confirmation prompt — for unattended/CI runs.
./disable_lucidity_lat.sh --yes -f accounts.txt
```

`accounts.txt` example:

```
# Lucidity-enabled LAT accounts
storageaccount1
storageaccount2
storageaccount3
storageaccount4
storageaccount5
...
```

### Options

| Flag | Default | Meaning |
|---|---|---|
| *(positional args)* | — | Storage account name(s) to act on. Takes priority over `-f` if both are given. |
| `-f <file>` | — | Read storage account names from this file instead (one per line). Only used when no account names are given as arguments. |
| `-l <path>` | `disable_lucidity_lat.log` | Log file location. |
| `-n`, `--dry-run` | off | Show current state and what would change; calls no `update`. |
| `-y`, `--yes` | off | Skip the `Proceed? [y/N]` confirmation prompt. |
| `-h`, `--help` | — | Show usage. |

## What it actually does

1. **Ensures prerequisites**: installs the Azure CLI and the `resource-graph`
   extension if missing, logs in if needed.
2. **Builds the account list**: from the positional arguments, or from `-f`
   if none were given. Validates each name against Azure's storage-account
   naming rules (3-24 lowercase letters/digits) and de-dupes.
3. **Resolves every account in one batched query**
   (`az graph query ... | where name in~ (...)`) to its subscription ID and
   resource group — no per-subscription looping. Names that don't resolve
   are reported as not found and excluded from the rest of the run.
4. **Checks current state**: reads `lastAccessTimeTrackingPolicy.enable`
   (`az storage account blob-service-properties show`) for every resolved
   account. Accounts already `false` are reported and skipped — nothing is
   written for them.
5. **Confirms** before changing anything real: prints a table —
   `STORAGE ACCOUNT | SUBSCRIPTION | RESOURCE GROUP` — of exactly the
   accounts that still have LAT enabled, and asks `Proceed? [y/N]`. Skipped
   under `--dry-run` or `--yes`.
6. **Disables LAT** on each one via
   `az storage account blob-service-properties update
   --enable-last-access-tracking false`, logging success/failure per account
   and continuing through the rest of the batch if one fails.
7. **Prints a summary**: accounts requested, already disabled, not
   found/no access, disabled (or "would disable" in dry-run) — followed by
   the same account/subscription/resource-group table, so the run's exact
   blast radius is always spelled out explicitly, not just a count.

## Troubleshooting

- **"not found in any subscription visible to the logged-in identity"** —
  either the name is misspelled, the account no longer exists, or the
  logged-in identity lacks Reader on the subscription that holds it (Resource
  Graph only sees what the caller can see).
- **A disable keeps failing** — check the log file for the actual Azure CLI
  error; usually a missing `.../blobServices/write` RBAC action or a
  resource lock on the storage account/resource group.
