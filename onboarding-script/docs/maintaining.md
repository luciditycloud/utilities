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
need Lucidity's rules (for example, new storage accounts, or after
Lucidity's outbound IP changes). The run finds the target subscriptions as
usual, then does only the storage firewall check and its prompt: it doesn't
resolve or create the service principal, assign any role, or do blob setup.
It can't be combined with `--mode`, `--feature-modules`, `--blob-setup` or
`--no-guest-insights`. The report's `mode` is `network-check-only`.

## How Lucidity's traffic reaches a storage account

Lucidity's backend runs in `aks-subnet` (East US), which has a Regional
`Microsoft.Storage` service endpoint, and goes out to the internet through
a load balancer with a public IP (`LUCIDITY_EGRESS_IPS`).

| Public network access | Result | What the script does |
|---|---|---|
| Enabled from all networks | Reachable | Nothing (`open`) |
| Enabled from selected networks | Reachable once Lucidity's rules are added | Adds the rules (`needs_rule`), by region as below |
| Disabled | Unreachable: Azure ignores firewall rules and allows only private endpoints, and Lucidity has none. Service endpoint traffic is blocked too, as it goes to the public endpoint | Reports it (`public_access_disabled`); out of scope |
| Secured by a network security perimeter | Depends on the perimeter's access rules | Reports it (`network_perimeter`) |

For selected networks, the region decides which rule works:

- **East US, West US, West US 3** (`LUCIDITY_SUBNET_REGIONS`): traffic from
  the subnet goes over the service endpoint with a private source address,
  so only the **subnet rule** lets it in. Azure IP rules don't apply to this
  traffic. The script still adds the IP rule: it has no effect while the
  endpoint is in place, costs nothing, and covers traffic that doesn't take
  the endpoint.
- **Every other region:** traffic leaves through the public outbound IP, so
  only the **IP rule** works. Azure rejects the subnet rule (retested
  2026-10-29 on a UK South account: `NetworkAclsValidationFailure`,
  "Microsoft.Storage resources in uksouth cannot be ACL-ed to virtual
  network … in eastus. Only resources in eastus, westus, westus3 can be
  ACL-ed to virtual networks in eastus").

The rejection is tested. Which rule actually carries the traffic in each
region is from Azure's documented behaviour, not tested: that needs blob
reads from a pod in `aks-subnet` against accounts with one rule each (East
US and West US 3 with the subnet rule only and with the IP rule only, UK
South with the IP rule only, and East US with public access disabled and a
subnet rule). The script adds both rules where it can, so its result doesn't
depend on which one it is.

## Network details

The *Lucidity network details* block at the top of the script holds values
that change on Lucidity's side:

- **Outbound IP changes:** put the new IP in `LUCIDITY_EGRESS_IPS`, move the
  old one to `LUCIDITY_RETIRED_EGRESS_IPS`, and update
  `LUCIDITY_EGRESS_IPS_VALID_UNTIL`. A customer rerun then adds the new rule
  and removes the old one. After the valid-until date, runs warn that the IP
  may be outdated. Customers who downloaded the script earlier need the new
  version.
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

## Open items

As of 2026-10-29.

**Scheduled changes**
- Lucidity's outbound IP changes around 2026-11-16: update
  `LUCIDITY_EGRESS_IPS`, move the old IP to `LUCIDITY_RETIRED_EGRESS_IPS`,
  and update `LUCIDITY_EGRESS_IPS_VALID_UNTIL`.
- Global service endpoint: switch over as described above.

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
  `az account management-group entities list`. Check those fields in a real
  tenant, both with and without access to the tenant root group.
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
- The region-aware subnet rules on real accounts in covered regions other
  than East US (West US, West US 3).
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
