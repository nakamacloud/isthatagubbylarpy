#!/bin/sh
# Instant tunnel-URL publisher: follows the cloudflared logs and runs the
# updater the moment a (new) URL appears, instead of waiting for cron.
# Survives container restarts: when the log stream ends, it re-attaches.
set -eu
CONTAINER="${CLOUDFLARED_CONTAINER:-cloudflared}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATER="${UPDATER:-$SCRIPT_DIR/update-tunnel-url.sh}"
LAST_FILE="${LAST_FILE:-${TMPDIR:-/tmp}/tunnel-url-last}"
log() { echo "$(date -u +%FT%TZ) $*"; }
[ -x "$UPDATER" ] || { log "updater not executable: $UPDATER"; exit 1; }
log "watching container $CONTAINER"
while true; do
  while ! docker logs --tail 1 "$CONTAINER" >/dev/null 2>&1; do sleep 5; done
  docker logs -f --tail 100 "$CONTAINER" 2>&1 | grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' | while read -r url; do
    last=""
    [ -f "$LAST_FILE" ] && last="$(cat "$LAST_FILE")"
    if [ "$url" != "$last" ]; then
      log "new URL: $url"
      if sh "$UPDATER"; then printf '%s' "$url" > "$LAST_FILE"; fi
    fi
  done
  log "log stream ended (container restarting?) - re-attaching in 5s"
  sleep 5
done