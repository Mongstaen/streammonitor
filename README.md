# streammonitor

A fork of [mairlist/streammonitor](https://github.com/mairlist/streammonitor)
(by Torben Weibert / mairlist) that monitors *multiple* Icecast/Shoutcast
MP3 streams from a single container instead of one container per stream, so
on-air status for several stations can be centralized on one host rather
than deployed per client.

Licensed AGPL-3.0, same as upstream — see [LICENSE](LICENSE).

Each stream is still checked the same way as upstream: `curl <url> | lame
--decode` is spawned per stream, and PCM samples are compared against
`SILENCE_THRESHOLD` to detect dead air.

## Configuration

- `STREAMS` (required) — comma-separated `name=url` pairs, e.g.:

  ```
  STREAMS=station-a=https://icecast.example.com/station-a,station-b=https://icecast.example.com/station-b
  ```

  `name` is used to key the stream in the API and in per-stream ntfy alert
  state — keep it stable once alerts are wired up, or you'll get a spurious
  recovered/alert pair for the renamed stream.
- `SILENCE_THRESHOLD` (optional, default `-20` dBFS) — applies to all
  streams.
- `CHECK_INTERVAL` (optional, default `1000` ms).
- `HTTP_PORT` (optional, default `8000`).

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

- `GET /:name` — single stream's status object, 404 if `name` isn't
  configured.
- `GET /:name/value/:key` — single field from one stream's status, as
  upstream's `/value/:key` did.

## Alerting

`monitor-ntfy/` polls `GET /` on the interval in `POLL_INTERVAL` (default
60s) and pushes an [ntfy](https://ntfy.sh) alert per stream on ok\<->bad
transitions, same behavior as the single-stream version this was forked
from — just looped over the array, with one state file per stream under
`STATE_DIR` (default `/var/lib/streammonitor-monitor`) so restarts don't
re-notify.

Env vars: `STATUS_URL`, `NTFY_URL` (both required), `STATE_DIR`,
`POLL_INTERVAL`.

## Deploying

`docker-compose.yml` here is a starting point: build both images, publish
the central monitor's port, and point the ntfy watcher at it. Adjust the
`STREAMS` list, `ports`, and `NTFY_URL` topic for your setup.

## License

AGPL-3.0, same as upstream — see [LICENSE](LICENSE). Forked from
[mairlist/streammonitor](https://github.com/mairlist/streammonitor) by
Torben Weibert / mairlist.
