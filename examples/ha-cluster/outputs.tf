output "jumphost_public_ipv4" {
  description = "Public IPv4 of the jumphost — the only inbound admin path into the cluster."
  value       = module.ha_cluster.jumphost_public_ipv4
}

output "jumphost_ssh_login" {
  description = "SSH login for the jumphost: jumphost_username if set, root otherwise."
  value       = module.ha_cluster.jumphost_ssh_login
}

output "kubernetes_api_endpoint" {
  description = "Kubernetes API endpoint, fronted by the Vultr load balancer (apiVIP)."
  value       = module.ha_cluster.kubernetes_api_endpoint
}

output "api_vip" {
  description = "The load balancer's IPv4, baked into the elemental image as network.apiVIP."
  value       = module.ha_cluster.api_vip
}

output "api_host" {
  description = "DNS name for the Kubernetes API, baked in as network.apiHost and present in the API server certificate's SANs."
  value       = module.ha_cluster.api_host
}

output "ingress_lb_ipv4" {
  description = "The ingress load balancer's IPv4 -- 80/443 forwarded to Traefik on the control-plane nodes. null when ingress_controller is \"none\"."
  value       = module.ha_cluster.ingress_lb_ipv4
}

output "snapshot_id" {
  description = "ID of the Vultr snapshot built by the jumphost (or the override passed via var.snapshot_id)."
  value       = module.ha_cluster.snapshot_id
}

output "rke2_token" {
  description = "Shared RKE2 join token baked into every node's config. Sensitive."
  value       = module.ha_cluster.rke2_token
  sensitive   = true
}

output "rancher_hostname" {
  description = "Hostname Rancher's ingress is configured for."
  value       = module.ha_cluster.rancher_hostname
}

output "rancher_url" {
  description = "Rancher's UI, on the ingress load balancer."
  value       = module.ha_cluster.rancher_url
}

output "rancher_bootstrap_password" {
  description = "Rancher's initial admin bootstrap password. Sensitive."
  value       = module.ha_cluster.rancher_bootstrap_password
  sensitive   = true
}

output "control_plane_internal_ip" {
  description = "VPC addresses of the control-plane nodes -- used by the post-deploy MTU check in the README."
  value       = module.ha_cluster.control_plane_internal_ip
}

output "gpu_node_ipv4" {
  description = "Public IPv4 of every GPU node that has one, both families -- used by the post-deploy exposure check in the README."
  value       = module.ha_cluster.gpu_node_ipv4
}

output "gpu_bare_metal_ipv4" {
  description = "Public IPv4 of the bare metal GPU nodes, keyed by hostname. Unprotected by design: bare metal has no Vultr firewall."
  value       = module.ha_cluster.gpu_bare_metal_ipv4
}

output "gpu_cloud_ipv4" {
  description = "Public IPv4 of the cloud GPU nodes, keyed by hostname. \"0.0.0.0\" means the pool is vpc_only."
  value       = module.ha_cluster.gpu_cloud_ipv4
}

output "gpu_cloud_internal_ip" {
  description = "VPC addresses of the cloud GPU nodes, keyed by hostname."
  value       = module.ha_cluster.gpu_cloud_internal_ip
}

# Fed back into the second `terraform apply` by deploy.sh — see the README's
# two-pass apply section. Re-exported here (rather than requiring
# `terraform -chdir=../../modules/...` output tricks) is what makes
# `terraform output -json control_plane_ids` work from this directory.
output "control_plane_ids" {
  description = "Vultr instance IDs of the control-plane nodes, fed to lb_backend_instance_ids on pass 2."
  value       = module.ha_cluster.control_plane_ids
}

output "gpu_node_cidrs" {
  description = "GPU node public IPs as /32 CIDRs, fed to lb_supervisor_extra_cidrs on pass 2."
  value       = module.ha_cluster.gpu_node_cidrs
}

output "nat_gateway_public_cidrs" {
  description = "NAT gateway public IPs as /32 CIDRs, fed to gpu_cloud_extra_cidrs on pass 2."
  value       = module.ha_cluster.nat_gateway_public_cidrs
}
