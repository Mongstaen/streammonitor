# streammonitor

A fork of [mairlist/streammonitor](https://github.com/mairlist/streammonitor)
(by Torben Weibert / mairlist) that monitors *multiple* Icecast/Shoutcast
MP3 streams from a single container instead of one container per stream, so
on-air status for several stations can be centralized on one host rather
than deployed per client.

Licensed AGPL-3.0, same as upstream — see [LICENSE](LICENSE).

## How it works

For each configured stream, streammonitor spawns `curl <url> | lame
--decode`, decodes the MP3 to raw PCM, and checks whether the samples stay
below `SILENCE_THRESHOLD` (i.e. dead air) or the process dies outright
(i.e. the stream is offline). It exposes the result of all streams as JSON
over HTTP so something else — a dashboard, `monitor-ntfy/` in this repo, a
cron job — can poll it and act on the result.

It does not send any notifications itself. If you want alerts, run
`monitor-ntfy/` alongside it (see [Alerting](#alerting) below) — or just
configure it from the [dashboard](#dashboard) once it's running.

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
5. (Optional) In the dashboard's **Notifications** panel, paste in an ntfy
   topic URL and/or a webhook URL, click **Save & send test**, and confirm
   you actually receive it (install the [ntfy app](https://ntfy.sh/) and
   subscribe to your topic first). See [Alerting](#alerting) for details.

If you skip step 5, `monitor-ntfy` still starts but sends nothing until a
channel is configured — streammonitor itself works fine either way,
alerting is just inert until then.

## Configuration

Everything lives in `config/`, which both containers share as a mounted
volume (`streammonitor` can write to it, `monitor-ntfy` only reads it):

- `config/streams.yml` — the streams to monitor (see Quick start).
- `config/notify.json` — ntfy/webhook settings, written by the dashboard's
  Notifications panel. Not required to exist; alerting is just inert until
  something's saved there.

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
- Has a **Notifications** panel to set an ntfy topic URL and/or a webhook
  URL, with a **Save & send test** button that fires one real notification
  immediately so you can confirm it actually arrives, rather than waiting
  for a real stream failure.

Settings are exposed as a small JSON API too, if you want to script it:

- `GET /api/settings` — current `{ntfyUrl, webhookUrl}` (either key may be
  absent).
- `POST /api/settings` — body `{ntfyUrl, webhookUrl}`; omit or send an
  empty string for a field to disable that channel. Values must be
  `http://` or `https://` URLs. Overwrites `config/notify.json` in full
  (not a merge).
- `POST /api/settings/test` — sends one test notification through each
  currently-saved channel; responds with per-channel `{ok, statusCode}` or
  `{ok: false, error}`.

This API has no authentication, same as the rest of streammonitor — see
the security note under [Deploying](#deploying).

## Alerting

`monitor-ntfy/` is a separate small container that polls `GET /` on the
main monitor and, per stream, when it transitions between OK and a bad
state (offline or silence >10s) — and again on recovery — pushes:

- an [ntfy](https://ntfy.sh) push notification, if an ntfy topic URL is
  configured, and/or
- a generic JSON webhook POST, if a webhook URL is configured. The body is
  `{name, event, state, message, text, timestamp}` — `text` duplicates
  `message` since that's the field Slack/Discord/Mattermost incoming
  webhooks look for by default, so simple integrations need no extra
  templating.

State is tracked per stream under `STATE_DIR` so a restart doesn't re-fire
alerts for streams that were already broken.

The easiest way to configure both is the [dashboard](#dashboard)'s
Notifications panel — it writes `config/notify.json`, which `monitor-ntfy`
picks up on its next poll (up to `POLL_INTERVAL` later). To actually
receive ntfy alerts, install the [ntfy app](https://ntfy.sh/) (or use a
browser) and subscribe to your topic. Anyone who knows an ntfy topic name
can subscribe to it or publish to it, so treat the topic name like a
shared secret — pick something unguessable, or self-host ntfy.

Environment variables (set in `docker-compose.yml`) act only as bootstrap
defaults — whatever's saved in `config/notify.json` via the dashboard
always takes precedence over these:

- `STATUS_URL` (required) — URL of the main streammonitor's `GET /`
  endpoint, e.g. `http://streammonitor:8000/` when both run under the same
  Compose project.
- `NTFY_URL` (optional) — full ntfy topic URL to POST alerts to.
- `WEBHOOK_URL` (optional) — full webhook URL to POST alerts to.
- `STATE_DIR` (optional, default `/var/lib/streammonitor-monitor`) —
  where per-stream last-known-state files are kept. Should be a persistent
  volume (already set up in `docker-compose.yml`) so restarts don't
  re-notify for streams that were already down.
- `POLL_INTERVAL` (optional, default `60` seconds) — how often to poll the
  main monitor.

If neither an ntfy topic nor a webhook is configured anywhere, state
changes are still logged but nothing is sent.

## Deploying

`docker-compose.yml` here is a starting point covering both containers:

```sh
docker compose up -d --build
```

Things you'll likely want to change for a real deployment:

- `config/streams.yml` — your actual stations (see Quick start).
- Notification settings — set from the [dashboard](#dashboard) rather than
  the compose file, once it's running.
- `ports` — which host port the status API is exposed on, if 8000
  conflicts with something else.
- Put something in front of port 8000 (reverse proxy, firewall rule) if
  the host is reachable from the internet — the status API, dashboard, and
  `/api/settings` all have no authentication. Anyone who can reach port
  8000 can read your stream URLs and repoint your notification webhook,
  which could be used to spam an arbitrary internal or external URL
  (SSRF-adjacent) — don't expose this port publicly without a proxy that
  adds auth.

## License

AGPL-3.0, same as upstream — see [LICENSE](LICENSE). Forked from
[mairlist/streammonitor](https://github.com/mairlist/streammonitor) by
Torben Weibert / mairlist.
