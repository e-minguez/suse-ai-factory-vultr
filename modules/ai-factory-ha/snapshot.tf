# Handoff between "the jumphost built an image" and "Terraform has a snapshot
# ID": both sides agree on one description string, derived here and passed to
# the build script (jumphost.tf's factory_script), so neither can drift.
#
# A timestamp, not a random id, so `vultr-cli snapshot list` sorts as a build
# history -- orphans accumulate, since destroy never removes them.
#
# time_static, not timestamp(): timestamp() re-evaluates every plan, drifting
# the description and with it the jumphost's ForceNew user_data.
resource "time_static" "build" {
  triggers = {
    # Hash the RENDERED config, not the *.tftpl sources: a change to a
    # variable alone would leave a source hash untouched, so the wait would
    # be skipped and nodes provisioned from the previous build's snapshot.
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
  # e.g. "suse-ai-factory-20260914-143512", UTC -- time_static records a "Z"
  # instant and formatdate does no conversion, so it compares directly against
  # Vultr's own date_created.
  snapshot_description = "${var.cluster_name}-${formatdate("YYYYMMDD-hhmmss", time_static.build.rfc3339)}"
}

# Blocks the apply until the snapshot is complete, or image_build_timeout
# runs out. count = 0 when snapshot_id overrides the build or deploy_nodes is
# false -- nothing is waiting on the image.
resource "terraform_data" "snapshot_ready" {
  count = var.snapshot_id == null && var.deploy_nodes ? 1 : 0

  depends_on = [vultr_instance.jumphost]

  # triggers_replace, not just `input`: local-exec fires only on create, and
  # a changed `input` updates in place. Without this a rebuild would skip the
  # wait and read a snapshot that does not exist yet.
  triggers_replace = [local.snapshot_description]
  input            = local.snapshot_description

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-snapshot.sh"
    environment = {
      SNAPSHOT_DESCRIPTION = local.snapshot_description
      TIMEOUT_SECONDS      = var.image_build_timeout
      POLL_SECONDS         = 30
    }
  }
}

# depends_on is load-bearing: it defers the read to apply time. Without it
# Terraform reads during plan, before the image exists, and fails.
data "vultr_snapshot" "ai_factory" {
  count = var.snapshot_id == null && var.deploy_nodes ? 1 : 0

  depends_on = [terraform_data.snapshot_ready]

  filter {
    name   = "description"
    values = [local.snapshot_description]
  }

  lifecycle {
    postcondition {
      # The provider already errors on 0 or >1 matches; this only catches a
      # match in a non-terminal state.
      condition     = self.status == "complete"
      error_message = "Snapshot ${local.snapshot_description} is \"${self.status}\", not \"complete\"."
    }
  }
}

locals {
  # Not a coalesce(): with deploy_nodes = false both branches are null, and
  # coalesce() errors on all-null rather than returning null. Null is the
  # correct answer there -- nothing has asked for a snapshot.
  effective_snapshot_id = var.snapshot_id != null ? var.snapshot_id : try(data.vultr_snapshot.ai_factory[0].id, null)
}
