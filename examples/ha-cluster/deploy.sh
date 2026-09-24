#!/usr/bin/env bash
#
# Two-pass apply for the HA cluster example.
#
# WHY TWO PASSES:
# The load balancer's backend list (attached_instances) is an inline field
# of vultr_load_balancer, not a separate resource — so "create the LB" and
# "attach the backends" are one node in Terraform's graph. Wiring
# attached_instances straight to vultr_instance.control_plane[*].id would
# close a dependency cycle:
#
#   LB (attached_instances) -> control-plane instances -> snapshot ->
#   jumphost (needs the LB's IP baked into the image) -> back to the LB
#
# The module breaks the cycle by taking the backend list out of the graph:
# lb_backend_instance_ids and lb_supervisor_extra_cidrs are plain variables
# (default []), not references. Pass 1 stands up everything with an empty
# backend list; pass 2 feeds the real values back in, sourced from pass 1's
# own outputs. Both passes are safe to re-run — the snapshot wait is a no-op
# once the snapshot already exists.
#
# Pass 2's values are written to pass2.auto.tfvars.json rather than passed as
# -var on the command line: Terraform auto-loads any *.auto.tfvars.json in
# the working directory on every subsequent plan/apply, whereas a -var flag
# is gone the moment the command exits. Without this file, a plain
# `terraform apply` run any time after deploy.sh finishes would see
# lb_backend_instance_ids revert to its [] default and silently detach every
# control-plane node from the load balancer.
#
# THIS SCRIPT RESETS THAT FILE TO EMPTY BEFORE PASS 1 RUNS, every time.
# Reason, found the hard way: lb_backend_instance_ids is a plain variable,
# not a reference to vultr_instance.control_plane -- Terraform has no
# dependency edge telling it those specific IDs are about to stop existing
# whenever something (a new snapshot from a rebuilt image, a plan change,
# anything ForceNew) replaces the control-plane/GPU nodes. Without the
# reset, a stale pass2.auto.tfvars.json left over from a previous run makes
# pass 1 destroy the old instances and then try to attach those same
# now-deleted IDs to the load balancer in the same apply, which Vultr
# rejects with a 422 "Invalid Instance IDs" -- and the apply aborts with
# the old nodes already gone and their replacements never created. Starting
# every pass 1 from an empty backend list (matching the variables' own
# defaults) makes that failure mode structurally impossible: pass 1 never
# has stale IDs to fight with, and pass 2 (right after, same invocation)
# regenerates the file from that run's own fresh outputs regardless.
#
# lb_backend_instance_ids feeds BOTH load balancers -- the API one and the
# ingress one, which share the same control-plane backends.
#
# The cost of the reset: EVERY run of this script now detaches the load
# balancers' backends at the start of pass 1 and reattaches them at the end
# of pass 2, even a fully idempotent re-run where nothing about the
# control-plane/GPU nodes actually changes. That is a real, brief outage
# window on 6443/9345 and on 80/443 every run, not just ones with node
# replacement -- traded
# deliberately for never again failing an apply mid-replace with the old
# nodes already destroyed and their successors never created.
#
# WHAT TO EXPECT:
# Pass 1 blocks for tens of minutes with NO console output while the
# jumphost builds the elemental image (podman pull + customize) and Vultr
# imports the resulting raw as a snapshot. This is normal. From another
# terminal, watch progress with:
#
#   ssh root@<jumphost_public_ipv4> tail -f /var/log/elemental-factory.log
#
# Between pass 1 and pass 2 both load balancers exist but have zero backends,
# so `curl https://<lb-ip>:6443` or a port scan against :6443 will show a
# dead/refused connection. That is expected, not a failure — it clears up
# once pass 2 attaches the control-plane nodes and GPU CIDRs. The ingress
# load balancer stays down longer still: its health check is Traefik's own
# /ping, which only answers once the cluster has finished deploying charts.
#
# PORT 80 AND THE SNAPSHOT:
# The module imports the image with vultr_snapshot_from_url, which fetches it
# off the jumphost over tcp/80. That rule is a Terraform resource gated by
# image_import_port_open, so it cannot be opened and closed in one apply:
# the reset below leaves the key out (default true, open) for pass 1, and
# pass 2 writes false, closing it once the snapshot is complete. A routine
# re-run therefore opens it for the length of pass 1 even when nothing is
# rebuilt -- with nothing listening, since the jumphost stops serving
# image_serve_seconds after its build.
#
# snapshot_id is NOT pinned. The managed snapshot's id is known from state at
# plan time, so an unchanged cluster plans no node replacement without it --
# and pinning it would drop the managed resource to count = 0 and DESTROY the
# snapshot the nodes run from.
#
# Whether to rebuild is decided by time_static.build's triggers (snapshot.tf).
# To force one regardless (e.g. to pick up a changed upstream image under the
# same tag), run:
#
#   ./deploy.sh --rebuild
#
# which adds -replace on time_static.build to pass 1. That replaces the
# jumphost, the snapshot and every node built from it; the old snapshot is
# deleted, not kept.
#
# USAGE:
#   ./deploy.sh [--rebuild] [--yes] [-- | terraform apply args...]
#
# Double-dash flags are this script's own and are consumed here; everything
# else is forwarded verbatim to both `terraform apply` calls. An unrecognised
# --flag is a hard error rather than being forwarded, so a typo surfaces here
# instead of as a confusing Terraform error. Use `--` to stop flag parsing.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./deploy.sh [--rebuild] [--yes] [terraform apply args...]

  --rebuild   Force a fresh image build on pass 1 (-replace on
              time_static.build), replacing the snapshot and every node.
  --yes       Pass -auto-approve to both terraform apply passes.
  --help      Show this message.
  --          Stop parsing this script's flags; forward the rest verbatim.

Any other argument is forwarded to both `terraform apply` invocations.
USAGE
}

REBUILD=false
TF_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=true; shift ;;
    --yes) TF_ARGS+=(-auto-approve); shift ;;
    --help | -h)
      usage
      exit 0
      ;;
    --)
      shift
      TF_ARGS+=("$@")
      break
      ;;
    --*)
      echo "ERROR: unknown option '$1'." >&2
      echo >&2
      usage >&2
      exit 2
      ;;
    *) TF_ARGS+=("$1"); shift ;;
  esac
done

if [[ -z "${VULTR_API_KEY:-}" ]]; then
  echo "ERROR: VULTR_API_KEY is not set." >&2
  echo "Both the vultr provider and the module's scripts/wait-for-snapshot.sh need it in the environment." >&2
  exit 1
fi

PASS1_ARGS=()
if [[ "$REBUILD" == true ]]; then
  echo "==> --rebuild requested: forcing a fresh image build on pass 1"
  PASS1_ARGS+=(-replace=module.ha_cluster.time_static.build)
fi

echo "==> Resetting pass2.auto.tfvars.json to empty before pass 1 (see the comment above for why)"
# image_import_port_open is left out, not set to true, so the variable's own
# default applies and port 80 is open for any import pass 1 has to do.
cat > pass2.auto.tfvars.json <<'EOF'
{
  "lb_backend_instance_ids": [],
  "lb_supervisor_extra_cidrs": [],
  "gpu_cloud_extra_cidrs": []
}
EOF

echo "==> Pass 1: network, load balancer, jumphost image factory, control-plane + GPU nodes"
echo "    (this blocks for tens of minutes once the jumphost starts building the image;"
echo "     watch it with: ssh root@<jumphost_public_ipv4> tail -f /var/log/elemental-factory.log)"
terraform apply ${PASS1_ARGS[@]+"${PASS1_ARGS[@]}"} ${TF_ARGS[@]+"${TF_ARGS[@]}"}

echo "==> Pass 2: attach load balancer backends (API + ingress) and GPU supervisor CIDRs, close port 80"
echo "    (neither LB has backends until this completes — a dead :6443 in between is expected)"
# image_import_port_open = false: the snapshot is complete by now (pass 1
# blocked on it), so the import rule goes -- see PORT 80 above.
cat > pass2.auto.tfvars.json <<EOF
{
  "lb_backend_instance_ids": $(terraform output -json control_plane_ids),
  "lb_supervisor_extra_cidrs": $(terraform output -json gpu_node_cidrs),
  "gpu_cloud_extra_cidrs": $(terraform output -json nat_gateway_public_cidrs),
  "image_import_port_open": false
}
EOF
terraform apply ${TF_ARGS[@]+"${TF_ARGS[@]}"}

echo "==> Done. See outputs for jumphost_public_ipv4, kubernetes_api_endpoint, api_vip,"
echo "    ingress_lb_ipv4 and rancher_url."
echo "==> pass2.auto.tfvars.json now pins the load balancer's backends for every future"
echo "    plan/apply in this directory — do not delete it, and re-run this script (not a"
echo "    bare 'terraform apply') if control-plane or GPU nodes are ever replaced."
