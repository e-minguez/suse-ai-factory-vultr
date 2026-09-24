output "jumphost_public_ipv4" {
  description = "Public IPv4 of the jumphost/image factory -- the only inbound admin path into the cluster."
  value       = vultr_instance.jumphost.main_ip
}

output "jumphost_ssh_login" {
  description = "SSH login for the jumphost: jumphost_username if set, root otherwise."
  value       = "${var.jumphost_username != "" ? var.jumphost_username : "root"}@${vultr_instance.jumphost.main_ip}"
}

output "jumphost_vpc_ip" {
  description = "Jumphost's address on the VPC."
  value       = vultr_instance.jumphost.internal_ip
}

output "kubernetes_api_endpoint" {
  description = "Kubernetes API endpoint, fronted by the load balancer at apiVIP. Reachable once RKE2 is up and (per the two-pass apply) the LB has backends attached."
  value       = "https://${vultr_load_balancer.api.ipv4}:6443"
}

output "api_vip" {
  description = "The load balancer's IPv4 -- the address baked into every node's elemental config as network.apiVIP."
  value       = vultr_load_balancer.api.ipv4
}

output "api_host" {
  description = "DNS name for the Kubernetes API, baked in as network.apiHost and therefore present in the API server certificate's SANs. Defaults to rke2-<api_vip>.sslip.io."
  value       = local.api_host
}

output "ingress_lb_ipv4" {
  description = "The ingress load balancer's IPv4 -- where 80/443 are forwarded to Traefik's hostPorts on the control-plane nodes. null when ingress_controller is \"none\"."
  value       = local.ingress_lb_ipv4
}

output "ingress_endpoint" {
  description = "URL the cluster's Ingress resources are reachable on. Any hostname resolving to the ingress load balancer works; rancher_hostname is the one this module configures."
  value       = local.ingress_lb_ipv4 == null ? null : "https://${local.ingress_lb_ipv4}"
}

output "nat_gateway_private_ip" {
  description = "NAT gateway's address on the VPC -- DHCP hands this out as the default route to every vpc_only control-plane node."
  value       = vultr_nat_gateway.this.private_ips[0]
}

output "nat_gateway_public_ips" {
  description = "NAT gateway's public IPs -- the source address the load balancer sees for every control-plane node's hairpinned join traffic on 9345."
  value       = vultr_nat_gateway.this.public_ips
}

output "vpc_subnet" {
  description = "CIDR of the cluster VPC."
  value       = "${vultr_vpc.this.v4_subnet}/${vultr_vpc.this.v4_subnet_mask}"
}

output "snapshot_id" {
  description = "The Vultr snapshot the cluster was (or will be) provisioned from -- either the one this module imported (vultr_snapshot_from_url) or var.snapshot_id if that override was set."
  value       = local.effective_snapshot_id
}

output "rke2_token" {
  description = "Shared RKE2 join token baked into every node's kubernetes/config/{server,agent}.yaml."
  value       = random_password.token.result
  sensitive   = true
}

output "rancher_hostname" {
  description = "Hostname Rancher's ingress is configured for -- var.rancher_hostname if set, otherwise rancher-<ingress_lb_ipv4>.sslip.io. null when \"rancher\" is not in var.components -- nothing serves this hostname then."
  value       = contains(local.enabled_components, "rancher") ? local.rancher_hostname : null
}

output "rancher_url" {
  description = "Rancher's UI, on the ingress load balancer. Serves an ingress-generated self-signed certificate unless cert-manager was given a real issuer. null when \"rancher\" is not in var.components."
  value       = contains(local.enabled_components, "rancher") ? "https://${local.rancher_hostname}" : null
}

output "rancher_bootstrap_password" {
  description = "Rancher's initial admin bootstrap password -- var.rancher_bootstrap_password if set, otherwise a generated one. null when \"rancher\" is not in var.components."
  value       = contains(local.enabled_components, "rancher") ? local.rancher_bootstrap_password : null
  sensitive   = true
}

output "control_plane_ids" {
  description = "Vultr instance IDs of the control-plane nodes. Fed into lb_backend_instance_ids on the example's second apply pass -- see the README."
  value       = vultr_instance.control_plane[*].id
}

output "control_plane_internal_ip" {
  description = "VPC addresses of the control-plane nodes."
  value       = vultr_instance.control_plane[*].internal_ip
}

locals {
  # A vpc_only vultr_instance reports main_ip as "0.0.0.0" rather than omitting
  # it, so filter: an unfiltered list pushes 0.0.0.0/32 into the load
  # balancer's 9345 rule on pass 2, which is both useless and alarming to read.
  gpu_public_ipv4 = [
    for ip in concat(
      [for k in sort(keys(vultr_bare_metal_server.gpu)) : vultr_bare_metal_server.gpu[k].main_ip],
      [for k in sort(keys(vultr_instance.gpu_cloud)) : vultr_instance.gpu_cloud[k].main_ip],
    ) : ip if ip != "" && ip != "0.0.0.0"
  ]
}

output "gpu_node_ipv4" {
  description = "Public IPv4 of every GPU node that has one, both families, bare metal first. Bare metal always appears here -- it has no vpc_only equivalent and no Vultr firewall of its own. A cloud GPU pool appears unless it set vpc_only."
  value       = local.gpu_public_ipv4
}

output "gpu_node_cidrs" {
  description = "Each public GPU node IP as a /32. Fed into lb_supervisor_extra_cidrs on the example's second apply pass, so the load balancer accepts 9345 traffic from the GPU nodes too. vpc_only cloud nodes are absent and need nothing: they hairpin through the NAT gateway, whose public IPs the module allows by reference."
  value       = [for ip in local.gpu_public_ipv4 : "${ip}/32"]
}

output "gpu_bare_metal_ipv4" {
  description = "Public IPv4 of the bare metal GPU nodes only, keyed by hostname."
  value       = { for k, s in vultr_bare_metal_server.gpu : k => s.main_ip }
}

output "gpu_cloud_ipv4" {
  description = "Public IPv4 of the cloud GPU nodes only, keyed by hostname. \"0.0.0.0\" is what Vultr reports for a vpc_only instance."
  value       = { for k, s in vultr_instance.gpu_cloud : k => s.main_ip }
}

output "gpu_cloud_internal_ip" {
  description = "VPC addresses of the cloud GPU nodes, keyed by hostname. vultr_bare_metal_server has no equivalent attribute, which is why there is no bare metal counterpart."
  value       = { for k, s in vultr_instance.gpu_cloud : k => s.internal_ip }
}

output "gpu_cloud_ids" {
  description = "Vultr instance IDs of the cloud GPU nodes, keyed by hostname. Not load balancer backends -- only the control plane is."
  value       = { for k, s in vultr_instance.gpu_cloud : k => s.id }
}

output "gpu_cloud_firewall_group_id" {
  description = "Firewall group protecting the cloud GPU nodes, or null when there are no cloud pools. The thing bare metal cannot have."
  value       = one(vultr_firewall_group.gpu_cloud[*].id)
}

output "nat_gateway_public_cidrs" {
  description = "The NAT gateway's public IPs as /32s. Fed into gpu_cloud_extra_cidrs on the example's second apply pass: the value is unknown at plan time, so it cannot be a resource for_each key and has to round-trip through a variable."
  value       = [for ip in vultr_nat_gateway.this.public_ips : "${ip}/32"]
}
