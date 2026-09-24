# The jumphost builds and serves the raw image; Terraform imports it with
# vultr_snapshot_from_url, so the snapshot lives in state and `terraform
# destroy` removes it. The jumphost never holds a Vultr API key.
#
# Order within one apply:
#   jumphost boots, builds, serves   (templates/image-factory.sh.tftpl)
#   terraform_data.image_served      polls the URL from the operator's machine
#   vultr_snapshot_from_url          create-from-url, then waits for "complete"
#   nodes                            provisioned from it
#
# time_static is the build identity: every trigger below rotates
# random_id.serve_path (jumphost.tf), which replaces the jumphost and the
# snapshot together. A timestamp, not a random id, so the served file name
# reads as a build history in the jumphost's log.
#
# time_static, not timestamp(): timestamp() re-evaluates every plan, drifting
# the file name and with it the jumphost's ForceNew user_data.
resource "time_static" "build" {
  triggers = {
    # Hash the RENDERED config, not the *.tftpl sources: a change to a
    # variable alone would leave a source hash untouched, so no rebuild would
    # happen and nodes would come up from the previous build's snapshot.
    cluster  = var.cluster_name
    endpoint = vultr_load_balancer.api.ipv4
    image    = var.elemental_image # not part of elemental_files; only reaches factory_script
    config   = sha256(jsonencode(local.elemental_files))

    # Also not in elemental_files, for the same reason as `image` above: both
    # reach the build only through factory_script, which is deliberately left
    # out of the config hash so that editing the build script itself does not
    # renumber the build.
    #
    # The manifest is the content behind local.aif_release_manifest_url
    # (either aif_release_manifest_url or the tag derived from aif_version),
    # fetched at plan time purely for this hash. Without it, a manifest URL on
    # a moving branch ref could change upstream -- new chart versions, a new
    # extension image -- and no plan would notice, since the URL string is
    # what would otherwise be compared.
    manifest = sha256(data.http.aif_release_manifest.response_body)

    # The FILTERED map (locals.tf), not the raw variable: an override for an
    # extension no enabled component pulls in changes nothing about the image,
    # so it must not renumber the build either.
    sysexts = sha256(jsonencode(local.effective_sysext_overrides))
  }
}

locals {
  # e.g. "suse-ai-factory-20260914-143512.raw", UTC -- time_static records a
  # "Z" instant and formatdate does no conversion.
  image_file = "${var.cluster_name}-${formatdate("YYYYMMDD-hhmmss", time_static.build.rfc3339)}.raw"
  image_url  = "http://${vultr_instance.jumphost.main_ip}/${random_id.serve_path.hex}/${local.image_file}"
}

# Port 80 for Vultr's create-from-url fetcher. A resource, not an API call
# from the jumphost, so no key has to live there -- which means it cannot be
# created and removed within one apply. deploy.sh's pass 2 sets
# image_import_port_open = false once the snapshot is complete, and resets it
# to the default (true) before every pass 1 so a rebuild finds it open.
#
# Created alongside the jumphost, not after the build: the cloud firewall is a
# distributed filter, and a rule created seconds before create-from-url is not
# necessarily in force at the edge the fetcher arrives through. The build buys
# it propagation time for free.
resource "vultr_firewall_rule" "image_import" {
  count = var.image_import_port_open ? 1 : 0

  firewall_group_id = vultr_firewall_group.jumphost.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "80"
  notes             = "elemental image import"
}

# Blocks until the jumphost answers for the raw, or image_build_timeout runs
# out. Polled from OUTSIDE, over the same public path Vultr's fetcher takes,
# so a firewall rule that has not propagated yet shows up here as "not yet"
# instead of as a create-from-url that Vultr silently drops.
#
# triggers_replace keys off the build, not the URL: a jumphost replaced for an
# unrelated reason (a new jumphost_username, say) gets a new IP without
# anything needing a new image.
resource "terraform_data" "image_served" {
  count = var.snapshot_id == null ? 1 : 0

  depends_on = [vultr_firewall_rule.image_import]

  triggers_replace = [random_id.serve_path.hex]
  input            = local.image_url

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-image.sh"
    environment = {
      IMAGE_URL       = local.image_url
      TIMEOUT_SECONDS = var.image_build_timeout
      POLL_SECONDS    = 30
    }
  }
}

# One attempt. Vultr DELETES the record when its fetch fails, and the
# provider's read then errors on the 404 instead of dropping it from state --
# so a failed import needs a `terraform state rm` of this resource before the
# next apply (see the README's Known gaps).
#
# ignore_changes + replace_triggered_by: url embeds the jumphost's IP and is
# ForceNew, so without this any jumphost replacement would replace the
# snapshot and, through snapshot_id, every node. Only a new build should.
resource "vultr_snapshot_from_url" "ai_factory" {
  count = var.snapshot_id == null ? 1 : 0

  depends_on = [terraform_data.image_served]

  url      = local.image_url
  use_uefi = true

  lifecycle {
    ignore_changes       = [url]
    replace_triggered_by = [random_id.serve_path]
  }

  # The provider returns as soon as Vultr accepts the request, with status
  # still "pending"; nodes built from that would fail. This holds creation
  # until "complete", and a failure taints the resource.
  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-snapshot.sh"
    environment = {
      SNAPSHOT_ID     = self.id
      TIMEOUT_SECONDS = var.image_serve_seconds
      POLL_SECONDS    = 30
    }
  }
}

locals {
  # one(), not [0]: with snapshot_id set the build resource has count = 0 and
  # indexing it would be an error even in the untaken branch.
  effective_snapshot_id = var.snapshot_id != null ? var.snapshot_id : one(vultr_snapshot_from_url.ai_factory[*].id)
}
