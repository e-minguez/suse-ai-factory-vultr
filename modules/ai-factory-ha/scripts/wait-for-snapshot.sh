#!/usr/bin/env bash
# Invoked from snapshot.tf via a creation-time local-exec provisioner on
# vultr_snapshot_from_url, on the OPERATOR's machine (not the jumphost). The
# provider returns as soon as Vultr accepts create-from-url, with the snapshot
# still "pending"; this polls SNAPSHOT_ID until it is "complete", so nothing
# downstream boots from a half-imported image.
#
# Needs only curl + python3 (json module) -- no jq dependency.
set -euo pipefail

: "${SNAPSHOT_ID:?SNAPSHOT_ID must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"

if [ -z "${VULTR_API_KEY:-}" ]; then
  echo "ERROR: VULTR_API_KEY is not set in the operator's environment (the same key the vultr provider itself needs). Cannot poll the Vultr API without it." >&2
  exit 1
fi

API_BASE="https://api.vultr.com/v2"

log() {
  echo "[wait-for-snapshot] $*" >&2
}

# Recovery for a vanished record, printed on both paths that can mean it.
state_rm_hint() {
  log "The resource is now in state with an id Vultr no longer knows, and the provider errors on"
  log "the 404 at refresh. Before re-running apply:"
  log "  terraform state rm 'module.ha_cluster.vultr_snapshot_from_url.ai_factory[0]'"
}

log "polling snapshot $SNAPSHOT_ID until complete (timeout ${TIMEOUT_SECONDS}s, every ${POLL_SECONDS}s)"

START_TIME=$(date +%s)
LAST_PROGRESS_LOG=$START_TIME
STATUS=""
# api.vultr.com returns 502 during platform maintenance windows, including
# mid-import. Not fatal and does not reset the clock: the import proceeds on
# Vultr's side whether or not their API answers.
TRANSIENT=0
MAX_TRANSIENT=20

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TIME))

  # Not -f: a 404 has a meaning here, diagnosed below. -4 because an
  # IP-restricted key gets 401 "Unauthorized IP address: <ipv6>" on a
  # dual-stack host.
  HTTP_CODE=$(curl -4 -sS -o /tmp/wait-for-snapshot.$$.json -w '%{http_code}' \
    -H "Authorization: Bearer $VULTR_API_KEY" \
    "$API_BASE/snapshots/$SNAPSHOT_ID" || true)
  BODY=$(cat /tmp/wait-for-snapshot.$$.json 2>/dev/null || true)
  rm -f /tmp/wait-for-snapshot.$$.json

  case "$HTTP_CODE" in
    200)
      TRANSIENT=0
      STATUS=$(python3 -c 'import json,sys
print(json.loads(sys.argv[1]).get("snapshot", {}).get("status", ""))' "$BODY")
      case "$STATUS" in
        complete)
          log "snapshot $SNAPSHOT_ID is complete after ${ELAPSED}s"
          break
          ;;
        pending) ;;
        *)
          log "ERROR: snapshot $SNAPSHOT_ID is in unexpected/terminal status \"$STATUS\", not \"pending\" or \"complete\""
          exit 1
          ;;
      esac
      ;;
    404)
      log "ERROR: snapshot $SNAPSHOT_ID no longer exists. Vultr deletes the record when its fetcher"
      log "cannot retrieve the image, so the import never got the file: most likely port 80 had not"
      log "propagated at the edge Vultr fetched through, or the jumphost's serve window ran out."
      log "The jumphost's http access log (/var/log/elemental-factory.log) shows whether any address"
      log "besides 127.0.0.1 and yours ever fetched it."
      state_rm_hint
      exit 1
      ;;
    000 | 5??)
      TRANSIENT=$((TRANSIENT + 1))
      log "transient: HTTP $HTTP_CODE from the Vultr API ($TRANSIENT/$MAX_TRANSIENT consecutive)"
      if [ "$TRANSIENT" -ge "$MAX_TRANSIENT" ]; then
        log "ERROR: the Vultr API has been unavailable for $MAX_TRANSIENT consecutive polls, giving up. The snapshot may still complete -- check 'vultr-cli snapshot get $SNAPSHOT_ID'."
        exit 1
      fi
      ;;
    *)
      log "ERROR: the Vultr API rejected the request (HTTP $HTTP_CODE): $BODY"
      log "This is a credentials or rate-limit problem, not a build problem -- VULTR_API_KEY must be valid and, if it is IP-restricted, must allow this machine's address."
      exit 1
      ;;
  esac

  if [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
    log "ERROR: timed out after ${ELAPSED}s with snapshot $SNAPSHOT_ID still \"$STATUS\". The jumphost has stopped serving by now, so it will not complete."
    state_rm_hint
    exit 1
  fi

  if [ $((NOW - LAST_PROGRESS_LOG)) -ge 60 ]; then
    log "still waiting: snapshot $SNAPSHOT_ID status=${STATUS:-unknown} (${ELAPSED}s elapsed)"
    LAST_PROGRESS_LOG=$NOW
  fi

  sleep "$POLL_SECONDS"
done

log "checking uefi flag on snapshot $SNAPSHOT_ID (write-only field: absence is expected, not an error)"
RAW_RESPONSE=$(curl -4 -fsS -H "Authorization: Bearer $VULTR_API_KEY" "$API_BASE/snapshots/$SNAPSHOT_ID")

if printf '%s' "$RAW_RESPONSE" | grep -qi 'uefi'; then
  log "uefi-ish key present in snapshot response, asserting it is truthy"
  # sys.argv, not stdin: stdin is already the heredoc carrying the program.
  python3 - "$RAW_RESPONSE" <<'PYEOF'
import json
import re
import sys

data = json.loads(sys.argv[1])

def find_uefi(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if re.search("uefi", k, re.IGNORECASE):
                yield k, v
            yield from find_uefi(v)
    elif isinstance(obj, list):
        for item in obj:
            yield from find_uefi(item)

found = list(find_uefi(data))
if not found:
    sys.exit(0)

for key, value in found:
    if not value:
        print(f"ERROR: snapshot reports {key}={value!r}, expected a truthy EFI flag", file=sys.stderr)
        sys.exit(1)
    print(f"confirmed {key}={value!r}", file=sys.stderr)
PYEOF
else
  log "EFI flag not reported by the Vultr API (expected -- uefi is write-only on this endpoint)"
fi

log "snapshot $SNAPSHOT_ID ready"
