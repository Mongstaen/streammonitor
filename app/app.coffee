require "coffeescript"
net = require "net"
express = require "express"
http = require "http"
https = require "https"
path = require "path"
child_process = require "child_process"
fs = require "fs"
yaml = require "js-yaml"

# Retrieve config from environment
httpPort = process.env.HTTP_PORT or 8000
checkInterval = process.env.CHECK_INTERVAL or 1000
silenceThreshold = process.env.SILENCE_THRESHOLD or -20

configPath = process.env.STREAMS_CONFIG or "/app/config/streams.yml"
notifyConfigPath = process.env.NOTIFY_CONFIG or "/app/config/notify.json"

unless fs.existsSync configPath
  console.log "Error: streams config file not found: %s (set STREAMS_CONFIG to override)", configPath
  process.exit()

config = yaml.load fs.readFileSync configPath, "utf8"

unless config?.streams?.length
  console.log "Error: %s must define a non-empty top-level 'streams' list", configPath
  process.exit()

streams = for s in config.streams
  name: s.name
  url: s.url

for s in streams
  unless s.name and s.url
    console.log "Error: invalid entry in %s (expected {name, url}): %s", configPath, JSON.stringify(s)
    process.exit()

# Convert silenceThreshold to absolute 16-bit value
silenceThresholdLinear = 32768 * Math.exp((silenceThreshold * Math.log(10))/20)

# Per-stream state, keyed by name
states = {}
for s in streams
  states[s.name] =
    url: s.url
    offlineSince: new Date()
    onlineSince: null
    silenceSince: new Date()
    pid: null
    child: null

# Transition helpers - idempotent, so retrying a still-broken stream every
# checkInterval doesn't keep resetting offlineSince back to "now" and
# masking a real outage as ever-growing "silence" instead.
markOnline = (state) ->
  return if state.onlineSince
  state.onlineSince = new Date()
  state.offlineSince = null

markOffline = (state) ->
  return if state.offlineSince
  state.offlineSince = new Date()
  state.onlineSince = null

# function that is periodically called to connect to a given stream
checkChildProcess = (name) =>
  state = states[name]
  # process still running? -> exit
  return if state.pid

  args = "curl -s " + state.url + " | lame --quiet --mp3input --decode -t -"

  child = child_process.spawn "/bin/sh", ["-c", args]
  state.child = child

  child.on "error", (err) ->
    console.log "[%s] Error starting process: %s", name, err
    markOffline state
    state.pid = 0

  child.on "exit", (code) ->
    console.log "[%s] Process exited with code %d", name, code
    markOffline state
    state.pid = 0

  # Only counts as online once we've actually decoded audio, not just on
  # spawning the pipeline - a bad URL can spawn curl/lame fine and then
  # exit a moment later with nothing ever going through.
  child.stdout.on "data", (data) ->
    markOnline state
    for i in [0..data.length/2-1]
      sample = Math.abs(data.readInt16LE i*2)
      if sample > silenceThresholdLinear
        state.silenceSince = new Date()
        break

  state.pid = child.pid

  console.log "[%s] Process started, pid=%d", name, state.pid


# Returns the current status of one stream as an object
getStreamStatus = (name) ->
  state = states[name]
  now = new Date()
  name: name
  url: state.url
  silenceThreshold: silenceThreshold
  status: if state.onlineSince then "OK" else "ERROR"
  now: now
  onlineSince: state.onlineSince
  onlineDuration: if state.onlineSince then Math.floor((now.getTime() - state.onlineSince.getTime()) / 1000) else 0
  offlineSince: state.offlineSince
  offlineDuration: if state.offlineSince then Math.floor((now.getTime() - state.offlineSince.getTime()) / 1000) else 0
  silenceSince: state.silenceSince
  silenceDuration: Math.floor((now.getTime() - state.silenceSince.getTime()) / 1000)

# Returns the status of every configured stream as an array of objects
getAllStatus = () ->
  (getStreamStatus(s.name) for s in streams)


# Notification settings (ntfy/webhook URLs), shared with monitor-ntfy via
# notifyConfigPath. Read fresh on every request since the dashboard's Save
# button writes the file directly rather than going through this process.
loadNotifySettings = ->
  try
    JSON.parse fs.readFileSync notifyConfigPath, "utf8"
  catch
    {}

saveNotifySettings = (settings) ->
  fs.mkdirSync path.dirname(notifyConfigPath), recursive: true
  fs.writeFileSync notifyConfigPath, JSON.stringify(settings, null, 2)

# POSTs body to targetUrl (http or https) and calls cb(err, statusCode)
httpPost = (targetUrl, body, headers, cb) ->
  parsed = new URL(targetUrl)
  mod = if parsed.protocol == "https:" then https else http
  req = mod.request targetUrl, {method: "POST", headers: headers}, (res) ->
    res.resume()
    cb null, res.statusCode
  req.on "error", (err) -> cb err
  req.end body

sendNtfyTest = (ntfyUrl, cb) ->
  httpPost ntfyUrl, "Test notification from the streammonitor dashboard", {
    "Title": "streammonitor test"
    "Priority": "default"
    "Tags": "test_tube"
    "Content-Type": "text/plain"
  }, cb

sendWebhookTest = (webhookUrl, cb) ->
  payload = JSON.stringify
    event: "test"
    message: "Test notification from the streammonitor dashboard"
    text: "Test notification from the streammonitor dashboard"
    timestamp: new Date().toISOString()
  httpPost webhookUrl, payload, {"Content-Type": "application/json"}, cb


# Create web app
app = express()
app.set "json spaces", 2
app.use express.json()

# Root document returns an array with the status of every stream
app.get "/", (req, res) ->
  res.jsonp getAllStatus()

# Live dashboard UI
app.get "/dashboard", (req, res) ->
  res.sendFile path.join(__dirname, "public", "dashboard.html")

# Current notification settings
app.get "/api/settings", (req, res) ->
  res.json loadNotifySettings()

# Save notification settings. A missing/empty field clears that channel.
app.post "/api/settings", (req, res) ->
  body = req.body or {}
  settings = {}
  for key in ["ntfyUrl", "webhookUrl"]
    value = body[key]
    continue unless value
    try
      parsed = new URL(value)
      throw new Error() unless parsed.protocol in ["http:", "https:"]
    catch
      return res.status(400).json error: "#{key} must be a valid http:// or https:// URL"
    settings[key] = value
  saveNotifySettings settings
  res.json settings

# Sends one test notification per configured channel, using saved settings
app.post "/api/settings/test", (req, res) ->
  settings = loadNotifySettings()
  channels = []
  channels.push ["ntfy", settings.ntfyUrl, sendNtfyTest] if settings.ntfyUrl
  channels.push ["webhook", settings.webhookUrl, sendWebhookTest] if settings.webhookUrl

  unless channels.length
    return res.status(400).json error: "No notification channels configured yet"

  results = {}
  remaining = channels.length
  for [key, targetUrl, sender] in channels
    do (key, targetUrl, sender) ->
      sender targetUrl, (err, statusCode) ->
        results[key] = if err
          {ok: false, error: err.message}
        else
          {ok: statusCode < 300, statusCode: statusCode}
        remaining -= 1
        res.json results if remaining == 0

# Single stream's status, by name
app.get "/:name", (req, res) ->
  unless states[req.params.name]
    return res.status(404).jsonp error: "unknown stream: #{req.params.name}"
  res.jsonp getStreamStatus(req.params.name)

# Single field from a single stream's status
app.get "/:name/value/:key", (req, res) ->
  unless states[req.params.name]
    return res.status(404).jsonp error: "unknown stream: #{req.params.name}"
  res.jsonp getStreamStatus(req.params.name)[req.params.key]


# Create web server
server = http.Server(app)
server.listen httpPort

console.log "Stream monitor started on port %d, watching %d stream(s): %s",
  httpPort, streams.length, (s.name for s in streams).join(", ")

# Start periodic check for each stream's child process
for s in streams
  setInterval (checkChildProcess.bind(null, s.name)), checkInterval
