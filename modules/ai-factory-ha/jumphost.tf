# Unguessable path the raw is served from during the create-from-url window.
# It only has to outlast a Vultr fetch, but no reason to be predictable.
resource "random_id" "serve_path" {
  byte_length = 16
}

# Builds the raw with podman, serves it over HTTP, calls create-from-url and
# polls the import. A local, not inline in user_data, so cloud-init.yaml.tftpl
# can gzip+base64 it like the elemental config files.
#
# _documented: locals.tf strips the comments out of this and publishes the
# result as local.factory_script, which is what cloud-init.yaml.tftpl gets.
# Nothing should read this value directly.
locals {
  factory_script_documented = templatefile("${path.module}/templates/image-factory.sh.tftpl", {
    elemental_image      = var.elemental_image
    config_dir           = local.config_dir
    snapshot_description = local.snapshot_description
    serve_path           = random_id.serve_path.hex
    vultr_api_key        = var.vultr_api_key
    firewall_group_id    = vultr_firewall_group.jumphost.id
    log_file             = "/var/log/elemental-factory.log"
    # local, not var: null means "derive it from aif_version" (locals.tf).
    aif_release_manifest_url = local.aif_release_manifest_url

    # "" = no override, which is what the script branches on. try() because
    # indexing into a null object is an error, not a null.
    cluster_name       = var.cluster_name
    core_os_image_base = try(var.core_platform_override.os_image_base, "")
    core_os_image_iso  = try(var.core_platform_override.os_image_iso, "")
    core_k8s_version   = try(var.core_platform_override.kubernetes_version, "")
    core_k8s_image     = try(var.core_platform_override.kubernetes_image, "")

    # "{}" when unset OR when no enabled component pulls the named extension
    # in, which is what the script branches on. The filtering is in locals.tf.
    sysext_image_overrides_json = jsonencode(local.effective_sysext_overrides)
  })

  # A local so the size precondition below can read it -- a precondition
  # can't reliably read back the resource's own config attribute.
  jumphost_user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    files               = local.elemental_files
    factory_script      = local.factory_script
    config_dir          = local.config_dir
    ssh_authorized_keys = var.ssh_authorized_keys
    jumphost_username   = var.jumphost_username
  })
}

# openSUSE Leap 16, the jumphost's own OS -- not the elemental snapshot it
# builds. Needs a public IPv4: admin SSH in, and Vultr's create-from-url
# fetcher reads the raw off its public side.
#
# user_data embeds the LB's ipv4 (cluster.yaml's api_vip), which orders the
# jumphost after the LB without a depends_on -- safe only because the LB no
# longer references the control-plane instances (network.tf).
resource "vultr_instance" "jumphost" {
  region = var.region
  plan   = var.jumphost_plan
  os_id  = var.jumphost_os_id

  label    = "${var.cluster_name}-jumphost"
  hostname = "${var.cluster_name}-jumphost"

  vpc_ids           = [vultr_vpc.this.id]
  firewall_group_id = vultr_firewall_group.jumphost.id

  ssh_key_ids = var.ssh_key_ids
  tags        = var.tags
  enable_ipv6 = var.enable_ipv6

  user_data = local.jumphost_user_data

  lifecycle {
    precondition {
      # Vultr documents no ceiling. 32 KiB is a sanity check against a
      # template bug that duplicates content, not a known limit -- a real
      # rejection would surface at apply time anyway.
      #
      # The templates carry heavy comments deliberately, so what keeps the
      # payload under this is the comment strip at the bottom of locals.tf,
      # which drops whole-line comments at render time from both
      # local.elemental_files and local.factory_script. Source stays
      # documented, the wire stays small. If this trips, check that first --
      # the ceiling holds comfortably with ~60 KB of source behind it.
      #
      # nonsensitive() on the length only: user_data is built from sensitive
      # inputs, so its byte count inherits that -- and the count has to be
      # visible for the error to be actionable.
      condition     = length(local.jumphost_user_data) <= 32768
      error_message = "Rendered jumphost user_data is ${nonsensitive(length(local.jumphost_user_data))} bytes, over the 32 KiB sanity ceiling. Check the comment strip in locals.tf still covers both local.elemental_files and local.factory_script, then look for a template rendering something twice, unusually large ssh_authorized_keys (RSA keys run 700+ bytes each; ed25519 keys are ~80), or oversized credential values."
    }
  }
}
