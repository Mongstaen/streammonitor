require "coffeescript"
net = require "net"
express = require "express"
http = require "http"
child_process = require "child_process"

# Retrieve config from environment
httpPort = process.env.HTTP_PORT or 8000
checkInterval = process.env.CHECK_INTERVAL or 1000
silenceThreshold = process.env.SILENCE_THRESHOLD or -20

streamsEnv = process.env.STREAMS
unless streamsEnv
  console.log "Error: STREAMS must be set in environment (comma-separated name=url pairs)"
  process.exit()

# Parse "name=url,name=url,..." into [{name, url}, ...]
streams = for pair in streamsEnv.split(",")
  [name, urlParts...] = pair.trim().split("=")
  name: name?.trim()
  url: urlParts.join("=").trim()

for s in streams
  unless s.name and s.url
    console.log "Error: invalid STREAMS entry (expected name=url): %s", JSON.stringify(s)
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
    state.onlineSince = null
    state.offlineSince = new Date()
    state.pid = 0

  child.on "exit", (code) ->
    console.log "[%s] Process exited with code %d", name, code
    state.onlineSince = null
    state.offlineSince = new Date()
    state.pid = 0

  child.stdout.on "data", (data) ->
    for i in [0..data.length/2-1]
      sample = Math.abs(data.readInt16LE i*2)
      if sample > silenceThresholdLinear
        state.silenceSince = new Date()
        break

  state.pid = child.pid
  state.offlineSince = null
  state.onlineSince = new Date()

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


# Create web app
app = express()
app.set "json spaces", 2

# Root document returns an array with the status of every stream
app.get "/", (req, res) ->
  res.jsonp getAllStatus()

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
