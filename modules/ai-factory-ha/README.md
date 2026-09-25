# `modules/ai-factory-ha`

Terraform module for a highly-available SUSE AI Factory cluster on Vultr: a
jumphost that builds the elemental image and imports it as a snapshot, an odd
number of `vpc_only` control-plane VMs behind a Vultr load balancer acting as
the Kubernetes API VIP, and any mix of GPU worker pools -- bare metal, cloud,
or both at once -- joined over the same VPC.

The module builds its own snapshot as part of the apply: the jumphost pulls
the elemental container image, runs `podman ... customize --type raw` and
serves the result over HTTP; Terraform imports it with
`vultr_snapshot_from_url` and waits for it to complete before provisioning
nodes from it. The snapshot is in Terraform state, so `terraform destroy`
deletes it, and the jumphost never holds a Vultr API key. See
`examples/ha-cluster` for a runnable example and `deploy.sh`.

## Topology

```
        internet ──▶ lb.api      ──▶ 6443 world  ·  9345 CP+GPU only
        internet ──▶ lb.ingress  ──▶ 80/443, proxy protocol on, health check /ping:8080
                            │  both: vpc = the VPC, backends = the CPs
        internet ──▶ jumphost   the only inbound admin path
                            │
                     ┌──────┴────────────────┬─────────────────────────┐
                  cp-01/02/03          <pool>-NN bare metal      <pool>-NN cloud
                  vpc_only + NAT       in the VPC, public NIC    in the VPC, firewalled
                  Traefik pinned here  NO firewall possible      or vpc_only + NAT
```

Both GPU families are keyed by pool, so one cluster can carry several plans at
once -- `gpu_bare_metal_pools = { mi325x = { plan = "vbm-...", count = 2 } }`
alongside `gpu_cloud_pools = { a100 = { plan = "vcg-a100-12c-120g-80vram",
count = 2 } }`. Pool names are part of node identity: nodes are
`<cluster_name>-<pool>-NN`, which is the hostname Terraform sets on the
resource and Ignition writes to `/etc/hostname`.

Creation order:

```
1  vultr_vpc              the original (non-VPC2) VPC — only version wired to bare metal
2  vultr_nat_gateway      egress for the vpc_only control-plane nodes
3  vultr_load_balancer    api + ingress; Vultr assigns their IPv4s, backends still empty
4  jumphost               builds the elemental image with the API LB's IPv4 baked in as
                          apiVIP and the ingress LB's as Rancher's hostname, serves it
                          on :80 for image_serve_seconds; tcp/80 rule opened alongside
5  snapshot               Terraform polls the served URL from your machine, then
                          vultr_snapshot_from_url, then polls it until "complete"
6  cp-01/02/03            vultr_instance, vpc_only, no public NIC at all
   <pool>-NN              vultr_bare_metal_server, vpc_id, public IP unavoidable
   <pool>-NN              vultr_instance, vpc_ids, vpc_only by default, else firewalled
── second apply pass ─────────────────────────────────────────────────────
7  LB backends + rules    control-plane instance IDs, GPU /32s and the NAT
                          gateway's public /32s, fed back in
   close tcp/80           image_import_port_open = false
```

## Why the LB backends are a variable, and why there are two apply passes

`vultr_load_balancer`'s backend list (`attached_instances`) and its firewall
rules are inline fields of the load balancer resource — the provider has no
separate "attach a backend" or "add an LB firewall rule" resource. Wiring
`attached_instances` straight to `vultr_instance.control_plane[*].id` would
close a dependency cycle:

```
vultr_load_balancer.api      ──▶ attached_instances = vultr_instance.control_plane[*].id
vultr_instance.control_plane ──▶ vultr_snapshot_from_url.ai_factory
vultr_snapshot_from_url      ──▶ terraform_data.image_served
terraform_data.image_served  ──▶ vultr_instance.jumphost
vultr_instance.jumphost      ──▶ user_data contains vultr_load_balancer.api.ipv4
        └───────────────────────── back to the top
```

The LB has to *exist* before the jumphost — its IPv4 is baked into the
generated RKE2 config as `apiVIP` — but it does not need to know its backends
yet: a Vultr LB with zero backends is a valid, if useless, state. So
`attached_instances = var.lb_backend_instance_ids` (default `[]`), and the
9345 firewall rule's extra sources come from `var.lb_supervisor_extra_cidrs`
(also default `[]`) rather than from `vultr_bare_metal_server.gpu`.
Variables are plan-time inputs, not graph edges, so this keeps `count` and
every dependency plan-known without ever touching the nodes it fronts.

`var.gpu_cloud_extra_cidrs` rides the same mechanism for a different reason:
it carries the NAT gateway's public `/32`s to the cloud GPU nodes' firewall
group, and `vultr_nat_gateway.this.public_ips` is unknown at plan time. That
is fine inside the load balancer's `dynamic "firewall_rules"` block, which is
evaluated at apply, but a `vultr_firewall_rule` is a resource and a resource's
`for_each` keys must be known during plan. So it round-trips through pass 2.

`examples/ha-cluster/deploy.sh` fills both variables from the first apply's
own outputs:

```bash
terraform apply "$@"                     # pass 1
# writes pass2.auto.tfvars.json from pass 1's own outputs
terraform apply "$@"                     # pass 2
```

The values go into `pass2.auto.tfvars.json`, not a `-var` flag: Terraform
auto-loads any `*.auto.tfvars.json` on every later `plan`/`apply`, so the
backend list stays pinned. A `-var` would only live for the one command, and
the next plain `terraform apply` would see `[]` again and detach every backend.

Terraform still owns the backend list end to end — no `ignore_changes`, no
drift, and it self-heals if a node is replaced. Both passes are re-runnable:
pass 1's snapshot wait is a no-op once the snapshot exists.

Pass 2 also sets `image_import_port_open = false`. The jumphost's tcp/80 rule
for Vultr's fetcher is a `vultr_firewall_rule`, so it cannot be opened and
closed within one apply; pass 1 leaves it at its default (open) and pass 2
removes it once the snapshot is complete. A routine re-run opens it again for
the length of pass 1, with nothing listening unless a rebuild is under way —
the jumphost stops serving `image_serve_seconds` after its build.

## Ingress: Traefik on hostPorts, behind its own load balancer

`ingress_controller` (default `traefik`) becomes `ingress-controller:` in
`kubernetes/config/server.yaml`. RKE2 has packaged Traefik as a selectable
chart since v1.35.0 and made it the default in v1.36; setting it explicitly
means the flip changes nothing here.

**How the endpoint is exposed.** The `rke2-traefik` chart (40.1.003, what
`v1.35.6+rke2r1` ships) deploys a **DaemonSet** whose `web`/`websecure`
entrypoints take `hostPort` 80 and 443. The node itself listens, on every one
of its NICs — no NodePort hop, and the chart's `ClusterIP` Service is only for
in-cluster access. A `type: LoadBalancer` Service is not an option in this
cluster at all: `apiVIPMode: external` keeps MetalLB out and there is no cloud
controller manager, so one would sit `<pending>` forever.

**`kubernetes/manifests/traefik.yaml`** is a `HelmChartConfig` making three
changes to that:

| Value | Why |
|---|---|
| `nodeSelector` on `node-role.kubernetes.io/control-plane` | unpinned, the DaemonSet also binds 80/443 on any GPU node's **public** NIC — on bare metal that NIC has no Vultr firewall at all. The control planes are `vpc_only`, so there the ports exist only inside the VPC. This is also why `local.gpu_cloud_rules` omits 80/443/8080: no worker is ever an ingress backend |
| `proxyProtocol.trustedIPs` = the VPC CIDR, on `web` and `websecure` | the ingress LB sends PROXY headers; without this Traefik reads them as request bytes. The CIDR, not an address, because Vultr never reports the LB's VPC-side address |
| `ports.traefik.hostPort: 8080` | exposes `/ping` for the LB's health check |

**`vultr_load_balancer.ingress`** is a second load balancer rather than two
more forwarding rules on the API one, for two reasons that are both hard
constraints, not preferences:

- `proxy_protocol` is a **per-load-balancer** flag. RKE2's 6443 and 9345
  listeners do not speak PROXY, so enabling it on the API LB breaks every
  `kubectl` call and every node join. Without it, every access log, rate
  limiter and IP allowlist in the cluster sees the LB's VPC address.
- A Vultr LB has **exactly one** health check. Sharing meant Traefik's
  health riding on a TCP probe of 6443.

The ingress LB's health check is therefore HTTP `/ping` on **8080**, not 80 or
443: those now require a PROXY header from anything inside the VPC, and Vultr's
health checker does not send one, so probing them would fail every backend.

Both load balancers take the same control-plane backends, so one pass-2
variable fills both. Two `sslip.io` names come out of this, both baked into the
image and so both rebuild triggers:

- `rancher_hostname` → `rancher-<ingress_lb_ipv4>.sslip.io`, written into
  `kubernetes/helm/values/rancher.yaml`.
- `api_host` → `rke2-<api_vip>.sslip.io`, written as elemental
  `network.apiHost`, which puts it in the API server certificate's SANs.

## Node identity: metadata for network config, Ignition user_data for everything else

One elemental image is built and one snapshot is used for every node —
control plane and GPU alike. Vultr MACs do not exist before a server is
created, and neither `vultr_instance` nor `vultr_bare_metal_server` can be
re-imaged onto a different snapshot without `ForceNew` destroying and
recreating the host (with a new MAC), so a per-MAC network config baked at
build time can never converge. Instead, `network/configure-network.sh` runs
during elemental's `initrd` phase and reads Vultr's own instance metadata
(`169.254.169.254`, flat plaintext tree, no auth) to learn the *shape* of the
machine — how many NICs it has, their MACs, and which one faces the public
internet. Addresses are not discovered; see below.

Everything else reaches a node through one of **two layered Ignition
channels**, split on a single question: is this value the same on every node?

| Channel | Delivered as | Carries |
|---|---|---|
| `templates/elemental/butane.yaml.tftpl` | baked into the image, `base.d/90-butane.ign` | root password hash, SSH keys, `sshd.service`, `PermitRootLogin`, `/root/.profile`, `write-node-ip.service` (writes `99-node-ip.yaml` itself, from metadata, at first boot — see below), and with `suse-storage` selected `iscsi-prep.service` (seeds the `/etc` a sysext cannot ship and starts `iscsid` — see below) |
| `locals.tf`'s `node_runtime_ignition` | that node's Vultr `user_data` | `/etc/hostname`, `/var/lib/elemental/runtime.env` (`NODETYPE`/`IS_INIT_NODE`) |

They are layered, not exclusive. Ignition merges every `base.d` drop-in in
lexical order — elemental's own `10-elemental.ign` first, then
`90-butane.ign` — and then merges the platform config (Vultr's metadata
service) on top, so `user_data` wins any conflict. A node's journal shows both
in the same boot:
`reading system config file "/usr/lib/ignition/base.d/10-elemental.ign"`
followed by a successful `GET http://169.254.169.254/user-data/user-data`.

`runtime.env` is where that layering stops being a detail and becomes the
design. `kubernetes/cluster.yaml` deliberately carries **no `nodes:` list**, so
elemental's `internal/config/kubernetes.go:110` writes its own
`/var/lib/elemental/runtime.env` into `base.d` with `IS_INIT_NODE=true
NODETYPE=server`, and each node's `user_data` copy merges over it. That one
file then drives everything role-shaped: `k8s_conf_deploy.sh` resolves
`NODETYPE` from the environment before it ever consults the `hosts[]` table
built from `cluster.yaml`, and with no init node declared,
`k8s-resource-installer.service` is gated by
`ExecCondition=[ "$IS_INIT_NODE" = "true" ]` instead of `ConditionHost=`. Same
single-runner guarantee, but nothing about the cluster's shape is baked into
the image. This is the arrangement SUSE's own multi-node example uses
(`SUSE/elemental#579`, `examples/elemental/runtime-configs/multi-node/`).

The per-node half is hand-built with `jsonencode()` rather than butane — no
transpile step exists anywhere in this pipeline, and three files do not
justify adding one. It mirrors elemental's own AWS runtime-config examples
(upstream SUSE/elemental#579): one common image, per-node config delivered
through the cloud provider's userdata channel.

> **Do not re-derive this as "butane.yaml is inert on Vultr".** It is a
> tempting conclusion — elemental also ships its config on an `ignition`
> partition that `ignition.platform.id=vultr` does make unreadable — and it is
> wrong, because `base.d` arrives by a different route: `internal/config/ignition.go`
> writes both the generated config and the transpiled `butane.yaml` into a CPIO
> that extends the OS initrd. A build where `butane.yaml` appears to do nothing
> is usually the `initrdExtensions` skew instead, which delivers *no* `base.d`
> config at all. See `var.core_platform_override`.

**Cost of putting the credentials in the image.** `butane.yaml` is part of
`local.elemental_files`, whose hash is a `time_static.build` trigger, so
rotating a single SSH key rebuilds the image and replaces every node (~30
minutes) where the `user_data` path would have replaced only the nodes. The
hash and the keys also now sit in the snapshot, not only in instance
metadata. This is a deliberate trade, made to keep the cluster-wide
configuration in one reviewable file; if you need fast key rotation, move
`passwd` back into `node_runtime_ignition`, where it will override the
baked-in copy without an image rebuild.

This also removes the objection previously raised against SUSE/elemental#579,
which keeps the root password in the base butane while setting
`ignition.platform.id=aws`. That combination is fine and applies as written —
it is now what this module does.

## VPC addresses: discovered from metadata, not chosen by Terraform

Vultr allocates a VPC address per attachment — visible in the UI and in
`GET /v2/instances/{id}/vpcs` — and, on any instance with a public NIC, tells
the guest directly: `/v1/interfaces/<n>/ipv4/address` returns that same
allocation. That address is authoritative, and it does not have to match one
Terraform picked: this module used to compute and bake in its own, and on a
bare metal node the two disagreed (Vultr's `10.20.0.9` against the module's
`10.20.9.1` on the same NIC). The self-assignment was not just unnecessary but
wrong, and only the fabric's indifference to the mismatch — it does not filter
on the allocated address — kept it from being a live problem.

The one case where Vultr genuinely tells the guest nothing useful is a
`vpc_only` instance. The tree *is* served there — one entry, `network-type`
`evpn`, empty `ipv4/gateway`, empty `ipv4/netmask` — but `ipv4/address` is the
literal string `"dhcp"` rather than an address, matching what `/v1.json`
reports. Those are exactly the nodes — every control
plane, and any `gpu_cloud` pool with `vpc_only = true` — that never had a
Terraform-chosen address applied to begin with (see below), so nothing is lost
by dropping the table.

> An earlier revision of this section claimed `/v1/interfaces/` 404s wholesale
> on `vpc_only`. It does 404, but only *in the initrd*, where metadata is not
> yet reachable over a VPC NIC whose DHCP has not completed — an
> initrd-only observation generalised to the whole boot. Both scripts were
> built on it and both had to be rewritten: see "How each script decides the
> node's shape" below.

`network/configure-network.sh` classifies a dual-NIC node's interfaces at
first boot (a non-empty `ipv4/gateway` is the public NIC, an empty one is the
VPC NIC — see "WHY A vpc_only NIC IS LEFT ALONE" in that template) and, for
the VPC NIC, now reads its `ipv4/address` straight from that same metadata
tree instead of looking up its hostname in a table Terraform computed and
baked into the image at build time. `network/write-node-ip.sh` — a firstboot
systemd unit delivered through `butane.yaml.tftpl`, because
`configure-network.sh` runs inside a sandbox that cannot write anywhere but
`/proc`, `/sys` and `/dev` — repeats the same classification independently to
write `/etc/rancher/rke2/config.yaml.d/99-node-ip.yaml`.

### How each script decides the node's shape

**By counting physical NICs in `/sys/class/net`, not by asking metadata.** A
device with a backing `/sys/class/net/<if>/device` is a real NIC; one such
device means `vpc_only`, two means public + VPC. That count is local, always
available, and true the moment either script runs.

Both scripts originally branched on whether `/v1/interfaces/` answered. That
put `node-ip: dhcp` into every control plane's `99-node-ip.yaml` —
`rke2-server` exits 1 with `invalid node-ip: invalid ip format 'dhcp'` and
never starts. `configure-network.sh` had the same premise
with a worse failure mode available to it: on a boot where DHCP finished
before the initrd hook ran, it would have handed `nmc` a profile for the one
NIC that must never see a second DHCP transaction (see below). That path was a
race and was never observed firing, which is precisely why it was removed
rather than left to chance.

Both scripts also now validate any address metadata hands them as a dotted
quad before using it. "Non-empty" is not the same as "an IP address".

**Only nodes with a public NIC actually apply anything** — that is what
`public_nic` in `local.cluster_nodes` selects, not the node's role. A
control-plane node has one NIC, so both scripts stop at the count and leave
DHCP's address alone — which already *is* Vultr's own allocation. It is a
load balancer backend, and the LB dials whatever address Vultr has on file for the
instance, so applying a different one would risk a load balancer that can
never reach any backend. A `vpc_only` cloud GPU pool falls on the same side of
that line for the stronger reason below: its DHCP lease is one-shot.

Without `write-node-ip.sh`'s override, a GPU node whose default route goes out
its public NIC would advertise that public IP to the cluster instead of its
VPC one. Control-plane and `vpc_only` nodes get no such drop-in, for the same
reason they get no discovered static address either.

**A `vpc_only` node's DHCP lease is one-shot.** Vultr grants the real
registered address to exactly one DHCP transaction — in practice
NetworkManager's own auto-profile, firing on carrier-up before
`configure-network.sh` runs — and every transaction after that, forever,
including across reboots, gets a CGNAT `100.64.0.0/24` fallback. So the script
leaves that NIC's connection profile alone entirely and applies MTU and the
IPv6 disable through `ip link set mtu` and a sysctl write, both of which bypass
NetworkManager's state machine.

**`/tmp` is read-only in elemental's initrd.** The script stages its nmstate
document under `/run` (first writable candidate of `/run`, `/var/tmp`,
`/tmp`). Staging in `/tmp` instead fails late and confusingly: the script
classifies both NICs correctly, generates exactly the right nmstate document,
then dies on `mkdir: cannot create directory '/tmp/nmc-desired-states':
Read-only file system`.

What happens when this script fails is worth knowing, because none of the
symptoms point at it:

- `catalyst-net-initrd-script.service` ends up `failed`, and elemental orders
  its RKE2 firstboot behind that unit — so the node comes up with no
  `/etc/rancher` at all and `rke2-server` inactive. A missing Kubernetes
  install is a *networking* failure here.
- On a `vpc_only` node NetworkManager falls back to a DHCP lease from the NAT
  gateway's `100.64.0.0/24` CGNAT range: working internet egress, unreachable
  from anywhere inside the VPC. Egress working is not evidence this ran.
- On bare metal the public NIC comes up on DHCP regardless, so the node is
  fully reachable over SSH with only its VPC NIC missing.

`journalctl -b | grep configure-network` is the first thing to read on any
node that looks half-configured.

The NAT gateway's private IP and `var.dns_servers` are baked into the image
too, but only for a static-addressing fallback branch in the script that no
node type reaches today: they were added on the assumption that the VPC runs
no DHCP, whereas with the NAT gateway this module always creates, DHCP
supplies both a default route and resolvers. Kept
for a future node shape that needs static VPC addressing with no public NIC.

## `templates/cloud-init.yaml.tftpl` is deliberately comment-free

Unlike every other template in this module, `cloud-init.yaml.tftpl`'s own
top-level content (everything outside the `write_files` entries) ships as
literal, uncompressed bytes in the jumphost's `user_data` — only the
`write_files` entries themselves are gzip+base64'd.

It is also the one template the comment strip in `locals.tf` never sees: it is
rendered directly by `jumphost.tf`, not carried in `local.elemental_files`, so
nothing removes its comments on the way out. (That is deliberate — its first
line, `#cloud-config`, is a directive that looks exactly like a comment, and a
strip that ran here would delete it and silently turn the payload into
something cloud-init ignores.) Every other template can be commented freely
because the comments never reach the wire; this one cannot. So it carries
none, and explanations belong here instead.

What it does, and why:

- `disable_root: false` plus a top-level `ssh_authorized_keys:` list
  (from `var.ssh_authorized_keys`, the same list the elemental nodes get
  through their Ignition `user_data`) — the jumphost runs plain openSUSE, not
  elemental, so without this it would have no key-based access at all despite
  the variable existing. `disable_root: false` matters because
  cloud-init's `cc_ssh` module can lock root out of password auth on some
  images while still wiring the key up under a different account; Vultr's
  own default login on this image is root (no `user_scheme` override is
  set here), so root is where the key needs to land.
- `write_files` loops over `local.elemental_files` (locals.tf) plus one more
  fixed entry for `factory_script` (`/opt/image-factory.sh`, outside the
  config dir) — each gzip+base64'd so arbitrary generated YAML/shell content
  never has to be hand-indented into this template.
- `runcmd` launches the factory script under `nohup`/`setsid`, fully
  detached from cloud-init's own process group, so `cloud-init status
  --wait` returns long before the (tens-of-minutes) image build finishes;
  progress lives in the log file `image-factory.sh.tftpl`'s `log_file`
  variable points at.

## `core_platform_override`: why the OS image has to be pinned by hand

**Leave this unset and the cluster builds, boots, and has no Kubernetes on
it.** Not a crash — a clean, loginable node with no `/etc/rancher`, no `rke2`
units, an empty `systemctl --failed` and not one error in any log.

`elemental customize` does not install anything. It writes the media; the
install runs later, on the node's first boot, using the `elemental3ctl` that
came out of the **OS image** (`internal/customize/templates/auto_installer.sh.tpl`).
Two different elemental versions are involved in one build, and they have to
agree on the format of the media between them.

They currently don't. The customize container this module requires
(`beta/uc/elemental:3.1.0-6.5`, needed for `apiVIPMode: external`) emits
`bootloader.initrdExtensions` in the media's `install.yaml`. That key attaches
the CPIO archive carrying `/usr/lib/ignition/base.d/10-elemental.ign` — which
*is* the entire Kubernetes firstboot chain. Every `elemental3ctl` on the 3.0.x
line unmarshals the YAML, silently ignores the unknown key, and concatenates
nothing. Support first appears on the 3.1.0 line (`3.1.0~alpha.20260909`).

This is a **branch** difference, not a date race — worth being precise about,
because it determines whether waiting helps. The newest GA
`base-os-kernel-default` (`16.0-3.45`) is `3.0.3.20260908`, built a day *later*
than the feature merged upstream and still without it, because GA tracks the
3.0.x maintenance line. A newer GA build will not fix this; only the 3.1.0
line carries the feature, and today that means the beta channel.

No published release manifest pins an OS image new enough, and
`corePlatform.image` cannot be redirected at a local file —
`pkg/manifest/resolver/resolver.go:96` hard-forces an `oci://` prefix onto it.
So the override **flattens** the manifest chain instead. The top-level
`manifestURI` *does* accept `file://`, which is already how this module loads
the AIF manifest, so `image-factory.sh` generates a single local **core
platform** manifest: our own `operatingSystem` and `kubernetes` pins, with the
AIF solution manifest's `components.systemd` and `components.helm` merged in
verbatim. A v0 core manifest's `Components` is a superset of a solution
manifest's, so nothing is lost, and `release.yaml` needs no change at all.

Only `os_image_iso` is ever consumed — `internal/customize/customize.go:76`
extracts the ISO variant and never reads `.Base` — but both are required by
the schema. The two repos are tagged independently, so their build numbers are
not expected to match.

Before trusting a new tag, check it on the jumphost. The cheap proxy is the
**base** image, whose rootfs has the binary on `PATH`:

```bash
podman run --rm --entrypoint sh \
  registry.suse.com/beta/uc/base-os-kernel-default:16.1-72.40 -c \
  'elemental3ctl version; grep -ac "Concatenating extensions" /usr/bin/elemental3ctl'
```

But the binary that actually installs the node comes from the **iso** image,
and it is not in that wrapper container's rootfs (which has no shell utilities
at all) — it is inside the ISO's squashfs. That is the authoritative check:

```bash
zypper -n in squashfs
id=$(podman create registry.suse.com/beta/uc/base-os-kernel-default-iso:16.1-72.67)
podman cp "$id:/iso" /var/tmp/isoimg && podman rm "$id"
mkdir -p /mnt/iso && mount -o loop,ro /var/tmp/isoimg/*.iso /mnt/iso
unsquashfs -d /var/tmp/sq /mnt/iso/LiveOS/squashfs.img usr/bin/elemental3ctl
grep -ac "Concatenating extensions" /var/tmp/sq/usr/bin/elemental3ctl
umount /mnt/iso && rm -rf /var/tmp/isoimg /var/tmp/sq   # the ISO is ~850 MB
```

A non-zero grep count means that image carries the fix; both tags above were
checked this way. Note `crane ls` sorts lexically — pipe through `sort -V`, or
`16.1-72.40` looks older than `16.1-72.5`.

Setting this deliberately pairs a **beta** OS image with AIF 2.2's chart set,
which is off the combination SUSE tests. That is currently unavoidable.

## What triggers an image rebuild

`time_static.build` records the instant of the current build; the served
file name (`<cluster>-YYYYMMDD-hhmmss.raw`, UTC) and `random_id.serve_path`
are derived from it. Its `triggers` are `cluster_name`, the load balancer's IPv4,
`elemental_image`, `sha256(jsonencode(local.elemental_files))` — the
*rendered* config dir, so a change to a variable alone still counts — plus two
inputs that reach the build only through `image-factory.sh` and therefore
cannot ride in `elemental_files`: `sha256` of the **content** behind
`local.aif_release_manifest_url` (the URL derived from `aif_version`, or
`aif_release_manifest_url` when set), and
`sha256(jsonencode(var.sysext_image_overrides))`.
Change any of them and `random_id.serve_path` rotates, which makes
`vultr_instance.jumphost`'s `user_data` `ForceNew` — the jumphost is replaced
and builds a new image — and, through `replace_triggered_by`, replaces
`vultr_snapshot_from_url.ai_factory` and with it every node.

The manifest trigger hashes the fetched body, not the URL, so a URL pointing
at a moving branch ref still rebuilds when the far end changes.

The practical consequences:

- **Editing anything under `templates/elemental/`, or `locals.tf`'s
  `elemental_files`, during a run replaces the jumphost mid-build** and starts
  a second one. Batch such edits and make them before starting an apply.
  `image-factory.sh.tftpl` is *not* in `elemental_files` — editing it replaces
  the jumphost but keeps the build id.
- **Rotating an SSH key is an image rebuild**, since `butane.yaml` is in
  `elemental_files`. See the trade-off note above.
- **So is changing `ingress_controller`**, and so is anything that moves the
  ingress load balancer's IPv4 — it reaches the image as `rancher_hostname`
  inside `rancher.yaml`, which the `elemental_files` hash covers.
- **A jumphost replaced for any other reason does not rebuild the cluster.**
  The snapshot's `url` embeds the jumphost's IP and is `ForceNew`, so it is
  in `ignore_changes`; only the build id replaces it. The new jumphost still
  builds and serves an image nobody imports.
- **A rebuild deletes the previous snapshot.** It is replaced, not kept, so
  there is no rolling back to it. `examples/ha-cluster/deploy.sh --rebuild`
  forces one with `-replace` on `time_static.build`.
- **`snapshot_id` is not a pin any more.** Setting it drops the managed
  snapshot to `count = 0` and destroys it; it is only for images built
  outside this module.
- **Editing a comment in a template does *not* rebuild.** See below.

### Comments are stripped before anything is rendered

The bottom of `locals.tf` runs every rendered file through two `replace()`
calls that drop whole-line `#` comments and collapse the blank runs they leave
behind. `templatefile()` writes into `local.elemental_files_documented` and
`local.factory_script_documented`; everything downstream reads the stripped
`local.elemental_files` and `local.factory_script`. Nothing should read the
`_documented` values directly.

Two reasons:

- **Size.** Every comment byte rides in the jumphost's `user_data`, which
  `jumphost.tf` caps at 32 KiB. Across all templates, gzip+base64'd the way
  `cloud-init.yaml.tftpl` encodes them, the payload measures **~35 KB with
  comments and ~14 KB without**. Gzip does not rescue prose here, because the
  files are encoded one at a time and no shared dictionary ever forms across
  them. Without the strip the payload is over the ceiling.
- **Rebuild churn.** `elemental_files` is what feeds
  `sha256(jsonencode(...))`, so the build hash is blind to comments. Rewording
  one would otherwise replace every node in the cluster.

What it does and does not touch:

- Strips a line whose first non-blank character is `#`, and its newline.
- Leaves `#!` alone, so shebangs survive — including the indented one inside
  `butane.yaml`'s `inline: |` block where `write-node-ip.sh` is embedded.
- Leaves trailing comments (`foo  # bar`) alone: deciding whether a `#` is
  inside a quoted string is beyond a regex, and they are a rounding error
  next to the block comments.
- Never runs on `cloud-init.yaml.tftpl` — see the section above.
- `image-factory.sh` is stripped by a **separate** expression rather than
  merged into one map with the elemental files. Merging them is a dependency
  cycle: the script interpolates `image_file`, which comes from
  `time_static.build`, whose trigger is the hash of `elemental_files`.

The practical rule: comment the templates as heavily as they deserve. The
prose is free at deploy time.

## SUSE AI Factory version

`var.aif_version` (default `"2.2.0"`) selects the release manifest, which is
what pins every chart version the cluster installs. It becomes a **tag** in
SUSE/aif and then a raw URL:

```
2.2.0        ->  aif-operator-2.2.0  ->
  https://raw.githubusercontent.com/SUSE/aif/refs/tags/aif-operator-2.2.0/uc-release-manifest/release_manifest.yaml
2.1.0        ->  aif-operator-2.1.0
2.3.0-dev.2  ->  aif-operator-2.3.0-dev.2     (pre-release)
```

`aif-operator`'s tag rather than the `release-X.Y` branch because a **tag is
immutable**: `release-2.2`'s tip can move after a cluster is built, an
`aif-operator-2.2.0` tree cannot. SUSE/aif tags per component
(`aif-ui-2.2.0`, `aif-operator-2.2.0`) and `aif-operator`'s is the one that
tracks the AI Factory version as a whole.

Three consequences worth stating plainly:

- **The version must be a full `X.Y.Z`.** There is no `2.2` tag, so there is
  no `"2.2"` here; a bare major.minor is rejected by a `validation` block
  rather than 404'ing later. Pre-release suffixes are accepted verbatim,
  because they are ordinary tags.
- **`2.0.x` is rejected.** `aif-operator-2.0.0` and `-2.0.1` predate
  `uc-release-manifest/`, so 2.1.0 is the floor.
- **A tag that does not exist is a plan-time 404**, with the derived tag named
  in the error and a `git ls-remote --tags` hint. Asking for a patch SUSE
  never cut fails there rather than half-way through a build.

A `check` block still compares the fetched manifest's own `metadata.version`
against `aif_version` and **warns** when they disagree. That is not paranoia
about the tag: `aif-operator-2.2.0-rc.1` ships a manifest declaring
`metadata.version: 2.0.1`, so upstream metadata does drift from its own tag,
and the warning is the difference between learning that at plan time and
learning it in a running cluster.

`aif_release_manifest_url` (default `null`) overrides the derivation
entirely — a branch ref, a fork, a local mirror. When it is set, `aif_version`
is ignored and the `check` block stays quiet.

This variable selects **charts only**. The OS side is pinned independently
and does not move with it: `elemental_image`, `core_platform_override` and
`sysext_image_overrides`. Changing `aif_version` changes the build id, so it
rebuilds the image and replaces every node — see the components warning
below, which applies identically here.

## SUSE AI Factory components

`var.components` (default `["rancher", "gpu-operator",
"local-path-provisioner", "aif-operator"]`) picks which Helm charts
`release.yaml` enables from the release manifest selected by
[`aif_version`](#suse-ai-factory-version). Known names: `cert-manager`, `rancher`,
`gpu-operator`, `local-path-provisioner`, `suse-storage`, `aif-operator`.
`locals.tf`'s `component_spec` is the single table driving all of it — a
future chart is one entry there.

They render in a fixed **canonical** order — `cert-manager, rancher,
gpu-operator, local-path-provisioner | suse-storage, aif-operator` — never the
order `var.components` was given in. That is deliberate: reordering the list
must not change `release.yaml`, since `release.yaml` is in
`local.elemental_files`, whose hash is a `time_static.build` trigger that
names the snapshot — `ForceNew` on every node. `cert-manager` is accepted as
an explicit entry but never required: it is injected automatically whenever
`rancher` is selected, because elemental's own `dependsOn` resolution
(`internal/config/helm.go`'s `enabledHelmCharts`) already walks the
manifest's `rancher -> cert-manager` and `aif-operator -> rancher` edges and
inserts a dependency before its dependent — naming it here too would only
risk contradicting that.

Four validated rules (`variables.tf`): every entry must be a known name, no
duplicates, `local-path-provisioner` and `suse-storage` cannot both be listed
(both set themselves as the default StorageClass — the manifest's own
comments warn about this twice), and `aif-operator` requires both `rancher`
and one of the two storage charts. Deliberately **not** validated:
`gpu-operator` against the presence of a GPU pool — either order (pools
before the operator while stock is chased, or the operator before any pool
exists) is a legitimate intermediate state.

`suse-storage` (Longhorn) **cannot start without `iscsiadm`**, which the base
OS image does not carry — `longhorn-manager` exits with `failed to check
environment, please make sure you have iscsiadm/open-iscsi installed on the
host`. The AIF manifest ships
`registry.suse.com/elemental/longhorn:4.111-4.79` as a systemd system
extension for that one reason.

Enabling `suse-storage` therefore also emits an explicit
`components.systemd: [{extension: suse-storage}]` into `release.yaml`, driven
by the `sysext` field of `local.component_spec`. In theory that is redundant —
the chart declares `dependsOn: [{name: suse-storage, type: sysext}]` and
elemental's `enabledExtensions()` enables any extension an enabled chart names
(`internal/config/systemd_sysext.go`, the `isDependency` closure). But that
was read out of elemental `main`, and this module pins `elemental:3.1.0-6.5`;
the same function's `isExtensionExplicitlyEnabled()` reads `release.yaml`'s
own list and does not depend on the tool being new enough. Given
`initrdExtensions` already cost a cluster to exactly this kind of skew, the
extension is named explicitly.

Note the two schemas differ and are easy to confuse. In the release
**manifest** it is `components.systemd.extensions: [{name, image}]`; in
`release.yaml` it is `components.systemd: [{extension}]` — a flat list, keyed
`extension` (`internal/image/release/release.go`). An extension named in
`release.yaml` must exist in the manifest or the build fails with `requested
systemd extension(s) not found`.

That asymmetry is also why `var.sysext_image_overrides` exists. The manifest
pins the extension's image and `release.yaml` has no field to override it, so
the only place to change it is the manifest — which `image-factory.sh.tftpl`
already rewrites for `core_platform_override`. The same Python step now takes
a `{extension: image}` map and rewrites `components.systemd.extensions[].image`
in place, before the core-platform flatten copies that list across, so one
edit covers both output shapes; it runs for a sysext override alone with no
core override set. A name the manifest does not declare is **fatal at build
time**, listing the names it does declare, rather than overriding nothing and
leaving the failure to surface forty minutes later as a missing binary inside
a crash-looping pod — which is exactly how the `open-iscsi` problem presented
the first time. Both the map's keys and its values are validated
quote-free and whitespace-free in `variables.tf`, because the JSON is handed
to the build script inside shell single quotes.

**It defaults to `{ suse-storage = "registry.suse.com/beta/uc/longhorn:5.279-4.13" }`,
not to `{}`** — for the same reason `elemental_image` defaults to a beta
build. AIF 2.2 pins the GA `registry.suse.com/elemental/longhorn:4.111-4.79`,
and `core_platform_override` (documented as effectively required) has no
sensible target today that is not on the beta 16.1 line, so the manifest's own
pin is the wrong build for every cluster this module actually produces.
Defaulting to `{}` would hand that mismatch silently to anyone enabling
`suse-storage`.

**An override only applies to an extension some enabled component actually
pulls in.** `local.effective_sysext_overrides` filters the map against
`local.enabled_sysexts` before anything downstream sees it, so on the default
chart set — `local-path-provisioner`, no Longhorn — the default override is
inert: the manifest is not rewritten, the build id does not move (the
`time_static.build` trigger hashes the *filtered* map), and a manifest that
does not declare the extension does not fail a build that was never going to
use it. Select `suse-storage` and it takes effect.

That leaves two names the module treats differently. One the manifest does not
declare is **fatal at build time** — but only once the filter has let it
through, i.e. only when it matters. One that no component could ever enable is
almost certainly a typo, so a `check` block in `variables.tf` warns at plan
time rather than letting the override vanish silently; a warning and not an
error, because a name the module cannot enable is inert either way. The gap
between them is deliberate: *"the manifest has no such extension"* is fatal,
*"nothing selected needs this extension"* is a no-op.

One limitation falls out of the filter: an extension the manifest marks
`Required`, or one pulled in by a chart this module does not model, never
appears in `enabled_sysexts` and so cannot be overridden at all. Add it to
`component_spec`'s `sysext` field if that comes up.

Longhorn's replicas are kept off GPU nodes
without pinning Longhorn's own DaemonSets there:
`kubernetes/helm/values/suse-storage.yaml.tftpl` sets
`defaultSettings.createDefaultDiskLabeledNodes: true`, and
`kubernetes/config/server.yaml.tftpl` applies the matching
`node.longhorn.io/create-default-disk=true` node label — **servers only** —
when `suse-storage` is enabled. `longhorn-manager`/`longhorn-csi-plugin`
still run everywhere (a GPU node has to be able to *mount* a volume); only
default disk creation, and therefore replica storage, is confined to the
control planes. The label is applied at node registration, so it lands on a
fresh build and not retroactively.

**The extension alone is not enough: `iscsi-prep.service` is what makes
open-iSCSI actually run.** `systemd-sysext` merges `/usr` (and `/opt`) and
nothing else, and an extension has no install scriptlet, so everything the
`open-iscsi` RPM would normally place in `/etc` is simply absent on a node
carrying the `suse-storage` extension: no `/etc/iscsi` directory,
no generated `initiatorname.iscsi` (so `iscsid` cannot start — `systemctl
start iscsid` reports only `A dependency job for iscsid.service failed`), no
`iscsid.conf`, and no `.wants` symlink anywhere, so `iscsid` is `disabled`.
Nothing in the cluster looks broken: Longhorn installs, every pod is
`Running`, the PVC **binds** and replicas schedule — and then the consuming
pod hangs in `ContainerCreating` for ever with `AttachVolume.Attach failed …
code = DeadlineExceeded`, because the host has no initiator to log in to the
engine's target with.

`templates/elemental/storage/iscsi-prep.sh`, delivered and enabled through
`butane.yaml` only when `local.enable_iscsi_prep` (i.e. when the
`suse-storage` *extension* is enabled, not merely the chart), repairs that at
every boot: it creates `/etc/iscsi`, generates an `InitiatorName` if there is
none (per node — it cannot be baked into an image one snapshot serves to the
whole cluster), seeds `iscsid.conf` from whatever the extension ships or from
a documented fallback, `modprobe`s `iscsi_tcp` and starts `iscsid`. It waits
up to 60 s for the extension to be merged and then gives up **quietly**, on
the same principle as `write-node-ip.service`: a node that refuses to boot
over a storage extension is worse than a node without Longhorn. It carries no
`Before=iscsid.service` and starts the daemon with `--no-block`, because
ordering ahead of a unit and then blocking on its start job deadlocks systemd;
and it starts `iscsid` each boot rather than `systemctl enable`-ing it, since
an enablement symlink in `/etc` would point into the extension and dangle
until `systemd-sysext` has run.

Because the whole thing is gated, `butane.yaml` renders byte-identically on
the default (`local-path-provisioner`) component set — verified by diffing the
rendered output — so no default cluster sees a new build id for it.

**`local-path-provisioner` has the mirror-image problem, and the same shape of
fix.** The chart stores every PVC under `/opt/local-path-provisioner` and does
not create that directory: the provisioner's helper pod runs a plain `mkdir`
inside a container, which fails with `Permission denied` and leaves the PVC
`Pending` indefinitely. Two things have to be true for that `mkdir` to work,
and the directory existing is only the first. The second is its SELinux label
— created by inheritance it comes out `usr_t`, like the rest of `/opt`, which
no container may write. `mkdir -Z` instead asks the loaded policy for the
path's default label, and `rke2-selinux` ships a file-context rule putting
`/opt/local-path-provisioner` at `container_file_t`. So the `-Z` is not a
precaution; it is the entire fix, and it works because RKE2's own policy
already anticipates this path.

This cannot be an Ignition `storage.directories` entry. Ignition runs in the
initrd against `/sysroot`, where `/opt` is part of the read-only image, and a
failed write there is not a warning — it fails the whole files stage and takes
the boot with it (see *Ignition writes nothing under the image's own tree*).
`/opt` becomes writable only once the real root is up, so the work belongs in
a boot-time unit. `local-path-prep.service`, gated on
`local.enable_local_path_prep` (the *chart*, unlike `iscsi-prep`'s extension),
runs `mkdir -pZ` followed by a `-`-prefixed `restorecon -R`, which self-heals
a directory that already exists with the wrong label without making a
`policycoreutils`-less image a boot failure. Like `write-node-ip.service` it
is `Before=` RKE2 as ordering only: one missing directory should not stop a
node joining. Gating keeps `butane.yaml` byte-identical for a `suse-storage`
cluster.

No MetalLB chart exists in the manifest at all; `apiVIPMode: external`
(above) is what actually keeps a VIP-managing component out, independent of
which charts get enabled here.

**Changing `var.components` rebuilds the image and replaces every node** —
this is not the rebuild-free scale-out path documented elsewhere in this
README; the chart set is baked into the image. **Switching
`local-path-provisioner` to `suse-storage` is not a migration**: it is a new
cluster with a different default StorageClass and no data carried across.

The manifest itself is **not** embedded in the jumphost's `user_data` —
at ~4 KB it would eat a large slice of the 32 KiB sanity ceiling `jumphost.tf`
enforces, for no benefit, so `image-factory.sh.tftpl` curls it directly into
the config dir at build time instead. Terraform still fetches it once (via
`data.http.aif_release_manifest`) purely to hash its content into the build
id, so a change on the far end still forces a rebuild on the next apply. With
the default derivation that trigger is inert — a tag does not move — and it
earns its keep only when `aif_release_manifest_url` points at a branch; see
[above](#suse-ai-factory-version).

local-path-provisioner's and suse-storage's charts pull from an
authenticated Application Collection repository, so `release.yaml` carries
`appco_username`/`appco_password` credentials for them — which is why those
two variables, though they default to `null`, are validated as **required**
whenever either storage chart is in `components`: the plan fails up front
instead of the cluster coming up with a provisioner stuck in
`ImagePullBackOff` and no working StorageClass. For
local-path-provisioner,
`kubernetes/manifests/local-path-provisioner.yaml` creates the matching
`application-collection` image pull secret the chart's own values expect
(Terraform computes the `dockerconfigjson`, not a manifest placeholder).
`aif-operator.yaml` takes three credential sets, all optional but highly
recommended: the same Application Collection ones, a SUSE registration code
(`suse_registration_code` — per SUSE's convention, the registry "username"
for that registry is the regcode itself) with `suse_registry_password`, and
an NVIDIA NGC API key (`nvidia_api_key`, paired with `nvidia_username`,
which defaults to NGC's literal `$oauthtoken` convention). Each set left `null` (or
`""`) is omitted from `aif-operator.yaml`'s `credentials:` block rather than
written with empty values, and each username/password pair is validated to
be set together or not at all. In practice the appco pair is always present
with aif-operator, since aif-operator requires a storage chart and both
storage charts require it. `rancher.yaml` gets a hostname and bootstrap password that the
manifest doesn't otherwise set — see `rancher_hostname` and
`rancher_bootstrap_password`.

## Inputs

Required, no default:

| Variable | Type | Why it can't be defaulted |
|---|---|---|
| `region` | `string` | plan availability and GPU stock are per-region; there is no sane default |
| `vultr_api_key` | `string`, sensitive | `availability.tf`'s plan-time stock checks call the API through the http provider; the vultr provider's own key comes from the environment, and Terraform can't read an env var into a default. Never sent to the jumphost |
| `admin_cidrs` | `list(string)` | defaulting SSH to `0.0.0.0/0` would be wrong, and defaulting to `[]` would silently lock you out |
| `root_password_hash` | `string`, sensitive | goes into the image's `butane.yaml`; without it there is no console login on any node, and no password for `su -` |
| `node_user_password_hash` | `string`, sensitive | the unprivileged account's own password, validated to differ from `root_password_hash` — otherwise the split buys nothing |
| `ssh_authorized_keys` | `list(string)` | without at least one key, nothing has a way in over SSH at all — see below |

Everything else has a default — see `variables.tf` for the full list and the
reasoning behind each one. Notable ones:

| Variable | Default | Note |
|---|---|---|
| `elemental_image` | SUSE's beta channel build (see Known gaps) | not the released `:3.0` tag — that predates `apiVIPMode: external` support |
| `core_platform_override` | `null` | **should not be left at its default** — without it the build follows the manifest chain to an OS image that silently drops the Kubernetes firstboot chain, producing nodes with no Kubernetes and no error. See [above](#core_platform_override-why-the-os-image-has-to-be-pinned-by-hand) |
| `sysext_image_overrides` | `{ suse-storage = "registry.suse.com/beta/uc/longhorn:5.279-4.13" }` | `{extension = image}` rewritten into the release manifest before the build reads it, keyed as the manifest spells the extension. The sibling of `core_platform_override`, for the same reason: with a beta OS image the manifest's GA-pinned extension is the wrong build. Inert unless an enabled component pulls the named extension in, so the default only bites when `suse-storage` is selected; a name the manifest does not declare then fails the build. See [above](#suse-ai-factory-components) |
| `control_plane_count` | `3` | validated odd and >= 3 (etcd quorum) |
| `gpu_bare_metal_pools` | `{}` | map of `{plan, count}`; `plan` validated `vbm-*`. Empty means no bare metal workers — every GPU-bearing `vbm-*` plan lists at $7,000-$45,696/month, so an unmodified `terraform apply` must not provision one. `vbm-72c-480gb-gh200-gpu` (~$2,009/month) is the one cheap option and is ARM, which elemental3 cannot customize |
| `gpu_cloud_pools` | `{}` | map of `{plan, count, plan_type, vpc_only}`, provisioned as `vultr_instance`. **`vpc_only` defaults to `true`** — no public NIC, egress through the NAT gateway, admin through the jumphost, same shape as a control-plane node; set it `false` for a firewalled public NIC (direct SSH, or to keep multi-GB driver pulls off the shared NAT gateway). `plan_type` is the query type the stock check is scoped to and is inferred when null -- the plan id's prefix, which for every ordinary family is its type, except `vcg-*` which resolves to `vdm` because the whole-node accelerator SKUs report `type: vdm`. Only the fractional vGPU SKUs are `type: vcg` and must set it explicitly, and those want the host vGPU driver stack that an elemental3 image does not have. A non-GPU cloud plan is accepted, to exercise this path where there is no GPU stock |
| `gpu_cloud_extra_cidrs` | `[]` | NAT gateway `/32`s for the cloud GPU firewall group; filled on pass 2, see [above](#why-the-lb-backends-are-a-variable-and-why-there-are-two-apply-passes) |
| `lb_nodes` | `1` | validated odd (provider requirement); applies to both load balancers |
| `api_vip_mode` | `"external"` | Vultr LB owns the API address; `"managed"` would hand it to MetalLB instead |
| `api_host` | `null` | defaults to `"rke2-<api_vip>.sslip.io"`, written as elemental `network.apiHost` and therefore into the API server certificate's SANs |
| `ingress_controller` | `"traefik"` | see [Ingress](#ingress-traefik-on-hostports-behind-its-own-load-balancer); only `"traefik"` gets the ingress load balancer; `"ingress-nginx"` is EOL upstream |
| `ingress_cidrs` | `["0.0.0.0/0"]` | who may reach the ingress load balancer on 80/443 |
| `deploy_nodes` | `true` | `false` stands up only the network, load balancer and jumphost — useful for building the image without paying for nodes yet. The snapshot is still imported, so the apply still blocks on it |
| `snapshot_id` | `null` | override: provision from a snapshot built outside this module. **Destroys** the managed snapshot if one exists |
| `image_serve_seconds` | `3600` | how long the jumphost serves the raw before stopping; also the timeout for the snapshot's `complete` wait |
| `image_import_port_open` | `true` | the jumphost's tcp/80 rule for the import; `deploy.sh` sets it `false` on pass 2 |
| `image_build_timeout` | `5400` | how long Terraform waits for the jumphost to serve the raw |
| `lb_backend_instance_ids` | `[]` | see [above](#why-the-lb-backends-are-a-variable-and-why-there-are-two-apply-passes) |
| `lb_supervisor_extra_cidrs` | `[]` | same |
| `fips` | `false` | the upstream example enables FIPS by default but warns every node must then be FIPS-ready — not a call to make silently |
| `rancher_hostname` | `null` | defaults to `"rancher-<ingress_lb_ipv4>.sslip.io"` (computed in `locals.tf`) when null — the ingress load balancer, not the API one |
| `rancher_bootstrap_password` | `null` | defaults to a generated `random_password` when null — see `outputs.rancher_bootstrap_password` |
| `appco_registry` | `"dp.apps.rancher.io"` | best-evidence guess at the container registry host behind Application Collection's only documented OCI endpoint; override if wrong |
| `appco_username`, `appco_password` | `null` | **required** (plan-time validation) when `components` lists `local-path-provisioner` or `suse-storage`; otherwise optional. When unset, `aif-operator.yaml`'s `applicationCollection:` block is omitted |
| `suse_registration_code`, `suse_registry_password` | `null` | optional but highly recommended; when unset, `aif-operator.yaml`'s `suseRegistry:` block is omitted |
| `nvidia_api_key` | `null` | optional but highly recommended; when unset, `aif-operator.yaml`'s `nvidia:` credentials block is omitted entirely |
| `nvidia_username` | `"$oauthtoken"` | NGC's convention for API-key auth; override only if your NGC setup expects something else |
| `gpu_driver_repository` / `gpu_driver_version` | experimental OBS SLES 16.1 build / `"615"` | overrides the release manifest's `driver.repository`/`driver.version` via `gpu-operator.yaml`. The operator pulls `<repo>/driver:<version>-<uname -r>-sles16.1`, so the repo needs a tag for the nodes' exact kernel. Revert to `registry.suse.com/third-party/nvidia` once it publishes 16.1 drivers. Changing either rebuilds the image and replaces every node |
| `aif_version` | `"2.2.0"` | which AI Factory release manifest to build against. Becomes SUSE/aif's `aif-operator-<version>` tag, so it must be a full `X.Y.Z` (no `"2.2"`), optionally with a pre-release suffix (`"2.3.0-dev.2"`); `2.1.0` is the floor, since `aif-operator-2.0.x` ships no manifest. A tag, not a branch, because it cannot move under a built cluster — but a `check` block still warns when the manifest's own `metadata.version` disagrees, which upstream does. Selects **charts only** — the OS side is `elemental_image` / `core_platform_override` / `sysext_image_overrides`. See [above](#suse-ai-factory-version). Changing it rebuilds the image and replaces every node |
| `aif_release_manifest_url` | `null` | override: a full raw URL to a release manifest, for a branch ref, a fork or a mirror. When set, `aif_version` is ignored |
| `components` | `["rancher", "gpu-operator", "local-path-provisioner", "aif-operator"]` | which AI Factory Helm charts `release.yaml` enables — see [above](#suse-ai-factory-components). Changing it rebuilds the image and replaces every node |
| `node_username` | `"suse"` | unprivileged login baked into the image for every elemental node, carrying `ssh_authorized_keys`; escalate with `su -`, since sudo is not installed. Changing it rebuilds the image and replaces every node |
| `permit_root_ssh` | `false` | when true, `PermitRootLogin yes` **and** the SSH keys on root. Off means SSH lands on `node_username` only. Changing it rebuilds the image and replaces every node |
| `jumphost_username` | `"suse"` | unprivileged jumphost login with passwordless sudo and the same SSH keys as root; `""` makes the jumphost root-only. Same default name as `node_username` but a different account on a different machine -- the jumphost runs plain openSUSE via cloud-init, so it *does* get sudo. Changing it replaces the jumphost, which rebuilds the image |

## Outputs

| Output | Notes |
|---|---|
| `jumphost_public_ipv4`, `jumphost_vpc_ip` | the jumphost's addresses |
| `jumphost_ssh_login` | `<jumphost_username or root>@<public ipv4>`, ready to pass to `ssh` |
| `kubernetes_api_endpoint`, `api_vip`, `api_host` | the API LB's address as a URL and a bare IPv4, plus the `sslip.io` name in the server certificate's SANs |
| `ingress_lb_ipv4`, `ingress_endpoint` | the ingress LB's address; both `null` unless `ingress_controller = "traefik"` |
| `nat_gateway_private_ip`, `nat_gateway_public_ips` | the NAT gateway's VPC and public sides |
| `vpc_subnet` | the cluster VPC's CIDR |
| `snapshot_id` | the effective snapshot (imported or overridden) |
| `rke2_token` | sensitive; shared join token |
| `rancher_hostname`, `rancher_url`, `rancher_bootstrap_password` | Rancher's ingress hostname, the same as a URL, and the initial admin password (sensitive) |
| `control_plane_ids`, `control_plane_internal_ip` | control-plane instance IDs and VPC addresses |
| `gpu_node_ipv4`, `gpu_node_cidrs` | every GPU node's public IP across both families, and the same as `/32` CIDRs. `vpc_only` cloud nodes are filtered out — Vultr reports their `main_ip` as `0.0.0.0`, which would otherwise end up in the LB's firewall |
| `gpu_bare_metal_ipv4` | bare metal GPU public IPs, keyed by hostname |
| `gpu_cloud_ipv4`, `gpu_cloud_internal_ip`, `gpu_cloud_ids` | cloud GPU public IPs, VPC addresses and instance IDs, keyed by hostname. There is no bare metal counterpart to `internal_ip`: `vultr_bare_metal_server` does not export one |
| `gpu_cloud_firewall_group_id` | the firewall group protecting the cloud GPU nodes, or `null` when there are no cloud pools |
| `nat_gateway_public_cidrs` | the NAT gateway's public IPs as `/32`s |

`control_plane_ids`, `gpu_node_cidrs` and `nat_gateway_public_cidrs` exist
specifically to be fed back as `lb_backend_instance_ids` /
`lb_supervisor_extra_cidrs` / `gpu_cloud_extra_cidrs` on the second apply pass.

## Known gaps

- **GPU bare metal nodes have no platform firewall.** `vultr_bare_metal_server`
  has no `firewall_group_id` argument, and neither does the underlying Vultr
  API — there is no Vultr-side control that restricts inbound traffic to a
  bare metal node's public interface. See the root README's Security section.
  A `gpu_cloud_pools` pool is the way out: `vultr_instance` takes a firewall
  group, and drops the public NIC entirely under `vpc_only`, which is its
  default.
- **`elemental_image`'s default (`registry.suse.com/beta/uc/elemental:3.1.0-6.5`)
  is a beta build, not a final tagged release.** It carries the `apiVIPMode`
  support added by upstream PR #578, confirmed by pulling the tag and grepping
  the compiled `elemental3` binary for the struct tag rather than taking it on
  trust. But "beta" still means no stability guarantee and the tag can be
  superseded; switch to a real tagged elemental release once one ships with
  the fix.
  `registry.opensuse.org/devel/unifiedcore/tumbleweed/containers/elemental:latest`
  (openSUSE's community continuous build, checkable the same way) remains a
  fallback.
- **UEFI on the imported snapshot cannot be verified through the Terraform
  provider.** `vultr_snapshot_from_url` sends `use_uefi = true`, but the
  field is write-only in the API; `scripts/wait-for-snapshot.sh`
  best-effort-checks the raw response and logs what it finds. The real
  guarantee is a node that actually boots.
- **The snapshot import is attempted once; a failure means re-running
  apply.** The provider makes a single `create-from-url` call and has no
  retry. Vultr's fetcher occasionally misses a freshly created firewall rule
  that has not reached its edge yet; `scripts/wait-for-image.sh` fetching the
  URL from your machine first makes that rarer, not impossible. When it
  happens Vultr deletes the snapshot record, `wait-for-snapshot.sh` fails
  with a 404, and the provider then **errors on that 404 at every refresh**
  instead of dropping the resource. Recover with
  `terraform state rm 'module.ha_cluster.vultr_snapshot_from_url.ai_factory[0]'`
  and re-run — `./deploy.sh --rebuild` if the jumphost's serve window
  (`image_serve_seconds`) has run out, since nothing is served any more.
- **The jumphost serves for a fixed window, not until the import is done.**
  Knowing when Vultr finished would need an API key on the jumphost, which
  it deliberately no longer has.
- **SSH lands on `node_username`, not root.** The image's `butane.yaml`
  creates that account (default `suse`) with `node_user_password_hash` and
  `ssh_authorized_keys`, enables `sshd.service`, and drops a
  `sshd_config.d/sshd.conf` with `PermitRootLogin no`. Set
  `permit_root_ssh = true` to get `PermitRootLogin yes` *and* the same keys on
  root; the two move together, so there is never a node where one says yes and
  the other no. Root keeps `root_password_hash` either way — that is the
  console login and the password `su -` asks for.
- **Escalation is `su -`, not sudo, and that is forced.** There is no `sudo`
  binary in the elemental OS image, no `wheel` group and no sudoers rules, so
  the jumphost's cloud-init
  `sudo: ALL=(ALL) NOPASSWD:ALL` pattern has nothing to hook into. It also
  means anything privileged — `kubectl` with the RKE2 kubeconfig included —
  needs the root password, which is the point of the two hashes being
  required to differ.
- **`/home` is a separate btrfs subvolume and `butane.yaml` mounts it.** It is
  `@/home` on the SYSTEM partition, not part of the root filesystem, and it is
  not mounted in the initrd where Ignition runs. Without the
  `storage.filesystems` entry, `useradd` would build the home directory on the
  root filesystem and the real subvolume would mount straight over the top at
  boot — an account with no home and no `authorized_keys`, failing only at
  login time, an image rebuild away from a fix.
- **`appco_registry`'s value is an assumption, not a confirmed fact.** The
  release manifest's only documented Application Collection endpoint is the
  Helm OCI repository (`oci://dp.apps.rancher.io/charts`); the container
  registry the local-path-provisioner image pull secret needs to authenticate
  against is assumed to be the same host. Override the variable if a pod
  in the `local-path-provisioner` namespace can't pull its image.
- **`gpu_cloud_pools` has never run against real stock.** The path is
  statically verified — `validate` clean, mixed-family plans produce the right
  node set, VPC addresses and `99-node-ip.yaml` placement with no cycle — but
  every whole-node `vdm` plan has reported no locations whenever it was
  checked, so no cloud GPU node has been booted. Bare metal pools are the
  exercised path.
- **Longhorn persistence across reboot is unproven.** Replicas land on
  `/var/lib/longhorn` and `/var` is writable, but no node has been rebooted
  with data on it. A related unknown: if `/etc` is ephemeral on this image,
  `iscsi-prep.service` regenerates the iSCSI `InitiatorName` on every boot and
  leaves stale node records behind. The script is idempotent either way.
- **The Terraform-managed import has not run against Vultr yet.**
  `vultr_snapshot_from_url`, `wait-for-image.sh` and the reworked
  `wait-for-snapshot.sh` are statically validated only. The 5xx handling in
  `wait-for-snapshot.sh` has only been exercised against a stub HTTP server.

## Non-goals

Deliberate omissions, not gaps:

- **Cross-region GPU pools.** VPCs and load balancers are hard region-scoped,
  and the use case does not need it.
- **A preemptible/spot flag.** No API or provider surface exists for one.
- **Per-pool `region`, `vpc_subnet`, `tags`, `ssh_key_ids`, `enable_ipv6`.**
  Shared across pools deliberately; only `mdisk_mode` is family-specific, by
  omission rather than design.
- **Narrowing the cloud GPU firewall rules below the control plane's port
  list.** Over-narrowing risks breaking a working cluster for no measurable
  gain.
- **Day-2 operations** — cluster upgrades, tearing the
  jumphost down once the build has finished.
