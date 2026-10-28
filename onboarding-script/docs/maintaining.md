# Maintaining read-only.sh (for Lucidity)

Notes for Lucidity's team on testing and maintaining
[`read-only.sh`](../read-only.sh). Customer-facing documentation is in the
[README](../README.md).

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
- Blob optimization (`--features blobs`) has its own container and blob
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

As of 2026-10-28.

**Scheduled changes**
- Lucidity's outbound IP changes around 2026-11-16: update
  `LUCIDITY_EGRESS_IPS`, move the old IP to `LUCIDITY_RETIRED_EGRESS_IPS`,
  and update `LUCIDITY_EGRESS_IPS_VALID_UNTIL`.
- Global service endpoint: switch over as described above.

**Not yet tested in real Azure** (see the test log in
[testing-guide.md](testing-guide.md))
- The command-line options, the all-subscriptions default with its
  confirmation, and `--exclude-ids`. Tested only against a simulated Azure
  CLI.
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

## Previous version

The earlier read-only assessment script, its `teardown.sh` and README are in
[`legacy/`](../legacy/). There is no teardown script for this version.
