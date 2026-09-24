# SUSE AI Factory on Vultr

Terraform for deploying SUSE AI Factory on Vultr from an
[elemental3](https://github.com/suse/elemental) image, with RKE2, Rancher and
the AI Factory stack baked into the image at build time.

| | |
|---|---|
| Module | [`modules/ai-factory-ha`](modules/ai-factory-ha/) |
| Example | [`examples/ha-cluster`](examples/ha-cluster/) |

A jumphost that builds the elemental image and imports it as a snapshot, three
`vpc_only` control-plane VMs behind a Vultr load balancer acting as the API
VIP, a second load balancer fronting the Traefik ingress, and any mix of GPU
worker pools — bare metal (`vbm-*`), cloud (`vcg-*`), or both at once. It
builds its own image, and applies in two passes via `deploy.sh`.

Start with [`examples/ha-cluster/README.md`](examples/ha-cluster/README.md) to
run it, and [`modules/ai-factory-ha/README.md`](modules/ai-factory-ha/README.md)
for the design and the full variable reference.

[PLATFORM-NOTES.md](PLATFORM-NOTES.md) covers which Vultr plans an elemental
image can actually use — bare metal boot modes, why the fractional Cloud GPU
plans are unusable and the whole-node ones are not, and two bare metal API
limits worth knowing before you plan a deployment.

## Known limitation: no NVIDIA driver for SLES 16.1 yet (as of 2026-09-23)

GPU nodes, bare metal and cloud alike, provision and join the cluster, but the
GPU operator cannot install a driver on them, so they expose no
`nvidia.com/gpu` capacity and GPU workloads do not schedule.

The nodes run SLES 16.1 (kernel `6.12.0-160100.x`), which the module needs:
`core_platform_override` pins the 16.1 OS image because the 16.0 one does not
bring up Kubernetes (see
[the module README](modules/ai-factory-ha/README.md#core_platform_override-why-the-os-image-has-to-be-pinned-by-hand)).
The precompiled driver images at
[`registry.suse.com/third-party/nvidia/driver`](https://registry.suse.com/repositories/third-party-nvidia-driver-sles16)
are published for SLES 16.0 only, so the driver pod fails with
`ImagePullBackOff` on a tag such as `610-6.12.0-160100.5-default-sles16.1`.

A 16.0 image cannot stand in for it. Loading a 16.0 module on a 16.1 node fails
with `nvidia: disagrees about version of symbol module_layout`: the kernel's
module ABI changed between the two, so retagging or pinning an older driver
branch does not help.

This resolves once SLES 16.1 driver images are published; no change to the
module should be needed. Until then, the options are building the driver
container for the 16.1 kernel yourself, or leaving `gpu-operator` out of
`components`.

## Usage

```bash
cd examples/ha-cluster
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars -- every REPLACE_WITH_* placeholder
export VULTR_API_KEY=...

./deploy.sh
```

`deploy.sh` runs both passes. Pass 1 blocks for the length of the image build
with no output; watch it with
`ssh root@<jumphost-ip> tail -f /var/log/elemental-factory.log`. The example
README covers timing, the post-deploy checks, and what `terraform destroy`
leaves behind.

## Fast-fail on availability

Vultr GPU stock is limited, and a create against an out-of-stock plan fails
partway through an apply. The module checks first, one precondition per pool:

```
GET https://api.vultr.com/v2/regions/{region}/availability?type={vbm|vdm|vcg}
```

It returns `available_plans`, which is live stock rather than the set of plans
merely offered in the region. The read happens during `terraform plan`, so a
bad `region`/`plan` combination fails before anything is created:

```
Error: Resource precondition failed

  Bare metal plan "vbm-24c-256gb-amd" is not currently available in region
  "ams". Available bare metal plans there: vbm-8c-132gb, vbm-6c-32gb, ...
```

Send the `Authorization` header: unauthenticated, the endpoint answers HTTP 200
with an *empty* `available_plans` rather than a 401, so a missing key is
indistinguishable from real out-of-stock. Two other limits worth knowing. It is
best-effort — stock can drain between plan and apply, so a create can still
fail. And it needs outbound access to `api.vultr.com` at plan time. Set
`verify_plan_availability = false` to skip it.

## Security

**Vultr Firewall does not apply to bare metal servers.** This was verified
against the current Vultr OpenAPI spec, the govultr SDK, `vultr-cli`, and the
Terraform provider v2.32.0 source:

- `firewall_group_id` exists only on `POST /instances` and
  `PATCH /instances/{instance-id}`. It is absent from `POST /bare-metals`
  and `PATCH /bare-metals/{baremetal-id}`.
- The `bare_metal` API response object has no `firewall_group_id` field; the
  `instance` object does.
- `vultr_bare_metal_server` in the Terraform provider has no
  `firewall_group_id` argument, and no such attribute is computed either.
- Vultr's own docs publish an "Enable a Firewall Group" page for Cloud
  Compute, Optimized Cloud Compute, Cloud GPU and VX1 instances, but the
  Bare Metal networking docs list only IPv4, IPv6, Reserved IPs and VPC,
  no firewall.

There is no Vultr-side control that restricts inbound traffic to a bare metal
server's public interface.

**The way around it, where stock allows:** a `gpu_cloud_pools` pool deploys
`vultr_instance` on a `vcg-*` plan, so it *does* take a `firewall_group_id`,
and `vpc_only = true` removes the public NIC entirely. Control-plane nodes are
`vpc_only` already and are never exposed. Everything below applies to
`gpu_bare_metal_pools` only.

**Consequence: every bare metal node is fully exposed on its public IPv4/IPv6
address, on every port, until something running on the host itself filters
inbound traffic.** That something is the elemental3 image, not Terraform. This
module cannot and does not enforce network policy on the host.

**What the image needs to do about it** (host-level firewall: nftables,
firewalld, or equivalent, baked into the image or applied by it at first
boot):

- Default-deny inbound.
- Allow established/related traffic.
- Allow loopback.
- Allow TCP/22 (SSH) from `0.0.0.0/0`.
- Allow TCP/6443 (Kubernetes API) from `0.0.0.0/0`.
- Deny everything else inbound.

The elemental3 image used here does not yet implement that policy, so treat
every bare metal node as exposed on all ports. `nmap -Pn <node-ip>` against a
running host tells you where you stand.

## License

Apache-2.0. See [LICENSE](LICENSE).
