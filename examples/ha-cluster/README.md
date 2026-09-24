# SUSE AI Factory HA cluster on Vultr

Terraform example that provisions a highly-available SUSE AI Factory cluster
on Vultr: a jumphost that builds the elemental image and imports it as a
snapshot, three `vpc_only` control-plane VMs behind two Vultr load balancers —
one acting as the Kubernetes API VIP, one fronting the Traefik ingress — and
any mix of GPU worker pools (bare metal, cloud, or both), all from a single
(two-pass) `terraform apply`. Uses `modules/ai-factory-ha`.

You do not build or import the elemental snapshot yourself: the jumphost
builds and serves it, and Terraform imports it as a `vultr_snapshot_from_url`
it owns — so `terraform destroy` deletes it too. See the module's design notes for the full topology
and rationale.

## Prerequisites

- Terraform >= 1.9 (the module's `vpc_subnet` validation cross-references
  another variable, which is only legal from 1.9).
- `VULTR_API_KEY` exported in the environment (read by the `vultr` provider
  and by the module's snapshot-wait script).
- `vultr_api_key` in `terraform.tfvars`, for the plan-time stock checks. It
  stays on your machine, so the same value as `VULTR_API_KEY` is fine.
- Two different `openssl passwd -6` hashes: `root_password_hash` and
  `node_user_password_hash`. Terraform rejects the plan if they match.
- At least one public key for `ssh_authorized_keys` -- this is how you get
  into the elemental nodes, as `node_username` (default `suse`). Root SSH is
  off unless you set `permit_root_ssh = true`.

  All of these are baked into the image via `butane.yaml`, so **changing any
  one of them rebuilds the image and replaces every node**.
- SUSE Application Collection credentials (`appco_username`/`appco_password`).
  **Required** whenever `components` lists `local-path-provisioner` or
  `suse-storage` -- both charts and their images are pulled from Application
  Collection, so the plan fails up front without them rather than leaving the
  cluster with a storage provisioner stuck in `ImagePullBackOff`.
- Optional but highly recommended: a SUSE registration code + registry
  password (`suse_registration_code`/`suse_registry_password`) and an NVIDIA
  NGC API key (`nvidia_api_key`), both handed to aif-operator. Whatever is unset
  is omitted from `aif-operator.yaml`'s `credentials:` block. Each
  username/password pair must be set together or not at all.
- At least one admin CIDR for `admin_cidrs` (your IP or VPN range).
- At least one GPU pool in `gpu_bare_metal_pools` or `gpu_cloud_pools` --
  **both default to `{}`, and every real option is expensive.** See below.
- A `core_platform_override`. Not optional in practice: without it the build
  silently produces nodes with no Kubernetes on them at all. See below.

### Logins

Two unprivileged accounts, both named `suse` by default, on two different
kinds of machine — and they do **not** work the same way.

**The jumphost** (`jumphost_username`, plain openSUSE, created by cloud-init):
passwordless sudo, the same `ssh_authorized_keys` as root, password login
locked. Set it to `""` for a root-only jumphost. The `jumphost_ssh_login`
output prints whichever login applies, so `ssh $(terraform output -raw
jumphost_ssh_login)` works either way. Changing it replaces the jumphost,
which rebuilds the image.

**The elemental nodes** (`node_username`, created by the image's
`butane.yaml`): `ssh_authorized_keys`, its own `node_user_password_hash`, and
**no sudo** — there is no `sudo` binary in the elemental OS image, no `wheel`
group, no sudoers rules. Escalate with `su -` and the root password. So
anything privileged, `kubectl` with the RKE2 kubeconfig included, costs a
second credential:

```bash
ssh suse@<node>
su -                         # root_password_hash, not node_user_password_hash
kubectl get nodes
```

`permit_root_ssh = true` restores the old behaviour — `PermitRootLogin yes`
plus the SSH keys on root — which is worth doing on a throwaway cluster, since
every node-side check in the troubleshooting section below wants root and the
`su -` step gets old fast. It is an image-wide setting either way: flipping it
rebuilds the image and replaces every node.

Root keeps `root_password_hash` regardless — that is the console login (Vultr's
web console is the only way in when SSH itself is broken) and the password
`su -` asks for.

### AI Factory version

`aif_version` (default `"2.2.0"`) picks the release manifest, and the manifest
is what pins every chart version installed. The value becomes a **tag** in
SUSE/aif — `aif-operator-<version>` — and the manifest is read from that tag:

```hcl
aif_version = "2.2.0"        # -> tag aif-operator-2.2.0
aif_version = "2.1.0"        # -> aif-operator-2.1.0
aif_version = "2.3.0-dev.2"  # -> aif-operator-2.3.0-dev.2, a pre-release
```

It must be a full `X.Y.Z`: there is no `2.2` tag, so there is no `"2.2"` here.
`2.1.0` is the oldest that works (`aif-operator-2.0.x` ships no manifest), and
a version SUSE has not tagged fails at plan time with a 404 naming the tag it
looked for. `git ls-remote --tags https://github.com/SUSE/aif` lists what
exists.

A tag and not the `release-2.2` branch because a tag cannot move under a
cluster you already built. Terraform still reads the fetched manifest's own
`metadata.version` and prints a plan-time **warning** when it differs from
what you asked for — worth having, because upstream metadata does drift from
its own tag (`aif-operator-2.2.0-rc.1`'s manifest says `2.0.1`).

To build from something that is not a tag — a branch, a fork, a mirror — set
`aif_release_manifest_url`, which overrides `aif_version` entirely:

```hcl
aif_release_manifest_url = "https://raw.githubusercontent.com/SUSE/aif/refs/heads/main/uc-release-manifest/release_manifest.yaml"
```

This selects the **charts** only. The OS image is pinned separately and does
not follow it — `elemental_image`, `core_platform_override` and
`sysext_image_overrides`. Changing `aif_version` rebuilds the image and
replaces every node, same as `components` below.

### Components

`components` (default `["rancher", "gpu-operator", "local-path-provisioner",
"aif-operator"]`) picks which SUSE AI Factory Helm charts `release.yaml`
enables. Known names: `cert-manager`, `rancher`, `gpu-operator`,
`local-path-provisioner`, `suse-storage`, `aif-operator`. They are always
rendered in a fixed canonical order, not the order given here, so the default
value reproduces exactly what this module has always shipped.

Rules, enforced at `terraform validate` time:

- `cert-manager` is injected automatically whenever `rancher` is selected --
  listing it yourself is accepted but never required.
- `local-path-provisioner` and `suse-storage` (Longhorn) cannot both be
  listed: both set themselves as the default StorageClass.
- `aif-operator` requires `rancher`.
- `aif-operator` requires one of `local-path-provisioner` or `suse-storage`.

Selecting `local-path-provisioner` ships a `local-path-prep.service` that
creates `/opt/local-path-provisioner` at boot with `mkdir -pZ`. Nothing to
set. The chart stores every PVC there and does not create the directory
itself, so without the unit the provisioner's helper pod fails with
`mkdir: can't create directory ...: Permission denied` and the PVC never
leaves `Pending`. `-Z` is the working part: a directory created without it
inherits `usr_t` from `/opt`, which no container may write, while `-Z` takes
the label from the loaded policy — and `rke2-selinux` maps that exact path to
`container_file_t`. Ignition cannot do this instead; `/opt` belongs to the
read-only image at Ignition time and only becomes writable once the real root
is up.

Selecting `suse-storage` also enables the `suse-storage` systemd system
extension, which is what supplies `open-iscsi` — Longhorn refuses to start
without `iscsiadm`, and the base OS image has none. The module writes that
into `release.yaml` for you; nothing to set. Its replicas are
pinned to the control-plane nodes only, via a `node.longhorn.io/create-default-disk=true`
label RKE2 applies at node registration (`kubernetes/config/server.yaml`) --
GPU nodes still run Longhorn's manager/CSI DaemonSets so they can *mount* a
volume, they just never store replica data.

The extension by itself is not enough, and the module makes up the difference:
a systemd extension can only supply `/usr`, so the node gets `iscsid` but none
of the `/etc` state it needs to run (no `/etc/iscsi`, no `InitiatorName`, no
`iscsid.conf`, and the unit left `disabled`). Selecting `suse-storage`
therefore also ships an `iscsi-prep.service` that creates all of it at boot and
starts `iscsid`. Nothing to set. Worth knowing only because of how the missing
piece presents: everything looks healthy — pods `Running`, PVC `Bound`,
replicas scheduled — and the pod using the volume sits in `ContainerCreating`
until it is fixed.

The image that extension is built from is **not** the one the manifest pins.
AIF 2.2 pins the GA `registry.suse.com/elemental/longhorn:4.111-4.79`, which
does not match the beta OS image `core_platform_override` has to select, so
`sysext_image_overrides` defaults to the beta build and rewrites the manifest
before the build reads it:

```hcl
sysext_image_overrides = {
  suse-storage = "registry.suse.com/beta/uc/longhorn:5.279-4.13"  # the default
}
```

Nothing to set — and nothing happens unless you select `suse-storage`: an
override for an extension no enabled component pulls in is dropped, so on the
default chart set this rewrites nothing and does not change the build id.

Two things to know once it does apply. Keys are extension names as the
*manifest* spells them, and naming one the manifest does not declare fails the
build immediately rather than silently doing nothing; so if you point
`aif_release_manifest_url` at a manifest with no `suse-storage` extension,
set `sysext_image_overrides = {}`. A name the module could never enable (a
typo) is dropped instead, with a plan-time warning.

**Two warnings:**

- **Changing `components` rebuilds the image and replaces every node.**
  `release.yaml` is baked into the image; this is not the rebuild-free
  scale-out path described above for GPU pools.
- **Switching `local-path-provisioner` to `suse-storage` is not a migration.**
  It is a new cluster with a different default StorageClass and no data
  carried across from the old one.

### Ingress, and the second load balancer

`ingress_controller` defaults to `traefik`, written into RKE2's server config.
RKE2 packages Traefik as a **DaemonSet that takes hostPort 80/443**, so no
`NodePort` and no `type: LoadBalancer` Service is involved — the node itself
answers on those ports. (A `type: LoadBalancer` Service would sit `<pending>`
forever here anyway: `apiVIPMode: external` keeps MetalLB out and there is no
cloud controller manager.)

Two knock-on decisions:

- **A `HelmChartConfig` pins the DaemonSet to the control-plane nodes.**
  Unpinned, it would also bind 80/443 on any GPU node's public IP — and a bare
  metal one has **no Vultr firewall** (see the exposure section below). The
  control planes are `vpc_only`, so there those ports exist only in the VPC.
- **A second Vultr load balancer, not two more rules on the API one.**
  `proxy_protocol` is a per-load-balancer flag and RKE2's 6443/9345 listeners
  do not speak PROXY, so it cannot be enabled on the API LB. Without it every
  access log and IP allowlist in the cluster sees the load balancer's own VPC
  address instead of the client. A Vultr LB also has exactly one health check;
  separating them lets the ingress LB probe Traefik's `/ping` (on hostPort
  8080, VPC-only) rather than inherit a TCP probe of 6443.

Both load balancers take the same control-plane backends, so `deploy.sh`'s
pass 2 fills both from one variable. Cost: roughly $10/month extra.

Hostnames, both `sslip.io` so nothing needs a DNS zone of your own:

| Output | Default | What it is |
|---|---|---|
| `rancher_hostname` | `rancher-<ingress_lb_ipv4>.sslip.io` | Rancher's Ingress host; `rancher_url` is the same with `https://` |
| `api_host` | `rke2-<api_vip>.sslip.io` | elemental `network.apiHost`, added to the API server certificate's SANs so a kubeconfig can use a name |

Set `ingress_controller = "none"` to skip the ingress load balancer entirely;
`rancher_hostname` then falls back to the API load balancer's address, where
nothing serves it. `ingress-nginx` is accepted but went end-of-life upstream in
March 2026 and is removed in RKE2 v1.37; it gets no pinning and no LB here.

### GPU pools: two families, mixable, both empty by default

GPU workers are declared as **maps of pools**, one map per Vultr resource
family, and a cluster may use any combination:

```hcl
gpu_bare_metal_pools = {
  mi325x = { plan = "vbm-256c-3072gb-8-mi325x-gpu", count = 2 }
}
gpu_cloud_pools = {
  a100 = { plan = "vcg-a100-12c-120g-80vram", count = 2 }
  big  = { plan = "vcg-a100-96c-960g-640vram", count = 1, vpc_only = false }
}
```

`vpc_only` defaults to **`true`** on a cloud pool: no public NIC, egress
through the NAT gateway, admin through the jumphost — the same shape as a
control-plane node. Set it `false`, as `big` does above, when you want direct
SSH to the node or do not want multi-GB GPU-operator driver images funnelled
through the single shared NAT gateway; the NIC is still behind
`vultr_firewall_group.gpu_cloud` either way. Bare metal gets no say: a
`vultr_bare_metal_server` always has a public NIC.

Why maps rather than a count and a plan: GPU stock on Vultr is fragmented per
account and per region, so the plan you can get one of is rarely the plan you
can get four of. Mixing is the normal case, not an edge case.

**Pool names are node identity.** Nodes are `<cluster_name>-<pool>-NN`; that
hostname is what `/etc/hostname` and every RKE2 role decision key off, so
renaming a pool still replaces its nodes. Names must be unique across both
maps, 1-16 characters of `[a-z0-9-]`, and `cp` is reserved for the control
plane.

Adding a pool, renaming one, or bumping a `count` is now a pure Terraform
add/replace of just the affected nodes — no image rebuild, and nothing else in
the cluster is touched. Nothing node-shaped is baked into the image any more:
each node reads its own VPC address from Vultr's instance metadata at first
boot instead of looking itself up in a table computed at plan time (see
`modules/ai-factory-ha/README.md`'s "VPC addresses" section).

#### Bare metal — `gpu_bare_metal_pools`

`vultr_bare_metal_server`, `vbm-*` plans. Mandatory public NIC with **no
firewall of any kind** (see the exposure section below). From
`GET /v2/plans-metal`, every plan with an actual GPU (`gpu_brand != "none"`);
prices are list prices and indicative:

| Plan | GPUs | Cost/mo |
|---|---|---|
| `vbm-48c-1024gb-4-a100-gpu` | 4x A100 | $7,000 |
| `vbm-64c-2048gb-8-l40-gpu` | 8x L40S | $12,000 |
| `vbm-112c-2048gb-8-a100-gpu` | 8x A100 | $15,053 |
| `vbm-256c-3072gb-8-mi355x-gpu` | 8x MI355X | $15,126 |
| `vbm-112c-2048gb-8-h100-gpu` | 8x H100 | $16,074 |
| `vbm-256c-3072gb-8-mi325x-gpu` | 8x MI325X | $24,810 |
| `vbm-256c-3072gb-8-b200-gpu` | 8x B200 | $45,696 |

`vbm-72c-480gb-gh200-gpu` (~$2,009/month, 1x GH200) is meaningfully
cheaper, but it's **ARM** (NVIDIA Grace) and elemental3 only supports
customizing x86_64 images -- it isn't usable here regardless of price.

#### Cloud — `gpu_cloud_pools`

`vultr_instance`, `vcg-*` plans. The reason to prefer these where they exist:
`vultr_instance` takes a `firewall_group_id`, and under the default
`vpc_only = true` it has no public NIC at all, reaching registries through the
NAT gateway exactly as the control plane does.

`plan_type` is the plan's **own `type` field**, not its id prefix — check it
against an authenticated `GET /v2/plans?type=all`:

| Plan | GPUs | `type` | Notes |
|---|---|---|---|
| `vcg-a100-12c-120g-80vram` | 1x A100-80 | `vdm` | ~$1,750/mo, on-demand |
| `vcg-a100-96c-960g-640vram` | 8x A100-80 | `vdm` | ~$14,000/mo, on-demand |
| `vcg-h100-216c-1914gb-640vram` | 8x H100 | `vdm` | `deploy_ondemand: false` |
| `vcg-b200-248c-2826g-1536vram` | 8x B200 | `vdm` | ~$45,696/mo, `deploy_ondemand: false` |
| `vcg-mi325x-*`, `vcg-mi355x-*` | 8x MI3xx | `vdm` | `deploy_ondemand: false` |
| `vcg-a16-*`, `vcg-l40s-*`, `vcg-a40-<24c` | fractional | `vcg` | vGPU — see below |

Two traps:

- **Fractional (`type: vcg`) SKUs are not expected to work.** They are vGPU
  slices and need the matching NVIDIA guest driver built against the host's
  vGPU manager, which an elemental3 image does not carry and cannot DKMS-build
  into an immutable rootfs.
- **`deploy_ondemand: false` means preemptible-only.** This module does not
  request preemptible instances, so those plans will fail at create time even
  when the availability endpoint lists them.

`plan_type` is inferred from the plan id and normally needs no value: every
ordinary cloud family's prefix already **is** its type (`voc-*` is type `voc`,
`vx1-*` is `vx1`), and `vcg-*` resolves to `vdm`, right for every whole-node
SKU. The fractional row above is the only case where the prefix gets it wrong,
so it is the only case that has to say `plan_type = "vcg"` — and per the trap
above, those plans are not expected to boot anyway.

#### Standing in a non-GPU plan

Neither pool map insists on a GPU plan, and for exercising the code path you
do not want one: `ams` carries zero `vdm`/`vcg` stock and the cheapest `vbm`
GPU plan is $7,000/month. An ordinary dedicated-vCPU instance joins as a worker
like any other — firewall group, dual-NIC metadata, scale-out all behave
identically — it simply never gets a GPU, and the GPU operator's node feature
discovery leaves it alone.

```hcl
gpu_bare_metal_pools = {
  gpu = { plan = "vbm-6c-32gb-amd", count = 1 }
}
gpu_cloud_pools = {
  cgpu = { plan = "voc-c-4c-8gb-150s-amd", count = 1 }
}
```

#### Check stock before you commit

Most regions carry no GPU plans at all, in either family — and the availability
endpoint needs the `Authorization` header or it silently answers with an empty
list rather than a 401:

```bash
for t in vbm vdm vcg; do
  echo "== $t"
  curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
    "https://api.vultr.com/v2/regions/<region>/availability?type=$t"
done
```

The module runs this check itself during `plan` (`verify_plan_availability`,
default `true`) and names the offending pool when a plan is missing. Pools
with `count = 0` are skipped, so a pool can be parked at 0 while its plan is
out of stock.

### `elemental_image`'s default, and why it isn't the `:3.0` release

The released `registry.suse.com/elemental/elemental:3.0` tag does **not**
support `apiVIPMode: external`. That support
([SUSE/elemental PR #578](https://github.com/suse/elemental)) merged to
elemental's `main` branch. Without it, the image build
rejects `apiVIPMode` on its `oneof=managed external` validator and deploys
MetalLB regardless — which defeats the reason this module uses a Vultr load
balancer as the API VIP in the first place.

Instead, `elemental_image` defaults to `registry.suse.com/beta/uc/elemental:3.1.0-6.5`
— SUSE's own beta channel, version 3.1.0. **Confirmed directly, not taken on
word:** the tag was pulled and its compiled `elemental3` binary grepped for the
struct tag PR #578 added —
`apiVIPMode ... validate:"omitempty,oneof=managed external"` is present.
(The same check works for any candidate image: `podman pull`, extract the
layer, `strings <path>/elemental3 | grep apiVIPMode`.)

This is still a **beta** build, not a final tagged release, so treat it
like any pre-release: no stability guarantee, and it can be superseded.
Switch to a real tagged elemental release once one ships with the fix.
`registry.opensuse.org/devel/unifiedcore/tumbleweed/containers/elemental:latest`
(openSUSE's community continuous build, verified the same way) remains a
fallback if this tag is ever pulled or replaced.

### `core_platform_override` is effectively required

`elemental customize` only writes the media; the install runs later from the
**OS image's** own `elemental3ctl`, and every 3.0.x build silently ignores
`bootloader.initrdExtensions` -- the key that delivers the entire Kubernetes
firstboot chain. So the 3.1.0 customize container this example needs, paired
with any published OS image, produces nodes that boot perfectly with no
`/etc/rancher`, no rke2 units, and not one error in any log.

`core_platform_override` pins an OS image new enough to honour the key. A
known-working combination:

```hcl
core_platform_override = {
  os_image_base      = "registry.suse.com/beta/uc/base-os-kernel-default:16.1-72.40"
  os_image_iso       = "registry.suse.com/beta/uc/base-os-kernel-default-iso:16.1-72.67"
  kubernetes_version = "v1.35.6+rke2r1"
  kubernetes_image   = "registry.suse.com/elemental/rke2/rke2-tar:1.35.6_rke2r1-9.1"
}
```

Check the build log for `Extracting ISO from container image ...base-os-kernel-default-iso`
at customize step 6, and a booted node's journal for `reading system config
file "/usr/lib/ignition/base.d/10-elemental.ign"`. If the node logs `no config
dir at "/usr/lib/ignition/base.d"` instead, the override did not take.

When picking newer tags, remember `crane ls` sorts lexically -- pipe through
`sort -V` or `16.1-72.40` looks newer than `16.1-72.5`.

## Usage

```bash
cd examples/ha-cluster
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars -- every REPLACE_WITH_* placeholder
export VULTR_API_KEY=...

terraform init
terraform plan
./deploy.sh
```

`./deploy.sh --yes` passes `-auto-approve` to both passes, so neither
prompts. `--help` lists the rest; any argument the script does not recognise
is forwarded verbatim to both `terraform apply` calls, except an unknown
`--flag`, which is a hard error so a typo surfaces here rather than as a
confusing Terraform message.

Whether an image is rebuilt is decided by the module's build triggers (an
edit under `templates/elemental/`, a changed variable that reaches the image,
the upstream release manifest's content). `./deploy.sh --rebuild` forces one
regardless — `-replace` on `time_static.build` in pass 1 — which replaces the
jumphost, the snapshot and every node. The previous snapshot is **deleted**,
not kept.

## The two-pass apply, and why

`vultr_load_balancer`'s backend list (`attached_instances`) is an inline
field of the load balancer resource, not a separate one — so "create the
LB" and "attach the backends" are a single node in Terraform's graph.
Wiring the backends straight to the control-plane instances would close a
dependency cycle: the LB needs to exist before the jumphost (its IPv4 is
baked into the elemental image as `apiVIP`), the control-plane nodes are
built from the snapshot the jumphost produces, and if the LB's config also
depended on those same control-plane nodes, the graph loops back on itself.

The module breaks the cycle by keeping `lb_backend_instance_ids` and
`lb_supervisor_extra_cidrs` as plain variables (default `[]`), not resource
references. `gpu_cloud_extra_cidrs` rides along for a different reason: it
carries the NAT gateway's public `/32`s into the cloud GPU firewall group, and
`vultr_nat_gateway.this.public_ips` is unknown at plan time — fine inside the
load balancer's `dynamic` block, which is evaluated at apply, but illegal as a
`vultr_firewall_rule`'s `for_each` key. `deploy.sh` runs:

```bash
terraform apply "$@"                                        # pass 1
# writes pass2.auto.tfvars.json from pass 1's own outputs
terraform apply "$@"                                        # pass 2
```

Pass 2's values land in `pass2.auto.tfvars.json`, not a `-var` flag —
Terraform auto-loads any `*.auto.tfvars.json` in the working directory on
every subsequent `plan`/`apply`, so the backend list stays pinned. A `-var`
override only lives for the one command it's passed to; without this file, a
plain `terraform apply` run later would see `lb_backend_instance_ids` revert
to its `[]` default and detach every control-plane node from the load
balancer. **Don't delete `pass2.auto.tfvars.json`, and re-run `./deploy.sh`
(not a bare `terraform apply`) if a control-plane or GPU node is ever
replaced**, so the file gets regenerated with the new IDs/CIDRs.

Both passes are re-runnable: pass 1's snapshot wait is a no-op once the
snapshot exists, and pass 2 is a short backend-list update.

Pass 2 also closes port 80. The jumphost's `tcp/80 from 0.0.0.0/0` rule, which
Vultr's fetcher needs for the import, is a Terraform resource gated by
`image_import_port_open`; Terraform cannot create and remove it in one apply,
so pass 1 leaves it open (the default) and pass 2 writes `false`. Every run
reopens it for the length of pass 1 — with nothing listening unless a rebuild
is under way, since the jumphost stops serving `image_serve_seconds` (default
60 min) after its build. A bare `terraform apply` that needs a rebuild after
pass 2 fails waiting for the image; use `./deploy.sh`.

### What to expect timing-wise

Pass 1 blocks for **tens of minutes with no console output** while the
jumphost pulls the elemental container image, runs `customize --type raw`,
serves the resulting raw over HTTP, and Terraform has Vultr import it as a
snapshot and waits for that to complete.
From another terminal, watch progress with:

```bash
ssh root@<jumphost_public_ipv4> tail -f /var/log/elemental-factory.log
```

Between pass 1 and pass 2, both load balancers exist but have **zero
backends**. A `curl` or port scan against `:6443` during that window will
show a dead/refused connection — that is expected, not a failure. It
clears up once pass 2 attaches the control-plane nodes. The ingress load
balancer stays down longer: its health check is Traefik's own `/ping`, which
only answers once the cluster has finished deploying its charts.

## Post-deploy checks

```bash
vultr-cli load-balancer get <lb-id>          # backends attached and healthy

# RKE2's API cert is signed by its own cluster CA, not a public one -- tls-san
# (via apiVIP) only makes the LB's address a valid *subject* on that cert, it
# doesn't make the CA trusted, so this still needs one of:
curl --cacert /var/lib/rancher/rke2/server/tls/server-ca.crt \
  https://<lb-ip>:6443/version               # from a control-plane node, where that file exists
curl -k https://<lb-ip>:6443/version         # from anywhere else

# Control-plane nodes are vpc_only and have no public IP at all -- there is
# nothing to scan from outside the VPC. Confirm from inside instead, e.g.
# from the jumphost: `nc -zv <cp-vpc-ip> 22` should fail from off-cluster.
nmap -Pn <gpu-node-ip>                       # documents the known bare-metal exposure, see below
ssh root@<jumphost-ip>                       # the only inbound admin path
  kubectl get nodes                          # 3 control-plane + N GPU workers, right hostnames
  ping -M do -s 1422 <cp-vpc-ip>             # confirms the 1450 MTU path is unfragmented
```

`control_plane_internal_ip` and `gpu_node_ipv4` outputs supply the
`<cp-vpc-ip>` and `<gpu-node-ip>` placeholders above. `gpu_bare_metal_ipv4` and
`gpu_cloud_ipv4` split the latter per family, keyed by hostname, which is what
you want when scanning: a bare metal node should answer, a firewalled cloud one
should not, and a `vpc_only` one reports `0.0.0.0` because it has no public
address at all.

### Ingress checks

```bash
kubectl -n kube-system get ds rke2-traefik -o wide   # pods on the 3 CPs only
kubectl get ingressclass                             # traefik, marked default

curl -I http://$(terraform output -raw ingress_lb_ipv4)   # 404 from Traefik = path is live
curl -k https://$(terraform output -raw rancher_hostname) # Rancher's UI
nmap -Pn -p80,443 <gpu-node-ip>                           # must be closed -- the DaemonSet is pinned

# Real client addresses. Without proxy protocol working end to end this shows
# the ingress LB's VPC address instead of yours:
kubectl -n kube-system logs ds/rke2-traefik | tail
```

If every ingress backend shows unhealthy in `vultr-cli load-balancer get`,
the health check is the first thing to look at: it is HTTP `/ping` on port
8080, which needs `ports.traefik.hostPort: 8080` from the `HelmChartConfig` to
have applied. It deliberately does **not** probe 80 or 443 — those require a
PROXY header from anything inside the VPC, and Vultr's health checker does not
send one, so probing them would fail every backend.

## Known exposure: GPU bare metal nodes have no platform firewall

Bare metal GPU workers (`vultr_bare_metal_server`, i.e. anything in
`gpu_bare_metal_pools`) carry a public NIC and **cannot** be protected by Vultr
Firewall — the provider's resource has no `firewall_group_id` argument for bare
metal, and neither does the underlying API. The gap is documented in full in
the root [README's Security section](../../README.md#security); the only
control available is host-level firewalling baked into the elemental image
itself.

**`gpu_cloud_pools` is the way out where the plans exist.** A cloud GPU node is
a `vultr_instance`, so it gets a firewall group (RKE2's port list from the VPC
subnet, SSH from `admin_cidrs` only), and under the default `vpc_only = true`
it has no public NIC to protect in the first place. The tradeoff for `vpc_only`
is that every image and driver pull goes through the single shared NAT gateway
— the reason it is a default rather than the only option.

## Troubleshooting

- **A bare metal worker comes up with no VPC address.** The node boots and
  takes its public IP, but its second NIC sits at `NO-CARRIER` with no
  address, while an identically-built sibling is fine. The Vultr API holds the
  attachment and has reserved an address; `configure-network.sh` runs to
  completion and generates the right nmstate document naming that exact
  address. It never activates, because NetworkManager will not bring up a
  profile on a link with no carrier. Check carrier **before** reading any of
  the config:

  ```sh
  ip -o link show                         # NO-CARRIER on the second NIC?
  cat /sys/class/net/enp1s0f1np1/carrier  # 0 = the port is not lit
  curl -sS http://169.254.169.254/v1/interfaces/1/ipv4/address
  ```

  If metadata has an address and carrier is `0`, nothing in this repo can fix
  it — the port is not lit on the host side, and the script logs three
  `WARNING` lines saying so. It is not specific to this module or to the
  elemental image: a `vbm-*` deployed from the Vultr UI with a stock distro
  image, attached to the same VPC, can come up the same way, its NIC carrying
  a VPC address from Vultr's own cloud-init and still `NO-CARRIER`. Confirm
  the attachment exists before escalating to Vultr support:

  ```sh
  curl -sS -H "Authorization: Bearer $VULTR_API_KEY" \
    "https://api.vultr.com/v2/bare-metals/<id>/vpcs"
  ```

- **"snapshot ... no longer exists" from `wait-for-snapshot.sh`, then every
  plan errors on a 404.** Vultr's fetcher never got the image: Vultr deletes
  the record when the fetch fails, and the provider then errors on the
  missing snapshot at every refresh instead of dropping it from state. The
  import is attempted **once** — there is no retry, by design — so this means
  re-running. Usually the image is fine and the port-80 rule was not yet in
  force at the edge the fetcher arrived through; that is intermittent, and
  `wait-for-image.sh` fetching the URL from your machine first makes it
  rarer, not impossible. Recover with:

  ```sh
  terraform state rm 'module.ha_cluster.vultr_snapshot_from_url.ai_factory[0]'
  ./deploy.sh            # --rebuild instead if the jumphost has stopped serving
  ```

  The jumphost stops serving `image_serve_seconds` after its build, so once
  that window has passed only `--rebuild` has something to import. To tell a
  firewall miss from a bad image, on the jumphost:

  ```sh
  grep '\.raw' /var/log/elemental-factory.log | grep -v 127.0.0.1
  ```

  Only your own address (from `wait-for-image.sh`) → the fetcher never
  connected. A `GET` from another public address → look at the image instead;
  the log records its apparent and on-disk size at step 8.
- **A lone `~ health_check { + path = "/" }` on the API load balancer is
  provider drift, not something you changed.** Vultr returns an *empty* path
  for a `tcp` health check; the provider's schema defaults `path` to `"/"` and
  its read copies the API value into state, so the two never agree and no
  config value converges — omitting `path` gets the same default back. It is
  noise, not danger: an in-place `health_check` update leaves the LB's `ipv4`
  known, so it cannot propose replacing anything. Silenced with
  `ignore_changes = [health_check[0].path]` in `network.tf`. The ingress LB is
  an HTTP check and returns its `/ping` normally.
- **A local-path PVC stays `Pending` and the helper pod logs `mkdir: can't
  create directory '/opt/local-path-provisioner/pvc-...': Permission denied`.**
  The directory is missing, or it exists with the wrong SELinux label —
  `usr_t` inherited from `/opt`, which a container cannot write.
  `local-path-prep.service` creates it correctly at boot; check whether it ran:

  ```sh
  systemctl status local-path-prep.service
  ls -ldZ /opt/local-path-provisioner   # want container_file_t, not usr_t
  ```

  The manual repair is `mkdir -pZ /opt/local-path-provisioner`, or
  `restorecon -R /opt/local-path-provisioner` if the directory is already
  there with the wrong label. The provisioner retries, so the pending PVC
  binds on its own within seconds.
- **A Longhorn PVC binds but never mounts.** The cause is a missing `/etc`,
  not a missing package. The pod stays in `ContainerCreating` and the only clue is
  `AttachVolume.Attach failed … rpc error: code = DeadlineExceeded` — Longhorn
  itself looks perfect: all pods `Running`, all four `nodes.longhorn.io`
  schedulable, the volume's `Scheduled` condition `True`. A systemd extension
  can only deliver `/usr`, so the `suse-storage` extension brings `iscsid` but
  not the `/etc/iscsi` the `open-iscsi` RPM would have created, and the daemon
  cannot start without it. `iscsi-prep.service` fixes it at boot. To check a
  node by hand:

  ```sh
  systemctl is-active iscsid            # should be active
  systemctl status iscsi-prep.service   # the unit that makes it so
  cat /etc/iscsi/initiatorname.iscsi
  ```

  A bare `systemctl start iscsid` reporting only `A dependency job for
  iscsid.service failed` is the missing `InitiatorName`, nothing else; the
  manual repair is `mkdir -p /etc/iscsi && echo "InitiatorName=$(iscsi-iname)"
  > /etc/iscsi/initiatorname.iscsi`, then start it. The volume attaches within
  seconds — the attach is retried indefinitely, so the stuck pod recovers on
  its own.
- **"Unit could not be found" for `k8s-config-installer.service` or
  `k8s-resource-installer.service` after first boot means SUCCESS.** Both unit
  templates end with `ExecStartPost` lines that `systemctl disable` and then
  `rm -rf` themselves. Absence is the completion signal, not a failure.
- **Editing anything under `templates/elemental/` or `locals.tf` changes
  `time_static.build`'s triggers** (`sha256(jsonencode(local.elemental_files))`),
  and `vultr_instance.jumphost.user_data` is `ForceNew`. A one-character edit
  mid-run replaces the jumphost and starts a second build. Batch template edits;
  make them before starting a run, never during. `image-factory.sh.tftpl` is
  *not* in `elemental_files` — editing it replaces the jumphost but keeps the
  build id.
- **Rotating an SSH key is an image rebuild.** The keys live in `butane.yaml`,
  which is in `elemental_files`. If that ever needs to be fast, move `passwd`
  back into `node_runtime_ignition`, where it overrides the baked-in copy
  without a rebuild.
- **`terraform_data` `input` changes are in-place only** and do not re-run
  `local-exec`. `triggers_replace` is what forces it.
- **A missing `/etc/rancher` on a node is a networking failure, not a Kubernetes
  one.** Elemental orders its RKE2 firstboot behind
  `catalyst-net-initrd-script.service`; if `configure-network.sh` dies, RKE2
  never installs. `journalctl -b | grep configure-network` is the first thing to
  read on any node that looks half-configured.
- **A `vpc_only` node's VPC address comes from DHCP and must not be overridden.**
  Vultr grants the real registered address to exactly one DHCP transaction — in
  practice NetworkManager's own auto-profile, firing on carrier-up before
  `configure-network.sh` runs — and every transaction after that, forever,
  including across reboots, gets a CGNAT `100.64.0.0/24` fallback. So the script
  leaves that NIC's connection profile completely alone and applies MTU and
  IPv6-disable through `ip link set mtu` and a sysctl write, both of which
  bypass NetworkManager's state machine. Control-plane nodes get no
  `99-node-ip.yaml` either — `write-node-ip.service` sees a single physical
  NIC and exits having written nothing.
- **Node shape is decided by the physical NIC count, never by whether metadata
  answers.** A `vpc_only` node *does* serve `/v1/interfaces/` once it is up; it
  just reports `ipv4/address` as the literal string `"dhcp"`. Treating "tree
  present" as "dual NIC" writes `node-ip: dhcp` into every control plane and
  leaves `rke2-server` crash-looping on `invalid node-ip: invalid ip format
  'dhcp'`. The tree only 404s in the initrd, because metadata is unreachable
  over a VPC NIC that has not finished DHCP — a timing property, not a
  topology one.
- **"The node can ping 1.1.1.1" is not evidence its network config worked.**
  Check `ip -o a` and `ip route` directly.
- **`crane ls` sorts lexically.** Always `| sort -V`, or `16.1-72.40` looks older
  than `16.1-72.5`.
- **Never point the ingress LB's health check at 80 or 443.** Traefik's
  `proxyProtocol.trustedIPs` is REQUIRE-like *inside* the trusted range: a
  connection from a trusted IP with no PROXY header is rejected, not tolerated.
  Vultr's health checker dials from a VPC address — inside `trustedIPs` — and
  sends no PROXY header, so it would fail every backend and blackhole all
  ingress while the config looks perfectly correct. Hence
  `ports.traefik.hostPort: 8080` and a check on `/ping`.
- **`kubectl logs ds/rke2-traefik` will never show a client IP.** The chart ships
  access logs **off**, and `logs ds/...` samples only one of the three pods
  anyway. Do not turn them on to answer the question — `traefik.yaml.tftpl` is in
  `elemental_files`, so that is a full image rebuild. Ask a pod instead:

  ```bash
  kubectl create deploy whoami --image=traefik/whoami
  kubectl expose deploy whoami --port=80
  kubectl create ingress whoami --class=traefik \
    --rule="whoami-<ingress-lb-ip>.sslip.io/*=whoami:80"
  curl -s http://whoami-<ingress-lb-ip>.sslip.io | grep -i x-forwarded-for
  ```

  `X-Forwarded-For` is your real address if the chain works. `RemoteAddr` is the
  pod network hop and is always a `10.42.x.x` — not a failure.
- **Rancher's Ingress shows an empty `ADDRESS` column, forever.** Traefik does
  not write `status.loadBalancer.ingress` without a `type: LoadBalancer` Service,
  and there is no CCM here. Cosmetic.
- **Canal's defaults are wrong on this network, and fail quietly.** Flannel picks
  its VXLAN source from the default route, which on a dual-NIC bare metal worker
  is the *public* NIC; Calico's `vethuMTU` assumes a 1500 underlay; and Felix's
  metrics endpoint listens on `0.0.0.0:9091`, which on bare metal means the
  public internet. All three are corrected by a `HelmChartConfig` the module
  writes to `/var/lib/rancher/rke2/server/manifests/canal.yaml` through each
  server's Ignition config — `canal.yaml.tftpl`'s header comment has the
  evidence. It has to be in RKE2's own manifests directory, on disk before
  `rke2-server` starts: arriving after the chart is installed is permanent, not
  just late, because the values land in a ConfigMap read through `env.valueFrom`,
  so the DaemonSet pod template never changes and Helm has nothing to roll. For
  the same reason, patching it on a running cluster is a no-op until you
  `kubectl delete po -n kube-system --selector k8s-app=canal`.

## Destroying

```bash
terraform destroy
```

The snapshot is in state and destroyed with everything else — and so is the
jumphost's port-80 rule, if pass 2 has not already removed it.

One thing it does not clean up, which bills:

- **Orphan bare metal** from interrupted runs. `vultr-cli bare-metal list`,
  matched against Terraform state.
