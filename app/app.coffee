require "coffeescript"
net = require "net"
express = require "express"
http = require "http"
https = require "https"
path = require "path"
child_process = require "child_process"
fs = require "fs"
yaml = require "js-yaml"

# Only needed for SMTP email notifications, so a missing module degrades to
# "SMTP unavailable" instead of taking the whole monitor down at boot.
nodemailer = null
try
  nodemailer = require "nodemailer"
catch err
  console.log "Note: nodemailer not available (%s) - SMTP email is disabled, run npm install / rebuild the image to enable it", err.message

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

# Sent on every outbound HTTP call. Resend sits behind Cloudflare, which
# blocks clients with no User-Agent, so this isn't cosmetic.
USER_AGENT = "streammonitor/0.1"

# POSTs body to targetUrl (http or https) and calls
# cb(err, statusCode, responseBody). The response body is kept so a rejected
# API call (a bad Resend key, say) can report why rather than just "400".
httpPost = (targetUrl, body, headers, cb) ->
  parsed = new URL(targetUrl)
  mod = if parsed.protocol == "https:" then https else http
  sendHeaders = {"User-Agent": USER_AGENT}
  sendHeaders[key] = value for key, value of (headers or {})
  sendHeaders["Content-Length"] = Buffer.byteLength(body) if body
  req = mod.request targetUrl, {method: "POST", headers: sendHeaders}, (res) ->
    chunks = ""
    res.setEncoding "utf8"
    res.on "data", (chunk) -> chunks += chunk if chunks.length < 2000
    res.on "end", -> cb null, res.statusCode, chunks
  req.on "error", (err) -> cb err
  req.end body

TEST_SUBJECT = "streammonitor test"
TEST_MESSAGE = "Test notification from the streammonitor dashboard"

sendNtfyTest = (ntfyUrl, cb) ->
  httpPost ntfyUrl, TEST_MESSAGE, {
    "Title": TEST_SUBJECT
    "Priority": "default"
    "Content-Type": "text/plain"
  }, cb

sendWebhookTest = (webhookUrl, cb) ->
  payload = JSON.stringify
    event: "test"
    message: TEST_MESSAGE
    text: TEST_MESSAGE
    timestamp: new Date().toISOString()
  httpPost webhookUrl, payload, {"Content-Type": "application/json"}, cb


# Email notifications, via either the Resend HTTP API or plain SMTP.
#
# Every field can come from either the environment (bootstrap default, so a
# deployment can keep credentials in .env and never type them into the UI) or
# from config/notify.json (written by the dashboard), with notify.json
# winning field by field - same precedence as ntfy/webhook URLs.
EMAIL_FIELDS = [
  "provider", "from", "fromName", "to", "resendApiKey"
  "smtpHost", "smtpPort", "smtpSecure", "smtpUser", "smtpPass"
]
EMAIL_SECRET_FIELDS = ["resendApiKey", "smtpPass"]

emailEnvDefaults = ->
  provider: (process.env.EMAIL_PROVIDER or "").toLowerCase()
  from: process.env.EMAIL_FROM or ""
  fromName: process.env.EMAIL_FROM_NAME or ""
  to: process.env.EMAIL_TO or ""
  resendApiKey: process.env.RESEND_API_KEY or ""
  smtpHost: process.env.SMTP_HOST or ""
  smtpPort: process.env.SMTP_PORT or ""
  smtpSecure: process.env.SMTP_SECURE or ""
  smtpUser: process.env.SMTP_USER or ""
  smtpPass: process.env.SMTP_PASS or ""

# "1"/"true"/"yes"/"on" -> true, "0"/"false"/... -> false, blank -> null
parseBool = (value) ->
  return value if typeof value == "boolean"
  text = String(value ? "").trim().toLowerCase()
  return null unless text
  text in ["1", "true", "yes", "on"]

# Splits a recipient list into individual addresses. Accepts an array, or a
# string separated by commas or semicolons (Outlook's habit) or just spaces.
# Display names are kept intact - splitting on whitespace only when there's
# no separator and no "Name <addr>" form to tear apart.
parseRecipients = (value) ->
  return (String(item).trim() for item in value when String(item).trim()) if Array.isArray value
  text = String(value ? "").trim()
  return [] unless text
  parts = if /[,;]/.test text
    text.split /[,;]+/
  else if text.indexOf("<") >= 0
    [text]
  else
    text.split /\s+/
  (item.trim() for item in parts when item.trim())

# Merges saved email settings over the env defaults
effectiveEmail = (email) ->
  saved = email or {}
  merged = emailEnvDefaults()
  for key in EMAIL_FIELDS
    value = saved[key]
    merged[key] = value if value? and value != ""
  merged.provider = String(merged.provider or "").toLowerCase()
  merged

# Fills in the SMTP defaults that depend on each other: port 465 means
# implicit TLS, anything else means STARTTLS on 587.
resolveSmtp = (email) ->
  port = parseInt email.smtpPort, 10
  secure = parseBool email.smtpSecure
  port = (if secure then 465 else 587) unless port
  secure = (port == 465) unless secure?
  host: email.smtpHost
  port: port
  secure: secure
  user: email.smtpUser
  pass: email.smtpPass

# Accepts both "a@b.com" and "Name <a@b.com>"
looksLikeAddress = (value) ->
  match = /<([^>]+)>\s*$/.exec String(value or "").trim()
  address = if match then match[1] else String(value or "").trim()
  /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test address

# An explicit "off" provider is how the dashboard switches email off even
# when the environment sets EMAIL_PROVIDER - notify.json can only override
# env values field by field, so it needs a value that means "nothing".
emailEnabled = (email) ->
  !!email.provider and email.provider != "off"

# Returns an error string for an unusable email config, or null if it's fine
# (including "email switched off").
validateEmail = (email) ->
  return null unless emailEnabled email
  unless email.provider in ["resend", "smtp"]
    return "email provider must be either \"resend\" or \"smtp\""
  unless looksLikeAddress email.from
    return "email sender must be an address like alerts@example.com (or EMAIL_FROM)"
  recipients = parseRecipients email.to
  unless recipients.length
    return "at least one email recipient is required (or EMAIL_TO)"
  for recipient in recipients
    unless looksLikeAddress recipient
      return "\"#{recipient}\" is not a valid email recipient"
  if email.provider == "resend"
    unless email.resendApiKey
      return "a Resend API key is required (paste one here or set RESEND_API_KEY)"
  else
    unless resolveSmtp(email).host
      return "an SMTP host is required (enter one here or set SMTP_HOST)"
  null

# Builds the From header, e.g. "Radiohjelpen Alerts <noreply@...>". A bare
# noreply@ address reads badly in an inbox. An explicit "Name <addr>" already
# in the address field wins, so nothing gets double-wrapped.
formatSender = (email) ->
  address = String(email.from or "").trim()
  name = String(email.fromName or "").trim()
  return address if not name or address.indexOf("<") >= 0
  # Quote only when the name contains something an unquoted display name
  # can't hold, per RFC 5322's specials.
  if /[(),.:;<>@\[\]\\"]/.test name
    name = '"' + name.replace(/(["\\])/g, "\\$1") + '"'
  "#{name} <#{address}>"

sendResendEmail = (email, subject, message, cb) ->
  payload = JSON.stringify
    from: formatSender email
    to: parseRecipients email.to
    subject: subject
    text: message
  httpPost "https://api.resend.com/emails", payload, {
    "Content-Type": "application/json"
    "Authorization": "Bearer #{email.resendApiKey}"
  }, cb

sendSmtpEmail = (email, subject, message, cb) ->
  unless nodemailer
    return cb new Error "nodemailer is not installed in this image - rebuild it (docker compose build) to use SMTP"
  smtp = resolveSmtp email
  options =
    host: smtp.host
    port: smtp.port
    secure: smtp.secure
  options.auth = {user: smtp.user, pass: smtp.pass} if smtp.user
  nodemailer.createTransport(options).sendMail {
    from: formatSender email
    to: parseRecipients(email.to).join ", "
    subject: subject
    text: message
  }, (err) -> if err then cb err else cb null

# Sends one email through whichever provider is configured. cb matches
# httpPost's, so it drops into the same test-channel plumbing.
sendEmail = (email, subject, message, cb) ->
  if email.provider == "resend"
    sendResendEmail email, subject, message, cb
  else
    sendSmtpEmail email, subject, message, cb

sendEmailTest = (email, cb) ->
  sendEmail email, TEST_SUBJECT, TEST_MESSAGE, cb


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

# What the dashboard sees: saved settings with secrets withheld, plus which
# fields the environment is supplying, so the UI can show those as
# placeholders instead of silently pretending nothing is configured.
publicSettings = ->
  settings = loadNotifySettings()
  savedEmail = settings.email or {}
  env = emailEnvDefaults()

  email = {}
  for key in EMAIL_FIELDS when key not in EMAIL_SECRET_FIELDS
    email[key] = savedEmail[key] ? ""
  email.hasResendApiKey = !!savedEmail.resendApiKey
  email.hasSmtpPass = !!savedEmail.smtpPass

  envDefaults = {}
  for key in EMAIL_FIELDS when key not in EMAIL_SECRET_FIELDS
    envDefaults[key] = env[key]
  envDefaults.hasResendApiKey = !!env.resendApiKey
  envDefaults.hasSmtpPass = !!env.smtpPass

  ntfyUrl: settings.ntfyUrl or ""
  webhookUrl: settings.webhookUrl or ""
  email: email
  envDefaults:
    ntfyUrl: process.env.NTFY_URL or ""
    webhookUrl: process.env.WEBHOOK_URL or ""
    email: envDefaults
    smtpAvailable: !!nodemailer

# Current notification settings
app.get "/api/settings", (req, res) ->
  res.json publicSettings()

# Save notification settings. Overwrites notify.json in full: a blank field
# is left to whatever the environment supplies (email secrets excepted - see
# below), and email is switched off unless a provider is picked.
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

  # Email is off unless a provider is picked, and switching it off drops the
  # stored credentials with it - that's the way to get a secret back out of
  # notify.json once it's in there.
  emailBody = body.email or {}
  provider = String(emailBody.provider or "").trim().toLowerCase()
  if provider in ["", "off"]
    # The marker is only worth writing if there's an env default to override;
    # otherwise leaving email out of the file already means off.
    settings.email = {provider: "off"} if emailEnvDefaults().provider
  else
    savedEmail = (loadNotifySettings().email or {})
    email = {provider: provider}
    for key in EMAIL_FIELDS when key != "provider"
      value = emailBody[key]
      # Secrets left blank mean "keep the one already saved", so the UI never
      # has to send a password back to us just to change the port.
      value = savedEmail[key] if (value is undefined or value == "") and key in EMAIL_SECRET_FIELDS
      # A recipient list posted as an array stays an array, rather than being
      # flattened to a string and re-split on the way back out.
      if key == "to" and Array.isArray value
        recipients = parseRecipients value
        email[key] = recipients if recipients.length
        continue
      continue if value is undefined or value == null or value == ""
      email[key] = if typeof value == "boolean" then value else String(value).trim()
    problem = validateEmail effectiveEmail(email)
    return res.status(400).json error: problem if problem
    settings.email = email

  saveNotifySettings settings
  res.json publicSettings()

# Sends one test notification per configured channel, using saved settings
app.post "/api/settings/test", (req, res) ->
  settings = loadNotifySettings()
  email = effectiveEmail settings.email
  channels = []
  channels.push ["ntfy", settings.ntfyUrl, sendNtfyTest] if settings.ntfyUrl
  channels.push ["webhook", settings.webhookUrl, sendWebhookTest] if settings.webhookUrl
  channels.push ["email", email, sendEmailTest] if emailEnabled(email) and not validateEmail(email)

  unless channels.length
    return res.status(400).json error: "No notification channels configured yet"

  results = {}
  remaining = channels.length
  for [key, target, sender] in channels
    do (key, target, sender) ->
      sender target, (err, statusCode, responseBody) ->
        results[key] = if err
          {ok: false, error: err.message}
        else if statusCode? and statusCode >= 300
          {ok: false, statusCode: statusCode, error: (responseBody or "").slice(0, 300)}
        else if statusCode?
          {ok: true, statusCode: statusCode}
        else
          {ok: true}
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
