# GPU workers, from the same snapshot as the control plane, in two resource
# families that can be mixed in one cluster. The hostname is what the elemental
# config keys the "agent" role off, in both cases.
#
# for_each keyed by hostname rather than count: pools are independent, and with
# count, growing the first pool would renumber every node after it and shuffle
# resource addresses across physical machines. Hostnames are stable names, so
# adding a pool only adds instances.

# --- Bare metal (vbm-* plans) -------------------------------------------------
#
# Deliberately NO firewall_group_id: there is no Vultr-side firewall for bare
# metal at all -- neither the resource nor the API carries one -- so the public
# IP these nodes are stuck with is unprotected at the platform level. See the
# root README's Security section. A cloud GPU pool is the way out of that; see
# below.
resource "vultr_bare_metal_server" "gpu" {
  for_each = var.deploy_nodes ? { for n in local.gpu_bare_metal_nodes : n.hostname => n } : {}

  depends_on = [terraform_data.gpu_plan_availability_check]

  region      = var.region
  plan        = each.value.plan
  snapshot_id = local.effective_snapshot_id

  # Singular vpc_id, unlike vultr_instance's plural vpc_ids -- a real
  # difference between the two resource types, not a typo.
  vpc_id = vultr_vpc.this.id

  label    = each.key
  hostname = each.key

  tags             = var.tags
  ssh_key_ids      = var.ssh_key_ids
  enable_ipv6      = var.enable_ipv6
  mdisk_mode       = var.mdisk_mode
  activation_email = var.activation_email

  # Raw Ignition JSON, not cloud-init -- same mechanism as control-plane.tf's
  # user_data, plus the node-ip drop-in this node type needs.
  user_data = local.node_runtime_ignition[each.key]
}

# --- Cloud (vultr_instance, the vcg-* plans) ----------------------------------
#
# Same image, same Ignition mechanism, same agent role. What differs is what
# the resource type can do: vpc_ids, vpc_only and firewall_group_id all exist
# here, so unlike a bare metal worker a cloud GPU node's exposure is
# controllable -- either firewalled, or (vpc_only = true) with no public NIC at
# all, reaching the registry through the NAT gateway like the control plane.
#
# No mdisk_mode: vultr_instance has no equivalent.
resource "vultr_instance" "gpu_cloud" {
  for_each = var.deploy_nodes ? { for n in local.gpu_cloud_nodes : n.hostname => n } : {}

  # The availability check, plus egress: a vpc_only instance with no NAT
  # gateway yet boots into a network with no default route at all.
  depends_on = [
    terraform_data.gpu_plan_availability_check,
    vultr_nat_gateway.this,
  ]

  region      = var.region
  plan        = each.value.plan
  snapshot_id = local.effective_snapshot_id

  vpc_only = each.value.vpc_only
  vpc_ids  = [vultr_vpc.this.id]

  firewall_group_id = one(vultr_firewall_group.gpu_cloud[*].id)

  label    = each.key
  hostname = each.key

  tags             = var.tags
  activation_email = var.activation_email

  # Meaningless on a vpc_only node -- there is no public NIC for either to
  # attach to -- and Vultr ignores them rather than erroring.
  ssh_key_ids = each.value.vpc_only ? [] : var.ssh_key_ids
  enable_ipv6 = each.value.vpc_only ? false : var.enable_ipv6

  # Raw Ignition JSON, not cloud-init. Same per-node config as every other
  # node. The 99-node-ip.yaml drop-in is NOT in here: write-node-ip.service
  # (baked into the image via butane.yaml) writes it at first boot from
  # metadata, on a dual-NIC node only -- a vpc_only one must not have it, for
  # the reason spelled out in control-plane.tf.
  user_data = local.node_runtime_ignition[each.key]
}
