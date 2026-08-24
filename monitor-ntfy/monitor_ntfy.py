#!/usr/bin/env python3
"""Poll a streammonitor-central JSON status endpoint (array of streams) and
push ntfy alerts per-stream on state change.

Meant to run in a loop every minute. Only notifies on ok->bad and bad->ok
transitions per stream (state tracked in one file per stream), not on every
poll.

Usage: monitor_ntfy.py <status_url> <ntfy_topic_url> [state_dir]
"""

import json
import logging
import os
import re
import sys
import urllib.request

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


def state_file_for(state_dir: str, name: str) -> str:
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    return os.path.join(state_dir, f"{safe_name}.state")


def main() -> int:
    if len(sys.argv) not in (3, 4):
        logger.error("usage: monitor_ntfy.py <status_url> <ntfy_topic_url> [state_dir]")
        return 1

    status_url, ntfy_url = sys.argv[1], sys.argv[2]
    state_dir = sys.argv[3] if len(sys.argv) == 4 else "/var/lib/streammonitor-monitor"

    try:
        entries = fetch_all(status_url)
    except Exception as exc:
        logger.error("Can't reach streammonitor-central: %s", exc)
        return 1

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
        try:
            if state == "ok":
                send_ntfy(ntfy_url, f"Streammonitor {name}: recovered", message, "default", "white_check_mark")
            else:
                send_ntfy(ntfy_url, f"Streammonitor {name}: ALERT", message, "urgent", "rotating_light")
        except Exception:
            logger.exception("[%s] Failed to send ntfy notification", name)
            had_failure = True
            continue

        with open(state_file, "w") as f:
            f.write(state)

    return 1 if had_failure else 0


if __name__ == "__main__":
    sys.exit(main())
