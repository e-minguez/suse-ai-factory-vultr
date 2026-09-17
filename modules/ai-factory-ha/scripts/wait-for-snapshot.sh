#!/usr/bin/env bash
# Invoked from snapshot.tf via a local-exec provisioner, on the OPERATOR's
# machine (not the jumphost). Polls the Vultr API for a snapshot matching
# SNAPSHOT_DESCRIPTION and waits until it is "complete". Idempotent: if the
# snapshot already exists and is complete, returns immediately, so a
# re-applied/interrupted apply resumes cleanly.
#
# Needs only curl + python3 (json module) -- no jq dependency.
set -euo pipefail

: "${SNAPSHOT_DESCRIPTION:?SNAPSHOT_DESCRIPTION must be set}"
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

# Fetches every snapshot page (per_page=500, following meta.links.next) and
# prints "<id>\t<status>" for the first one whose description matches exactly.
# No jq: python3 does the JSON walking.
#
# Exit codes are three-way on purpose, because the caller has to tell "the
# build hasn't produced it yet" apart from "the API didn't answer":
#   0  found, printed
#   1  the API answered and has no snapshot with that description
#   2  transient API failure (5xx or a network error) -- nothing was learned
find_snapshot() {
  python3 - "$API_BASE" "$VULTR_API_KEY" "$SNAPSHOT_DESCRIPTION" <<'PYEOF'
import json
import socket
import sys
import urllib.error
import urllib.request

# Force IPv4: on a dual-stack host, an IP-restricted VULTR_API_KEY gets 401
# "Unauthorized IP address: <ipv6>" because urllib prefers the AAAA record.
# Same failure the jumphost's factory script hits.
_getaddrinfo = socket.getaddrinfo
socket.getaddrinfo = lambda host, port, family=0, type=0, proto=0, flags=0: (
    _getaddrinfo(host, port, socket.AF_INET, type, proto, flags)
)

api_base, api_key, description = sys.argv[1], sys.argv[2], sys.argv[3]
url = f"{api_base}/snapshots?per_page=500"

while url:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {api_key}"})
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as exc:
        # 5xx is a platform-side outage or maintenance window; only a 4xx
        # says anything about our request.
        if exc.code >= 500:
            print(f"{exc.code} {exc.reason}", file=sys.stderr)
            sys.exit(2)
        # 401/403 is a wrong or IP-restricted key, 429 is a rate limit we are
        # not going to outwait -- polling for another hour helps neither.
        print(f"{exc.code} {exc.reason}: {exc.read(2048).decode(errors='replace')}", file=sys.stderr)
        sys.exit(3)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        print(f"network error: {exc}", file=sys.stderr)
        sys.exit(2)

    for snap in data.get("snapshots", []):
        if snap.get("description") == description:
            print(f"{snap.get('id')}\t{snap.get('status')}")
            sys.exit(0)

    next_url = data.get("meta", {}).get("links", {}).get("next")
    url = next_url if next_url else None

sys.exit(1)
PYEOF
}

log "polling for snapshot description \"$SNAPSHOT_DESCRIPTION\" (timeout ${TIMEOUT_SECONDS}s, every ${POLL_SECONDS}s)"

START_TIME=$(date +%s)
LAST_PROGRESS_LOG=$START_TIME
SNAPSHOT_ID=""
SNAPSHOT_STATUS=""

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TIME))

  RC=0
  RESULT=$(find_snapshot) || RC=$?

  case "$RC" in
    0)
      SNAPSHOT_ID=$(printf '%s' "$RESULT" | cut -f1)
      SNAPSHOT_STATUS=$(printf '%s' "$RESULT" | cut -f2)

      if [ "$SNAPSHOT_STATUS" = "complete" ]; then
        log "snapshot $SNAPSHOT_ID (\"$SNAPSHOT_DESCRIPTION\") is complete after ${ELAPSED}s"
        break
      fi

      if [ "$SNAPSHOT_STATUS" != "pending" ]; then
        log "ERROR: snapshot $SNAPSHOT_ID (\"$SNAPSHOT_DESCRIPTION\") is in unexpected/terminal status \"$SNAPSHOT_STATUS\", not \"pending\" or \"complete\""
        exit 1
      fi
      ;;
    1)
      : # the API answered, the snapshot is not there yet -- keep waiting
      ;;
    2)
      # Not fatal and does not reset the clock: the build proceeds on Vultr's
      # side whether or not their API answers. Logged every time, since a run
      # of these explains an otherwise inexplicable timeout.
      log "transient: the Vultr API did not answer this poll (see the error above); still waiting (${ELAPSED}s elapsed)"
      ;;
    *)
      log "ERROR: the Vultr API rejected the request (see the error above). This is a credentials or rate-limit problem, not a build problem -- VULTR_API_KEY must be valid and, if it is IP-restricted, must allow this machine's address."
      exit 1
      ;;
  esac

  if [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
    log "ERROR: timed out after ${ELAPSED}s waiting for snapshot \"$SNAPSHOT_DESCRIPTION\" to become complete."
    log "A missing snapshot and a failed image build look identical from here, by design -- check the build log on the jumphost:"
    log "  ssh <jumphost> tail -f /var/log/elemental-factory.log"
    exit 1
  fi

  if [ $((NOW - LAST_PROGRESS_LOG)) -ge 60 ]; then
    if [ -n "$SNAPSHOT_ID" ]; then
      log "still waiting: snapshot $SNAPSHOT_ID status=$SNAPSHOT_STATUS (${ELAPSED}s elapsed)"
    else
      log "still waiting: no snapshot named \"$SNAPSHOT_DESCRIPTION\" found yet (${ELAPSED}s elapsed) -- the jumphost may still be building"
    fi
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

log "snapshot \"$SNAPSHOT_DESCRIPTION\" ($SNAPSHOT_ID) ready"
