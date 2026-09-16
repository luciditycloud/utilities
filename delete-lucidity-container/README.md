# delete_lucidity_container.sh

A bash + Azure CLI script that finds and deletes every `lucidity-inventory`
container across an Azure estate — one subscription, a list of
subscriptions, every subscription you can see, or every subscription under
one or more management groups. 

It deletes via the ARM control-plane API (`az storage container-rm delete`)
— no storage account keys or connection strings needed, just the
`Microsoft.Storage/storageAccounts/blobServices/containers/delete` RBAC
action on the target scope.

## Before you run it

- **Installs the Azure CLI for you** if it's missing — detects
  `apt`/`dnf`/`yum`/`zypper`/`brew` and uses Microsoft's own install method.
  If none of those package managers are found, it stops and tells you to
  install the CLI manually rather than guessing.
- **Checks you're logged in**, and if not, runs `az login` for you. For
  unattended runs (a pipeline, a scheduled job), set these three
  environment variables instead and it will log in with a service
  principal automatically:

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
found, it never deletes anything:

```bash
wget https://raw.githubusercontent.com/luciditycloud/utilities/refs/heads/main/delete-lucidity-container/delete_lucidity_container.sh
chmod +x delete_lucidity_container.sh
./delete_lucidity_container.sh --dry-run
```

`-s`/`-m` are both optional — pass neither and it scans every subscription
the logged-in identity can see (same as `-s all`); pass one to scope down.
See *Options* below.

Once the dry-run output looks right, drop `--dry-run` to make the real,
irreversible change. The script lists exactly what it's about to delete and
asks `Proceed? [y/N]` before touching anything:

```bash
./delete_lucidity_container.sh
```

## Usage

```bash
chmod +x delete_lucidity_container.sh

# No scope flag at all — every subscription the logged-in identity can see.
# Same as `-s all`.
./delete_lucidity_container.sh

# Single subscription — lists first, asks for confirmation before deleting.
./delete_lucidity_container.sh -s "<sub-id>"

# Multiple subscriptions in one run (comma- or space-separated).
./delete_lucidity_container.sh -s "<sub-id-1>,<sub-id-2>"

# Every subscription the logged-in identity can see (explicit form).
./delete_lucidity_container.sh -s all

# Management-group scope — resolves every child subscription automatically
# (nested management groups included).
./delete_lucidity_container.sh -m "<mg-id>"

# Preview only — never calls `container-rm delete`.
./delete_lucidity_container.sh -s "<sub-id>" --dry-run

# Skip the confirmation prompt — for unattended/CI runs.
./delete_lucidity_container.sh -s "<sub-id>" --yes

# Shrink the blast radius before trusting a big run: specific accounts,
# or resource groups matching a pattern.
./delete_lucidity_container.sh -s "<sub-id>" -a "acct1,acct2" --dry-run
./delete_lucidity_container.sh -s "<sub-id>" -r '^rg-prod-' --dry-run

# A different container name, e.g. to reuse this script for cleanup of
# some other well-known container.
./delete_lucidity_container.sh -s "<sub-id>" -t "some-other-container"
```

### Options

| Flag | Default | Meaning |
|---|---|---|
| `-s "<subIds\|all>"` | `all` | Subscription id(s), comma- or space-separated, or `all` for every subscription the caller can see. Optional; mutually exclusive with `-m`. |
| `-m "<mgIds>"` | — | Management group id(s), comma- or space-separated. Child subscriptions (nested included) are resolved and included automatically. Optional; mutually exclusive with `-s`. If neither `-s` nor `-m` is given, the script behaves as `-s all`. |
| `-t <name>` | `lucidity-inventory` | Container name to look for and delete. |
| `-a "<accts>"` | *(all in scope)* | Restrict to these storage account names, comma- or space-separated — a safety net for testing on a small set first. |
| `-r <regex>` | *(none)* | Only consider resource groups matching this regex. |
| `-l <path>` | `delete_lucidity_container.log` | Log file location. |
| `-n`, `--dry-run` | off | List what would be deleted; calls no `container-rm delete`. |
| `-y`, `--yes` | off | Skip the `Proceed? [y/N]` confirmation prompt — required for unattended/CI runs, since nothing there can answer it. |
| `-h`, `--help` | — | Show usage. |

## Auth Details

- **A service principal login is scoped to one tenant per run.**
  `AZ_SP_TENANT` is a single tenant ID, and `-s all` / no scope flag only
  enumerates subscriptions inside *that* tenant (`az account list` doesn't
  reach across tenants for a non-interactive SP login). If you manage
  several tenants, run the script once per tenant — same `AZ_SP_APP_ID`/
  `AZ_SP_PASSWORD` if it's a multi-tenant app registration already
  provisioned as a service principal in each tenant, different
  `AZ_SP_TENANT` each time.
- Whichever identity ends up logged in needs rights to **read** storage
  accounts and **delete** blob containers (via ARM) on every subscription
  in scope — e.g. Contributor, Storage Account Contributor, or a narrower
  custom role with `.../containers/read` and `.../containers/delete`. Note
  this is a different, and larger, permission than the `blobs/read`
  data-plane action Lucidity's own read-only role holds — this script is
  meant to be run by an operator, not by Lucidity's service principal.
- MG mode (`-m`) additionally needs Reader (or better) **at the management
  group** to enumerate its child subscriptions.
- No `jq`/`python` dependency — pure bash + `az` CLI TSV parsing. Plain
  indexed arrays only (no bash 4 associative arrays), so it runs fine under
  macOS's default `/bin/bash` (3.2) with no version gate needed.
- **Deletion is irreversible** unless the storage account has blob
  soft-delete enabled for containers, in which case Azure retains it for
  the account's configured retention window instead of purging it
  immediately — check `az storage account blob-service-properties show`
  if you need to know before running. Either way, always dry-run first.

## What it actually does

1. **Ensures prerequisites**: installs the Azure CLI if missing, and logs
   in (interactively, or via a service principal from `AZ_SP_*` env vars)
   if not already authenticated.
1. **Resolves scope** — either the subscription IDs you passed directly (or
   every subscription visible to the caller, with `-s all`), or every
   subscription under the management group(s) you passed (nested MGs
   included, via `az account management-group entities list`).
2. **Lists storage accounts** in each subscription in scope (or just the
   ones named in `-a`), optionally narrowed further by `-r` on resource
   group name.
3. **Checks each account** for a container named `lucidity-inventory` (or
   whatever `-t` was given) via `az storage container-rm exists` — a
   control-plane check, no data-plane keys involved.
4. **Confirms** before touching anything real: prints every container it
   found, across every account/subscription, and asks `Proceed? [y/N]`.
   Skipped automatically under `--dry-run` (nothing to confirm) or `--yes`
   (for unattended/CI runs).
5. **Deletes** each one via `az storage container-rm delete --yes`, logging
   success/failure per account and continuing through the rest of the batch
   if one fails — a permissions gap or resource lock on one account should
   never abort the whole run.
6. **Prints a summary**: how many subscriptions were scanned (and how many
   were skipped for lack of access), how many containers were found,
   deleted, and failed, and where the log file is.

The script is not idempotent-with-state like `gpv2_migrate.sh` — there's no
state file to resume from, because there's nothing to resume: an account
whose container is already gone simply won't show up as "found" on the next
run, so re-running is always safe.

## Troubleshooting

- **"No child subscriptions enumerated for management group..."** — the
  identity running the script needs Reader (or better) *at the management
  group itself* to enumerate child subscriptions via `az account
  management-group entities list`.
- **"Could not list storage accounts in subscription \<id\>"** — no access
  to that subscription (or the call failed for another reason). The
  script logs this and moves to the next subscription rather than
  aborting the whole run.
- **A delete keeps failing** — check the log file for the actual Azure CLI
  error; the most common causes are a missing
  `.../blobServices/containers/delete` RBAC action, or a resource lock on
  the storage account/resource group.
- **The container reappears / still shows up in the Azure portal after a
  "deleted OK" line** — check whether blob soft-delete for containers is
  enabled on that storage account; a soft-deleted container is retained
  for the account's configured window before it's actually purged.
