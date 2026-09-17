# The original (non-VPC2) VPC: VPC2 is deprecated, and only this one is wired
# to vultr_bare_metal_server's vpc_id and vultr_instance's vpc_only. The subnet
# is explicit rather than auto-selected so the range is reviewable in a diff.
resource "vultr_vpc" "this" {
  region         = var.region
  description    = "${var.cluster_name}-vpc"
  v4_subnet      = var.vpc_subnet
  v4_subnet_mask = var.vpc_subnet_mask
}

# Egress for the vpc_only control-plane instances, which have no public NIC
# of their own. Also the address the LB sees as the source of every CP -> LB
# supervisor (9345) join, since that traffic hairpins CP -> NAT -> internet ->
# LB rather than staying inside the VPC (apiVIP is the LB's public address).
resource "vultr_nat_gateway" "this" {
  vpc_id = vultr_vpc.this.id
  label  = "${var.cluster_name}-nat"
  tag    = var.cluster_name
}

# Fronts the RKE2 API/supervisor. Created early so it has an address before the
# jumphost builds the image (apiVIP is baked into the RKE2 config). Backends are
# NOT wired here: an inline reference to vultr_instance.control_plane would close
# a dependency cycle -- see lb_backend_instance_ids' description.
resource "vultr_load_balancer" "api" {
  region              = var.region
  label               = "${var.cluster_name}-api-lb"
  balancing_algorithm = "leastconn"
  vpc                 = vultr_vpc.this.id
  nodes               = var.lb_nodes

  # sort() is not cosmetic. attached_instances is an ORDERED list to the
  # provider, and Vultr returns it sorted, while deploy.sh writes it in
  # control-plane index order -- so an unsorted value is a diff that never
  # converges. That matters far beyond tidiness: a pending change on this
  # resource is enough to defer data.vultr_snapshot.ai_factory's read to apply
  # time (it depends on the jumphost, whose user_data embeds this LB's ipv4),
  # which makes local.effective_snapshot_id unknown at plan, which is ForceNew
  # on every node. A permanent no-op diff here therefore means every bare
  # `terraform plan` proposes destroying the cluster. Sorting both sides makes
  # the diff disappear and disarms that.
  attached_instances = sort(var.lb_backend_instance_ids)

  forwarding_rules {
    frontend_protocol = "tcp"
    frontend_port     = 6443
    backend_protocol  = "tcp"
    backend_port      = 6443
  }

  forwarding_rules {
    frontend_protocol = "tcp"
    frontend_port     = 9345
    backend_protocol  = "tcp"
    backend_port      = 9345
  }

  # An HTTP check fails against the API's TLS handshake, so this is a bare
  # TCP check.
  #
  # path is meaningless for a TCP check, and Vultr returns it EMPTY -- but the
  # provider schema declares it Optional with Default "/"
  # (resource_vultr_load_balancer.go), and the read sets path straight from the
  # API response. So the desired value is "/" whether it is written here or
  # left out, refresh puts "" in state, and every plan proposes
  # `~ health_check { + path = "/" }` for ever.
  #
  # Ignored rather than fought: there is no value that converges, an update
  # would PUT the same no-op on every apply, and a standing diff on this
  # resource is exactly what the attached_instances note above warns about.
  # Scoped to the one attribute, so a real change to protocol/port still plans.
  health_check {
    protocol = "tcp"
    port     = 6443
    path     = "/"
  }

  lifecycle {
    ignore_changes = [health_check[0].path]
  }

  # 6443 (the API) is the one thing meant to be reachable from anywhere. 9345
  # (the supervisor, used only on node join) is restricted to the NAT gateway's
  # public IPs -- the source a vpc_only node's hairpinned join arrives from --
  # plus the /32s of the GPU nodes that have a public NIC, filled in on pass 2
  # (lb_supervisor_extra_cidrs). A vpc_only cloud GPU node needs no entry: it
  # hairpins through the NAT gateway, so it is already covered above.
  firewall_rules {
    port    = 6443
    ip_type = "v4"
    source  = "0.0.0.0/0"
  }

  dynamic "firewall_rules" {
    # public_ips are bare addresses, but this field takes a CIDR -- without
    # the appended /32 the rule silently never matches.
    for_each = concat(
      [for ip in vultr_nat_gateway.this.public_ips : "${ip}/32"],
      var.lb_supervisor_extra_cidrs,
    )
    content {
      port    = 9345
      ip_type = "v4"
      source  = firewall_rules.value
    }
  }
}

# Fronts the ingress controller on 80/443. A SECOND load balancer rather than
# two more forwarding rules on the API one, for two reasons:
#
#  1. proxy_protocol is a per-load-balancer flag, not per-rule. RKE2's 6443 and
#     9345 listeners do not speak PROXY, so turning it on for the API LB would
#     break every kubectl call and every node join. Without it the ingress
#     backends see the LB's own VPC address as the client, and every access
#     log, rate limiter and IP allowlist in the cluster is blind.
#  2. A Vultr LB has exactly one health check. Sharing meant Traefik's health
#     riding on a TCP probe of 6443; here it gets its own (below).
#
# Backends are the same control-plane instances as the API LB -- Traefik is
# pinned to them (kubernetes/manifests/traefik.yaml) -- so the same pass-2
# variable fills both. Created unconditionally alongside the API LB, before the
# jumphost, because its address is baked into the image as Rancher's hostname.
resource "vultr_load_balancer" "ingress" {
  count = var.ingress_controller == "none" ? 0 : 1

  region              = var.region
  label               = "${var.cluster_name}-ingress-lb"
  balancing_algorithm = "leastconn"
  vpc                 = vultr_vpc.this.id
  nodes               = var.lb_nodes

  # sort() for the same reason as the API LB above.
  attached_instances = sort(var.lb_backend_instance_ids)

  # Real client addresses. Traefik's web/websecure entrypoints are configured
  # to trust PROXY headers from the VPC CIDR to match -- the two settings are
  # a pair, and enabling either one alone breaks the listener.
  proxy_protocol = true

  # TCP, not HTTP: Traefik terminates TLS itself and the LB has no certificate.
  dynamic "forwarding_rules" {
    for_each = [80, 443]
    content {
      frontend_protocol = "tcp"
      frontend_port     = forwarding_rules.value
      backend_protocol  = "tcp"
      backend_port      = forwarding_rules.value
    }
  }

  # Traefik's own /ping, on the entrypoint the chart reserves for it. Must NOT
  # be 80 or 443: those expect a PROXY header from anything inside the VPC, and
  # Vultr's health checker does not send one, so every backend would fail. 8080
  # is bound by the same hostPort mechanism as 80/443 (traefik.yaml) and, since
  # the control-plane nodes are vpc_only, exists only on the VPC.
  health_check {
    protocol = "http"
    port     = 8080
    path     = "/ping"
  }

  dynamic "firewall_rules" {
    for_each = { for pair in setproduct([80, 443], var.ingress_cidrs) : "${pair[0]}-${pair[1]}" => pair }
    content {
      port    = firewall_rules.value[0]
      ip_type = "v4"
      source  = firewall_rules.value[1]
    }
  }
}
