# streammonitor

A fork of [mairlist/streammonitor](https://github.com/mairlist/streammonitor)
(by Torben Weibert / mairlist) that monitors *multiple* Icecast/Shoutcast
MP3 streams from a single container instead of one container per stream, so
on-air status for several stations can be centralized on one host rather
than deployed per client.

Licensed AGPL-3.0, same as upstream — see [LICENSE](LICENSE).

<img width="2004" height="1318" alt="CleanShot 2026-08-24 at 08 37 03@2x" src="https://github.com/user-attachments/assets/6588a5ad-c490-4aab-887a-68ae5a55bc6b" />

## How it works

For each configured stream, streammonitor spawns `curl <url> | lame
--decode`, decodes the MP3 to raw PCM, and checks whether the samples stay
below `SILENCE_THRESHOLD` (i.e. dead air) or the process dies outright
(i.e. the stream is offline). It exposes the result of all streams as JSON
over HTTP so something else — a dashboard, `monitor-ntfy/` in this repo, a
cron job — can poll it and act on the result.

It does not send any notifications itself. If you want alerts, run
`monitor-ntfy/` alongside it (see [Alerting](#alerting) below) — it can push
to ntfy, a generic JSON webhook, and email via either Resend or SMTP. Every
channel can be configured from the [dashboard](#dashboard) once it's running,
from `.env`, or a mix of both.

## Quick start

Requires Docker and Docker Compose.

1. Clone this repo and `cd` into it.
2. Copy the example stream list and point it at your own streams:

   ```sh
   cp config/streams.example.yml config/streams.yml
   ```

   Edit `config/streams.yml`, e.g.:

   ```yaml
   streams:
     - name: station-a
       url: https://icecast.example.com/station-a
     - name: station-b
       url: https://icecast.example.com/station-b
   ```

3. Start it:

   ```sh
   docker compose up -d --build
   ```

4. Open `http://localhost:8000/dashboard` in a browser. You should see one
   card per stream. A freshly started stream shows red ("offline") for the
   first second or two until `curl`/`lame` connect — that's normal.
5. (Optional) Set up alerting, either way round:

   - **From the dashboard** — in the **Notifications** panel, fill in an
     ntfy topic URL, a webhook URL, and/or the email fields, then click
     **Save & send test** and confirm you actually receive it (for ntfy,
     install the [ntfy app](https://ntfy.sh/) and subscribe to your topic
     first).
   - **From `.env`** — `cp .env.example .env`, fill in what you need, and
     `docker compose up -d`. Handy for keeping an SMTP password or Resend
     API key out of the UI, and for provisioning a host from config.

   See [Alerting](#alerting) for what each channel does and how the two
   sources combine.

If you skip step 5, `monitor-ntfy` still starts but sends nothing until a
channel is configured — streammonitor itself works fine either way,
alerting is just inert until then.

## Configuration

Everything lives in `config/`, which both containers share as a mounted
volume (`streammonitor` can write to it, `monitor-ntfy` only reads it):

- `config/streams.yml` — the streams to monitor (see Quick start).
- `config/notify.json` — notification settings (ntfy, webhook, email),
  written by the dashboard's Notifications panel. Not required to exist;
  alerting is just inert until something's saved there or set in `.env`.

Notification credentials come from the environment, and `docker compose`
reads a `.env` file next to `docker-compose.yml` automatically — so
`cp .env.example .env` and edit that rather than putting secrets in the
compose file. See [Alerting](#alerting) for the full list.

Plus these environment variables, settable in `docker-compose.yml`:

- `STREAMS_CONFIG` (optional, default `/app/config/streams.yml`) — path
  *inside the container* to the YAML file listing the streams to monitor.
  You normally don't need to change this; `docker-compose.yml` already
  mounts `config/` to `/app/config`. The format is:

  ```yaml
  streams:
    - name: station-a
      url: https://icecast.example.com/station-a
    - name: station-b
      url: https://icecast.example.com/station-b
  ```

  `name` is used to key the stream in the API (`GET /:name`) and in
  per-stream ntfy alert state — keep it stable once alerts are wired up,
  renaming it will look like the old stream went offline and a new one
  came online.
- `SILENCE_THRESHOLD` (optional, default `-20` dBFS) — audio level below
  which a stream counts as silent. Applies to all streams; a more negative
  number (e.g. `-30`) is a *more* lenient/quieter threshold.
- `CHECK_INTERVAL` (optional, default `1000` ms) — how often each stream's
  decoded audio is sampled for silence.
- `HTTP_PORT` (optional, default `8000`) — port the status API listens on
  inside the container. Change the left-hand side of the `ports:` mapping
  in `docker-compose.yml` to expose it on a different host port.

## HTTP interface

- `GET /` — array of status objects, one per configured stream, each shaped
  like upstream's single-stream response plus a `name` field:

  ```json
  [
    {
      "name": "station-a",
      "url": "https://icecast.example.com/station-a",
      "silenceThreshold": -20,
      "status": "OK",
      "now": "2026-08-24T12:53:22.091Z",
      "onlineSince": "2026-08-24T12:53:05.629Z",
      "onlineDuration": 16,
      "offlineSince": null,
      "offlineDuration": 0,
      "silenceSince": "2026-08-24T12:53:21.903Z",
      "silenceDuration": 0
    }
  ]
  ```

  `status` is `"OK"` once the stream has actually produced decoded audio
  and stays that way while it keeps flowing; `"ERROR"` before that first
  audio arrives or after the decoder process dies (stream unreachable,
  connection dropped, URL doesn't serve audio, etc.) — it does *not* by
  itself mean silence; check `silenceDuration` for that.
- `GET /:name` — single stream's status object, 404 if `name` isn't
  configured.
- `GET /:name/value/:key` — single field from one stream's status, as
  upstream's `/value/:key` did. E.g. `GET /station-a/value/silenceDuration`.

## Dashboard

`GET /dashboard` is a small self-contained web UI (no build step, no
external assets) that:

- Shows a live-refreshing (every 3s) card per stream, colored by the same
  ok/silence/offline classification `monitor-ntfy` uses for alerts.
- Has a **Notifications** panel to set an ntfy topic URL, a webhook URL,
  and/or email (Resend or SMTP), with a **Save & send test** button that
  fires one real notification through every configured channel immediately
  so you can confirm it actually arrives, rather than waiting for a real
  stream failure.

Anything already set in the environment shows up in the panel as a
greyed-out placeholder and stays in force unless you type over it. Secrets
(`RESEND_API_KEY`, `SMTP_PASS`) are never sent to the browser — a saved one
shows as "saved - leave blank to keep it", so you can edit the port without
retyping the password.

Settings are exposed as a small JSON API too, if you want to script it:

- `GET /api/settings` — current `{ntfyUrl, webhookUrl, email, envDefaults}`.
  `email` is what's saved in `config/notify.json`, with secrets replaced by
  the booleans `hasResendApiKey`/`hasSmtpPass`; `envDefaults` mirrors the
  same shape for what the environment supplies.
- `POST /api/settings` — body `{ntfyUrl, webhookUrl, email}`; omit or send
  an empty string for a field to leave it to the environment. URLs must be
  `http://` or `https://`. `email` takes
  `{provider, from, to, resendApiKey, smtpHost, smtpPort, smtpSecure, smtpUser, smtpPass}`
  — `provider` is `"resend"`, `"smtp"`, or `"off"`, and a blank secret keeps
  whatever is already saved. Overwrites `config/notify.json` in full (not a
  merge), and responds with the same shape as `GET`. A config that can't
  work (no recipients, SMTP without a host, and so on) is rejected with
  400 and an explanation rather than saved.
- `POST /api/settings/test` — sends one test notification through each
  currently-configured channel; responds with per-channel `{ok, statusCode}`
  or `{ok: false, error}`, where `error` carries the provider's own message
  when there is one.

This API has no authentication, same as the rest of streammonitor — see
the security note under [Deploying](#deploying).

## Alerting

`monitor-ntfy/` is a separate small container that polls `GET /` on the
main monitor and, per stream, when it transitions between OK and a bad
state (offline or silence >10s) — and again on recovery — pushes:

- an [ntfy](https://ntfy.sh) push notification, if an ntfy topic URL is
  configured,
- a generic JSON webhook POST, if a webhook URL is configured. The body is
  `{name, event, state, message, text, timestamp}` — `text` duplicates
  `message` since that's the field Slack/Discord/Mattermost incoming
  webhooks look for by default, so simple integrations need no extra
  templating, and/or
- a plain-text email, if an email provider is configured. Subject is
  `Streammonitor <stream>: ALERT` or `Streammonitor <stream>: recovered`,
  body is the same one-line message as the other channels.

All configured channels fire for the same transition; they're not
either/or.

State is tracked per stream under `STATE_DIR` so a restart doesn't re-fire
alerts for streams that were already broken.

### Email: Resend or SMTP

Pick one of two providers with `EMAIL_PROVIDER` (or the dashboard's
Provider dropdown):

- `resend` — POSTs to the [Resend](https://resend.com) HTTP API with
  `RESEND_API_KEY`. Nothing to run yourself and no SMTP ports to get
  through, but the sending domain has to be verified in Resend first (use
  `onboarding@resend.dev` as the sender while testing).
- `smtp` — talks to any SMTP server: your own relay, a corporate
  Exchange/Microsoft 365 host, Postmark, Mailgun, whatever. `SMTP_PORT`
  defaults to `587` with opportunistic STARTTLS; port `465` (or
  `SMTP_SECURE=true`) means implicit TLS. Leave `SMTP_USER`/`SMTP_PASS`
  unset for a relay that doesn't want authentication.

`EMAIL_TO` (and the dashboard's **To** field) takes several recipients,
separated by commas or semicolons — so an Outlook-style
`a@example.com; b@example.com` paste works, as does
`Ops <a@example.com>; On Call <b@example.com>`. A JSON array works too when
`config/notify.json` is written by hand.

### Where settings come from

Two sources, and they combine field by field:

1. The environment — `docker-compose.yml`, or (better, for secrets) a
   `.env` file beside it, which `docker compose` reads automatically. Start
   from `.env.example`.
2. `config/notify.json`, written by the [dashboard](#dashboard)'s
   Notifications panel. `monitor-ntfy` picks changes up on its next poll
   (up to `POLL_INTERVAL` later).

`config/notify.json` wins wherever it sets a value, and the environment
fills in the rest — so you can keep `SMTP_PASS` in `.env` while still
changing recipients from the dashboard. Choosing **Off** in the dashboard's
Provider dropdown records an explicit "off" that beats an `EMAIL_PROVIDER`
default from the environment, and switching email off also drops any
credentials stored in `notify.json`.

To actually receive ntfy alerts, install the [ntfy app](https://ntfy.sh/)
(or use a browser) and subscribe to your topic. Anyone who knows an ntfy
topic name can subscribe to it or publish to it, so treat the topic name
like a shared secret — pick something unguessable, or self-host ntfy.

Environment variables for `monitor-ntfy`:

- `STATUS_URL` (required) — URL of the main streammonitor's `GET /`
  endpoint, e.g. `http://streammonitor:8000/` when both run under the same
  Compose project.
- `NTFY_URL` (optional) — full ntfy topic URL to POST alerts to.
- `WEBHOOK_URL` (optional) — full webhook URL to POST alerts to.
- `EMAIL_PROVIDER` (optional) — `resend`, `smtp`, or unset for no email.
- `EMAIL_FROM` (optional) — sender address. `Name <addr@example.com>` also
  works, and wins over `EMAIL_FROM_NAME`.
- `EMAIL_FROM_NAME` (optional) — display name shown in the recipient's
  inbox instead of a bare `noreply@` address, e.g. `Streammonitor Alerts`.
- `EMAIL_TO` (optional) — one or more recipients, separated by commas or
  semicolons. `Name <addr@example.com>` entries are kept intact.
- `RESEND_API_KEY` (optional) — required when `EMAIL_PROVIDER=resend`.
- `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`, `SMTP_PASS`
  (optional) — used when `EMAIL_PROVIDER=smtp`; only `SMTP_HOST` is
  required, see above for the defaults.
- `STATE_DIR` (optional, default `/var/lib/streammonitor-monitor`) —
  where per-stream last-known-state files are kept. Should be a persistent
  volume (already set up in `docker-compose.yml`) so restarts don't
  re-notify for streams that were already down.
- `POLL_INTERVAL` (optional, default `60` seconds) — how often to poll the
  main monitor.

The channel variables are also read by the main `streammonitor` container,
since the dashboard's **Save & send test** button sends through the same
channels — `docker-compose.yml` already passes them to both.

If no channel is configured anywhere, state changes are still logged but
nothing is sent. An email channel that's switched on but unusable (no
recipients, say) is logged as an error each poll rather than failing
quietly.

## Deploying

`docker-compose.yml` here is a starting point covering both containers:

```sh
docker compose up -d --build
```

Things you'll likely want to change for a real deployment:

- `config/streams.yml` — your actual stations (see Quick start).
- Notification settings — set them from the [dashboard](#dashboard) or in
  `.env` (`cp .env.example .env`), not in `docker-compose.yml` itself,
  which is committed.
- `ports` — which host port the status API is exposed on, if 8000
  conflicts with something else.
- Put something in front of port 8000 (reverse proxy, firewall rule) if
  the host is reachable from the internet — the status API, dashboard, and
  `/api/settings` all have no authentication. Anyone who can reach port
  8000 can read your stream URLs, repoint your notification webhook or
  SMTP server (which could be used to spam an arbitrary internal or
  external host, SSRF-adjacent), and send mail through whatever email
  credentials are configured — don't expose this port publicly without a
  proxy that adds auth. `/api/settings` never hands back a stored API key
  or SMTP password, but it will happily use them.

## License

AGPL-3.0, same as upstream — see [LICENSE](LICENSE). Forked from
[mairlist/streammonitor](https://github.com/mairlist/streammonitor) by
Torben Weibert / mairlist.
