#!/usr/bin/env bash
# Invoked from network.tf via a creation-time local-exec provisioner on each
# vultr_load_balancer, on the OPERATOR's machine (not the jumphost). The
# provider can return from create before Vultr has assigned the LB a public
# IPv4, and records ipv4 = "" in state. The address is baked into the image
# (apiVIP, apiHost, Rancher's hostname), so an image built then has an empty
# endpoint -- and the next refresh sees the real one, rebuilds the image and
# replaces every node. This holds creation until the address exists; network.tf
# then reads it back through data.http.lb, not the resource's stale attribute.
#
# Needs only curl + python3 (json module) -- no jq dependency.
set -euo pipefail

: "${LB_ID:?LB_ID must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"

if [ -z "${VULTR_API_KEY:-}" ]; then
  echo "ERROR: VULTR_API_KEY is not set in the operator's environment (the same key the vultr provider itself needs). Cannot poll the Vultr API without it." >&2
  exit 1
fi

log() {
  echo "[wait-for-lb-ipv4] $*" >&2
}

log "polling load balancer $LB_ID for a public IPv4 (timeout ${TIMEOUT_SECONDS}s, every ${POLL_SECONDS}s)"

START_TIME=$(date +%s)

while true; do
  ELAPSED=$(($(date +%s) - START_TIME))

  # -4 for the same reason as wait-for-snapshot.sh: an IP-restricted key gets
  # 401 over IPv6 on a dual-stack host. Errors are retried until the timeout,
  # not fatal: the LB exists, the API only has to answer once.
  BODY=$(curl -4 -fsS --max-time 10 \
    -H "Authorization: Bearer $VULTR_API_KEY" \
    "https://api.vultr.com/v2/load-balancers/$LB_ID" 2>/dev/null || true)
  IPV4=$(python3 -c 'import json,sys
try:
    print(json.loads(sys.argv[1]).get("load_balancer", {}).get("ipv4") or "")
except ValueError:
    print("")' "$BODY")

  if [ -n "$IPV4" ]; then
    log "load balancer $LB_ID has IPv4 $IPV4 after ${ELAPSED}s"
    exit 0
  fi

  if [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
    log "ERROR: load balancer $LB_ID still has no IPv4 after ${ELAPSED}s. The resource is tainted and will be replaced on the next apply."
    exit 1
  fi

  sleep "$POLL_SECONDS"
done
