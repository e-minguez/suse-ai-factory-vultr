variable "region" {
  type        = string
  description = "Vultr region ID to deploy into, e.g. \"ams\"."
}

variable "elemental_image" {
  type        = string
  default     = "registry.suse.com/beta/uc/elemental:3.1.0-6.5"
  description = "Container image reference passed to `podman run ... customize` on the jumphost. Default is SUSE's own beta channel build (version 3.1.0), which carries apiVIPMode support (upstream PR #578) -- see the README. The released registry.suse.com/elemental/elemental:3.0 tag predates that PR."
}

variable "vultr_api_key" {
  type        = string
  sensitive   = true
  description = "Vultr API key, handed to the jumphost's image-factory script so it can call create-from-url and poll the snapshot import. This ends up in the jumphost's cloud-init user_data, retrievable via GET /v2/instances/{id}/user-data until the instance is destroyed. Use a key scoped with Vultr's IP allowlist to the jumphost and revoke it once the snapshot exists. The vultr provider itself reads VULTR_API_KEY from the environment separately."
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the jumphost on 22/tcp. No default: 0.0.0.0/0 would be an open SSH door, and [] would silently lock everyone out."

  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "admin_cidrs must contain at least one CIDR block."
  }

  validation {
    condition     = alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "Every admin_cidrs entry must be a CIDR block with an explicit prefix, e.g. \"203.0.113.1/32\"."
  }
}

variable "root_password_hash" {
  type        = string
  sensitive   = true
  description = "Password hash set as passwd.users[root].password_hash in the image's butane.yaml. Generate with `openssl passwd -6`. Changing it rebuilds the image and replaces every node. No default: without it there is no console login on any node at all."
}

variable "ssh_authorized_keys" {
  type        = list(string)
  description = "Public keys injected onto both the elemental nodes (baked into the image via butane.yaml, onto node_username and -- only if permit_root_ssh is true -- root, so rotating one rebuilds the image and replaces every node) and the jumphost (via cloud-init). No default: without at least one key, nothing has a way in except the console."

  validation {
    condition     = length(var.ssh_authorized_keys) > 0
    error_message = "ssh_authorized_keys must contain at least one public key."
  }
}

variable "node_username" {
  type        = string
  default     = "suse"
  description = "Unprivileged login created on every elemental node, carrying ssh_authorized_keys and node_user_password_hash. This is where SSH lands by default; escalate with `su -` and the root password (sudo is not installed in the elemental image). Changing it rebuilds the image and replaces every node."
}

variable "node_user_password_hash" {
  type        = string
  sensitive   = true
  description = "Password hash for node_username on the elemental nodes. Generate with `openssl passwd -6`. Must differ from root_password_hash. Changing it rebuilds the image and replaces every node."
}

variable "permit_root_ssh" {
  type        = bool
  default     = false
  description = "Allow `ssh root@<node>` on the elemental nodes, and give root the SSH keys too. Off by default -- log in as node_username and `su -`. Convenient on a throwaway cluster, since the troubleshooting recipes in the README are all written as root. Changing it rebuilds the image and replaces every node."
}

variable "appco_username" {
  type        = string
  default     = null
  sensitive   = true
  description = "SUSE Application Collection username. Required when components lists local-path-provisioner or suse-storage (the module fails the plan otherwise); optional but highly recommended for aif-operator."
}

variable "appco_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "SUSE Application Collection password/token, paired with appco_username."
}

variable "appco_registry" {
  type        = string
  default     = "dp.apps.rancher.io"
  description = "Container registry host the local-path-provisioner image pull secret authenticates against."
}

variable "suse_registration_code" {
  type        = string
  default     = null
  sensitive   = true
  description = "SUSE registration code -- used as the \"username\" for aif-operator.yaml's suseRegistry credentials, per SUSE's own convention. Optional but highly recommended: when null, the suseRegistry block is omitted."
}

variable "suse_registry_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Password paired with suse_registration_code."
}

variable "nvidia_api_key" {
  type        = string
  default     = null
  sensitive   = true
  description = "NVIDIA NGC API key. Optional but highly recommended: when null, aif-operator.yaml's nvidia: credentials block is omitted entirely. The paired username is nvidia_username."
}

variable "nvidia_username" {
  type        = string
  default     = "$oauthtoken"
  description = "Username paired with nvidia_api_key. Defaults to \"$oauthtoken\", NGC's convention for API-key auth; override only if needed."
}

variable "components" {
  type        = list(string)
  default     = ["rancher", "gpu-operator", "local-path-provisioner", "aif-operator"]
  description = "Which SUSE AI Factory Helm charts release.yaml enables. Always rendered in a fixed canonical order regardless of the order given here, so the default reproduces exactly what this module always shipped. \"cert-manager\" is injected automatically whenever \"rancher\" is selected -- listing it explicitly is accepted but never required. \"local-path-provisioner\" and \"suse-storage\" (Longhorn) cannot both be listed: both set themselves as the default StorageClass. \"aif-operator\" requires \"rancher\" and one of the two storage charts. Changing this rebuilds the image and replaces every node -- see the module README's \"What triggers an image rebuild\"."
}

variable "rancher_hostname" {
  type        = string
  default     = null
  description = "Hostname written into kubernetes/helm/values/rancher.yaml. Defaults to \"rancher-<ingress_lb_ipv4>.sslip.io\" when null -- the ingress load balancer, which is where 80/443 are forwarded."
}

variable "rancher_bootstrap_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Rancher initial admin bootstrap password. Defaults to a generated random_password when null."
}

variable "cluster_name" {
  type        = string
  default     = "suse-ai-factory"
  description = "Prefix used to build resource labels and node hostnames (\"<cluster_name>-cp-NN\", \"<cluster_name>-gpu-NN\")."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be a valid DNS label: lowercase alphanumeric and hyphens only, not starting or ending with a hyphen."
  }
}

variable "vpc_subnet" {
  type        = string
  default     = "10.20.0.0"
  description = "IPv4 network address of the VPC. Must not overlap RKE2's default cluster-cidr (10.42.0.0/16) or service-cidr (10.43.0.0/16); the module validates this."
}

variable "vpc_subnet_mask" {
  type        = number
  default     = 20
  description = "IPv4 subnet mask (prefix length) of the VPC."
}

variable "vpc_mtu" {
  type        = number
  default     = 1450
  description = "MTU set on the VPC's private network adapters. RKE2's VXLAN overlay costs 50 bytes on top, landing pod MTU at 1400."
}

variable "dns_servers" {
  type        = list(string)
  default     = ["108.61.10.10", "8.8.8.8"]
  description = "Resolvers baked into each node's network config at build time. Vultr's original VPC has no DHCP."
}

variable "control_plane_count" {
  type        = number
  default     = 3
  description = "Number of vpc_only control-plane vultr_instance nodes. Must stay odd (etcd quorum) and at least 3."

  validation {
    condition     = var.control_plane_count >= 3 && var.control_plane_count % 2 == 1
    error_message = "control_plane_count must be odd and at least 3."
  }
}

variable "control_plane_plan" {
  type        = string
  default     = "vx1-g-4c-16g-240s"
  description = "Vultr cloud instance plan ID for control-plane nodes. Defaults to a VX1 plan (dedicated vCPU, 4c/16GB/240GB) per Vultr's own recommendation."
}

# GPU workers, in two resource families that can be mixed freely in one
# cluster: bare metal (vbm-* plans, vultr_bare_metal_server) and cloud (the
# vcg-* plans, vultr_instance). Each is a MAP of pools so that different plans
# and counts can coexist -- "2x A100-80 + 1x A100-640 + 2x MI325X" is three
# pools. Both default to {}: nothing GPU-shaped is provisioned unless asked
# for, because the cheapest usable plan in either family is four figures a
# month. See the module's variable descriptions for the full reasoning.
variable "gpu_bare_metal_pools" {
  type = map(object({
    plan  = string
    count = optional(number, 1)
  }))
  default     = {}
  description = "Bare metal GPU worker pools, keyed by pool name; each takes a vbm-* plan and a count. Pool names become hostnames as \"<cluster_name>-<pool>-NN\"."
}

variable "gpu_cloud_pools" {
  type = map(object({
    plan      = string
    count     = optional(number, 1)
    plan_type = optional(string, null)
    vpc_only  = optional(bool, true)
  }))
  default     = {}
  description = "Cloud GPU worker pools, keyed by pool name, provisioned as vultr_instance. Unlike bare metal these can drop the public NIC entirely, and do by default (vpc_only = true) -- egress goes through the NAT gateway like the control plane's, and admin access through the jumphost. Set vpc_only = false for a public NIC, still behind the Vultr firewall group, when you want direct SSH or do not want multi-GB driver pulls funnelled through one NAT gateway. plan_type is the plan's own type field, used only to scope the stock check; leave it null and the module infers it from the plan id -- the prefix for every ordinary family, \"vdm\" for vcg-*. Set it to \"vcg\" explicitly for the fractional vGPU SKUs, the one case the prefix gets wrong."
}

variable "jumphost_plan" {
  type        = string
  default     = "vc2-6c-16gb"
  description = "Vultr cloud instance plan ID for the jumphost/image factory. Needs enough disk for the raw image (image_disk_size) plus pulled OCI layers plus the served copy."
}

variable "jumphost_os_id" {
  type        = number
  default     = 2656
  description = "Vultr OS ID for the jumphost. 2656 is openSUSE Leap 16 x64, the only SUSE image on elemental's supported build-host list. This is the jumphost's own OS, not the elemental snapshot it builds and boots the other nodes from."
}

variable "jumphost_username" {
  type        = string
  default     = "suse"
  description = "Unprivileged login created on the jumphost by cloud-init, with passwordless sudo and the same ssh_authorized_keys as root. Jumphost only -- the elemental nodes stay root-only. Set to \"\" for a root-only jumphost. Changing it replaces the jumphost, which rebuilds the image."
}

variable "lb_nodes" {
  type        = number
  default     = 1
  description = "Number of load balancer instances Vultr provisions behind each load balancer (API and ingress). Must be odd."

  validation {
    condition     = var.lb_nodes % 2 == 1
    error_message = "lb_nodes must be odd."
  }
}

variable "ingress_controller" {
  type        = string
  default     = "traefik"
  description = "RKE2's ingress-controller. \"traefik\" (default) pins the DaemonSet to the control-plane nodes and creates a second Vultr load balancer for 80/443 with proxy protocol on. \"none\" skips that load balancer; \"ingress-nginx\" is end-of-life upstream and gets neither."

  validation {
    condition     = contains(["none", "traefik", "ingress-nginx"], var.ingress_controller)
    error_message = "ingress_controller must be one of: none, traefik, ingress-nginx."
  }
}

variable "ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the ingress load balancer on 80/443. Open by default -- this is the address Rancher's UI lives on."
}

variable "api_vip_mode" {
  type        = string
  default     = "external"
  description = "Elemental network.apiVIPMode. \"external\" (default) means the Vultr LB owns the API address and MetalLB/ECO are skipped."

  validation {
    condition     = contains(["managed", "external"], var.api_vip_mode)
    error_message = "api_vip_mode must be one of: managed, external."
  }
}

variable "api_host" {
  type        = string
  default     = null
  description = "Elemental network.apiHost -- a DNS name added to the API server certificate's SANs. Defaults to \"rke2-<api_vip>.sslip.io\" when null."
}

variable "aif_version" {
  type        = string
  default     = "2.2.0"
  description = "SUSE AI Factory version to build against. Selects the release manifest from SUSE/aif's aif-operator-<version> tag, so it must be a full X.Y.Z -- \"2.2.0\", not \"2.2\" -- optionally with a pre-release suffix such as \"2.3.0-dev.2\". 2.1.0 is the oldest tag carrying a manifest."
}

variable "aif_release_manifest_url" {
  type        = string
  default     = null
  description = "Full URL of the release manifest, overriding aif_version entirely. Null (the default) derives it from aif_version's tag, which is immutable; set this to build from a branch ref, a fork or a mirror."
}

variable "core_platform_override" {
  type = object({
    os_image_base      = string
    os_image_iso       = string
    kubernetes_version = string
    kubernetes_image   = string
  })
  default     = null
  description = "Pins the OS and Kubernetes images directly instead of following the AIF manifest's corePlatform.image, by generating a local core platform manifest that keeps AIF's helm charts and systemd extensions. Needed because every published core platform manifest pins an OS image whose elemental3ctl silently ignores initrdExtensions, which is how the Kubernetes firstboot chain is delivered -- nodes built without it boot cleanly with no Kubernetes and no error anywhere. See the module's variables.tf for the full explanation."
}

variable "sysext_image_overrides" {
  type = map(string)
  default = {
    suse-storage = "registry.suse.com/beta/uc/longhorn:5.279-4.13"
  }
  description = "Per-extension OCI image overrides applied to the AIF release manifest before the image is built, keyed by the extension's name as the manifest spells it. The manifest pins each systemd extension's image and release.yaml has no field to override it, so this is the only way to move one. Defaults to the beta longhorn extension, because the manifest's GA pin does not match the beta OS image core_platform_override has to select; set to {} to follow the manifest's own pins. Only applies to extensions an enabled component pulls in, so the default does nothing until \"suse-storage\" is in components. Once it applies, naming an extension the manifest does not declare fails the build."
}

variable "image_disk_size" {
  type        = string
  default     = "8G"
  description = "install.yaml raw.diskSize -- only the size of the built raw/snapshot, not a cap on the running node's disk (elemental's first-boot bootstrap expands the partition to fill the actual instance's real disk). Small on purpose here for faster builds/imports while iterating."

  validation {
    condition     = can(regex("^[1-9][0-9]*[KMGT]$", var.image_disk_size))
    error_message = "image_disk_size must match <positive integer><K|M|G|T>, e.g. \"35G\"."
  }
}

variable "fips" {
  type        = bool
  default     = false
  description = "Whether install.yaml sets cryptoPolicy: fips. Off by default: every node would need to be FIPS-ready."
}

variable "snapshot_id" {
  type        = string
  default     = null
  description = "Override: use an already-imported Vultr snapshot instead of having the jumphost build one."
}

variable "deploy_nodes" {
  type        = bool
  default     = true
  description = "Whether to provision the control-plane and GPU nodes. false stands up only the network, load balancer and jumphost/image factory."
}

variable "lb_backend_instance_ids" {
  type        = list(string)
  default     = []
  description = "Instance IDs attached to the load balancer as backends. Left empty on the first apply, filled from control_plane_ids on the second pass by deploy.sh. See the README's two-pass apply section."
}

variable "lb_supervisor_extra_cidrs" {
  type        = list(string)
  default     = []
  description = "Extra CIDRs allowed to reach the load balancer on 9345, meant for the GPU nodes' public /32s. Filled from gpu_node_cidrs on the second pass by deploy.sh."
}

variable "gpu_cloud_extra_cidrs" {
  type        = list(string)
  default     = []
  description = "Extra CIDRs allowed to reach the cloud GPU nodes' firewall group, meant for the NAT gateway's public /32s. Filled from nat_gateway_public_cidrs on the second pass by deploy.sh, for the same reason as the two above: the value is unknown at plan time."
}

variable "image_build_timeout" {
  type        = number
  default     = 5400
  description = "Seconds the snapshot-wait step will poll the Vultr API before giving up."
}

variable "verify_plan_availability" {
  type        = bool
  default     = true
  description = "Whether to run pre-flight checks, during plan, that the chosen plans are actually in stock in the chosen region."
}

variable "ssh_key_ids" {
  type        = list(string)
  default     = []
  description = "Vultr SSH key IDs injected into the jumphost."
}

variable "tags" {
  type        = list(string)
  default     = []
  description = "Tags applied to created Vultr resources that support them."
}

variable "enable_ipv6" {
  type        = bool
  default     = false
  description = "Whether to enable IPv6 on the jumphost and GPU bare metal nodes."
}

variable "mdisk_mode" {
  type        = string
  default     = "none"
  description = "Managed disk mode for the GPU bare metal nodes."

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
