# `cost` -- Vultr spend estimator for a `terraform.tfvars`

`modules/ai-factory-ha`'s cheapest GPU pool is four figures a month and its
most expensive is $45,696/month. Until now the only pricing information was
four hand-maintained Markdown tables (`PLATFORM-NOTES.md`,
`examples/ha-cluster/README.md`, `terraform.tfvars.example`,
`modules/ai-factory-ha/variables.tf`) that list bare metal GPU plans only --
nothing about the control plane, the jumphost, the two load balancers, the
NAT gateway, or the snapshot -- and that go stale silently whenever Vultr
changes a price.

`cost` takes a `terraform.tfvars`, resolves it against the module's own
`variables.tf` defaults, fetches Vultr's public plan catalog, and prints a
per-resource breakdown across 1h/8h/24h/7d/30d. It never talks to your
account: both catalog endpoints it calls are unauthenticated, so this works
before you have provisioned anything and without a `VULTR_API_KEY`.

This is a separate Go module (`tools/cost/go.mod`), so the repo root itself
stays Go-free and nobody running Terraform ever sees a `go.sum`.

## Usage

```
go build -o cost .
./cost [flags] terraform.tfvars
```

| Flag | Default | Meaning |
|---|---|---|
| `--defaults PATH` | walk up from the tfvars' directory | path to `modules/ai-factory-ha/variables.tf` |
| `--region ID` | (from the tfvars) | override the region; required if the tfvars sets none |
| `--json` | off | print a self-contained JSON report instead of a table |
| `--plans FILE` | (network) | load the plan catalog from a file instead of the API |
| `--no-network` | off | never call the live API; use `--plans` or a warm cache |
| `--allow-unknown-plans` | off | price an unrecognized plan ID as $0 with a warning, instead of failing |
| `--durations LIST` | `1h,8h,24h,7d,30d` | comma-separated durations (`h`/`d` units) |

```bash
# Against a real tfvars.
./cost ../../examples/ha-cluster/terraform.tfvars

# Offline, against a saved catalog snapshot, as JSON.
./cost --no-network --plans internal/vultr/testdata/plans.json --json terraform.tfvars

# A region override, e.g. to compare against the one region (sao) that
# carries a location_cost surcharge on most plans.
./cost --region sao terraform.tfvars
```

Exit codes: `0` success, `2` a configuration problem (tfvars, `variables.tf`,
or flags), `3` a pricing-data problem (catalog unreachable, or a plan ID this
tool has never heard of at a non-zero quantity). Warnings go to stderr and,
under `--json`, also into the report's own `warnings` array, so a captured
JSON document is self-contained even in a script that discards stderr.

## Where the numbers come from

Catalog prices are fetched live from `GET /v2/plans?per_page=500` and
`GET /v2/plans-metal?per_page=100` -- both public, no API key. `hourly_cost`
is used verbatim, never derived from `monthly_cost`: measured across the
live catalog, `monthly_cost / hourly_cost` ranges from 664 to 1363 depending
on the plan, so treating one figure as authoritative for the other silently
mis-prices things. Whether a plan is capped at its monthly rate is decided by
its own `invoice_type` field (`"monthly"` vs `"hourly"`), not by its ID
prefix -- the default `control_plane_plan` (`vx1-g-4c-16g-240s`) looks like
an ordinary capped cloud plan but is `invoice_type: "hourly"` and never caps,
while the default `jumphost_plan` (`vc2-6c-16gb`) does.

Three items have no rate card in the API at all and are hardcoded here, each
cited at its constant in `internal/pricing/rates.go`:

| Item | Rate | Source |
|---|---|---|
| Load balancer, per node | $0.015/hr, capped at $10/month | <https://www.vultr.com/pricing/> ("Load Balancers"), <https://docs.vultr.com/vultr-load-balancers-overview> |
| NAT gateway | $0.03/hr, capped at $20/month | <https://www.vultr.com/pricing/#nat-gateways> |
| Snapshot storage | $0.05/GB/month, no cap | <https://docs.vultr.com/vultr-snapshots-overview> ("Billing") |

`0.015 * 672 = 10.08` and `0.03 * 672 = 20.16`, so the round monthly figures
and 672 hours are each other's rounding, not two independently chosen
numbers -- which is also why capping has to be done on dollars
(`monthly_cost`/the constant above), never on a literal 672- or 730-hour
cutoff.

The snapshot is the one line item that is not a Terraform resource at all: it
is built out-of-band by the jumphost's `image-factory.sh.tftpl` via the Vultr
API, and `terraform destroy` does not remove it (recorded at
`image-factory.sh.tftpl:430`). It is always priced as exactly one snapshot,
sized from `image_disk_size`, prorated into every duration column *and*
restated in the table's footer as continuing to bill after a destroy.

Money is stored as `int64` micros (millionths of a dollar), parsed from the
API's JSON via `json.Number` -> `big.Rat` -- never through a `float64` -- so
e.g. `0.153` becomes exactly `153000` rather than a binary-float
approximation, and the golden test files under `internal/render/testdata`
stay byte-stable from run to run.

## How a tfvars is parsed

`terraform.tfvars` and `variables.tf` are both parsed with
[`hashicorp/hcl/v2`](https://github.com/hashicorp/hcl), not a hand-rolled
scanner: `variables.tf` has braces inside quoted regexes
(`can(regex("^[a-z0-9]([a-z0-9-]{0,14}[a-z0-9])?$", k))`, four times) that a
brace-counter ends a block early on, plus two top-level `check` blocks a
scanner has no way to recognize and skip. HCL's own parser tokenizes both
correctly.

The harder problem is that `gpu_bare_metal_pools` and `gpu_cloud_pools`
declare their per-attribute defaults (`count = optional(number, 1)`,
`vpc_only = optional(bool, true)`) inside the variable's `type` expression,
not in `default`. `hcl/v2`'s `ext/typeexpr` package (no extra dependency)
extracts those via `typeexpr.TypeConstraintWithDefaults`, and the two-step
`defs.Apply(raw)` then `convert.Convert(val, ty)` order matters: converting
first turns a missing optional attribute into `null` (the type constraint
marks it optional, so conversion happily fills a hole with `null`), leaving
the defaults tree nothing left to apply. This mirrors Terraform's own
`configs/named_values.go`.

`internal/tfconfig.Config` is this tool's security boundary: it is a narrow
struct (`Region`, `ClusterName`, `DeployNodes`, `ControlPlaneCount`,
`ControlPlanePlan`, `JumphostPlan`, `BareMetalPools`, `CloudPools`,
`LBNodes`, `IngressController`, `ImageDiskGB`, and `SnapshotIDSet` -- presence
of `snapshot_id`, never its value), and no `cty.Value` read from a tfvars
ever escapes `Resolve` into anything else. Every credential-shaped variable
the real module declares (`vultr_api_key`, `root_password_hash`,
`ssh_authorized_keys`, the SUSE/AppCo/NVIDIA credentials, ...) is simply
never looked up by name, so there is no field for a value to leak through
even by accident. Diagnostics never go through `hcl.NewDiagnosticTextWriter`,
which echoes the offending source line -- in a tfvars, that line can be a
credential -- and instead print only `file:line:col: Summary`, with `Detail`
dropped outright whenever the diagnostic's source is inside the tfvars.

## Known limits

- **Snapshot size is a ceiling.** `image_disk_size` is the raw disk size that
  gets imported; Vultr bills the imported snapshot's actual (smaller) size.
  Snapshots also accumulate across rebuilds -- this tool always counts
  exactly one.
- **Bandwidth overage is unknowable ahead of time** ($0.01/GB outbound).
  Each plan reports an included bandwidth pool; showing that is possible,
  predicting overage is not, so this tool does neither.
- **Bare metal has no `location_cost`** in the API, so regional variation on
  `vbm-*` plans cannot be detected. The same is true of the LB and NAT
  gateway constants above, which Vultr's own docs say vary by region.
- **The cap rule is inferred.** Vultr documents the 672-vs-730-hour split by
  product family, not by `invoice_type`; the mapping used here is observed
  against the live catalog, not published anywhere.
- **`30d` is 720 hours, which is not a calendar month.** For a capped
  (`invoice_type: "monthly"`) plan this makes no difference -- the cap binds
  first. For an uncapped one it undershoots the plan's published
  `monthly_cost` by roughly 1.4%, because Vultr derives that figure from ~730
  hours: `vbm-48c-1024gb-4-a100-gpu` is $9.589/hr, so this tool's 30 d column
  reads $6,904.08 against the $7,000/month quoted in `PLATFORM-NOTES.md` and
  the example's README. Both are right; they are answering different
  questions. Use `--durations 730h` for the calendar-month equivalent.
- **Excluded outright, because the module never enables them:** auto-backups
  (+20%), DDoS protection ($10/mo/IP), reserved IPs ($3/mo), block storage,
  object storage, and preemptible pricing (`*_preemptible` fields are read
  from the catalog but never used -- the module never requests preemptible
  capacity).

## Development

```bash
make build   # go build -o cost .
make test    # go test ./...
make fixtures  # refresh internal/vultr/testdata from the live API (network; not part of `make test`)
```

See `internal/tfconfig/testdata`, `internal/vultr/testdata`, and
`internal/render/testdata/golden` for the fixtures `go test` runs against by
default -- all placeholder or fabricated values, never real credentials (see
`.gitignore`'s carve-out for `tools/cost/**/testdata/**`).
