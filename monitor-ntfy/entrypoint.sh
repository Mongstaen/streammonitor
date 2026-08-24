#!/bin/sh
set -eu

: "${STATUS_URL:?STATUS_URL env var required}"
export STATE_DIR="${STATE_DIR:-/var/lib/streammonitor-monitor}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"

# NTFY_URL/WEBHOOK_URL are optional bootstrap defaults - monitor_ntfy.py also
# checks NOTIFY_CONFIG (a file shared with streammonitor's dashboard) for
# values saved there, which take precedence.
while true; do
  python3 /app/monitor_ntfy.py || true
  sleep "$POLL_INTERVAL"
done
