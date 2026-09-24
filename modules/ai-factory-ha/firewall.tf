# Only the jumphost has a Vultr firewall group of any real consequence: it is
# the sole public admin entrypoint. Port 80 for the snapshot import is in
# snapshot.tf (vultr_firewall_rule.image_import), next to what it serves.
resource "vultr_firewall_group" "jumphost" {
  description = "${var.cluster_name}-jumphost"
}

resource "vultr_firewall_rule" "jumphost_ssh" {
  for_each = toset(var.admin_cidrs)

  firewall_group_id = vultr_firewall_group.jumphost.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = split("/", each.value)[0]
  subnet_size       = tonumber(split("/", each.value)[1])
  port              = "22"
  notes             = "ssh from admin_cidrs"
}

# Attached to the control-plane instances for defense in depth even though a
# vpc_only instance has no public NIC to begin with -- this way the config
# survives anyone flipping vpc_only off later. Every rule is scoped to the
# VPC subnet: nothing here is meant to be reachable from the internet.
resource "vultr_firewall_group" "control_plane" {
  description = "${var.cluster_name}-control-plane"
}

locals {
  # RKE2's own port list: API, supervisor, etcd, kubelet, VXLAN, NodePort.
  control_plane_rules = merge(
    {
      ssh        = { protocol = "tcp", port = "22" }
      kube_api   = { protocol = "tcp", port = "6443" }
      supervisor = { protocol = "tcp", port = "9345" }
      etcd       = { protocol = "tcp", port = "2379:2381" }
      kubelet    = { protocol = "tcp", port = "10250" }
      vxlan      = { protocol = "udp", port = "8472" }
      nodeport   = { protocol = "tcp", port = "30000:32767" }
    },
    # The ingress controller's hostPorts, plus Traefik's /ping entrypoint --
    # all three reached from the ingress load balancer, which sits in the VPC.
    var.ingress_controller == "none" ? {} : {
      http         = { protocol = "tcp", port = "80" }
      https        = { protocol = "tcp", port = "443" }
      ingress_ping = { protocol = "tcp", port = "8080" }
    },
  )
}

resource "vultr_firewall_rule" "control_plane" {
  for_each = local.control_plane_rules

  firewall_group_id = vultr_firewall_group.control_plane.id
  protocol          = each.value.protocol
  ip_type           = "v4"
  subnet            = var.vpc_subnet
  subnet_size       = var.vpc_subnet_mask
  port              = each.value.port
  notes             = each.key
}

# Cloud GPU workers get the firewall bare metal cannot have. This is the whole
# security argument for gpu_cloud_pools: a vultr_bare_metal_server's mandatory
# public IP is unprotectable at the platform level (see the root README's
# Security section), while vultr_instance takes a firewall_group_id.
#
# Only created when there is a cloud pool to attach it to.
resource "vultr_firewall_group" "gpu_cloud" {
  count = length(var.gpu_cloud_pools) > 0 ? 1 : 0

  description = "${var.cluster_name}-gpu-cloud"
}

locals {
  # The control-plane port list minus the ingress hostPorts: the Traefik
  # DaemonSet is pinned to the control-plane nodes, so nothing ever dials 80,
  # 443 or 8080 on a worker.
  gpu_cloud_rules = {
    kube_api   = { protocol = "tcp", port = "6443" }
    supervisor = { protocol = "tcp", port = "9345" }
    etcd       = { protocol = "tcp", port = "2379:2381" }
    kubelet    = { protocol = "tcp", port = "10250" }
    vxlan      = { protocol = "udp", port = "8472" }
    nodeport   = { protocol = "tcp", port = "30000:32767" }
  }

  # The VPC subnet is where all of this traffic should actually come from.
  # gpu_cloud_extra_cidrs carries the NAT gateway's public /32s, for the case
  # where a control-plane node's traffic hairpins out and arrives at a GPU
  # node's public address instead; see that variable's description.
  gpu_cloud_rule_sources = concat([local.vpc_cidr], var.gpu_cloud_extra_cidrs)

  gpu_cloud_firewall_rules = merge(
    {
      for pair in setproduct(keys(local.gpu_cloud_rules), local.gpu_cloud_rule_sources) :
      "${pair[0]}-${pair[1]}" => {
        protocol = local.gpu_cloud_rules[pair[0]].protocol
        port     = local.gpu_cloud_rules[pair[0]].port
        cidr     = pair[1]
        notes    = "${pair[0]} from ${pair[1]}"
      }
    },
    # SSH from admin_cidrs only, unlike a bare metal worker whose port 22 is
    # open to the internet because nothing can close it.
    {
      for cidr in var.admin_cidrs : "ssh-${cidr}" => {
        protocol = "tcp"
        port     = "22"
        cidr     = cidr
        notes    = "ssh from admin_cidrs"
      }
    },
  )
}

resource "vultr_firewall_rule" "gpu_cloud" {
  for_each = length(var.gpu_cloud_pools) > 0 ? local.gpu_cloud_firewall_rules : {}

  firewall_group_id = one(vultr_firewall_group.gpu_cloud[*].id)
  protocol          = each.value.protocol
  ip_type           = "v4"
  subnet            = split("/", each.value.cidr)[0]
  subnet_size       = tonumber(split("/", each.value.cidr)[1])
  port              = each.value.port
  notes             = each.value.notes
}
