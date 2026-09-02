# gpv2_migrate.sh

A bash + Azure CLI script that upgrades Azure storage accounts off the
retiring **GPv1** (`kind: Storage`) and legacy **Blob Storage**
(`kind: BlobStorage`) account kinds onto **GPv2** (`kind: StorageV2`) —
Microsoft's own account kind retires GPv1 and legacy Blob Storage on
**October 13, 2026**.

It lists accounts still on the old kind, upgrades them one by one, logs
anything that fails, and — if you run it again — automatically retries
only what didn't finish. No flags to remember for a retry: run the exact
same command and it picks up where it left off.

## What it actually does

1. **Lists** every storage account still on `kind=Storage` or
   `kind=BlobStorage`, across whichever subscriptions you point it at —
   pulling name, resource group, SKU, and current access tier in that same
   listing call, so nothing extra has to be looked up before upgrading.
2. **Confirms** before touching anything real: it prints exactly which
   accounts are about to be upgraded and asks `Proceed? [y/N]`. Skipped
   automatically under `--dry-run` (nothing to confirm) or `--yes`
   (for unattended/CI runs).
3. **Upgrades** each one, one at a time, via
   `az storage account update --set kind=StorageV2`. This is a control-plane
   change only — no data moves, no downtime, same endpoint and keys.
4. If an upgrade **fails**, the script logs it, keeps going with the rest
   of the batch, and at the end tells you how many accounts are upgraded
   vs. still remaining, and where to find the failure details.
5. **Run it again** and it repeats step 1: it lists whatever is *still*
   `kind=Storage`/`kind=BlobStorage` in Azure. Anything truly upgraded no
   longer matches that filter, so it's never touched twice. Anything that
   failed last time is still on the old kind, so it's retried
   automatically — no special flag needed (it'll ask for confirmation again
   unless `--yes` is set).
6. Once a run finds **nothing left** to upgrade, it prints a final report:
   every account it has ever touched, its original kind, and its current
   kind (re-checked live, not just trusted from memory).

**The resumability trick, in one sentence:** Azure's own `kind` field *is*
the checkpoint. The state file the script keeps is just a readable log and
retry counter on top of that — re-running the script is safe because of
what's actually true in Azure, not because of anything clever in the state
file.

## What it deliberately will NOT touch

| Case | Why it's skipped |
|---|---|
| Accounts still on the classic (ASM) deployment model | `az storage account list` only returns ARM accounts, so these never even appear in the script's results. They need a separate, older migration. |
| Databricks-managed accounts (name starts `dbstorage`, or the resource group has "databricks" in it) | Microsoft auto-migrates these on its own; touching them manually is more likely to cause a problem than solve one. |
| GPv1 accounts on standard **ZRS** redundancy | Microsoft's own documentation is inconsistent about whether the redundancy-conversion path here needs downtime. These are logged and left for a human to route to the dedicated ZRS migration doc. |

Both skip cases are recorded in the state file with a reason, and show up
in the final report — they're excluded on purpose, not silently dropped.

## Before you run it

- Needs **bash 4.0+** (it uses associative arrays). macOS ships bash 3.2 as
  `/bin/bash` by default — the script detects this and fails immediately
  with a clear message rather than the cryptic errors an old bash would
  otherwise produce. Install a newer one (`brew install bash`) and invoke
  the script with its full path, e.g.
  `/opt/homebrew/bin/bash gpv2_migrate.sh ...`.
- The identity running the script needs **Contributor** (or a narrower
  custom role with `Microsoft.Storage/storageAccounts/write` and `.../read`)
  on every subscription you point it at.
- It **installs the Azure CLI and `jq` for you** if they're missing —
  detects `apt`/`dnf`/`yum`/`zypper`/`brew` and uses Microsoft's own install
  method. If none of those package managers are found, it stops and tells
  you to install the CLI manually rather than guessing.
- It expects you to already be logged in (`az login`). For unattended runs
  (a pipeline, a scheduled job), set these three environment variables
  instead and it will log in with a service principal automatically:

  ```bash
  export AZ_SP_APP_ID="<app-id>"
  export AZ_SP_PASSWORD="<client-secret>"
  export AZ_SP_TENANT="<tenant-id>"
  ```

  Also pass `--yes` for unattended runs — without it, the confirmation
  prompt (see above) will hang forever waiting for input that will never
  come, since nothing is reading from stdin.

- **The upgrade is irreversible.** There is no downgrade path from GPv2
  back to GPv1. Run with `--dry-run` against a non-production subscription
  first.

## Execution

Get the script and take it for a dry run first — this only lists and
classifies accounts, it never changes anything:

```bash
wget https://raw.githubusercontent.com/luciditycloud/utilities/refs/heads/main/gpv2-migrate/gpv2_migrate.sh
chmod +x gpv2_migrate.sh
./gpv2_migrate.sh --dry-run
```

On macOS, invoke it with a bash 4+ binary instead of the system default
(see *Before you run it* above — the script will otherwise refuse to run):

```bash
/opt/homebrew/bin/bash gpv2_migrate.sh --dry-run
```

Once the dry-run output looks right, drop `--dry-run` to make the real,
irreversible change. The script will list exactly what it's about to
upgrade and ask for confirmation before touching anything:

```bash
./gpv2_migrate.sh
```

See *Usage* below for scoping to specific subscriptions/resource groups,
unattended/CI runs, and every other flag.

## Usage

```bash
chmod +x gpv2_migrate.sh

# Default: every subscription you can see, tier=Hot, real changes.
# (pauses for a y/N confirmation before making any change)
./gpv2_migrate.sh

# Skip the confirmation prompt — for unattended/CI runs.
./gpv2_migrate.sh --yes

# Scope to specific subscriptions.
./gpv2_migrate.sh --subscriptions <sub-id-1>,<sub-id-2>

# Use Cool as the default tier for accounts that don't already have one.
./gpv2_migrate.sh --tier Cool

# Only touch resource groups matching a pattern (e.g. a single wave).
./gpv2_migrate.sh --rg-filter '^prod-'

# See what would happen — lists and classifies, calls no `update`.
./gpv2_migrate.sh --dry-run

# It died halfway through (network blip, expired token, Ctrl-C, reboot)?
# Just run the identical command again.
./gpv2_migrate.sh
```

### Options

| Flag | Default | Meaning |
|---|---|---|
| `--subscriptions <ids\|all>` | `all` | Comma-separated subscription IDs, or `all` for every subscription you can see. |
| `--tier <Hot\|Cool>` | `Hot` | Default access tier for accounts that don't already have one. (An account's *default* tier can only be Hot or Cool — Cool/Archive are per-blob, not account-level.) A legacy Blob Storage account that already has a tier keeps it, regardless of this flag. |
| `--rg-filter <regex>` | *(none)* | Only act on accounts whose resource group matches this regex — use it to scope a single wave. |
| `--state-file <path>` | `gpv2_migration_state.csv` | Where progress is tracked. |
| `--log-file <path>` | `gpv2_migration.log` | Where every action and error is logged. |
| `--dry-run` | off | List and classify accounts, but never call `az storage account update`. |
| `-y`, `--yes` | off | Skip the `Proceed? [y/N]` confirmation prompt — required for unattended/CI runs, since nothing there can answer it. |
| `-h`, `--help` | — | Show usage. |

## The files it creates

**`gpv2_migration_state.csv`** — one row per account, a real comma-delimited
CSV so it opens cleanly in Excel/Sheets/a browser, rewritten atomically after
every single account so a crash never corrupts it or loses more than the one
in-flight change:

```
name,resource_group,subscription_id,kind_original,sku,target_tier,status,attempts,last_error,updated_at
```

The Azure resource ID isn't stored — it's just `name`/`resource_group`/
`subscription_id` glued into Azure's own fixed URI template, so it's fully
recoverable from the other columns. The script rebuilds it in memory when it
needs to (as the internal lookup key, and for `az ... --ids`).

`status` is one of:

- `pending` — discovered, not yet attempted (or a failure, waiting to be retried)
- `upgraded` — done
- `failed` — the last attempt errored; will be retried automatically next run
- `skipped` — a Databricks or GPv1-ZRS account, deliberately excluded

You can open this file any time the script isn't running to see exactly
where things stand — don't hand-edit it while a run is in progress.

**`gpv2_migration.log`** — a plain-text, timestamped log of everything the
script did, including the full Azure CLI error text for any failure.

## What a run looks like

**First run** (one account fails partway through):

```
[2026-09-02T06:21:41Z] Scanning subscription <sub> for GPv1 / legacy Blob Storage accounts...

The following 3 account(s) will be upgraded to GPv2 — this is IRREVERSIBLE:
  acct1                            rg=rg-prod                  sub=<sub> tier=Hot
  acct2                            rg=rg-prod                  sub=<sub> tier=Hot
  ...

Re-run with --dry-run to preview only, or --yes to skip this prompt.
Proceed? [y/N] y
[2026-09-02T06:21:41Z] Upgrading acct1 (rg=rg-prod) -> StorageV2, tier=Hot ...
[2026-09-02T06:21:41Z]   -> upgraded OK (acct1)
[2026-09-02T06:21:41Z] Upgrading acct2 (rg=rg-prod) -> StorageV2, tier=Hot ...
[2026-09-02T06:21:41Z] ERROR:   -> upgrade FAILED for acct2 (attempt 1) — details in gpv2_migration.log
---- Run summary (5 account(s) tracked) ----
  Upgraded            : 2
  Failed (auto-retried next run): 1
  Skipped (excluded)  : 2
  Still pending       : 0
Some accounts failed. Check gpv2_migration.log for details, then just run this exact same command again to retry them.
```

**Second run** (identical command — only the failed account is retried):

```
[2026-09-02T06:21:43Z] Loaded existing state: 5 account(s) previously tracked in gpv2_migration_state.csv.
[2026-09-02T06:21:43Z] Scanning subscription <sub> for GPv1 / legacy Blob Storage accounts...
[2026-09-02T06:21:43Z] Re-queuing previously-failed account for retry: acct2 (rg-prod)

The following 1 account(s) will be upgraded to GPv2 — this is IRREVERSIBLE:
  acct2                            rg=rg-prod                  sub=<sub> tier=Hot

Re-run with --dry-run to preview only, or --yes to skip this prompt.
Proceed? [y/N] y
[2026-09-02T06:21:43Z] Upgrading acct2 (rg=rg-prod) -> StorageV2, tier=Hot ...
[2026-09-02T06:21:43Z]   -> upgraded OK (acct2)

==== MIGRATION COMPLETE — nothing left on GPv1 / legacy Blob Storage in scope ====
NAME                             RESOURCE GROUP           ORIGINAL KIND  NOW          TIER
acct1                            rg-prod                  Storage        StorageV2    Hot
acct2                            rg-prod                  Storage        StorageV2    Hot
acct3                            rg-prod                  Storage        (skipped)    N/A
====================================================================================
```

## Why comma and not tab, while parsing Azure's output

This tripped up an earlier draft of the script, worth knowing if you ever
touch this code: bash's `read` **collapses consecutive tab characters even
when `IFS` is restricted to just tab**, because tab is treated as "IFS
whitespace" no matter how you set `IFS`. A GPv1 account always has a
*null* access tier — a completely normal empty field — and that empty
field sitting between two tab delimiters would silently shift every column
after it. The script re-delimits Azure CLI's tab-separated output to `,`
before parsing, which isn't "IFS whitespace" and doesn't get collapsed. This
was caught by testing against a mock Azure CLI before delivery, not left as
a latent bug.

## Troubleshooting

- **"Not logged in to Azure CLI"** — run `az login` interactively, or set
  the three `AZ_SP_*` environment variables for unattended use.
- **"No supported package manager found"** — the box doesn't have
  apt/dnf/yum/zypper/brew; install the Azure CLI and `jq` manually, then
  re-run.
- **An account keeps failing on every run** — check `gpv2_migration.log`
  for the actual Azure CLI error (usually a permissions gap, or the
  account name in the error line points to something worth checking by
  hand, like a resource lock).
- **"Could not list storage accounts in subscription \<id\>"** — your
  identity has no access to that subscription (or the call failed for
  another reason). The script logs this and skips straight to the next
  subscription rather than aborting the whole run; check `gpv2_migration.log`
  for the underlying Azure CLI error, and grant at least Reader (plus
  Contributor to actually upgrade) if access is the issue.
- **Want to abandon a partial run and start clean** — delete
  `gpv2_migration_state.csv` (or point `--state-file` elsewhere). This
  does **not** touch anything already upgraded in Azure — it only forgets
  the script's own bookkeeping, and the next run rediscovers reality from
  Azure directly.
