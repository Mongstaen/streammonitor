#!/bin/sh
set -eu

: "${STATUS_URL:?STATUS_URL env var required}"
: "${NTFY_URL:?NTFY_URL env var required}"
STATE_DIR="${STATE_DIR:-/var/lib/streammonitor-monitor}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"

while true; do
  python3 /app/monitor_ntfy.py "$STATUS_URL" "$NTFY_URL" "$STATE_DIR" || true
  sleep "$POLL_INTERVAL"
done
