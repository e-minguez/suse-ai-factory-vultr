#!/usr/bin/env bash
# Invoked from snapshot.tf via a local-exec provisioner, on the OPERATOR's
# machine (not the jumphost). Polls IMAGE_URL -- the raw the jumphost serves --
# until it answers 200, so create-from-url is only called once the file is
# actually reachable from the internet. Needs no API key: just curl.
set -euo pipefail

: "${IMAGE_URL:?IMAGE_URL must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"

log() {
  echo "[wait-for-image] $*" >&2
}

HOST=$(printf '%s' "$IMAGE_URL" | cut -d/ -f3)
log "polling for the raw image on $HOST (timeout ${TIMEOUT_SECONDS}s, every ${POLL_SECONDS}s)"

START_TIME=$(date +%s)
LAST_PROGRESS_LOG=$START_TIME

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TIME))

  # HEAD, so a poll never pulls the image. http.server answers HEAD with the
  # same status as GET.
  if curl -4 -fsS -I -o /dev/null --max-time 10 "$IMAGE_URL" 2>/dev/null; then
    log "raw image is being served after ${ELAPSED}s"
    exit 0
  fi

  if [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
    log "ERROR: timed out after ${ELAPSED}s waiting for $HOST to serve the raw image."
    log "Either the build failed or port 80 is closed. Check the build log on the jumphost:"
    log "  ssh <jumphost> tail -f /var/log/elemental-factory.log"
    log "and that image_import_port_open is true -- deploy.sh resets it before pass 1; a bare"
    log "'terraform apply' after pass 2 leaves it false and the rule absent."
    exit 1
  fi

  if [ $((NOW - LAST_PROGRESS_LOG)) -ge 60 ]; then
    log "still waiting (${ELAPSED}s elapsed) -- the jumphost is most likely still building"
    LAST_PROGRESS_LOG=$NOW
  fi

  sleep "$POLL_SECONDS"
done
