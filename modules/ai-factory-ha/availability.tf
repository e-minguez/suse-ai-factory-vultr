# Plan-in-stock checks at plan time, so a bad plan fails before anything is
# created. Best-effort: stock can drain between plan and apply.
#
# SEND THE API KEY here, despite `security: []` in Vultr's own spec. An
# unauthenticated call has been seen to return HTTP 200 with an EMPTY
# available_plans rather than a 401, so omitting the header does not break the
# check -- it silently concludes every plan is out of stock everywhere.
# (The key already reaches state via the jumphost's user_data; request_headers
# here is not a new exposure.)
#
# One untyped query covers every family. The endpoint takes an optional
# ?type=, but without it the answer is the union of all of them -- vc2, vx1,
# vbm, vcg and vdm alike (checked 2026-09-30 across several regions, vdm
# against the only two in stock: blr's vcg-a40-24c and sea's vcg-b200). The
# typed form is a trap: the type is the plan's own `type` field, which the
# plan id does not determine -- vcg-a16-12c-128g-32vram is type vcg but
# vcg-a16-6c-64g-16vram is vdm -- so any per-type query needs a guess, and a
# wrong guess reports an in-stock plan as unavailable.
#
# Not checkable: whether control_plane_plan supports vpc_only. The response's
# available_vpc_only_plans is empty in every region tried.
data "http" "plan_availability" {
  count = var.verify_plan_availability ? 1 : 0

  url = "https://api.vultr.com/v2/regions/${var.region}/availability"
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
      error_message = "Vultr availability API returned HTTP ${self.status_code} for region \"${var.region}\". A 400 here usually means the region ID is invalid. Response: ${self.response_body}"
    }
  }
}

locals {
  # tolist() is load-bearing: jsondecode returns a TUPLE, whose element types
  # are per-position, and coalescelist() below needs a uniform list(string).
  available_plans = var.verify_plan_availability ? tolist(try(jsondecode(data.http.plan_availability[0].response_body).available_plans, [])) : []
}

# Preconditions must attach to a resource's lifecycle, and this check is not
# an attribute of any real one.
resource "terraform_data" "cloud_plan_availability_check" {
  count = var.verify_plan_availability ? 1 : 0

  lifecycle {
    # Nothing at all available in a live region means a missing key, not empty
    # stock: every region carries some ordinary cloud plan. Checked first so
    # the plan-specific messages below are not mistaken for real stock answers.
    precondition {
      condition     = length(local.available_plans) > 0
      error_message = "Vultr reported zero available plans in region \"${var.region}\". This endpoint returns an empty list rather than a 401 when the API key is missing or invalid, so check vultr_api_key before believing the region is out of stock."
    }

    precondition {
      condition     = contains(local.available_plans, var.control_plane_plan)
      error_message = "Control-plane plan \"${var.control_plane_plan}\" is not currently available in region \"${var.region}\". Available: ${join(", ", local.available_plans)}"
    }

    precondition {
      condition     = contains(local.available_plans, var.jumphost_plan)
      error_message = "Jumphost plan \"${var.jumphost_plan}\" is not currently available in region \"${var.region}\". Available: ${join(", ", local.available_plans)}"
    }
  }
}

# GPU pools, both families, flattened to one pool -> {plan, family} map so the
# availability check is written once. count = 0 pools are left out: they
# create nothing, and parking a pool at 0 while its plan is out of stock is
# exactly what count = 0 is for. Scaling one up re-enables its check.
locals {
  gpu_pool_plans = merge(
    {
      for k, p in var.gpu_bare_metal_pools : k => {
        plan   = p.plan
        family = "bare metal"
      } if p.count > 0
    },
    {
      for k, p in var.gpu_cloud_pools : k => {
        plan   = p.plan
        family = "cloud"
      } if p.count > 0
    },
  )

  # What the error message lists: the bare metal and vcg- slice of the stock,
  # since the full list is ~100 ordinary plans. By id prefix, which is fine for
  # display -- it is only the type field that the prefix does not determine.
  gpu_candidate_plans = [for p in local.available_plans : p if startswith(p, "vbm-") || startswith(p, "vcg-")]
}

# GPU nodes that already exist, so the check below only gates pools that would
# create something. Without this, every plan re-checks stock for nodes that are
# already running -- and GPU stock is often exactly one unit, which the
# cluster's own node is holding, so a healthy cluster failed its next plan.
#
# Asked of the Vultr API, not read off vultr_instance.gpu_cloud /
# vultr_bare_metal_server.gpu: both depends_on the check, so that would be a
# cycle. Matched on label (= hostname, which carries cluster_name), plan and
# region: a plan change replaces the node, so it needs stock again. One page of
# 500 only; a node past it merely looks missing, which runs the check -- the
# safe direction. Both endpoints 401 without a valid key, so a bad key fails
# here rather than silently skipping the check.
data "http" "gpu_existing" {
  for_each = var.verify_plan_availability ? toset([
    for p in values(local.gpu_pool_plans) : p.family == "bare metal" ? "bare-metals" : "instances"
  ]) : toset([])

  url = "https://api.vultr.com/v2/${each.key}?per_page=500"
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
      error_message = "Vultr returned HTTP ${self.status_code} listing ${each.key}. A 401 means vultr_api_key is missing or invalid."
    }
  }
}

locals {
  # "label|plan" of every server in the region; the response's list key is the
  # endpoint name with an underscore (bare-metals -> bare_metals).
  gpu_existing = toset(flatten([
    for k, d in data.http.gpu_existing : [
      for s in jsondecode(d.response_body)[replace(k, "-", "_")] :
      "${s.label}|${s.plan}" if s.region == var.region
    ]
  ]))

  # Per pool, the hostnames the next apply would create.
  gpu_pool_missing = {
    for k, p in local.gpu_pool_plans : k => concat(
      [for n in local.gpu_bare_metal_nodes : n.hostname if p.family == "bare metal" && n.pool == k && !contains(local.gpu_existing, "${n.hostname}|${n.plan}")],
      [for n in local.gpu_cloud_nodes : n.hostname if p.family == "cloud" && n.pool == k && !contains(local.gpu_existing, "${n.hostname}|${n.plan}")],
    )
  }
}

# One check instance per pool, so the error names the pool that is wrong rather
# than the first one that fails. Preconditions must attach to a resource's
# lifecycle, and this check is not an attribute of any real one.
resource "terraform_data" "gpu_plan_availability_check" {
  for_each = var.verify_plan_availability ? local.gpu_pool_plans : {}

  input = "${each.key}:${each.value.plan}"

  lifecycle {
    precondition {
      condition     = length(local.gpu_pool_missing[each.key]) == 0 || contains(local.available_plans, each.value.plan)
      error_message = "GPU pool \"${each.key}\" needs to create ${join(", ", local.gpu_pool_missing[each.key])} on ${each.value.family} plan \"${each.value.plan}\", which is not currently available in region \"${var.region}\". Bare metal and vcg- plans available there: ${join(", ", coalescelist(local.gpu_candidate_plans, ["<none>"]))}. Most regions carry little or no GPU stock."
    }
  }
}
