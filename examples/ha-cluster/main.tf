provider "vultr" {
  # Reads VULTR_API_KEY from the environment; set api_key explicitly only
  # if you have a reason to keep it out of the shell environment.
}

module "ha_cluster" {
  source = "../../modules/ai-factory-ha"

  region              = var.region
  elemental_image     = var.elemental_image
  vultr_api_key       = var.vultr_api_key
  admin_cidrs         = var.admin_cidrs
  root_password_hash  = var.root_password_hash
  ssh_authorized_keys = var.ssh_authorized_keys

  node_username           = var.node_username
  node_user_password_hash = var.node_user_password_hash
  permit_root_ssh         = var.permit_root_ssh

  appco_username             = var.appco_username
  appco_password             = var.appco_password
  appco_registry             = var.appco_registry
  suse_registration_code     = var.suse_registration_code
  suse_registry_password     = var.suse_registry_password
  nvidia_api_key             = var.nvidia_api_key
  components                 = var.components
  rancher_hostname           = var.rancher_hostname
  rancher_bootstrap_password = var.rancher_bootstrap_password

  cluster_name    = var.cluster_name
  vpc_subnet      = var.vpc_subnet
  vpc_subnet_mask = var.vpc_subnet_mask
  vpc_mtu         = var.vpc_mtu
  dns_servers     = var.dns_servers

  control_plane_count = var.control_plane_count
  control_plane_plan  = var.control_plane_plan

  gpu_bare_metal_pools = var.gpu_bare_metal_pools
  gpu_cloud_pools      = var.gpu_cloud_pools

  jumphost_plan     = var.jumphost_plan
  jumphost_os_id    = var.jumphost_os_id
  jumphost_username = var.jumphost_username

  lb_nodes     = var.lb_nodes
  api_vip_mode = var.api_vip_mode
  api_host     = var.api_host

  ingress_controller = var.ingress_controller
  ingress_cidrs      = var.ingress_cidrs

  aif_version              = var.aif_version
  aif_release_manifest_url = var.aif_release_manifest_url
  core_platform_override   = var.core_platform_override
  sysext_image_overrides   = var.sysext_image_overrides
  image_disk_size          = var.image_disk_size
  fips                     = var.fips

  snapshot_id  = var.snapshot_id
  deploy_nodes = var.deploy_nodes

  # Left empty on the first apply and filled in by deploy.sh's second pass —
  # see the "two-pass apply" section in this example's README for why the LB
  # backends and extra supervisor CIDRs cannot just reference the nodes here.
  lb_backend_instance_ids   = var.lb_backend_instance_ids
  lb_supervisor_extra_cidrs = var.lb_supervisor_extra_cidrs
  gpu_cloud_extra_cidrs     = var.gpu_cloud_extra_cidrs

  image_build_timeout      = var.image_build_timeout
  verify_plan_availability = var.verify_plan_availability

  ssh_key_ids      = var.ssh_key_ids
  tags             = var.tags
  enable_ipv6      = var.enable_ipv6
  mdisk_mode       = var.mdisk_mode
  activation_email = var.activation_email
}
