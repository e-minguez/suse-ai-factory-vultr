# vpc_only control-plane nodes, built from the snapshot the jumphost produces.
#
# count keys off plan-known variables, never off local.effective_snapshot_id:
# that comes from a data source with depends_on and so is unknown until apply,
# even though it feeds this resource's own snapshot_id.
resource "vultr_instance" "control_plane" {
  count = var.deploy_nodes ? var.control_plane_count : 0

  # Without egress first, a vpc_only instance boots into a network with no
  # default route at all -- there is no public NIC to fall back to.
  depends_on = [vultr_nat_gateway.this]

  region      = var.region
  plan        = var.control_plane_plan
  snapshot_id = local.effective_snapshot_id

  # No public NIC or IP at all. The NAT gateway (network.tf) is the only
  # egress, and the jumphost is the only path in.
  vpc_only = true
  vpc_ids  = [vultr_vpc.this.id]

  firewall_group_id = vultr_firewall_group.control_plane.id

  label    = local.control_plane_nodes[count.index].hostname
  hostname = local.control_plane_nodes[count.index].hostname

  tags = var.tags

  # Raw Ignition JSON, not cloud-init: elemental3 reads this as Ignition's
  # platform "user config" (ignition.platform.id=vultr), merged on top of the
  # image's base.d drop-ins. So it carries only what differs per node --
  # /etc/hostname, /var/lib/elemental/runtime.env, and (servers only)
  # RKE2's own manifests/canal.yaml. Root password, SSH keys and sshd are
  # baked into the image via butane.yaml.
  #
  # No node-ip drop-in reaches a vpc_only node, but nothing here decides that
  # any more: write-node-ip.service (butane.yaml, so on every node) finds no
  # /v1/interfaces/ tree on a vpc_only instance and exits having written
  # nothing. Which is the wanted outcome -- such a node's only address is what
  # RKE2 picks by default, and it comes from DHCP, so it matches what the load
  # balancer has on file. Interface setup itself is configure-network.sh's job
  # at first boot.
  user_data = local.node_runtime_ignition[local.control_plane_nodes[count.index].hostname]
}
