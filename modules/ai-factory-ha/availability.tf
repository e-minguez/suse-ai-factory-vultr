# Plan-in-stock checks at plan time, so a bad plan fails before anything is
# created. Best-effort: stock can drain between plan and apply.
#
# SEND THE API KEY here, despite `security: []` in Vultr's own spec. An
# unauthenticated call has been seen to return HTTP 200 with an EMPTY
# available_plans rather than a 401, so omitting the header does not break the
# check -- it silently concludes every cloud plan is out of stock everywhere.
# (The key already reaches state via the jumphost's user_data; request_headers
# here is not a new exposure.)
#
# The endpoint scopes its answer to one plan family, so all five cloud
# families are queried and unioned -- querying only vc2 reports a real,
# available vx1 plan as unavailable. GPU families (vbm, vdm, vcg) are checked
# separately below, per pool, and are deliberately NOT unioned into this list:
# a GPU plan is only valid for the resource family it belongs to.
#
# Not checkable: whether control_plane_plan supports vpc_only. The response's
# available_vpc_only_plans is empty in every region tried.
locals {
  cloud_plan_types = ["vc2", "vhf", "vhp", "voc", "vx1"]
}

data "http" "cloud_plan_availability" {
  for_each = var.verify_plan_availability ? toset(local.cloud_plan_types) : toset([])

  url = "https://api.vultr.com/v2/regions/${var.region}/availability?type=${each.key}"
  request_headers = {
    Accept        = "application/json"
    Authorization = "Bearer ${var.vultr_api_key}"
  }

  retry {
    attempts = 2
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Vultr availability API returned HTTP ${self.status_code} for region \"${var.region}\" (type=${each.key}). A 400 here usually means the region ID is invalid. Response: ${self.response_body}"
    }

    # An empty family in a live region means a missing key, not empty stock.
    postcondition {
      condition     = self.status_code != 200 || length(try(jsondecode(self.response_body).available_plans, [])) > 0
      error_message = "Vultr reported zero available ${each.key} plans in region \"${var.region}\". This endpoint returns an empty list rather than a 401 when the API key is missing or invalid, so check vultr_api_key before believing the region is out of stock."
    }
  }
}

locals {
  cloud_available_plans = var.verify_plan_availability ? distinct(flatten([
    for t in local.cloud_plan_types :
    try(jsondecode(data.http.cloud_plan_availability[t].response_body).available_plans, [])
  ])) : []
}

# Preconditions must attach to a resource's lifecycle, and this check is not
# an attribute of any real one.
resource "terraform_data" "cloud_plan_availability_check" {
  count = var.verify_plan_availability ? 1 : 0

  lifecycle {
    precondition {
      condition     = contains(local.cloud_available_plans, var.control_plane_plan)
      error_message = "Control-plane plan \"${var.control_plane_plan}\" is not currently available (checked ${join(", ", local.cloud_plan_types)}) in region \"${var.region}\". Available: ${join(", ", local.cloud_available_plans)}"
    }

    precondition {
      condition     = contains(local.cloud_available_plans, var.jumphost_plan)
      error_message = "Jumphost plan \"${var.jumphost_plan}\" is not currently available (checked ${join(", ", local.cloud_plan_types)}) in region \"${var.region}\". Available: ${join(", ", local.cloud_available_plans)}"
    }
  }
}

# The type a cloud pool's plan is checked under, when the pool did not say.
#
# For every ordinary cloud family the plan id's prefix IS the type -- voc-* is
# type voc, vx1-* is vx1 -- so inferring it spares the caller from retyping the
# first token of the plan id. The one prefix that does not determine a type is
# vcg-*: the whole-node accelerator SKUs (vcg-a100-*, vcg-b200-*,
# vcg-h100-*, vcg-mi3*, vcg-a40-96c-*) are type "vdm", while only
# the fractional vGPU ones (vcg-a16-*, vcg-a40-<24c, vcg-l40s-*) are type
# "vcg". It resolves to the majority case, "vdm"; a fractional plan has to set
# plan_type itself. That is also the only remaining reason the field exists.
#
# var.gpu_cloud_pools duplicates this expression in a validation block, which
# can reference nothing but its own variable. Keep the two in step.
locals {
  gpu_cloud_plan_types = {
    for k, p in var.gpu_cloud_pools :
    k => coalesce(p.plan_type, startswith(p.plan, "vcg-") ? "vdm" : split("-", p.plan)[0])
  }
}

# GPU pools, both families, flattened to one pool -> {plan, type} map so the
# availability check is written once. The type is the query parameter the
# endpoint scopes its answer to: "vbm" for bare metal, and for cloud whatever
# the pool declared or the rule above inferred.
locals {
  gpu_pool_plans = merge(
    {
      for k, p in var.gpu_bare_metal_pools : k => {
        plan   = p.plan
        type   = "vbm"
        family = "bare metal"
      }
    },
    {
      for k, p in var.gpu_cloud_pools : k => {
        plan   = p.plan
        type   = local.gpu_cloud_plan_types[k]
        family = "cloud"
      }
    },
  )

  # Only the types actually in use are queried; with no GPU pools at all this
  # is empty and the whole check disappears.
  gpu_plan_types = toset([for p in values(local.gpu_pool_plans) : p.type])
}

data "http" "gpu_plan_availability" {
  for_each = var.verify_plan_availability ? local.gpu_plan_types : toset([])

  url = "https://api.vultr.com/v2/regions/${var.region}/availability?type=${each.key}"
  # vbm still answers unauthenticated, but send the key anyway in case Vultr
  # extends the requirement -- the failure mode is silent (see above). vdm and
  # vcg do require it.
  request_headers = {
    Accept        = "application/json"
    Authorization = "Bearer ${var.vultr_api_key}"
  }

  retry {
    attempts = 2
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Vultr availability API returned HTTP ${self.status_code} for region \"${var.region}\" (type=${each.key}). A 400 here usually means the region ID is invalid. Response: ${self.response_body}"
    }

    # NOTE: no "an empty list means a missing key" postcondition here, unlike
    # the cloud check above. For GPU families an empty list is routinely
    # genuine -- whole regions return zero vdm plans with a valid key -- so
    # asserting non-empty would fail every correct
    # config in a region with no GPU stock. The missing-key hint is folded into
    # the per-pool message below instead.
  }
}

locals {
  # tolist() is load-bearing: jsondecode returns a TUPLE, so without it each
  # entry has its own type (tuple of exactly N strings) and the map as a whole
  # is an object, not a map(list(string)). Anything that needs the element type
  # to be uniform -- lookup()'s default, coalescelist() -- then fails to
  # type-check. It only surfaces once the response is known, which is why
  # plans run with verify_plan_availability = false never caught it.
  gpu_available_plans = var.verify_plan_availability ? {
    for t in local.gpu_plan_types :
    t => tolist(try(jsondecode(data.http.gpu_plan_availability[t].response_body).available_plans, []))
  } : {}
}

# One check instance per pool, so the error names the pool that is wrong rather
# than the first one that fails. Preconditions must attach to a resource's
# lifecycle, and this check is not an attribute of any real one.
resource "terraform_data" "gpu_plan_availability_check" {
  for_each = var.verify_plan_availability ? local.gpu_pool_plans : {}

  input = "${each.key}:${each.value.plan}"

  lifecycle {
    precondition {
      # Indexed, not lookup()ed: gpu_plan_types is derived from the same map
      # this resource iterates, so the key is always present and a default
      # would be dead code.
      condition     = contains(local.gpu_available_plans[each.value.type], each.value.plan)
      error_message = "GPU pool \"${each.key}\" wants ${each.value.family} plan \"${each.value.plan}\", which is not currently available in region \"${var.region}\". Available type=${each.value.type} plans there: ${join(", ", coalescelist(local.gpu_available_plans[each.value.type], ["<none>"]))}. An empty list can be real -- most regions carry no GPU stock -- but it is also what this endpoint returns instead of a 401 when vultr_api_key is missing or invalid, so check the key before believing it. Note also that the plan's own type field is what matters, not its id prefix: the vcg-a100/b200/h100/mi3 SKUs are type \"vdm\"."
    }
  }
}
