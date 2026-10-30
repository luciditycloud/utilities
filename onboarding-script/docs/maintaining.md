# Maintaining lucidity-onboarding.sh (for Lucidity)

Notes for Lucidity's team on testing and maintaining
[`lucidity-onboarding.sh`](../lucidity-onboarding.sh). Customer-facing
documentation is in the [README](../README.md).

## Keeping the docs in sync

Whenever the script changes, update in the same change:

- [README.md](../README.md): what customers see (options, prompts, statuses,
  troubleshooting).
- [testing-guide.md](testing-guide.md): the scenarios, expected output and
  test log.
- This page: settings without options, blob setup details, network details
  and open items.

Then run through the [testing guide](testing-guide.md) in a test
subscription.

## Script version

`SCRIPT_VERSION` at the top of the script is printed at the start of every
run and recorded in the report. Set it to the date of each change, so a
report shows which version a customer ran.

## Settings without options

These defaults at the top of the script have no command-line option. Change
them in the file only when needed:

| Setting | What it does |
|---|---|
| `SP_OBJECT_ID` | Lucidity's service principal object ID. Empty (default): found from `LUCIDITY_APP_ID`, and created if missing |
| `STORAGE_ACCOUNTS` | Limit the storage step to these accounts; empty means all in the onboarded subscriptions |
| `STORAGE_NETWORK_CHECK` | Check storage firewalls (default `true`) |
| `BLOB_VISIBILITY` | Blob inventory permissions (default `true`) |

## Blob visibility setup (`--blob-setup`)

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
- Blob optimization (`--feature-modules blobs`) has its own container and blob
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

Other storage values in the report: `not_found` (a name in
`STORAGE_ACCOUNTS` doesn't exist), `not_checked`
(`STORAGE_NETWORK_CHECK=false`), and `pending_approval` (changes not
approved, or no terminal).

The console shows counts only (accounts needing each rule, manual action,
blob setup), so it stays readable with hundreds of accounts. Each account's
status and changes are in the report's `storage.accounts`.

## Network check only (`--network-check-only`)

For customers whose roles are already in place but whose storage firewalls
need Lucidity's rules (for example, new storage accounts, or to move from
the IP rule to the subnet rule). The run finds the target subscriptions as
usual, then does only the storage firewall check and its prompt: it doesn't
resolve or create the service principal, assign any role, or do blob setup.
It can't be combined with `--mode`, `--feature-modules`, `--blob-setup` or
`--no-guest-insights`. The report's `mode` is `network-check-only`.

## How Lucidity's traffic reaches a storage account

Lucidity's backend runs in `aks-subnet` (`LUCIDITY_SUBNET_IDS`), which has a
**Global** `Microsoft.Storage` service endpoint (`Microsoft.Storage.Global`)
since 2026-10-30. Traffic to storage accounts in every region goes over the
endpoint, with a private source address, so the subnet rule is what lets it
in. Azure IP rules don't apply to this traffic.

| Public network access | Result | What the script does |
|---|---|---|
| Enabled from all networks | Reachable | Nothing (`open`) |
| Enabled from selected networks | Reachable once the subnet rule is added | Adds it (`needs_rule`) |
| Disabled | Unreachable: Azure ignores firewall rules and allows only private endpoints, and Lucidity has none. Service endpoint traffic is blocked too, as it goes to the public endpoint | Reports it (`public_access_disabled`); out of scope |
| Secured by a network security perimeter | Depends on the perimeter's access rules | Reports it (`network_perimeter`) |

**Before 2026-10-30** the endpoint was Regional (East US). Azure accepted the
subnet rule only on accounts in East US, West US and West US 3, so accounts
elsewhere got an IP rule for Lucidity's outbound IP `4.157.111.90` instead,
and accounts in those three regions got both. Azure rejected the subnet rule
elsewhere whatever the public access setting (tested 2026-10-24 and
2026-10-29: `NetworkAclsValidationFailure`, "Only resources in eastus,
westus, westus3 can be ACL-ed to virtual networks in eastus").

**Moving existing customers over:** the IP is now in
`LUCIDITY_RETIRED_EGRESS_IPS`, so a rerun (`--network-check-only` is
enough) adds the subnet rule and then removes the IP rule, account by
account. If adding the subnet rule fails, the IP rule is left in place.
Customers who don't rerun keep both rules: the IP rule then has no effect
for traffic over the endpoint, so whether those accounts stay reachable
depends on their existing subnet rule (only accounts in the three regions
above have one).

Tested 2026-10-30: Azure accepted the subnet rule on a UK South account
(`state` `Succeeded`), and a `--network-check-only` rerun removed the old IP
rule. Not tested: blob reads from `aks-subnet` through the Global endpoint,
in particular to an account outside East US, West US and West US 3 with only
the subnet rule.

## Network details

The *Lucidity network details* block at the top of the script holds values
that change on Lucidity's side:

- **Subnet:** `LUCIDITY_SUBNET_IDS`, with `LUCIDITY_SUBNET_REGIONS="*"`
  (every region, as the endpoint is Global). If Lucidity moves to another
  subnet, put the new ID in `LUCIDITY_SUBNET_IDS` and the old one in
  `LUCIDITY_RETIRED_SUBNET_IDS`: a rerun adds the new rule and then removes
  the old one.
- **Outbound IPs:** `LUCIDITY_EGRESS_IPS` is empty, so no IP rules are
  added. `LUCIDITY_RETIRED_EGRESS_IPS` holds the IP that earlier versions
  added, so a rerun removes it. If IP rules are ever needed again, put the
  IPs in `LUCIDITY_EGRESS_IPS` and their expected change date in
  `LUCIDITY_EGRESS_IPS_VALID_UNTIL`; after that date runs warn that the IP
  may be outdated.
- Customers who downloaded the script earlier need the new version to pick
  up any of these changes.

## Open items

As of 2026-10-30.

**Pointers**
- Lucidity's outbound IP `4.157.111.90` may change around 2026-11-16. The
  script no longer adds IP rules, so this matters only if they come back
  (see [Network details](#network-details)).
- The sales team needs the 2026-10-30 script so customers move to the
  subnet rule.

**Not yet tested in real Azure** (see the test log in
[testing-guide.md](testing-guide.md))
- Changes of 2026-10-29, tested only against a simulated Azure CLI: short
  options, `--feature-modules`, the `management-group` default,
  `--network-check-only`, and the count-based storage output.
- Management group scope without `--scope-ids` (kept as a fallback, with a
  warning, but deliberately not in the README or `--help`: customers should
  give the management group IDs): it picks the management groups with no
  accessible parent, using each entity's `permissions`
  (`noaccess` means not accessible) and `parentNameChain` from
  `az account management-group entities list`. Tested 2026-10-29 only in a
  tenant where the account can access no group (the root group showed
  `permissions` `noaccess`; the script stopped with an error). Check a
  tenant where the account can access the root group, and one where it can
  access only some groups.
- The all-subscriptions default with its confirmation (only the
  "nothing left after exclusions" case was run in real Azure).
- Management group scope with several subscriptions or nested groups, and
  skipping subscriptions that aren't enabled. Tested: one group with one
  subscription, a missing group, and a group role created with data
  permissions and assigned on the subscription.
- Add-only role updates that actually add permissions (rerunning with
  nothing to add is tested), and `--no-guest-insights`.
- Subnet rules for a customer storage account in a **different tenant**
  from Lucidity's subnet. Tested only within one tenant, on an East US
  account.
- Blob reads from `aks-subnet` through the Global endpoint, in particular to
  an account outside East US, West US and West US 3 with only the subnet
  rule. The rule itself is tested: on 2026-10-30 Azure accepted it on a UK
  South account, and a rerun removed the old IP rule.
- Creating Lucidity's service principal from its real application. Tested
  with a test app in the same tenant; Lucidity's multi-tenant app in a
  customer tenant is untested.
- Running without a terminal, and `--auto-approve`.
- Which firewall rule carries Lucidity's traffic in each region, and that
  public access disabled blocks it even with a subnet rule: needs access to
  `aks-subnet` (see
  [How Lucidity's traffic reaches a storage account](#how-luciditys-traffic-reaches-a-storage-account)).

## Previous version

The earlier read-only assessment script, its `teardown.sh` and README are in
[`legacy/`](../legacy/). There is no teardown script for this version.
