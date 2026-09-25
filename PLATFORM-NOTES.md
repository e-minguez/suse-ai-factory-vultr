# Platform notes

What the Vultr platform supports, and what that means for an elemental3 image.
These are the facts that decide which plans work — read them before choosing a
`region`/`plan` combination.

Elemental produces an image that is **EFI-only** and **immutable**: no kernel
sources, no writable root, no post-boot compilation. Everything below follows
from those two properties.

## Bare metal boots the image

Current `vbm-*` plans come up in EFI mode, so the elemental snapshot (imported
with `uefi = true`) boots unmodified. This is the path `examples/ha-cluster`
takes.

Two things to know:

- **One `vbm-*` plan is still BIOS-boot-only**, and Vultr's iPXE documentation
  still describes bare metal as Legacy PCBIOS only. If a freshly provisioned
  host reports `active` and the IP never responds, check the firmware boot mode
  from the console before suspecting the image:

  ```bash
  vultr-cli bare-metal vnc <server-id>
  ```

- **Firmware settings belong to the physical machine, not the deployment.**
  Hosts return to the pool and are reused, and provisioning does not reset
  firmware. A host switched to EFI by hand stays that way for whoever gets it
  next, so a single passing deploy is not a general result.

There is no API lever for this. `uefi` appears on exactly one endpoint,
`POST /snapshots/create-from-url`, and `POST /bare-metals` has no boot-mode
parameter.

## Cloud GPU: only the whole-node plans are usable

The `vcg-*` id prefix covers two different products.

**Fractional SKUs** (`vcg-a16-*`, `vcg-a40-*` under 24 cores, `vcg-l40s-*`)
report `type: vcg` / `disk_type: CLOUDGPU` and are **vGPU**. Their guest driver
is installed by running `/opt/nvidia/install.sh` on a booted host, with DKMS
rebuilding the module on every kernel change and `nvidia-gridd.service` holding
the licence. An immutable OS can do none of that. The usual escape — NVIDIA's
precompiled driver containers — is explicitly unavailable: NVIDIA's own
documentation states they do not support vGPU. So these plans cannot work with
this image, whatever their stock level says.

**Whole-node SKUs** (`vcg-a100-*`, `vcg-h100-*`, `vcg-b200-*`, `vcg-mi3*`)
report **`type: vdm` / `disk_type: DEDICATEDMETAL`** despite the `vcg-` prefix,
and are dedicated hardware with GPU passthrough. The precompiled-driver path
works on them, so they are the only Cloud GPU option this image can use. Set
`plan_type = "vdm"` on the pool — a `type=vcg` availability query never returns
them. Most report `deploy_ondemand: false` (preemptible-only, which this module
does not request), and stock is intermittent.

Passthrough is what makes the driver path work: the NVIDIA GPU Operator
pointed at precompiled driver containers, so nothing is compiled on the node.
The release manifest's source does not work on these nodes:

```yaml
driver:
  repository: registry.suse.com/third-party/nvidia
  usePrecompiled: true
  version: 595
```

That registry publishes SLES 16.0 builds only, and a 16.0 module does not load
on the 16.1 kernel. The module overrides it through
`gpu_driver_repository`/`gpu_driver_version`, defaulting to an experimental
OBS 16.1 build of branch `615` — see the top-level README.

## The real accelerators are bare metal

`GET /v2/plans-metal`, NVIDIA plans only. Prices are list prices and indicative:

| Plan | GPU | VRAM | $/mo |
|---|---|---|---|
| `vbm-72c-480gb-gh200-gpu` | GH200 | 96 GB | 2,009 |
| `vbm-48c-1024gb-4-a100-gpu` | A100 | 320 GB | 7,000 |
| `vbm-64c-2048gb-8-l40-gpu` | L40S | 384 GB | 12,000 |
| `vbm-112c-2048gb-8-a100-gpu` | A100 SXM | 640 GB | 15,053 |
| `vbm-112c-2048gb-8-h100-gpu` | H100 | 640 GB | 16,074 |
| `vbm-256c-3072gb-8-b200-gpu` | B200 | 1536 GB | 45,696 |

All passthrough, so the driver story is fine. This is why
`gpu_bare_metal_pools` defaults to `{}` — the cheapest entry is $2,009/month
and it is a GH200, which is ARM, and elemental3 only customizes x86_64 images.

## Two bare metal API limits

- **No firewall group.** `firewall_group_id` exists on `POST /instances` but
  not on `POST /bare-metals`, and the bare metal response object has no such
  field. There is no platform-side control over inbound traffic to a bare metal
  node's public interface — see the root [README's Security
  section](README.md#security). `gpu_cloud_pools` is the way around it where
  stock allows: those are `vultr_instance` and do take a firewall group.
- **No VPC-only create.** The console offers "Private Instance(s) behind NAT
  Gateway" for `vbm-*`, but `POST /v2/bare-metals` has no VPC parameter and no
  public-IPv4 toggle in govultr, `vultr-cli` or the Terraform provider. VPC
  exists only as the post-create `/vpcs/attach` endpoint, which is what this
  module uses, so a bare metal node always comes up with a public address.
  Compare `InstanceCreateReq`, which has both `VPCOnly` and
  `DisablePublicIPv4`.

## Checking stock

`available_plans` is live stock rather than the set of plans offered in a
region. **Send the `Authorization` header** — unauthenticated, the endpoint has
been seen to answer HTTP 200 with an empty list rather than a 401, which is
indistinguishable from real out-of-stock.

```bash
for r in $(curl -s "https://api.vultr.com/v2/regions?per_page=100" | jq -r '.regions[].id'); do
  for t in vcg vdm vbm; do
    echo "$r $t: $(curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
      "https://api.vultr.com/v2/regions/$r/availability?type=$t" | jq -c '.available_plans')"
  done
done
```

The module runs the same query at plan time, one precondition per pool; see the
root README's "Fast-fail on availability".

## Sources

- Vultr, [iPXE Boot Feature](https://docs.vultr.com/ipxe-boot-feature) — the
  bare metal boot-mode documentation.
- Vultr, [Explore GPU Variants](https://docs.vultr.com/products/compute/cloud-gpu/explore-gpu-variants)
  — which Cloud GPU models are vGPU and which are passthrough.
- Vultr, [Managing vGPU on Vultr Cloud GPU Instances](https://docs.vultr.com/how-to-manage-vgpu-on-vultr-cloud-gpu-instances)
  — `/opt/nvidia/install.sh`, DKMS, `nvidia-gridd.service` licensing.
- NVIDIA, [Precompiled Driver Containers](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/precompiled-drivers.html)
  — precompiled driver containers do not support vGPU.
- SUSE, [GPU operators on RKE2](https://documentation.suse.com/cloudnative/rke2/latest/en/add-ons/gpu_operators.html#v26.3.x)
  — GPU Operator values for SUSE's precompiled driver containers.
- SUSE, [`third-party/nvidia/driver` container images](https://registry.suse.com/repositories/third-party-nvidia-driver-sles16)
  — prebuilt NVIDIA kernel modules.
- Elemental source: `pkg/bootloader/grub.go` (EFI-only GRUB install),
  `pkg/firmware/efi_manager.go` and `pkg/upgrade` (`efibootmgr` on upgrade).
- Vultr API: `GET /v2/regions/{region}/availability?type=vcg|vdm|vbm`,
  `GET /v2/plans?type=all`, `GET /v2/plans-metal`, and the OpenAPI spec
  published in [vultr/vultr-mcp](https://github.com/vultr/vultr-mcp).
