variable "region" {
  type        = string
  description = "Vultr region ID to deploy into, e.g. \"ams\"."
}

variable "elemental_image" {
  type        = string
  default     = "registry.suse.com/beta/uc/elemental:3.1.0-6.5"
  description = "Container image passed to `podman run ... customize` on the jumphost. The default is a SUSE beta build, not the released elemental/elemental:3.0 tag -- that one predates apiVIPMode support and would deploy MetalLB regardless of api_vip_mode. Being a beta, it carries no stability guarantee; revisit once 3.1.0 ships as a stable tag. `registry.opensuse.org/devel/unifiedcore/tumbleweed/containers/elemental:latest` is a verified fallback."
}

variable "vultr_api_key" {
  type        = string
  sensitive   = true
  description = "Vultr API key for availability.tf's plan-time stock checks, which call the API through the http provider rather than the vultr one. The provider reads its own key from the environment (VULTR_API_KEY); Terraform has no way to read an env var into a variable default, so this has to be supplied explicitly. Never sent to the jumphost."
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the jumphost on 22/tcp. No default: 0.0.0.0/0 would be an open SSH door, and [] would silently lock everyone out."

  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "admin_cidrs must contain at least one CIDR block."
  }

  validation {
    # firewall.tf splits each entry on "/" and indexes into the result
    # unconditionally; an entry with no prefix (e.g. "1.2.3.4" instead of
    # "1.2.3.4/32") panics there with an unreadable index-out-of-range error
    # instead of a clear one here.
    condition     = alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "Every admin_cidrs entry must be a CIDR block with an explicit prefix, e.g. \"203.0.113.1/32\"."
  }
}

variable "root_password_hash" {
  type        = string
  sensitive   = true
  description = "Password hash (e.g. from `openssl passwd -6`) set as passwd.users[root].password_hash in the image's butane.yaml, which elemental bakes in as /usr/lib/ignition/base.d/90-butane.ign. Because it is part of the image, changing it rebuilds the image and replaces every node. No default: without it there is no console login on any node at all."
}

variable "ssh_authorized_keys" {
  type        = list(string)
  description = "Public keys injected onto every node that takes SSH access: the elemental nodes via the image's butane.yaml (onto var.node_username always, and onto root as well when var.permit_root_ssh is true), and the jumphost via cloud-init's own ssh_authorized_keys (it runs plain openSUSE, not elemental). Rotating a key therefore rebuilds the image and replaces every node. No default: without at least one key, nothing has a way into any of them except the console."

  validation {
    condition     = length(var.ssh_authorized_keys) > 0
    error_message = "ssh_authorized_keys must contain at least one public key."
  }
}

variable "node_username" {
  type        = string
  default     = "suse"
  description = "Unprivileged login created on every elemental node by the image's butane.yaml, carrying var.ssh_authorized_keys and var.node_user_password_hash. This is the account SSH is meant to land on: root login over SSH is off unless var.permit_root_ssh is set. Escalate with `su -` and the root password -- deliberately not sudo, which is not installed in the elemental OS image (no sudo binary, no wheel group, no sudoers rules). Distinct from var.jumphost_username, which cloud-init creates on the jumphost and which DOES get passwordless sudo. Changing this rebuilds the image and replaces every node."

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.node_username))
    error_message = "node_username must be a valid POSIX user name: lowercase, starting with a letter or underscore, at most 32 characters."
  }

  validation {
    condition     = var.node_username != "root"
    error_message = "node_username must not be \"root\": root is configured separately, from root_password_hash and permit_root_ssh."
  }
}

variable "node_user_password_hash" {
  type        = string
  sensitive   = true
  description = "Password hash (e.g. from `openssl passwd -6`) for var.node_username on every elemental node. Required and required to differ from root_password_hash: the whole point of the account is that the credential which gets you a shell is not the credential which gets you root. Like every other value in the image, changing it rebuilds the image and replaces every node."

  validation {
    # Terraform 1.9+ lets a validation read another variable, and there is no
    # cycle here because root_password_hash has no validation of its own.
    condition     = var.node_user_password_hash != var.root_password_hash
    error_message = "node_user_password_hash must differ from root_password_hash -- otherwise the unprivileged account and root share one credential and the split buys nothing."
  }
}

variable "permit_root_ssh" {
  type        = bool
  default     = false
  description = "Whether sshd on the elemental nodes accepts root logins (PermitRootLogin, written into /etc/ssh/sshd_config.d/sshd.conf) and whether root also receives var.ssh_authorized_keys. Off by default: log in as var.node_username and `su -`. Turning it on is a legitimate choice for a throwaway cluster -- it is the shortest path for the `ssh root@<node>` recipes throughout the docs -- but it is an image-wide setting, so flipping it rebuilds the image and replaces every node. Root always keeps root_password_hash for console login regardless."
}

variable "appco_username" {
  type        = string
  default     = null
  sensitive   = true
  description = "SUSE Application Collection username. Used to authenticate the local-path-provisioner / suse-storage Helm chart pulls (release.yaml) and their image pulls (kubernetes/manifests/local-path-provisioner.yaml's pull secret, suse-storage.yaml's privateRegistry), and written into kubernetes/helm/values/aif-operator.yaml's credentials.applicationCollection.username. Optional in the type, NOT in practice: required (validated at plan time) whenever components lists local-path-provisioner or suse-storage, since both are pulled from Application Collection and would otherwise sit in ImagePullBackOff with no StorageClass. When null, aif-operator.yaml omits the applicationCollection block. An empty string counts as unset."

  validation {
    # Both storage charts and their images live behind Application Collection
    # auth. Without credentials the image still builds and boots, and the
    # failure only shows up post-install as an ImagePullBackOff -- fail here
    # instead, before anything is created. try(): trimspace(null) errors, and
    # && does not short-circuit.
    condition = (
      !(contains(var.components, "local-path-provisioner") || contains(var.components, "suse-storage"))
      || try(trimspace(var.appco_username) != "" && trimspace(var.appco_password) != "", false)
    )
    error_message = "components lists local-path-provisioner or suse-storage, which are pulled from SUSE Application Collection and need appco_username and appco_password. Set both, or drop the storage chart from components."
  }

  validation {
    condition     = try(trimspace(var.appco_username) != "", false) == try(trimspace(var.appco_password) != "", false)
    error_message = "appco_username and appco_password must be set together -- one without the other is never usable."
  }
}

variable "appco_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "SUSE Application Collection password/token, paired with appco_username. See appco_username for when it is required."
}

variable "appco_registry" {
  type        = string
  default     = "dp.apps.rancher.io"
  description = "Container registry host the local-path-provisioner image pull secret authenticates against. The release manifest's only stated Application Collection endpoint is the Helm OCI repository oci://dp.apps.rancher.io/charts; this assumes the container images referenced by that chart are served from the same host, since Application Collection does not publish a separate documented registry host for images. Override if that assumption turns out to be wrong."
}

variable "suse_registration_code" {
  type        = string
  default     = null
  sensitive   = true
  description = "SUSE registration code, written as kubernetes/helm/values/aif-operator.yaml's credentials.suseRegistry.username -- per SUSE's own convention, the registry \"username\" for this registry is always the registration code itself. Optional but highly recommended: when null, aif-operator.yaml omits the suseRegistry block and aif-operator runs without SUSE registry credentials. An empty string counts as unset."

  validation {
    condition     = try(trimspace(var.suse_registration_code) != "", false) == try(trimspace(var.suse_registry_password) != "", false)
    error_message = "suse_registration_code and suse_registry_password must be set together -- one without the other is never usable."
  }
}

variable "suse_registry_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Password paired with suse_registration_code for the SUSE registry, written into aif-operator.yaml's credentials.suseRegistry.password."
}

variable "nvidia_api_key" {
  type        = string
  default     = null
  sensitive   = true
  description = "NVIDIA NGC API key, written into aif-operator.yaml's credentials.nvidia.password. Optional but highly recommended: when null (or an empty string), the whole nvidia: credentials block is omitted from aif-operator.yaml rather than written with an empty password. The paired username is nvidia_username."
}

variable "nvidia_username" {
  type        = string
  default     = "$oauthtoken"
  description = "Username written into aif-operator.yaml's credentials.nvidia.username alongside nvidia_api_key. Defaults to the literal string \"$oauthtoken\" -- NGC's own convention for API-key auth, not a secret. Override only if your NGC setup expects something else. Ignored when nvidia_api_key is unset."

  validation {
    condition     = trimspace(var.nvidia_username) != ""
    error_message = "nvidia_username must not be empty; leave it at its \"$oauthtoken\" default unless you know otherwise."
  }
}

variable "components" {
  type        = list(string)
  default     = ["rancher", "gpu-operator", "local-path-provisioner", "aif-operator"]
  description = "Which SUSE AI Factory Helm charts release.yaml enables. Rendered in a fixed CANONICAL order -- cert-manager, rancher, gpu-operator, local-path-provisioner | suse-storage, aif-operator -- never the order given here (see locals.tf's component_spec/enabled_components); that is what makes this default list render release.yaml byte-for-byte identical to what this module shipped before this variable existed, so upgrading the module alone does not force an image rebuild. `cert-manager` is accepted here but never required as an explicit entry -- it is injected automatically whenever `rancher` is selected, because elemental's own dependency resolution (`internal/config/helm.go`'s `enabledHelmCharts`/`addChart`) already walks the AIF manifest's `rancher -> cert-manager` and `aif-operator -> rancher` `dependsOn` edges and inserts a dependency before its dependent -- naming it here too would only risk contradicting that. `suse-storage` (Longhorn) needs no `components.systemd` entry either: its chart declares a sysext `dependsOn` and elemental's `internal/config/systemd_sysext.go` (`enabledExtensions`/`isDependency`) auto-enables the extension the manifest already ships for it. Changing this list changes release.yaml, which is in local.elemental_files and therefore rebuilds the image and replaces every node -- inherent, since the chart set is baked into the image. Not validated, deliberately: `gpu-operator` against the presence of a GPU pool -- either order is a legitimate intermediate state (pools provisioned before the operator while GPU stock is chased, or the operator enabled before any pool exists)."

  validation {
    condition = alltrue([
      for c in var.components : contains(
        ["cert-manager", "rancher", "gpu-operator", "local-path-provisioner", "suse-storage", "aif-operator"],
        c
      )
    ])
    error_message = "components entries must be one of: cert-manager, rancher, gpu-operator, local-path-provisioner, suse-storage, aif-operator."
  }

  validation {
    condition     = length(var.components) == length(distinct(var.components))
    error_message = "components must not contain duplicate entries."
  }

  validation {
    # Both make themselves the default StorageClass -- the release manifest's
    # own comments warn about running the two together twice over.
    condition     = !(contains(var.components, "local-path-provisioner") && contains(var.components, "suse-storage"))
    error_message = "components cannot list both local-path-provisioner and suse-storage -- both set themselves as the default StorageClass."
  }

  validation {
    condition     = !contains(var.components, "aif-operator") || contains(var.components, "rancher")
    error_message = "components lists aif-operator without rancher -- the AIF release manifest declares aif-operator -> rancher as a chart dependency."
  }

  validation {
    condition     = !contains(var.components, "aif-operator") || contains(var.components, "local-path-provisioner") || contains(var.components, "suse-storage")
    error_message = "components lists aif-operator without a storage chart -- add local-path-provisioner or suse-storage."
  }
}

variable "rancher_hostname" {
  type        = string
  default     = null
  description = "Hostname written into kubernetes/helm/values/rancher.yaml. Defaults to \"rancher-<ingress_lb_ipv4>.sslip.io\" (computed in locals.tf) when null -- sslip.io resolves the embedded address, so Rancher has a working ingress host with no DNS of your own, and it points at the ingress load balancer rather than the API one because that is where 80/443 are forwarded. Falls back to the API load balancer's address when ingress_controller is \"none\"."
}

variable "rancher_bootstrap_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Rancher initial admin bootstrap password, written into kubernetes/helm/values/rancher.yaml. Defaults to a generated random_password (see outputs.rancher_bootstrap_password) when null."
}

variable "cluster_name" {
  type        = string
  default     = "suse-ai-factory"
  description = "Prefix used to build resource labels and node hostnames (\"<cluster_name>-cp-NN\", \"<cluster_name>-gpu-NN\")."

  validation {
    # Feeds kubernetes/cluster.yaml's nodes[].hostname, which elemental
    # validates as a hostname; catching an invalid value here beats failing
    # ~20 minutes into a jumphost build.
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be a valid DNS label: lowercase alphanumeric and hyphens only, not starting or ending with a hyphen."
  }
}

variable "vpc_subnet" {
  type        = string
  default     = "10.20.0.0"
  description = "IPv4 network address of the VPC. Explicit, not auto-selected, so the range is reviewable in a diff. Must not overlap RKE2's default cluster-cidr (10.42.0.0/16) or service-cidr (10.43.0.0/16) -- see the validation below."

  validation {
    # A VPC range like 10.42.0.0/20 sits INSIDE RKE2's default cluster-cidr
    # of 10.42.0.0/16, and the result is subtle: the init node comes up with
    # `flannel.1: 10.42.0.0/32`, i.e. flannel has allocated itself the pod
    # subnet 10.42.0.0/24 -- potentially the same /24 that holds the VPC
    # addresses of the jumphost and the control-plane nodes. The connected
    # /20 route on enp1s0 is more specific than flannel's /16, so node-to-node
    # VPC traffic survives; but every pod veth installs a /32, which beats the
    # /20. So the cluster stays up and then loses individual VPC peers one at a
    # time as pods happen to be allocated their addresses -- intermittent,
    # host-specific, and nearly impossible to read as an addressing conflict.
    #
    # Validated rather than merely documented because the failure does not look
    # like a misconfiguration from any node's point of view.
    condition = var.vpc_subnet_mask >= 16 && !contains(
      ["10.42.0.0", "10.43.0.0"],
      cidrhost("${var.vpc_subnet}/16", 0)
    )
    error_message = "vpc_subnet must be a /16 or smaller and must not fall within 10.42.0.0/16 (RKE2's default cluster-cidr) or 10.43.0.0/16 (its default service-cidr). Pick a range outside both, e.g. 10.20.0.0/20."
  }
}

variable "vpc_subnet_mask" {
  type        = number
  default     = 20
  description = "IPv4 subnet mask (prefix length) of the VPC."
}

variable "vpc_mtu" {
  type        = number
  default     = 1450
  description = "MTU set on the VPC's private network adapters, per Vultr's own guidance for the original (non-VPC2) VPC. configure-network.sh applies this to every private NIC; RKE2's VXLAN overlay then costs 50 bytes on top, landing pod MTU at 1400."
}

variable "dns_servers" {
  type        = list(string)
  default     = ["108.61.10.10", "8.8.8.8"]
  description = "Resolvers baked into each node's network config, used only by configure-network.sh's static-addressing fallback -- no node type reaches it today, since VPC DHCP supplies resolvers. The first entry is Vultr's own, the second a public fallback."
}

variable "control_plane_count" {
  type        = number
  default     = 3
  description = "Number of vpc_only control-plane vultr_instance nodes. Must stay odd (etcd quorum) and at least 3 (a two-member etcd has no fault tolerance at all)."

  validation {
    condition     = var.control_plane_count >= 3 && var.control_plane_count % 2 == 1
    error_message = "control_plane_count must be odd and at least 3."
  }
}

variable "control_plane_plan" {
  type        = string
  default     = "vx1-g-4c-16g-240s"
  description = "Vultr cloud instance plan ID for control-plane nodes. The default is a dedicated-vCPU 4c/16GB plan: RKE2 plus the AI Factory Helm charts want more headroom than 8GB gives an etcd member."
}

# GPU workers come from two different Vultr resource families, and one cluster
# can use both at once:
#
#   gpu_bare_metal_pools -> vultr_bare_metal_server, vbm-* plans. There is no
#     Vultr firewall for bare metal at all, so the mandatory public IP is
#     unprotectable at the platform level (see the root README's Security
#     section).
#   gpu_cloud_pools      -> vultr_instance, the vcg-* plans. These support
#     vpc_ids, vpc_only and firewall_group_id, which is what closes that gap.
#
# Each family takes a MAP OF POOLS rather than one count + one plan, because
# GPU stock is fragmented per-account and per-region: the plan you can get one
# of is rarely the plan you can get four of. "2x vcg-a100-12c-120g-80vram plus
# 1x vcg-a100-96c-960g-640vram plus 2x vbm-256c-3072gb-8-mi325x-gpu" has to be
# expressible, and so does any subset of it. Both default to {}, which builds a
# control-plane-only cluster -- the only safe default when the cheapest entry
# on either list is four figures a month.
#
# THE MAP KEY IS PART OF NODE IDENTITY. Every node in a pool is named
# "<cluster_name>-<key>-NN" and matched against kubernetes/cluster.yaml by that
# name, so renaming a pool renames -- and therefore replaces -- its nodes. Keys
# must be unique across BOTH maps, and "cp" is reserved for the control plane.
variable "gpu_bare_metal_pools" {
  type = map(object({
    plan  = string
    count = optional(number, 1)
  }))
  default     = {}
  description = "Bare metal GPU worker pools, keyed by pool name. Each pool takes a vbm-* plan ID and a count (default 1). Every GPU-bearing bare metal plan costs $7,000-$45,696/month at list price, so nothing here is defaulted for you. vbm-72c-480gb-gh200-gpu (~$2,009/month) is the one cheap option and is NOT usable: it is ARM, and elemental3 only customizes x86_64 images. Pool names become hostnames as \"<cluster_name>-<pool>-NN\"; a pool named \"gpu\" reproduces the hostnames this module used before pools existed."

  validation {
    condition     = alltrue([for k in keys(var.gpu_bare_metal_pools) : can(regex("^[a-z0-9]([a-z0-9-]{0,14}[a-z0-9])?$", k))])
    error_message = "Every gpu_bare_metal_pools key must be 1-16 characters of lowercase alphanumerics and hyphens, not starting or ending with a hyphen -- it becomes part of a node hostname."
  }

  validation {
    condition     = !contains(keys(var.gpu_bare_metal_pools), "cp")
    error_message = "\"cp\" is reserved: it is the control plane's own hostname infix, and a pool using it would produce duplicate node names."
  }

  validation {
    # Without this, a cloud plan ID typed here surfaces from the availability
    # check as "not currently available in region", which reads as a stock
    # problem rather than a wrong-family one.
    condition     = alltrue([for k, p in var.gpu_bare_metal_pools : startswith(p.plan, "vbm-")])
    error_message = "Every gpu_bare_metal_pools plan must be a bare metal plan ID (vbm-*). Cloud plans -- including the vcg-* GPU ones -- go in gpu_cloud_pools, which provisions them as vultr_instance."
  }

  validation {
    condition     = alltrue([for k, p in var.gpu_bare_metal_pools : p.count >= 0])
    error_message = "Every gpu_bare_metal_pools count must be >= 0."
  }

  validation {
    condition     = alltrue([for k in keys(var.gpu_bare_metal_pools) : length("${var.cluster_name}-${k}-00") <= 63])
    error_message = "cluster_name plus a pool key must leave the generated hostname \"<cluster_name>-<pool>-NN\" within the 63-character DNS label limit."
  }
}

variable "gpu_cloud_pools" {
  type = map(object({
    plan      = string
    count     = optional(number, 1)
    plan_type = optional(string, null)
    vpc_only  = optional(bool, true)
  }))
  default     = {}
  description = "Cloud GPU worker pools, keyed by pool name, provisioned as vultr_instance. plan_type is the plan's OWN type field -- the query parameter availability.tf scopes its stock check to -- and is usually inferred, so leave it null. The inference (local.gpu_cloud_plan_types in availability.tf) is: anything but vcg-* takes the id prefix, which for every ordinary family IS the type (voc-* is type voc, vx1-* is vx1, and so on); vcg-* takes \"vdm\". Set it explicitly only for the fractional vGPU SKUs, where the prefix genuinely lies in the other direction. The whole-node accelerator SKUs (vcg-a100-*, vcg-b200-*, vcg-h100-*, vcg-mi3*, vcg-a40-96c-*) are all type \"vdm\"/DEDICATEDMETAL, while only vcg-a16-*, vcg-a40-<24c and vcg-l40s-* are type \"vcg\"/CLOUDGPU -- one prefix covering two types is the whole reason this field exists. Read it from `GET /v2/plans?type=all` with an Authorization header; without the header both type and locations lie. vpc_only defaults to TRUE: a cloud GPU worker needs nothing from the internet that the NAT gateway cannot give it, and a public NIC it never uses is attack surface plus a second address the cluster has to be told to ignore (see write-node-ip.sh). Set it false to get a public NIC -- firewalled by vultr_firewall_group.gpu_cloud either way -- when you want direct SSH, or when routing every driver and container image pull through the single shared NAT gateway is the wrong tradeoff, which it may well be for multi-GB GPU-operator driver images. Bare metal has no such choice: vultr_bare_metal_server always has a public NIC, so the dual-NIC path exists regardless of this default. An ordinary non-GPU cloud plan is accepted too: most regions carry no vdm/vcg stock at all, and a cheap dedicated-vCPU instance is the only way to exercise this path -- cloud worker join, the firewall group, dual-NIC metadata, scale-out -- without one. Such a node is a worker like any other; it simply never gets a GPU, and the gpu-operator's node feature discovery leaves it alone."

  validation {
    condition     = alltrue([for k in keys(var.gpu_cloud_pools) : can(regex("^[a-z0-9]([a-z0-9-]{0,14}[a-z0-9])?$", k))])
    error_message = "Every gpu_cloud_pools key must be 1-16 characters of lowercase alphanumerics and hyphens, not starting or ending with a hyphen -- it becomes part of a node hostname."
  }

  validation {
    condition     = !contains(keys(var.gpu_cloud_pools), "cp")
    error_message = "\"cp\" is reserved: it is the control plane's own hostname infix, and a pool using it would produce duplicate node names."
  }

  validation {
    # Both maps feed one hostname namespace, so a key in both would generate
    # two different nodes with the same name -- which elemental resolves by
    # giving one of them the other's RKE2 role.
    condition     = length(setintersection(keys(var.gpu_cloud_pools), keys(var.gpu_bare_metal_pools))) == 0
    error_message = "gpu_cloud_pools and gpu_bare_metal_pools must not share a pool name: both build hostnames as \"<cluster_name>-<pool>-NN\", so a shared key produces duplicate node identities."
  }

  validation {
    condition     = alltrue([for k, p in var.gpu_cloud_pools : !startswith(p.plan, "vbm-")])
    error_message = "gpu_cloud_pools takes cloud instance plans, not vbm-* bare metal ones -- those go in gpu_bare_metal_pools."
  }

  validation {
    # Checks the RESOLVED type, so a plan id with an unknown prefix and no
    # explicit plan_type fails here with a readable message rather than as an
    # HTTP 400 from the availability endpoint. The inference expression is
    # duplicated from local.gpu_cloud_plan_types in availability.tf, and has to
    # be: Terraform 1.9+ does let a validation reference a local, but that local
    # is itself derived from var.gpu_cloud_pools, so referencing it here is a
    # graph cycle ("Cycle: local.gpu_cloud_plan_types (expand), var.gpu_cloud_pools
    # (validation)" -- confirmed against Terraform 1.16.3). Keep the two in step.
    #
    # The allowed set is the two GPU families plus the ordinary cloud ones that
    # availability.tf already queries for the control plane. A non-GPU plan
    # here is legitimate: it is the only way to exercise the cloud-worker path
    # (scale out, firewall group, dual-NIC metadata) in a region with no GPU
    # stock, which is most of them.
    condition = alltrue([
      for k, p in var.gpu_cloud_pools : contains(
        ["vdm", "vcg", "vc2", "vhf", "vhp", "voc", "vx1"],
        coalesce(p.plan_type, startswith(p.plan, "vcg-") ? "vdm" : split("-", p.plan)[0])
      )
    ])
    error_message = "gpu_cloud_pools plan_type must resolve to one of vdm, vcg (the GPU families) or vc2, vhf, vhp, voc, vx1 (ordinary cloud plans, for testing the cloud-worker path without GPU stock). Left null it is inferred from the plan id -- the prefix, except vcg-* which resolves to vdm -- so an unrecognised prefix needs plan_type set explicitly. It is the Vultr plan's own type field, not its id prefix."
  }

  validation {
    condition     = alltrue([for k, p in var.gpu_cloud_pools : p.count >= 0])
    error_message = "Every gpu_cloud_pools count must be >= 0."
  }

  validation {
    condition     = alltrue([for k in keys(var.gpu_cloud_pools) : length("${var.cluster_name}-${k}-00") <= 63])
    error_message = "cluster_name plus a pool key must leave the generated hostname \"<cluster_name>-<pool>-NN\" within the 63-character DNS label limit."
  }
}

variable "gpu_cloud_extra_cidrs" {
  type        = list(string)
  default     = []
  description = "Extra CIDRs allowed to reach the cloud GPU nodes on the RKE2 port list, beyond the VPC subnet. Meant for the NAT gateway's public /32s, so that a control-plane node whose traffic hairpins out to a GPU node's PUBLIC address is not dropped. Not merely defensive: 99-node-ip.yaml pins every node's RKE2 node-ip to its VPC address, but flannel does not read node-ip -- it picks its VXLAN source from the default-route interface, which on a dual-NIC node is the public NIC, so pod traffic does hairpin out to public addresses. canal.yaml.tftpl now pins flannel to the VPC by address regex, which is the actual fix; keep this variable as a backstop for anything else that resolves a node by its public address. A plain variable rather than a reference because vultr_nat_gateway.this.public_ips is unknown at plan time and a resource's for_each cannot be; deploy.sh fills it from the nat_gateway_public_cidrs output on pass 2, the same mechanism as lb_supervisor_extra_cidrs."
}

variable "jumphost_plan" {
  type        = string
  default     = "vc2-6c-16gb"
  description = "Vultr cloud instance plan ID for the jumphost/image factory. Needs enough disk for the raw image (var.image_disk_size) plus pulled OCI layers (elemental_image, the core platform image, and whatever else elemental customize pulls) plus the served copy; size up if image_disk_size grows."
}

variable "jumphost_os_id" {
  type        = number
  default     = 2656
  description = "Vultr OS ID for the jumphost. 2656 is openSUSE Leap 16 x64 (from GET /v2/os), the only SUSE image on elemental's supported build-host list. This is the jumphost's own OS, not the elemental snapshot it builds and boots the other nodes from."
}

variable "jumphost_username" {
  type        = string
  default     = "suse"
  description = "Unprivileged login created on the jumphost by cloud-init, with passwordless sudo, the same ssh_authorized_keys as root and no password login. Jumphost only -- the elemental nodes stay root-only, since an account there would have to be baked into the image. Set to \"\" for a root-only jumphost. Changing this replaces the jumphost, which rebuilds the image."

  validation {
    condition     = var.jumphost_username == "" || can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.jumphost_username))
    error_message = "jumphost_username must be a valid POSIX user name: lowercase, starting with a letter or underscore, at most 32 characters."
  }
}

variable "lb_nodes" {
  type        = number
  default     = 1
  description = "Number of load balancer instances Vultr provisions behind each of this module's load balancers (the API one and, unless ingress_controller is \"none\", the ingress one). Must be odd (provider requirement)."

  validation {
    condition     = var.lb_nodes % 2 == 1
    error_message = "lb_nodes must be odd."
  }
}

variable "ingress_controller" {
  type        = string
  default     = "traefik"
  description = "RKE2's ingress-controller setting, written into kubernetes/config/server.yaml. \"traefik\" (default) also pins the DaemonSet to the control-plane nodes and stands up a second Vultr load balancer for 80/443 -- see network.tf and kubernetes/manifests/traefik.yaml. \"ingress-nginx\" is the pre-v1.36 RKE2 default but went end-of-life in March 2026 and is removed in v1.37; it gets no pinning, no proxy protocol and no ingress load balancer here. \"none\" skips the ingress load balancer entirely."

  validation {
    condition     = contains(["none", "traefik", "ingress-nginx"], var.ingress_controller)
    error_message = "ingress_controller must be one of: none, traefik, ingress-nginx."
  }
}

variable "ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the ingress load balancer on 80/443. Open by default -- an ingress nobody can reach has no purpose, and this is the address Rancher's UI lives on. Narrow it if the cluster is not meant to serve the public internet."
}

variable "api_host" {
  type        = string
  default     = null
  description = "Elemental network.apiHost, a DNS name for the Kubernetes API that elemental adds to the server certificate's SANs alongside apiVIP. Defaults to \"rke2-<api_vip>.sslip.io\" when null, so a kubeconfig can use a name instead of a bare IP without anyone running a DNS zone. Set to a name you control if you have one; there is no way to switch it off short of pointing it at the apiVIP itself."
}

variable "api_vip_mode" {
  type        = string
  default     = "external"
  description = "Elemental network.apiVIPMode. \"external\" (default) means a user-managed load balancer (the Vultr LB here) owns the API address and MetalLB/ECO are skipped; \"managed\" would hand the address to MetalLB instead, which this design has no use for."

  validation {
    condition     = contains(["managed", "external"], var.api_vip_mode)
    error_message = "api_vip_mode must be one of: managed, external."
  }
}

# SUSE/aif tags per COMPONENT, not per release, and aif-operator's tag is the
# one that tracks the AI Factory version as a whole: aif-operator-2.1.0,
# aif-operator-2.2.0, plus pre-releases aif-operator-2.2.0-rc.1 and
# aif-operator-2.3.0-dev.2. A tag rather than the release-X.Y branch because a
# tag is immutable -- release-2.2's tip can move under a built cluster, an
# aif-operator-2.2.0 tree cannot. aif-operator-2.0.x predates
# uc-release-manifest/ and 404s, so 2.1.0 is the floor.
variable "aif_version" {
  type        = string
  default     = "2.2.0"
  description = "AI Factory version, resolved to the SUSE/aif tag aif-operator-<version> and that tag's uc-release-manifest/release_manifest.yaml. Full X.Y.Z, optionally with a pre-release suffix: \"2.2.0\", \"2.1.0\", \"2.3.0-dev.2\", \"2.2.0-rc.1\". There is no \"2.2\" tag, so there is no \"2.2\" here. Ignored entirely if aif_release_manifest_url is set."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?$", var.aif_version))
    error_message = "aif_version must be a full X.Y.Z version, optionally with a pre-release suffix: \"2.2.0\", \"2.3.0-dev.2\". SUSE/aif tags releases as aif-operator-X.Y.Z, so a bare \"2.2\" resolves to no tag."
  }

  # Nothing below 2.1.0 has a manifest at this path, and saying so here beats a
  # 404 from the data source with no hint about why.
  validation {
    condition = (
      tonumber(split(".", split("-", var.aif_version)[0])[0]) > 2 ||
      tonumber(split(".", split("-", var.aif_version)[0])[1]) >= 1
    )
    error_message = "aif_version must be 2.1.0 or newer: SUSE/aif's aif-operator-2.0.x tags have no uc-release-manifest/release_manifest.yaml."
  }
}

variable "aif_release_manifest_url" {
  type        = string
  default     = null
  description = "Release manifest the jumphost curls into the config dir as release_manifest.yaml, referenced by release.yaml as manifestURI: file://./release_manifest.yaml. Leave null (the default) to derive it from aif_version's tag; set it to override that entirely -- a branch or commit URL, or a manifest hosted somewhere else. Either way the content is hashed into the build id (snapshot.tf), so a far-end change on a moving ref still forces a rebuild; it just won't show in a plan diff of these variables."
}

# Warns rather than fails: the manifest at the requested tag is still the best
# available answer, and upstream's own metadata is what is wrong. This does
# fire in practice -- aif-operator-2.2.0-rc.1 ships a manifest declaring
# metadata.version 2.0.1 -- so the warning is the difference between finding
# that out at plan time and finding it out in a running cluster.
#
# Skipped for an explicit URL, where aif_version is meaningless.
check "aif_version_matches_manifest" {
  assert {
    condition = (
      var.aif_release_manifest_url != null ||
      try(yamldecode(data.http.aif_release_manifest.response_body).metadata.version, "") == var.aif_version
    )
    error_message = "aif_version is \"${var.aif_version}\", but the manifest at tag ${local.aif_tag} declares metadata.version ${try(yamldecode(data.http.aif_release_manifest.response_body).metadata.version, "(unreadable)")} -- and THAT is what will be built. The tag is what was asked for, so this is upstream metadata disagreeing with its own tag; check the manifest before trusting the version number."
  }
}

# Two elemental versions are involved in one build and they have to agree:
# `elemental customize` only writes the media, while the install runs later
# from the OS image's own elemental3ctl. The customize container this module
# needs (3.1.0, for apiVIPMode: external) emits bootloader.initrdExtensions,
# the key that delivers the entire Kubernetes firstboot chain -- and every
# elemental3ctl on the 3.0.x line silently ignores it, producing a node that
# boots perfectly with no Kubernetes on it and no error anywhere. Support
# landed on the 3.1.0 line; a BRANCH difference, so a newer GA build will not
# fix it.
#
# corePlatform.image can't just be redirected at a local file (the resolver
# hard-forces an oci:// prefix) and no published core platform manifest pins a
# new enough OS image. So this flattens instead: the module writes its own
# schema-v0 core platform manifest with these pins and merges the AIF solution
# manifest's components.systemd and components.helm into it -- a v0 core
# manifest's Components is a superset, so nothing is lost.
#
# Setting it puts you deliberately off the tested combination: a beta OS image
# with AIF 2.2's chart set. Leave it null for the normal manifest chain.
variable "core_platform_override" {
  type = object({
    os_image_base      = string
    os_image_iso       = string
    kubernetes_version = string
    kubernetes_image   = string
  })
  default     = null
  description = "Replaces the release manifest chain with a locally-generated core platform manifest pinning these images, keeping the AIF manifest's systemd extensions and helm charts. Set this to escape the initrdExtensions skew described above. os_image_iso is the one that matters (customize extracts the ISO variant and never touches the base), but the schema requires both. kubernetes_version is the RKE2 version string (e.g. \"v1.35.6+rke2r1\") and kubernetes_image the matching rke2-tar OCI reference. null (default) keeps the normal chain."

  validation {
    # An OS image whose elemental3ctl predates 3.1.0~alpha.20260909 produces
    # a silently Kubernetes-less node, so pointing this at a GA tag defeats
    # the entire purpose of setting it. Can't check the binary from here, but
    # the GA repo path is a reliable enough proxy to be worth catching.
    condition = var.core_platform_override == null || !can(regex(
      "registry\\.suse\\.com/elemental/base-os-kernel-default",
      var.core_platform_override.os_image_iso
    ))
    error_message = "core_platform_override.os_image_iso points at the GA elemental/ repo, whose newest elemental3ctl (3.0.3) still ignores initrdExtensions -- overriding to it changes nothing. Use a beta/uc/ image."
  }
}

# The sibling of core_platform_override, for the same reason: beta bits. The
# AIF manifest pins each systemd extension's OCI image, and release.yaml can
# only name an extension -- there is no per-extension image field in that
# schema -- so an override has to rewrite the manifest itself. image-factory.sh
# does that in the same Python step that flattens the core platform, and will
# now run for a sysext override alone, with no core override set.
#
# It defaults to the beta longhorn extension rather than to {}, for the same
# reason elemental_image defaults to a beta build: the configuration this
# module is actually flown with is a beta one. core_platform_override is
# documented as effectively required, and every OS image it can sensibly point
# at today is on the beta 16.1 line, which the manifest's GA-pinned extension
# does not match. Defaulting to {} would mean anyone enabling suse-storage
# inherits that mismatch silently.
#
# Nothing here applies unless an enabled component actually pulls the named
# extension in -- locals.tf filters the map against local.enabled_sysexts, so
# the default is inert on the default (local-path-provisioner) chart set and
# does not even move the build id there. Once it does apply, a name the
# manifest does not declare stops the build early and says so; set this to {}
# against a manifest that does not ship the extension.
variable "sysext_image_overrides" {
  type = map(string)
  default = {
    # Pairs with the beta OS image core_platform_override selects. AIF 2.2 pins
    # registry.suse.com/elemental/longhorn:4.111-4.79, which is the GA build.
    suse-storage = "registry.suse.com/beta/uc/longhorn:5.279-4.13"
  }
  description = "Per-extension OCI image overrides applied to the release manifest before `elemental customize` reads it, keyed by the extension's name as the manifest spells it. Defaults to the beta longhorn extension, matching the beta OS image core_platform_override has to select; set to {} to follow the manifest's own pins instead. Only applies to extensions an enabled component pulls in -- the default does nothing until \"suse-storage\" is in var.components, and does not renumber the build until then either. Once it does apply, the named extension must exist in the manifest or the build fails early rather than silently overriding nothing."

  validation {
    condition = alltrue([
      for name in keys(var.sysext_image_overrides) :
      can(regex("^[a-z0-9][a-z0-9._-]*$", name))
    ])
    error_message = "sysext_image_overrides keys must be extension names as the release manifest spells them (lowercase alphanumerics, dots, dashes, underscores) -- e.g. \"suse-storage\"."
  }

  validation {
    # Passed to the build script as a shell single-quoted JSON blob, so a quote
    # or whitespace in the value would break out of it. No legitimate image
    # reference contains either.
    condition = alltrue([
      for image in values(var.sysext_image_overrides) :
      length(image) > 0 && !can(regex("[[:space:]'\"]", image))
    ])
    error_message = "sysext_image_overrides values must be non-empty OCI image references with no whitespace or quote characters."
  }
}

# The two validations above cannot see var.components, and the enablement
# filter in locals.tf deliberately makes an override for an unselected
# component a silent no-op -- which is right for the shipped default
# (suse-storage overridden, local-path-provisioner selected) and wrong for a
# typo, which would also silently do nothing.
#
# A check block distinguishes them: a name this module could never enable is
# almost certainly misspelled, so warn. A name it knows but has not selected is
# the normal case and stays quiet. A warning rather than an error because the
# module cannot be sure -- and because an override is inert either way.
check "sysext_image_overrides_are_known_extensions" {
  assert {
    condition = alltrue([
      for name in keys(var.sysext_image_overrides) :
      contains(local.known_sysexts, name)
    ])
    error_message = "sysext_image_overrides names extension(s) this module never enables: ${join(", ", setsubtract(keys(var.sysext_image_overrides), local.known_sysexts))}. Extensions it can enable: ${join(", ", local.known_sysexts)}. Check the spelling -- the override will otherwise be dropped silently. If the name is right and belongs to an extension no component pulls in, it has to be added to component_spec's sysext field in locals.tf to have any effect."
  }
}

variable "image_disk_size" {
  type        = string
  default     = "8G"
  description = "install.yaml raw.diskSize -- the size of the raw file elemental builds and imports as the snapshot, not a cap on the node's usable disk: first-boot bootstrap expands the partition to fill whatever the plan provides. Smaller buys a faster build and import; the cookbook's own figure is 35G."

  validation {
    # Catches a malformed size (e.g. "35Gi", "35g", "0G") at plan time
    # instead of ~20 minutes into a jumphost build, when elemental itself
    # rejects install.yaml.
    condition     = can(regex("^[1-9][0-9]*[KMGT]$", var.image_disk_size))
    error_message = "image_disk_size must match <positive integer><K|M|G|T>, e.g. \"35G\"."
  }
}

variable "fips" {
  type        = bool
  default     = false
  description = "Whether install.yaml sets cryptoPolicy: fips. Off by default: the upstream example enables it but warns every node must then be FIPS-ready, which is not a call to make silently on someone's behalf."
}

variable "snapshot_id" {
  type        = string
  default     = null
  description = "Override: provision the nodes from a snapshot built outside this module instead of the one it imports (see snapshot.tf). Setting it drops vultr_snapshot_from_url.ai_factory to count = 0, which DESTROYS a snapshot this module already built -- the managed one needs no pinning, its id is known from state."
}

variable "deploy_nodes" {
  type        = bool
  default     = true
  description = "Whether to provision the control-plane and GPU nodes. false stands up only the network, load balancer and jumphost/image factory -- which still builds and imports the snapshot, so the apply still blocks on it."
}

variable "lb_backend_instance_ids" {
  type        = list(string)
  default     = []
  description = "Instance IDs attached to the load balancer as backends. Deliberately a variable, not a reference to vultr_instance.control_plane[*].id: the LB must exist before the jumphost (its address is baked into the image) and the nodes come from the image the jumphost builds, so an inline reference would close a dependency cycle. Empty on pass 1, filled from its control_plane_ids output on pass 2. See the README's \"two-pass apply\" section."
}

variable "lb_supervisor_extra_cidrs" {
  type        = list(string)
  default     = []
  description = "Extra CIDRs (beyond the NAT gateway's public IPs) allowed to reach the load balancer on 9345. Meant for the GPU nodes' public /32s, which — unlike the vpc_only control-plane nodes — reach the LB directly rather than hairpinning through the NAT gateway. A vpc_only cloud GPU pool contributes nothing here and needs nothing: it hairpins through the NAT gateway like the control plane does. Filled from the first apply's gpu_node_cidrs output on the second pass, for the same cycle-avoidance reason as lb_backend_instance_ids."
}

variable "image_build_timeout" {
  type        = number
  default     = 5400
  description = "Seconds scripts/wait-for-image.sh will poll the jumphost for the served raw before giving up. 5400 (90 min) gives headroom over a cold podman pull of the elemental image plus the raw build."
}

variable "image_serve_seconds" {
  type        = number
  default     = 3600
  description = "Seconds the jumphost serves the raw after building it, then stops the http server and deletes the file. A fixed window because knowing when the import finished would need a Vultr API key on the jumphost. Also the timeout for scripts/wait-for-snapshot.sh, since an import still pending once serving stops will not complete."

  validation {
    condition     = var.image_serve_seconds >= 600
    error_message = "image_serve_seconds must be at least 600: Vultr's fetch of a multi-GB raw takes minutes, and wait-for-snapshot.sh shares this as its timeout."
  }
}

variable "image_import_port_open" {
  type        = bool
  default     = true
  description = "Whether the jumphost's firewall group allows tcp/80 from 0.0.0.0/0 for Vultr's create-from-url fetcher (snapshot.tf). A Terraform resource, so it cannot be opened and closed within one apply: examples/ha-cluster/deploy.sh leaves it at the default on pass 1 and sets it false on pass 2, after the snapshot is complete. A rebuild with it false fails in wait-for-image.sh."
}

variable "verify_plan_availability" {
  type        = bool
  default     = true
  description = "Whether to run pre-flight checks, during plan, that the chosen plans are actually in stock in the chosen region. See availability.tf. Best-effort: stock can still drain between plan and apply."
}

variable "ssh_key_ids" {
  type        = list(string)
  default     = []
  description = "Vultr SSH key IDs injected into the jumphost and every GPU node that has a public NIC. Likely unused on the GPU nodes, whose root keys come from the image's butane.yaml. Not applied to the control-plane instances, nor to a vpc_only cloud GPU pool, since neither has a public NIC to reach over SSH."
}

variable "tags" {
  type        = list(string)
  default     = []
  description = "Tags applied to created Vultr resources that support them."
}

variable "enable_ipv6" {
  type        = bool
  default     = false
  description = "Whether to enable IPv6 on the jumphost and the GPU nodes. Ignored for a vpc_only cloud GPU pool, which gets no public NIC of either family."
}

variable "mdisk_mode" {
  type        = string
  default     = "none"
  description = "Managed disk mode for the GPU bare metal nodes. Bare metal only: vultr_instance has no equivalent, so it does not reach gpu_cloud_pools."

  validation {
    condition     = contains(["raid1", "jbod", "none"], var.mdisk_mode)
    error_message = "mdisk_mode must be one of: raid1, jbod, none."
  }
}

variable "activation_email" {
  type        = bool
  default     = false
  description = "Whether Vultr should send an activation email when the GPU bare metal nodes are provisioned."
}
