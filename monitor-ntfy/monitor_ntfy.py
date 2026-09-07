#!/usr/bin/env python3
"""Poll a streammonitor-central JSON status endpoint (array of streams) and
push ntfy/webhook/email alerts per-stream on state change.

Meant to run in a loop every minute. Only notifies on ok->bad and bad->ok
transitions per stream (state tracked in one file per stream), not on every
poll.

Config comes from the environment (see entrypoint.sh): STATUS_URL (required),
STATE_DIR, NOTIFY_CONFIG, plus the channel settings NTFY_URL, WEBHOOK_URL and
the email ones (EMAIL_PROVIDER, EMAIL_FROM, EMAIL_TO, RESEND_API_KEY,
SMTP_HOST, SMTP_PORT, SMTP_SECURE, SMTP_USER, SMTP_PASS). Those channel
settings are bootstrap defaults; NOTIFY_CONFIG - a JSON file shared with
streammonitor's dashboard, e.g. {"ntfyUrl": "...", "email": {...}} - overrides
them field by field, so credentials can live in .env while the dashboard
still owns whatever it saves.
"""

import json
import logging
import os
import re
import smtplib
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from email.message import EmailMessage
from email.utils import formataddr

# Sent on every outbound HTTP call. Resend sits behind Cloudflare, which
# blocks urllib's default agent outright ("error code: 1010"), so this isn't
# cosmetic - without it the Resend channel can't connect at all.
USER_AGENT = "streammonitor/0.1"

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


def post(req: urllib.request.Request, timeout: int = 10) -> None:
    """POSTs req, turning an HTTP error into one that carries the response body.

    Providers explain refusals in the body - Resend names the domain that
    isn't verified, ntfy says which topic is rate-limited - and without it the
    log just reads "HTTP Error 403: Forbidden", which isn't actionable.
    """
    try:
        urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read(2000).decode("utf-8", "replace").strip()
        except Exception:
            pass
        raise RuntimeError(f"HTTP {exc.code} from {req.full_url}: {detail or exc.reason}") from None


def send_ntfy(ntfy_url: str, title: str, message: str, priority: str) -> None:
    req = urllib.request.Request(
        ntfy_url,
        data=message.encode(),
        headers={
            "Title": title,
            "Priority": priority,
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )
    post(req)


def send_webhook(webhook_url: str, payload: dict) -> None:
    req = urllib.request.Request(
        webhook_url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
        method="POST",
    )
    post(req)


def format_sender(cfg: dict) -> str:
    """Builds the From header, e.g. 'Radiohjelpen Alerts <noreply@...>'.

    A bare noreply@ address reads badly in an inbox. An explicit
    "Name <addr>" already in the address field wins, so nothing is
    double-wrapped. formataddr handles the quoting rules.
    """
    address = cfg["from"]
    name = cfg.get("from_name") or ""
    if not name or "<" in address:
        return address
    return formataddr((name, address))


def send_resend(cfg: dict, subject: str, message: str) -> None:
    payload = {
        "from": format_sender(cfg),
        "to": cfg["to"],
        "subject": subject,
        "text": message,
    }
    req = urllib.request.Request(
        "https://api.resend.com/emails",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {cfg['resend_api_key']}",
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )
    post(req, timeout=20)


def send_smtp(cfg: dict, subject: str, message: str) -> None:
    msg = EmailMessage()
    msg["From"] = format_sender(cfg)
    msg["To"] = ", ".join(cfg["to"])
    msg["Subject"] = subject
    msg.set_content(message)

    if cfg["smtp_secure"]:
        smtp = smtplib.SMTP_SSL(cfg["smtp_host"], cfg["smtp_port"], timeout=20)
    else:
        smtp = smtplib.SMTP(cfg["smtp_host"], cfg["smtp_port"], timeout=20)
    with smtp:
        smtp.ehlo()
        # Opportunistic STARTTLS: upgrade when the server offers it, but don't
        # insist, so an unauthenticated local relay still works.
        if not cfg["smtp_secure"] and smtp.has_extn("starttls"):
            smtp.starttls()
            smtp.ehlo()
        if cfg["smtp_user"]:
            smtp.login(cfg["smtp_user"], cfg["smtp_pass"])
        smtp.send_message(msg)


def send_email(cfg: dict, subject: str, message: str) -> None:
    if cfg["provider"] == "resend":
        send_resend(cfg, subject, message)
    else:
        send_smtp(cfg, subject, message)


def parse_bool(value, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    text = str(value if value is not None else "").strip().lower()
    if not text:
        return default
    return text in ("1", "true", "yes", "on")


def parse_recipients(value) -> list[str]:
    """Splits a recipient list into individual addresses.

    Accepts a list, or a string separated by commas or semicolons (Outlook's
    habit) or just spaces. Display names stay intact: whitespace is only a
    separator when there's no comma/semicolon and no "Name <addr>" form to
    tear apart.
    """
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    text = str(value if value is not None else "").strip()
    if not text:
        return []
    if re.search(r"[,;]", text):
        parts = re.split(r"[,;]+", text)
    elif "<" in text:
        parts = [text]
    else:
        parts = re.split(r"\s+", text)
    return [item.strip() for item in parts if item.strip()]


def email_config(overrides: dict) -> dict | None:
    """Resolves the email channel from notify.json over the env defaults.

    Returns None when email isn't configured (no provider) or is configured
    but unusable - the latter is logged, since a half-filled-in email channel
    is a misconfiguration worth seeing rather than silently ignoring.
    """
    saved = overrides.get("email")
    saved = saved if isinstance(saved, dict) else {}

    def field(key: str, env_key: str):
        value = saved.get(key)
        if value is None or value == "":
            value = os.environ.get(env_key) or ""
        return value

    provider = str(field("provider", "EMAIL_PROVIDER")).strip().lower()
    # "off" is what the dashboard writes to switch email off despite an
    # EMAIL_PROVIDER default in the environment.
    if not provider or provider == "off":
        return None

    cfg = {
        "provider": provider,
        "from": str(field("from", "EMAIL_FROM")).strip(),
        "from_name": str(field("fromName", "EMAIL_FROM_NAME")).strip(),
        "to": parse_recipients(field("to", "EMAIL_TO")),
        "resend_api_key": str(field("resendApiKey", "RESEND_API_KEY")).strip(),
        "smtp_host": str(field("smtpHost", "SMTP_HOST")).strip(),
        "smtp_user": str(field("smtpUser", "SMTP_USER")).strip(),
        "smtp_pass": str(field("smtpPass", "SMTP_PASS")),
    }

    try:
        port = int(field("smtpPort", "SMTP_PORT") or 0)
    except (TypeError, ValueError):
        port = 0
    secure_raw = field("smtpSecure", "SMTP_SECURE")
    if not port:
        port = 465 if parse_bool(secure_raw, False) else 587
    cfg["smtp_port"] = port
    cfg["smtp_secure"] = parse_bool(secure_raw, port == 465)

    if provider not in ("resend", "smtp"):
        logger.error("Unknown EMAIL_PROVIDER %r (expected \"resend\" or \"smtp\"), email disabled", provider)
        return None
    if not cfg["from"] or not cfg["to"]:
        logger.error("Email provider %s is set but sender/recipients are missing, email disabled", provider)
        return None
    if provider == "resend" and not cfg["resend_api_key"]:
        logger.error("Email provider resend is set but no API key is configured, email disabled")
        return None
    if provider == "smtp" and not cfg["smtp_host"]:
        logger.error("Email provider smtp is set but no SMTP host is configured, email disabled")
        return None
    return cfg


def load_notify_overrides(path: str) -> dict:
    """Reads {"ntfyUrl": ..., "webhookUrl": ..., "email": {...}} from the dashboard.

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
    email_cfg = email_config(overrides)

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
                    send_ntfy(ntfy_url, f"Streammonitor {name}: recovered", message, "default")
                else:
                    send_ntfy(ntfy_url, f"Streammonitor {name}: ALERT", message, "urgent")
            if webhook_url:
                send_webhook(webhook_url, {
                    "name": name,
                    "event": "recovered" if recovered else "alert",
                    "state": state,
                    "message": message,
                    "text": message,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                })
            if email_cfg:
                subject = f"Streammonitor {name}: {'recovered' if recovered else 'ALERT'}"
                send_email(email_cfg, subject, message)
            if not ntfy_url and not webhook_url and not email_cfg:
                logger.warning("[%s] state changed but no notification channel configured, alert not sent", name)
        except Exception as exc:
            logger.error("[%s] Failed to send notification: %s", name, exc)
            had_failure = True
            continue

        with open(state_file, "w") as f:
            f.write(state)

    return 1 if had_failure else 0


if __name__ == "__main__":
    sys.exit(main())
