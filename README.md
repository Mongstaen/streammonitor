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
`monitor-ntfy/` alongside it (see [Alerting](#alerting) below).

## Quick start

Requires Docker and Docker Compose.

1. Clone this repo and `cd` into it.
2. Copy the example stream list and point it at your own streams:

   ```sh
   cp streams.example.yml streams.yml
   ```

   Edit `streams.yml`, e.g.:

   ```yaml
   streams:
     - name: station-a
       url: https://icecast.example.com/station-a
     - name: station-b
       url: https://icecast.example.com/station-b
   ```

3. (Optional) If you want ntfy alerts, edit `NTFY_URL` in
   `docker-compose.yml` — it defaults to a public `ntfy.sh` topic which
   *anyone* can subscribe to or spam, so change the topic name to something
   unguessable, or point it at a self-hosted ntfy server. See
   [Alerting](#alerting).
4. Start it:

   ```sh
   docker compose up -d --build
   ```

5. Check it's working:

   ```sh
   curl http://localhost:8000/
   ```

   You should see one JSON status object per stream (see
   [HTTP interface](#http-interface)). A freshly started stream reports
   `"status": "ERROR"` for the first second or two until `curl`/`lame`
   connect — that's normal.

If you skip step 3, `monitor-ntfy` still starts but every alert goes to
the public `ntfy.sh/streammonitor-alerts` topic from `docker-compose.yml`
— fine for a quick test, not for real use.

## Configuration

Set via `streams.yml` (see Quick start) plus these environment variables,
settable in `docker-compose.yml`:

- `STREAMS_CONFIG` (optional, default `/app/config/streams.yml`) — path
  *inside the container* to the YAML file listing the streams to monitor.
  You normally don't need to change this; `docker-compose.yml` already
  mounts your `streams.yml` to that path. The format is:

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

  `status` is `"OK"` if the decoder process is currently running,
  `"ERROR"` if it isn't (stream unreachable, connection dropped, etc.) —
  it does *not* by itself mean silence; check `silenceDuration` for that.
- `GET /:name` — single stream's status object, 404 if `name` isn't
  configured.
- `GET /:name/value/:key` — single field from one stream's status, as
  upstream's `/value/:key` did. E.g. `GET /station-a/value/silenceDuration`.

## Alerting

`monitor-ntfy/` is a separate small container that polls `GET /` on the
main monitor and pushes an [ntfy](https://ntfy.sh) push notification per
stream when it transitions between OK and a bad state (offline or
silence >10s), and again when it recovers. State is tracked per stream
under `STATE_DIR` so a restart doesn't re-fire alerts for streams that
were already broken.

To actually receive the alerts, install the [ntfy app](https://ntfy.sh/)
(or use a browser) and subscribe to the topic name in your `NTFY_URL`.
Anyone who knows the topic name can subscribe to it too, so treat it like
a shared secret — don't use the default example topic for anything real.

Environment variables (set in `docker-compose.yml`):

- `STATUS_URL` (required) — URL of the main streammonitor's `GET /`
  endpoint, e.g. `http://streammonitor:8000/` when both run under the same
  Compose project.
- `NTFY_URL` (required) — full ntfy topic URL to POST alerts to, e.g.
  `https://ntfy.sh/your-unguessable-topic-name`.
- `STATE_DIR` (optional, default `/var/lib/streammonitor-monitor`) —
  where per-stream last-known-state files are kept. Should be a persistent
  volume (already set up in `docker-compose.yml`) so restarts don't
  re-notify for streams that were already down.
- `POLL_INTERVAL` (optional, default `60` seconds) — how often to poll the
  main monitor.

## Deploying

`docker-compose.yml` here is a starting point covering both containers:

```sh
docker compose up -d --build
```

Things you'll likely want to change for a real deployment:

- `streams.yml` — your actual stations (see Quick start).
- `NTFY_URL` — your own topic or self-hosted ntfy server.
- `ports` — which host port the status API is exposed on, if 8000
  conflicts with something else.
- Put something in front of port 8000 (reverse proxy, firewall rule) if
  the host is reachable from the internet — the status API has no
  authentication.

## License

AGPL-3.0, same as upstream — see [LICENSE](LICENSE). Forked from
[mairlist/streammonitor](https://github.com/mairlist/streammonitor) by
Torben Weibert / mairlist.
