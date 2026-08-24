#!/usr/bin/env python3
"""Poll a streammonitor-central JSON status endpoint (array of streams) and
push ntfy/webhook alerts per-stream on state change.

Meant to run in a loop every minute. Only notifies on ok->bad and bad->ok
transitions per stream (state tracked in one file per stream), not on every
poll.

Config is read entirely from the environment (see entrypoint.sh): STATUS_URL
(required), STATE_DIR, NTFY_URL, WEBHOOK_URL, NOTIFY_CONFIG. NTFY_URL and
WEBHOOK_URL are bootstrap defaults; if NOTIFY_CONFIG (a JSON file shared with
streammonitor's dashboard, e.g. {"ntfyUrl": "...", "webhookUrl": "..."})
exists and sets a value, that overrides the env var default.
"""

import json
import logging
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone

SILENCE_THRESHOLD_S = 10
SILENCE_ERROR_THRESHOLD_S = 60
OFFLINE_THRESHOLD_S = 10

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("streammonitor-monitor")


def fetch_all(status_url: str) -> list[dict]:
    with urllib.request.urlopen(status_url, timeout=10) as resp:
        return json.load(resp)


def stream_state(entry: dict) -> tuple[str, str, int]:
    """Returns (state, message, log_level) for one stream's status entry.

    state is "ok", "silence", or "offline"; log_level is the logging level
    the caller should log message at. Silence starts out as a WARNING and
    escalates to an ERROR once it's dragged on past SILENCE_ERROR_THRESHOLD_S,
    without changing the "silence" state used for ntfy alert transitions.
    """
    name = entry.get("name", "?")
    silence_duration = entry.get("silenceDuration", 0) or 0
    offline_duration = entry.get("offlineDuration", 0) or 0
    stream_url = entry.get("url", "?")

    if offline_duration > OFFLINE_THRESHOLD_S:
        return "offline", f"[{name}] Stream offline for {offline_duration}s ({stream_url})", logging.ERROR

    if silence_duration > SILENCE_THRESHOLD_S:
        level = logging.ERROR if silence_duration > SILENCE_ERROR_THRESHOLD_S else logging.WARNING
        return "silence", f"[{name}] Silence detected for {silence_duration}s ({stream_url})", level

    return "ok", f"[{name}] Stream OK ({stream_url})", logging.INFO


def send_ntfy(ntfy_url: str, title: str, message: str, priority: str, tags: str) -> None:
    req = urllib.request.Request(
        ntfy_url,
        data=message.encode(),
        headers={
            "Title": title,
            "Priority": priority,
            "Tags": tags,
        },
        method="POST",
    )
    urllib.request.urlopen(req, timeout=10)


def send_webhook(webhook_url: str, payload: dict) -> None:
    req = urllib.request.Request(
        webhook_url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    urllib.request.urlopen(req, timeout=10)


def load_notify_overrides(path: str) -> dict:
    """Reads {"ntfyUrl": ..., "webhookUrl": ...} written by the dashboard.

    Missing file or bad JSON just means "no overrides yet" - not an error.
    """
    try:
        with open(path) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def state_file_for(state_dir: str, name: str) -> str:
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    return os.path.join(state_dir, f"{safe_name}.state")


def main() -> int:
    status_url = os.environ.get("STATUS_URL")
    if not status_url:
        logger.error("STATUS_URL env var required")
        return 1

    state_dir = os.environ.get("STATE_DIR") or "/var/lib/streammonitor-monitor"
    notify_config_path = os.environ.get("NOTIFY_CONFIG") or "/app/config/notify.json"

    try:
        entries = fetch_all(status_url)
    except Exception as exc:
        logger.error("Can't reach streammonitor-central: %s", exc)
        return 1

    overrides = load_notify_overrides(notify_config_path)
    ntfy_url = overrides.get("ntfyUrl") or os.environ.get("NTFY_URL") or None
    webhook_url = overrides.get("webhookUrl") or os.environ.get("WEBHOOK_URL") or None

    os.makedirs(state_dir, exist_ok=True)
    had_failure = False

    for entry in entries:
        name = entry.get("name", "?")
        state, message, level = stream_state(entry)
        logger.log(level, message)

        state_file = state_file_for(state_dir, name)
        try:
            with open(state_file) as f:
                last_state = f.read().strip()
        except FileNotFoundError:
            last_state = None

        if state == last_state:
            continue

        logger.info("[%s] state changed: %s -> %s", name, last_state, state)
        recovered = state == "ok"
        try:
            if ntfy_url:
                if recovered:
                    send_ntfy(ntfy_url, f"Streammonitor {name}: recovered", message, "default", "white_check_mark")
                else:
                    send_ntfy(ntfy_url, f"Streammonitor {name}: ALERT", message, "urgent", "rotating_light")
            if webhook_url:
                send_webhook(webhook_url, {
                    "name": name,
                    "event": "recovered" if recovered else "alert",
                    "state": state,
                    "message": message,
                    "text": message,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                })
            if not ntfy_url and not webhook_url:
                logger.warning("[%s] state changed but no ntfy/webhook URL configured, alert not sent", name)
        except Exception:
            logger.exception("[%s] Failed to send notification", name)
            had_failure = True
            continue

        with open(state_file, "w") as f:
            f.write(state)

    return 1 if had_failure else 0


if __name__ == "__main__":
    sys.exit(main())
