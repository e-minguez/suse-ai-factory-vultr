# Shared RKE2 join token, used by kubernetes/config/{server,agent}.yaml.
# special = false: the value lands verbatim in a YAML scalar in the elemental
# config dir, where a special character would need escaping nobody would add.
resource "random_password" "token" {
  length  = 32
  special = false
}

# Used only when var.rancher_bootstrap_password is null. Always created --
# cheaper than a count/for_each just to keep it referenceable.
resource "random_password" "rancher_bootstrap" {
  length  = 24
  special = false
}

locals {
  # null when ingress_controller = "none". Both names below are baked into the
  # image, so both load balancers must exist before the jumphost does -- they
  # do, nothing in either references a node.
  ingress_lb_ipv4 = one(vultr_load_balancer.ingress[*].ipv4)

  # Rancher's ingress answers on the INGRESS load balancer, not the API one --
  # that is where 80/443 are forwarded. Falls back to the API address when
  # there is no ingress controller, where the name resolves but nothing serves
  # it; there is no better answer, and Rancher's chart requires a hostname.
  rancher_hostname           = coalesce(var.rancher_hostname, "rancher-${coalesce(local.ingress_lb_ipv4, vultr_load_balancer.api.ipv4)}.sslip.io")
  rancher_bootstrap_password = coalesce(var.rancher_bootstrap_password, random_password.rancher_bootstrap.result)

  api_host = coalesce(var.api_host, "rke2-${vultr_load_balancer.api.ipv4}.sslip.io")

  # A TAG, not a branch: SUSE/aif tags per component, and aif-operator's tag is
  # the one that moves with the AI Factory version as a whole ("2.2.0" ->
  # aif-operator-2.2.0). A tag is immutable, so unlike release-2.2 the manifest
  # behind it cannot change under a built cluster. Pre-releases are ordinary
  # tags too -- "2.3.0-dev.2" -> aif-operator-2.3.0-dev.2.
  aif_tag = "aif-operator-${var.aif_version}"

  # An explicit URL wins, so a commit-pinned or self-hosted manifest is still
  # one variable away. Everything downstream -- the data source below, the
  # jumphost's curl, the build-id hash -- reads THIS, not the variable.
  aif_release_manifest_url = coalesce(
    var.aif_release_manifest_url,
    "https://raw.githubusercontent.com/SUSE/aif/refs/tags/${local.aif_tag}/uc-release-manifest/release_manifest.yaml",
  )
}

# Fetched at plan time only to hash the manifest's content into the build id
# (snapshot.tf) -- the jumphost curls the same URL itself at build time. See
# the elemental_files comment below, and aif_release_manifest_url's
# description for why manifestURI is file://./release_manifest.yaml.
data "http" "aif_release_manifest" {
  url = local.aif_release_manifest_url

  lifecycle {
    postcondition {
      # A 404 here is nearly always aif_version naming a tag that does not
      # exist -- an unreleased version, or a patch SUSE never cut -- so the
      # message says which tag was derived and from what, rather than only
      # echoing a URL.
      condition     = self.status_code == 200
      error_message = "Fetching the AI Factory release manifest (${local.aif_release_manifest_url}) returned HTTP ${self.status_code}. ${var.aif_release_manifest_url != null ? "That URL came from aif_release_manifest_url." : "That URL was derived from aif_version = \"${var.aif_version}\" -- SUSE/aif has no ${local.aif_tag} tag, or that tag has no uc-release-manifest/release_manifest.yaml. Check `git ls-remote --tags https://github.com/SUSE/aif` for what exists; to build from an untagged ref, set aif_release_manifest_url instead."}"
    }
  }
}

# local-path-provisioner's imagePullSecrets expect a Secret named
# "application-collection"; kubernetes/manifests/local-path-provisioner.yaml
# below creates it. A dockerconfigjson Secret is just base64(json(...)), so
# Terraform computes it rather than a template hand-rolling it.
locals {
  dockerconfigjson_b64 = base64encode(jsonencode({
    auths = {
      (var.appco_registry) = {
        username = var.appco_username
        password = var.appco_password
        auth     = base64encode("${var.appco_username}:${var.appco_password}")
      }
    }
  }))
}

# Directory the cloud-init payload is unpacked into on the jumphost, and the
# -v mount point handed to `podman run ... customize --local`.
locals {
  config_dir = "/opt/elemental-config"
}

# write-node-ip.sh, rendered once here (no template vars of its own -- see its
# header) so it can be indent()ed straight into butane.yaml.tftpl's
# write-node-ip.service storage.files entry below. Kept as a named local,
# rather than inlined into that templatefile() call, so the script's own file
# is what gets read and rendered, not shell hand-typed into this file.
locals {
  write_node_ip_script = templatefile("${path.module}/templates/elemental/network/write-node-ip.sh.tftpl", {})

  # iscsi-prep.sh, likewise indent()ed into butane.yaml.tftpl -- but only when
  # the suse-storage extension is enabled (see local.enable_iscsi_prep below).
  # file(), not templatefile(): it has no template variables, and reading it
  # verbatim means its shell "$" and "${...}" need no escaping.
  iscsi_prep_script = file("${path.module}/templates/elemental/storage/iscsi-prep.sh")
}

# One image serves every node. Hostname and RKE2 role (NODETYPE/IS_INIT_NODE)
# are plan-time known, so they ride per node in Ignition user_data
# (node_runtime_ignition below) instead of being baked in. configure-network.sh
# works out which NIC is which at first boot, and on a dual-NIC (public + VPC)
# node also discovers and applies its own VPC address from Vultr's instance
# metadata (see the comment above local.control_plane_nodes below).
#
# The list is independent of var.deploy_nodes: the same image must work for a
# deploy_nodes=false apply that provisions nodes later.
locals {
  vpc_cidr = "${var.vpc_subnet}/${var.vpc_subnet_mask}"

  # Flannel's --iface-regex matches an interface by IP OR name, so the VPC
  # address range is what pins canal's VXLAN to the VPC NIC on every node --
  # see kubernetes/manifests/canal.yaml.tftpl for why that matters. Only the
  # octets the mask holds constant can go in the regex, so this is as tight as
  # the subnet allows and no tighter: a /20 yields "^10\.20\." in the default
  # config, which technically matches a /16. Harmless, because no interface on
  # these nodes carries any other address in that range -- pods are on
  # cluster-cidr (10.42/16 by default) and the public NICs are routable space.
  vpc_iface_regex_octets = var.vpc_subnet_mask >= 24 ? 3 : (var.vpc_subnet_mask >= 16 ? 2 : 1)
  vpc_iface_regex        = "^${join("\\.", slice(split(".", var.vpc_subnet), 0, local.vpc_iface_regex_octets))}\\."

  # 50 bytes of VXLAN header. Calico sizes the pod veths and has no idea what
  # the underlay is, so it must be told.
  pod_veth_mtu = var.vpc_mtu - 50

  # VPC addresses are not chosen here. Terraform cannot feed Vultr's own
  # allocation back in -- internal_ip only exists after create, while
  # user_data is ForceNew and the image predates every node, so either
  # direction is a cycle. The guest, however, can read its own allocation: on
  # a dual-NIC node /v1/interfaces/1/ipv4/{address,netmask} serves the real
  # values. vpc_only nodes do serve an interface tree too, but report
  # ipv4/address as the literal string "dhcp" -- and those are exactly the
  # nodes that never used a Terraform-assigned address anyway (see below). So
  # a first-boot read of metadata replaces the address table entirely:
  # network/configure-network.sh.tftpl now discovers and applies a dual-NIC
  # node's VPC address itself, and network/write-node-ip.sh.tftpl (rendered
  # into butane.yaml.tftpl below) writes
  # /etc/rancher/rke2/config.yaml.d/99-node-ip.yaml from the same source. This
  # also ends the self-assignment: no address here is ever Terraform's guess
  # applied to a NIC Vultr doesn't itself know about.
  #
  # public_nic still decides both of those per node, same reasoning as always:
  # a control-plane node is a load balancer backend, and the LB dials
  # whatever address Vultr has on file, so a self-assigned one risks a load
  # balancer that can never reach any backend -- it stays on DHCP, which
  # already is Vultr's own allocation. A vpc_only cloud GPU pool falls on the
  # same side of that line for the stronger reason that its DHCP lease is
  # one-shot (see "WHY A vpc_only NIC IS LEFT ALONE" in
  # configure-network.sh.tftpl). Neither node type's metadata `interfaces/`
  # tree even 200s, so both scripts simply find nothing to act on and leave
  # DHCP's address alone.
  control_plane_nodes = [
    for i in range(var.control_plane_count) : {
      hostname   = format("%s-cp-%02d", var.cluster_name, i + 1)
      pool       = "cp"
      plan       = var.control_plane_plan
      family     = "control-plane"
      type       = "server"
      init       = i == 0 # cp-01 initializes the cluster; the rest join it.
      public_nic = false  # vpc_only: VPC address comes from DHCP, see above.
    }
  ]

  # Pools are flattened in sort(keys()) order purely for deterministic
  # iteration -- hostnames are already stable per pool (format() below uses
  # only the pool's own name and per-pool index, never a running/global one),
  # so unlike before this address work, adding a pool, renaming one, or
  # bumping a count never renumbers a pool it didn't touch. Nothing here feeds
  # the image any more either (see the note above), so none of those changes
  # rebuilds anything: they are a pure Terraform add/replace of just the
  # affected nodes.
  gpu_bare_metal_nodes = [
    for n in flatten([
      for pool in sort(keys(var.gpu_bare_metal_pools)) : [
        for i in range(var.gpu_bare_metal_pools[pool].count) : {
          hostname = format("%s-%s-%02d", var.cluster_name, pool, i + 1)
          pool     = pool
          plan     = var.gpu_bare_metal_pools[pool].plan
        }
      ]
      ]) : {
      hostname   = n.hostname
      pool       = n.pool
      plan       = n.plan
      family     = "bare-metal"
      type       = "agent"
      init       = false
      public_nic = true # bare metal always has a public NIC -- see gpu-nodes.tf.
    }
  ]

  # public_nic is the inverse of vpc_only, and it decides two things: whether
  # write-node-ip.sh's 99-node-ip.yaml pins RKE2 to the VPC address, and
  # whether configure-network.sh applies a discovered static VPC address. A
  # vpc_only cloud GPU node must behave exactly like a control-plane node on
  # both counts, and it does so automatically: both scripts branch on the
  # physical NIC count, which is one on any vpc_only node. Neither needs this
  # flag at runtime -- Vultr's DHCP already hands out the one address it has
  # on file.
  gpu_cloud_nodes = [
    for n in flatten([
      for pool in sort(keys(var.gpu_cloud_pools)) : [
        for i in range(var.gpu_cloud_pools[pool].count) : {
          hostname = format("%s-%s-%02d", var.cluster_name, pool, i + 1)
          pool     = pool
          plan     = var.gpu_cloud_pools[pool].plan
          vpc_only = var.gpu_cloud_pools[pool].vpc_only
        }
      ]
      ]) : {
      hostname   = n.hostname
      pool       = n.pool
      plan       = n.plan
      family     = "cloud"
      type       = "agent"
      init       = false
      vpc_only   = n.vpc_only
      public_nic = !n.vpc_only
    }
  ]

  # concat() needs one object type, so every list above carries the same
  # attributes; vpc_only is the exception and is read only off gpu_cloud_nodes.
  gpu_nodes = concat(
    [for n in local.gpu_bare_metal_nodes : n],
    [for n in local.gpu_cloud_nodes : {
      hostname   = n.hostname
      pool       = n.pool
      plan       = n.plan
      family     = n.family
      type       = n.type
      init       = n.init
      public_nic = n.public_nic
    }],
  )

  cluster_nodes = concat(local.control_plane_nodes, local.gpu_nodes)
}

# Per-node Ignition "user config", keyed by hostname, wired to each node's own
# user_data in control-plane.tf/gpu-nodes.tf. Hand-built rather than
# transpiled: there is no butane step in this pipeline and this config is three
# files. Matches real butane 0.29.0 output (decimal mode, contents.source as an
# RFC 2397 data: URL, ignition version "3.5.0").
#
# This is the PER-NODE half. The cluster-wide half -- root's password hash and
# SSH keys, sshd, /root/.profile -- is baked into the image as
# base.d/90-butane.ign by templates/elemental/butane.yaml.tftpl. Ignition
# merges every base.d config first, then the platform config (this one, from
# Vultr's metadata service) on top, so the two are layered and this one wins on
# conflict.
locals {
  # Per node, and ONLY per node: anything identical across the cluster belongs
  # in butane.yaml.tftpl instead. Plain {path, mode, content} tuples; the
  # data: URI encoding happens once, below.
  node_files = {
    for node in local.cluster_nodes : node.hostname => concat(
      [
        {
          path    = "/etc/hostname"
          mode    = 420 # 0644
          content = "${node.hostname}\n"
        },
      ],
      # THE ONLY PLACE A NODE'S ROLE IS DECLARED. kubernetes/cluster.yaml has
      # no nodes: list, so elemental writes its own copy of this file into
      # base.d carrying IS_INIT_NODE=true NODETYPE=server; this one merges over
      # it (see the header above) and is what both k8s_conf_deploy.sh and
      # k8s-resource-installer.service's ExecCondition actually read.
      #
      # IS_INIT_NODE is emitted only on the init node -- not as "false"
      # elsewhere -- because absent and false behave identically downstream,
      # and the upstream example omits it the same way.
      [
        {
          path = "/var/lib/elemental/runtime.env"
          mode = 420 # 0644
          content = join("", concat(
            ["NODETYPE=${node.type}\n"],
            node.init ? ["IS_INIT_NODE=true\n"] : [],
          ))
        },
      ],
    )
  }

  # Identical on every server, and delivered per node anyway -- because of WHEN
  # it has to exist, not because it varies.
  #
  # RKE2 reads /var/lib/rancher/rke2/server/manifests at startup and turns each
  # file into an AddOn. Elemental's own kubernetes/manifests/ is a DIFFERENT
  # slot: k8s-resource-installer.service kubectl-applies it once the API server
  # answers, which is far too late for a HelmChartConfig. That is elemental
  # issue #570, whose documented workaround is exactly this -- write the file
  # straight into RKE2's manifests directory. On a fresh build:
  #
  #   12:30:17  ignition writes /var/lib/elemental/kubernetes/manifests/canal.yaml
  #   12:30:29  rke2-server starts
  #   12:30:33  RKE2 drops its own rke2-canal.yaml into the manifests dir
  #   12:30:58  the rke2-canal HelmChart is created -- chart defaults
  #   12:31:03  ConfigMap rke2-canal-config appears with veth_mtu 1450
  #   12:32:42  k8s-resource-installer applies our HelmChartConfig, 104s late
  #
  # For canal specifically that lateness is permanent, not merely slow: its
  # values reach the DaemonSet through rke2-canal-config via env.valueFrom and
  # the chart sets no checksum annotation, so the reinstall produces a
  # byte-identical pod template, nothing rolls, install-cni never re-runs and
  # /etc/cni/net.d/10-canal.conflist keeps the default MTU for the life of the
  # node. The init node comes up with 1450 pod veths on a 1400 underlay while
  # every node that joins later is correct. (traefik.yaml does not have this
  # problem: its values land in a pod template, so the reinstall rolls it.)
  #
  # Worth knowing if #570 is ever fixed: the failure it describes is a deadlock,
  # loud and self-announcing. This one is silent -- the chart installs, the
  # installer succeeds, every pod is Running, and the HelmChartConfig sits in the
  # cluster looking applied while doing nothing. Ordering resources WITHIN
  # k8s-resource-installer would not fix it; the file has to exist before
  # rke2-server starts, and that service runs after the API server answers.
  #
  # Ignition runs 12 seconds before rke2-server, so writing the file into RKE2's
  # own directory makes it an AddOn in the same sync as rke2-canal.yaml -- and
  # "canal.yaml" sorts before "rke2-canal.yaml": both AddOns present, conflist
  # 1400 on the init node with no pod bounce, every cali veth born at 1400,
  # 9091 closed from off-cluster.
  #
  # Servers only: agents never read this directory. All servers rather than just
  # the init node, so no server holds a divergent view of it.
  #
  # Being here also takes CNI tuning off the image-rebuild path: editing
  # canal.yaml.tftpl now replaces nodes instead of rebuilding the snapshot.
  node_server_manifests = {
    for node in local.cluster_nodes : node.hostname => node.type != "server" ? [] : [
      {
        path = "/var/lib/rancher/rke2/server/manifests/canal.yaml"
        mode = 420 # 0644
        content = templatefile("${path.module}/templates/elemental/kubernetes/manifests/canal.yaml.tftpl", {
          iface_regex = local.vpc_iface_regex
          veth_mtu    = local.pod_veth_mtu
        })
      },
    ]
  }

  # Ignition creates a file's parent directories implicitly, so this is
  # belt-and-braces: it pins the mode, and the directory still exists if the
  # list above is ever emptied.
  node_server_dirs = {
    for node in local.cluster_nodes : node.hostname => node.type != "server" ? [] : [
      "/var/lib/rancher/rke2/server/manifests",
    ]
  }

  node_runtime_ignition = {
    for hostname, files in local.node_files : hostname => jsonencode({
      ignition = { version = "3.5.0" }

      # passwd and systemd live in butane.yaml. A storage-only Ignition config
      # is still valid.
      storage = {
        directories = [
          for d in local.node_server_dirs[hostname] : {
            path = d
            mode = 493 # 0755
          }
        ]

        files = concat(
          [
            for f in files : {
              path      = f.path
              mode      = f.mode
              overwrite = true
              contents = {
                compression = ""

                # The replace() is load-bearing: urlencode() is Go's
                # url.QueryEscape, which renders a space as "+", but an RFC 2397
                # data: URI is only percent-decoded, so the "+" survives
                # literally. Real butane emits %20. It bites silently and only
                # for files containing a space -- none of the files above do
                # today, but the encoding has to be right for the next one
                # that does.
                source = "data:,${replace(urlencode(f.content), "+", "%20")}"
              }
            }
          ],
          # base64 rather than percent-encoding for these: they are mostly
          # prose, which percent-encoding roughly triples, and user_data is a
          # budget. Both forms are valid RFC 2397 and both are emitted by real
          # butane; this one also sidesteps the "+" trap above entirely.
          [
            for f in local.node_server_manifests[hostname] : {
              path      = f.path
              mode      = f.mode
              overwrite = true
              contents = {
                compression = ""
                source      = "data:;base64,${base64encode(f.content)}"
              }
            }
          ],
        )
      }
    })
  }
}

# Chart set enabled in release.yaml, driven by var.components. One spec entry
# per chart name: values_file is what release.yaml's valuesFile points at
# (null when a chart ships no values of its own), chart_credentials is Helm
# chart-PULL auth against oci://dp.apps.rancher.io/charts -- release.yaml's
# per-chart credentials: block, keyed by chart name because elemental's
# createAuthMap keys the auth map that way, not by repository -- and
# pull_secret_namespace is a separate, unrelated thing: an in-cluster
# Kubernetes image-PULL Secret this module creates by hand (see
# component_pull_secret_manifests below), because CreateNamespace: true is
# hardcoded on every generated HelmChart CR (pkg/helm/helm.go:109) and the
# Secret has to exist in that namespace before the chart runs. The two flags
# are independent on purpose: local-path-provisioner needs both, because its
# pods pull images directly from the same registry; suse-storage needs only
# the first, because its own values file sets
# privateRegistry.createSecret: true and the chart creates the Secret itself.
#
# sysext names a systemd system extension release.yaml must enable alongside
# the chart. In theory this is redundant: the AIF manifest's suse-storage chart
# already declares `dependsOn: [{name: suse-storage, type: sysext}]`, and
# elemental's enabledExtensions() turns any extension named by an enabled
# chart's ExtensionDependencies() into an enabled extension without being
# asked (internal/config/systemd_sysext.go, the isDependency closure).
#
# It is listed explicitly anyway, because that auto-enable was read out of
# elemental `main` and this module pins elemental 3.1.0-6.5 -- the exact kind
# of version skew that already cost a cluster once with initrdExtensions (see
# core_platform_override). The same function's isExtensionExplicitlyEnabled()
# honours release.yaml's own `components.systemd` list, which is the path that
# does not depend on the tool being new enough. Belt and braces, one line.
locals {
  component_spec = {
    cert-manager = {
      values_file           = null
      chart_credentials     = false
      pull_secret_namespace = null
      sysext                = null
    }
    rancher = {
      values_file           = "rancher.yaml"
      chart_credentials     = false
      pull_secret_namespace = null
      sysext                = null
    }
    gpu-operator = {
      values_file           = null
      chart_credentials     = false
      pull_secret_namespace = null
      sysext                = null
    }
    local-path-provisioner = {
      values_file           = "local-path-provisioner.yaml"
      chart_credentials     = true
      pull_secret_namespace = "local-path-provisioner"
      sysext                = null
    }
    # Longhorn cannot start without iscsiadm, which is not in the base OS
    # image. registry.suse.com/elemental/longhorn:4.111-4.79 exists in the AIF
    # manifest for that one reason, and its own comment there says so.
    # Without it longhorn-manager crash-loops on:
    #   "failed to check environment, please make sure you have
    #    iscsiadm/open-iscsi installed on the host"
    suse-storage = {
      values_file           = "suse-storage.yaml"
      chart_credentials     = true
      pull_secret_namespace = null
      sysext                = "suse-storage"
    }
    aif-operator = {
      values_file           = "aif-operator.yaml"
      chart_credentials     = false
      pull_secret_namespace = null
      sysext                = null
    }
  }

  # CANONICAL order, not the order var.components was typed in. Chart
  # dependsOn is resolved automatically and recursively by elemental itself
  # (internal/config/helm.go's enabledHelmCharts/addChart inserts a dependency
  # BEFORE its dependent), so this list only has to avoid contradicting that --
  # its actual job is making var.components' DEFAULT render release.yaml
  # byte-for-byte identical to what this module shipped before `components`
  # existed. That matters here specifically: release.yaml is in
  # local.elemental_files, sha256'd into time_static.build's trigger, which
  # names the snapshot -- ForceNew on every node -- so a reordered default
  # would propose destroying a running cluster on nothing but an upgrade of
  # this module. Treat the default's byte-identical rendering as an
  # acceptance test, not a nicety.
  component_order = [
    "cert-manager", "rancher", "gpu-operator",
    "local-path-provisioner", "suse-storage", "aif-operator",
  ]

  # rancher -> cert-manager is already enforced upstream (see component_spec's
  # header comment); this only adds what var.components didn't already say,
  # and never double-adds cert-manager if it's already present.
  components_with_deps = contains(var.components, "rancher") && !contains(var.components, "cert-manager") ? concat(var.components, ["cert-manager"]) : var.components

  enabled_components      = [for c in local.component_order : c if contains(local.components_with_deps, c)]
  enabled_component_specs = [for c in local.enabled_components : merge({ chart = c }, local.component_spec[c])]

  # Extensions the enabled charts need, in the same canonical order, deduped
  # (distinct) so two charts naming one extension emit it once. Empty for the
  # default chart set, which is what keeps the default release.yaml
  # byte-identical -- release.yaml.tftpl omits the block entirely when this is
  # empty rather than emitting `systemd: []`.
  enabled_sysexts = distinct([
    for c in local.enabled_components : local.component_spec[c].sysext
    if local.component_spec[c].sysext != null
  ])

  # Whether butane.yaml has to carry the open-iSCSI firstboot unit. Keyed off
  # the EXTENSION, not the chart: it is the sysext that delivers iscsid under
  # /usr with no /etc to go with it, and anything else that ever pulls that
  # same extension in needs the same repair. Gating it also keeps butane.yaml
  # -- and therefore the build id and the whole image -- byte-identical for the
  # default (local-path-provisioner) component set.
  enable_iscsi_prep = contains(local.enabled_sysexts, "suse-storage")

  # Whether butane.yaml has to carry the local-path-provisioner firstboot unit.
  # Keyed off the CHART, not an extension: the directory is the chart's default
  # storage path, so nothing else needs it. Gated for the same reason as
  # enable_iscsi_prep -- a suse-storage cluster gets a byte-identical
  # butane.yaml, and therefore the same build id, as one built before this
  # existed.
  enable_local_path_prep = contains(local.enabled_components, "local-path-provisioner")

  # Every extension this module knows how to enable, regardless of whether the
  # component that pulls it in is selected. Only used to tell a typo from a
  # deliberate no-op below.
  known_sysexts = distinct([
    for spec in values(local.component_spec) : spec.sysext if spec.sysext != null
  ])

  # var.sysext_image_overrides, narrowed to extensions that are actually
  # enabled. The variable ships a non-empty default (the beta longhorn build),
  # and the default component set does NOT include suse-storage, so without
  # this filter every ordinary local-path-provisioner cluster would rewrite an
  # extension it never builds -- and, worse, would fail the build outright
  # against any manifest that does not declare that extension, over a component
  # nobody asked for. Filtering here means an override is inert until the
  # component that needs it is selected.
  #
  # The build script keeps its own fatal check on names the manifest does not
  # declare. That check now only sees names that survived this filter, which is
  # the intended division: "the manifest has no such extension" is fatal, "no
  # selected component pulls this extension in" is a no-op.
  #
  # Consequence worth knowing: an extension the manifest marks Required, or one
  # pulled in by a chart this module does not model, cannot be overridden at
  # all -- it never appears in enabled_sysexts. Add it to component_spec's
  # sysext field if that day comes.
  effective_sysext_overrides = {
    for name, image in var.sysext_image_overrides : name => image
    if contains(local.enabled_sysexts, name)
  }

  # Longhorn's replica count for suse-storage.yaml.tftpl. control_plane_count
  # is validated >= 3 && odd (variables.tf), so the < 3 branch in that
  # template is unreachable in this module today -- see its own comment for
  # why it is kept anyway.
  suse_storage_node_count = var.control_plane_count

  # Values files and appco-pull-secret manifests driven by which components
  # are enabled. Split from the always-present entries in elemental_files
  # below so each one is entered ONLY when its component is: a cluster
  # without aif-operator, for instance, stops shipping the SUSE registration
  # code, registry password and NVIDIA API key into the image at all.
  component_values_files = merge(
    !contains(local.enabled_components, "rancher") ? {} : {
      "kubernetes/helm/values/rancher.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/helm/values/rancher.yaml.tftpl", {
        hostname           = local.rancher_hostname
        bootstrap_password = local.rancher_bootstrap_password
      })
    },
    !contains(local.enabled_components, "local-path-provisioner") ? {} : {
      # Static: no per-deployment values, so no templating needed.
      "kubernetes/helm/values/local-path-provisioner.yaml" = file("${path.module}/templates/elemental/kubernetes/helm/values/local-path-provisioner.yaml")
    },
    !contains(local.enabled_components, "suse-storage") ? {} : {
      "kubernetes/helm/values/suse-storage.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/helm/values/suse-storage.yaml.tftpl", {
        appco_username = var.appco_username
        appco_password = var.appco_password
        node_count     = local.suse_storage_node_count
      })
    },
    !contains(local.enabled_components, "aif-operator") ? {} : {
      "kubernetes/helm/values/aif-operator.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/helm/values/aif-operator.yaml.tftpl", {
        appco_username         = var.appco_username
        appco_password         = var.appco_password
        suse_registration_code = var.suse_registration_code
        suse_registry_password = var.suse_registry_password
        nvidia_api_key         = var.nvidia_api_key
      })
    },
  )

  # Image-pull Secret manifests, one per enabled component whose spec names a
  # pull_secret_namespace -- today only local-path-provisioner. suse-storage
  # is deliberately absent: see component_spec's header comment.
  component_pull_secret_manifests = {
    for c in local.enabled_components : "kubernetes/manifests/${c}.yaml" => templatefile(
      "${path.module}/templates/elemental/kubernetes/manifests/appco-pull-secret.yaml.tftpl",
      {
        namespace            = local.component_spec[c].pull_secret_namespace
        dockerconfigjson_b64 = local.dockerconfigjson_b64
      }
    ) if local.component_spec[c].pull_secret_namespace != null
  }
}

# The elemental config dir, keyed by path relative to config_dir. Looped over
# in cloud-init.yaml.tftpl's write_files with gzip+base64 encoding, which
# both shrinks the payload and sidesteps YAML-indenting arbitrary generated
# content by hand.
#
# This is the DOCUMENTED form. local.elemental_files below strips the comments
# out before anything consumes it -- nothing outside this file should read
# elemental_files_documented.
locals {
  elemental_files_documented = merge({
    "release.yaml" = templatefile("${path.module}/templates/elemental/release.yaml.tftpl", {
      components     = local.enabled_component_specs
      sysexts        = local.enabled_sysexts
      appco_username = var.appco_username
      appco_password = var.appco_password
    })

    # release_manifest.yaml is NOT embedded here -- ~3.8 KB against the
    # user_data ceiling, for no benefit since the jumphost has network access.
    # image-factory.sh curls aif_release_manifest_url into the config dir
    # before running elemental customize. data.http.aif_release_manifest above
    # exists only to hash the manifest into the build id; the two fetches are
    # minutes apart, so pin the URL to a commit SHA if it tracks a branch.

    "install.yaml" = templatefile("${path.module}/templates/elemental/install.yaml.tftpl", {
      disk_size = var.image_disk_size
      fips      = var.fips
    })

    # Everything identical on every node: the accounts (root's hash, the
    # unprivileged var.node_username with its own hash and the SSH keys, and
    # whether sshd takes root at all), the /home subvolume mount those accounts
    # need, /root/.profile, and the write-node-ip firstboot unit (see
    # local.write_node_ip_script below, and that script's own header for why
    # it has to be delivered this way rather than through
    # configure-network.sh). Layered with, not exclusive to, each node's
    # user_data -- see the template's header.
    "butane.yaml" = templatefile("${path.module}/templates/elemental/butane.yaml.tftpl", {
      root_password_hash      = var.root_password_hash
      ssh_authorized_keys     = var.ssh_authorized_keys
      node_username           = var.node_username
      node_user_password_hash = var.node_user_password_hash
      permit_root_ssh         = var.permit_root_ssh
      write_node_ip_script    = local.write_node_ip_script
      enable_iscsi_prep       = local.enable_iscsi_prep
      iscsi_prep_script       = local.iscsi_prep_script
      enable_local_path_prep  = local.enable_local_path_prep
    })

    # No node list is passed: roles ride per node in runtime.env instead. See
    # the template's header for the elemental source that makes that work, and
    # for why keeping node identity out of this file matters.
    "kubernetes/cluster.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/cluster.yaml.tftpl", {
      api_vip      = vultr_load_balancer.api.ipv4
      api_vip_mode = var.api_vip_mode
      api_host     = local.api_host
    })

    "kubernetes/config/server.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/config/server.yaml.tftpl", {
      token                = random_password.token.result
      ingress_controller   = var.ingress_controller
      suse_storage_enabled = contains(local.enabled_components, "suse-storage")
    })

    "kubernetes/config/agent.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/config/agent.yaml.tftpl", {
      token = random_password.token.result
    })

    # kubernetes/helm/values/{rancher,local-path-provisioner,suse-storage,
    # aif-operator}.yaml and kubernetes/manifests/*.yaml (the appco image-pull
    # Secrets) are NOT here -- both are component-driven, see
    # component_values_files and component_pull_secret_manifests above, and
    # both are merge()'d in below.

    # canal.yaml is NOT here. Its HelmChartConfig has to exist before RKE2
    # installs the chart, and this directory is applied minutes after that --
    # see node_server_manifests above, which delivers it through Ignition
    # instead.

    # nat_gateway_ip and dns_servers feed a fallback branch no node type
    # reaches today -- DHCP supplies both, given the NAT gateway this module
    # always creates. Kept for a future node shape that needs static VPC
    # addressing with no public NIC. No node-shaped input is passed any more:
    # the script now discovers a dual-NIC node's own VPC address from
    # metadata at first boot instead of looking it up in a baked table (see
    # the "VPC addresses" comment above local.control_plane_nodes).
    "network/configure-network.sh" = templatefile("${path.module}/templates/elemental/network/configure-network.sh.tftpl", {
      nat_gateway_ip = vultr_nat_gateway.this.private_ips[0]
      vpc_mtu        = var.vpc_mtu
      vpc_prefix     = var.vpc_subnet_mask
      dns_servers    = var.dns_servers
    })
    },

    local.component_values_files,
    local.component_pull_secret_manifests,

    # Only traefik gets a HelmChartConfig: ingress-nginx is on its way out
    # upstream and not worth carrying a second variant of this for.
    var.ingress_controller != "traefik" ? {} : {
      "kubernetes/manifests/traefik.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/manifests/traefik.yaml.tftpl", {
        vpc_cidr = local.vpc_cidr
      })
  })
}

# Comments stripped. Everything downstream reads local.elemental_files and
# local.factory_script, never the *_documented values feeding this block.
#
# Why: the templates are commented heavily on purpose, but every byte of them
# rides in the jumphost's user_data, which jumphost.tf caps at 32 KiB. Across
# all templates, gzip+base64'd the way cloud-init.yaml.tftpl encodes them,
# that is roughly 35 KB with comments and 14 KB without. Gzip does not rescue
# prose here -- the files are encoded one at a time, so no shared dictionary
# ever forms across them.
#
# The second, larger benefit: elemental_files is what snapshot.tf sha256s into
# time_static.build's `config` trigger, so the hash is now blind to comments.
# Editing a comment in any template does not rebuild the image or replace the
# cluster.
#
# What the regex does and does not touch:
#   - Strips a line whose first non-blank character is "#", and its newline.
#   - Leaves "#!" alone, so the shebang survives -- including the indented one
#     inside butane.yaml's `inline: |` block, where write-node-ip.sh is
#     embedded. That is the whole reason for the (?:[^!].*)? alternation.
#   - Leaves trailing comments ("foo  # bar") alone. Stripping those needs
#     to know whether the "#" is inside a quoted string, which a regex cannot,
#     and they are a rounding error next to the block comments.
#   - Leaves "#cloud-config" alone by not applying here at all:
#     cloud-init.yaml.tftpl is rendered in jumphost.tf, not through this map,
#     and its first line is a directive rather than a comment.
#   - ".*" does not cross a newline in RE2, so a comment can never eat the
#     line after it.
# Then runs of blank lines collapse to one, since removing a block comment
# usually leaves the blank lines that framed it back to back.
#
# image-factory.sh goes through the same pipe -- it is the single largest file
# in the payload (~14 KB of source, most of it commentary), so exempting it
# would give back most of the saving.
#
# It is stripped SEPARATELY rather than merged into one map with the elemental
# files. The merged version is the obvious-looking one and it deadlocks -- a
# single `merge()`d map stripped in one comprehension, re-split afterwards,
# gets you:
#
#   Cycle: time_static.build -> local.elemental_files -> <the merged map>
#          -> local.factory_script_documented -> local.snapshot_description
#
# image-factory.sh interpolates snapshot_description, which is derived from
# time_static.build, whose `config` trigger is the sha256 of elemental_files.
# Merging the two puts elemental_files downstream of the factory script and
# closes the loop. Keeping them as two expressions over shared regex locals
# costs a duplicated replace() pair and keeps the graph acyclic.
locals {
  # Wrapped in forward slashes, so replace() treats them as regexes.
  strip_comment_lines = "/(?m)^[ \\t]*#(?:[^!].*)?\\n/"
  collapse_blank_runs = "/\\n{3,}/"

  elemental_files = {
    for path, content in local.elemental_files_documented :
    path => replace(
      replace(content, local.strip_comment_lines, ""),
      local.collapse_blank_runs, "\n\n"
    )
  }

  factory_script = replace(
    replace(local.factory_script_documented, local.strip_comment_lines, ""),
    local.collapse_blank_runs, "\n\n"
  )
}
