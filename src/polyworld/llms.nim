import
  std/[json, monotimes, options, os, strutils, tables, times, uri],
  bassy, jsony,
  oracles, timings

const
  NativeRequests* = not defined(emscripten) and not defined(js) and
    not defined(gotaNoLlm)
    ## gotaNoLlm: the native training library links no HTTP client (curly
    ## needs --mm:arc/orc; the library is built with atomicArc).
  MaxRequestBytes* = 64 * 1024
  MaxResponseBytes* = 256 * 1024
  MaxHeaderBytes = 16 * 1024
  DefaultOracleModel* = "typesafe/jev-1.13"

when NativeRequests:
  import curly

  type LlmConnection = object
    curl: Curly
    inFlight: bool

  proc close(connection: var LlmConnection) {.raises: [].} =
    ## Drains the outstanding request before releasing Curly's worker.
    if connection.curl != nil:
      if connection.inFlight:
        discard connection.curl.waitForResponse()
      connection.curl.close()
      connection.curl = nil
      connection.inFlight = false

  proc `=destroy`(connection: var LlmConnection) =
    ## Releases the HTTP worker when its player is destroyed.
    connection.close()

type
  LlmError* = object of CatchableError
  LlmConfig* = object
    baseUrl*, key*, model*, oracleModel*: string
    sidecar*: bool
    interval*: int32
    timeoutMs*: int
  LlmClient* = ref object
    runtime {.cursor.}: Runtime
    oracle*: Oracle
    config*: LlmConfig
    slot*: int
    tick, lastAsk, nextId, pending: int32
    asked: bool
    when NativeRequests:
      connection: LlmConnection
    started: MonoTime
    completed, httpStatus: int32
    body, failure: string

proc parseDocument*(body: string): JsonNode {.raises: [LlmError].} =
  ## Parses bounded LLM JSON with jsony and reports LlmError on failure.
  if body.len > MaxResponseBytes:
    raise newException(LlmError, "LLM JSON exceeds the byte limit")
  var
    depth = 0
    quoted, escaped: bool
  for character in body:
    if quoted:
      if escaped:
        escaped = false
      elif character == '\\':
        escaped = true
      elif character == '"':
        quoted = false
    else:
      case character
      of '"':
        quoted = true
      of '{', '[':
        inc depth
        if depth > 64:
          raise newException(LlmError, "LLM JSON nesting exceeds 64 levels")
      of '}', ']':
        dec depth
      else:
        discard
  try:
    result = body.fromJson(JsonNode)
  except ValueError:
    raise newException(LlmError, "Invalid LLM JSON: " & getCurrentExceptionMsg())

proc environmentInt(name: string, fallback, maximum: int): int =
  ## Reads a bounded host setting without silently ignoring bad values.
  try:
    result = parseInt(getEnv(name, $fallback))
  except ValueError:
    raise newException(LlmError, name & " must be an integer")
  if result < 1 or result > maximum:
    raise newException(LlmError, name & " is outside the supported range")

proc validateBaseUrl(baseUrl: string) {.raises: [LlmError].} =
  ## Allows the production OpenRouter root and explicit loopback endpoints.
  if baseUrl.len == 0:
    return
  if baseUrl.find({'\x00' .. '\x20', '\x7f', '\\', '@', '%', '?', '#'}) >= 0:
    raise newException(LlmError, "Invalid host LLM base URL")
  var url: Uri
  try:
    url = parseUri(baseUrl)
  except ValueError:
    raise newException(LlmError, "Invalid host LLM base URL")
  let
    hostname = url.hostname.toLowerAscii()
    scheme = url.scheme.toLowerAscii()
    local = hostname in ["localhost", "127.0.0.1", "::1"]
  if url.username.len > 0 or url.password.len > 0 or
    scheme notin ["http", "https"]:
      raise newException(LlmError, "Invalid host LLM base URL")
  if not local and not (hostname == "openrouter.ai" and scheme == "https" and
    url.port in ["", "443"] and url.path.strip(leading = false, trailing = true,
      chars = {'/'}) == "/api"):
      raise newException(LlmError,
        "LLM base URL must be https://openrouter.ai/api or localhost, " &
        "127.0.0.1, or [::1]")
  if url.port.len > 0:
    try:
      if parseInt(url.port) notin 1 .. 65535:
        raise newException(LlmError, "Invalid LLM endpoint port")
    except ValueError:
      raise newException(LlmError, "Invalid LLM endpoint port")

proc llmConfig*(): LlmConfig =
  ## Uses the platform sidecar first, or explicit local OpenRouter access.
  if not NativeRequests or getEnv("COGAME_LLM").toLowerAscii == "off":
    return
  result.baseUrl = getEnv("COWORLD_LLM_ENDPOINT")
  result.sidecar = result.baseUrl.len > 0
  if not result.sidecar:
    result.key = getEnv("COGAME_LLM_KEY", getEnv("OPENROUTER_API_KEY"))
    result.baseUrl = getEnv("COGAME_LLM_BASE_URL")
    if result.baseUrl.len == 0 and result.key.len > 0:
      result.baseUrl = "https://openrouter.ai/api"
  if result.baseUrl.len == 0:
    return
  result.baseUrl = result.baseUrl.strip(trailing = true, chars = {'/'})
  validateBaseUrl(result.baseUrl)
  result.model =
    if result.sidecar: getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    else: getEnv("COGAME_LLM_MODEL")
  result.oracleModel = getEnv("COGAME_ORACLE_MODEL", DefaultOracleModel)
  result.interval = int32(environmentInt("COGAME_LLM_INTERVAL", 1, 100000))
  result.timeoutMs = environmentInt("COGAME_LLM_TIMEOUT_MS", 30000, 120000)

proc newLlmClient*(slot: int, config: LlmConfig): LlmClient =
  ## Creates one isolated seat without opening a network connection.
  if slot < 0 or config.interval < 0 or config.timeoutMs < 0:
    raise newException(LlmError, "Invalid LLM client configuration")
  validateBaseUrl(config.baseUrl)
  LlmClient(config: config, slot: slot, tick: -1, oracle: newOracle())

proc newLlmClient*(slot: int): LlmClient =
  ## Reads host settings once when constructing a player's LLM client.
  result = newLlmClient(slot, llmConfig())
  result.oracle.enabled = getEnv("COGAME_ORACLE").toLowerAscii != "off"

proc close*(client: LlmClient) {.raises: [].} =
  ## Waits for outstanding HTTP work, releases Curly, and forgets answers.
  if client == nil:
    return
  when NativeRequests:
    client.connection.close()
  client.pending = 0
  client.completed = 0
  client.body.setLen(0)
  client.failure.setLen(0)
  client.oracle.reset()

proc available*(client: LlmClient): bool {.raises: [].} =
  ## Reports whether the host configured a native inference endpoint.
  NativeRequests and client != nil and client.config.baseUrl.len > 0

proc hasPending*(client: LlmClient): bool {.raises: [].} =
  ## Reports requests that must settle before a barrier may advance.
  client != nil and client.pending != 0

proc ready*(client: LlmClient): int32 {.raises: [].} =
  ## Returns zero when ready, remaining spacing ticks, or minus one.
  if not client.available or client.pending != 0:
    return -1
  when NativeRequests:
    if client.connection.inFlight:
      return -1
  if client.asked:
    return int32(max(0'i64,
      int64(client.config.interval) - (int64(client.tick) - client.lastAsk)))

proc beginTick*(client: LlmClient, tick: int32) =
  ## Polls ready network work at the decision boundary and detects resets.
  if tick < client.tick:
    client.pending = 0
    client.completed = 0
    client.body.setLen(0)
    client.failure.setLen(0)
    client.asked = false
  client.tick = tick
  client.oracle.beginTick(tick)
  when NativeRequests:
    if not client.connection.inFlight:
      return
    var
      completed = client.connection.curl.pollForResponse()
      status: int32
      body, failure: string
    if completed.isSome:
      client.connection.inFlight = false
      if client.pending == 0:
        return
      var received = move(completed.get())
      status = int32(received.response.code)
      failure = move(received.error)
      var headerBytes = 0
      for (name, value) in received.response.headers:
        headerBytes += name.len + value.len + 4
      if received.response.body.len > MaxResponseBytes:
        failure = "LLM response exceeds the byte limit"
      elif headerBytes > MaxHeaderBytes:
        failure = "LLM response headers exceed the byte limit"
      else:
        body = move(received.response.body)
      if (getMonoTime() - client.started).inMilliseconds >=
        client.config.timeoutMs:
          failure = "LLM request timed out"
      if failure.len == 0 and status notin 200 .. 299:
        failure = "LLM HTTP " & $status
    elif client.pending != 0 and
      (getMonoTime() - client.started).inMilliseconds >= client.config.timeoutMs:
        failure = "LLM request timed out"
    else:
      return
    if client.pending == client.oracle.pending:
      var document: JsonNode
      if failure.len == 0:
        try:
          document = parseDocument(body)
        except LlmError:
          discard # Malformed JEV responses settle as failed requests.
      client.oracle.complete(client.pending, document)
    client.completed = client.pending
    client.httpStatus = status
    client.body = move(body)
    client.failure = move(failure)
    client.pending = 0

proc ask*(client: LlmClient, verb, path, body: string): int32 =
  ## Forwards an inference API body unchanged and returns its request ID.
  if client.ready != 0 or body.len > MaxRequestBytes:
    return 0
  if verb notin ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"] or
    not path.startsWith("/v1/") or path.len > 2048 or
    path.find({'\x00' .. '\x1f', '\x7f', '\\', '#'}) >= 0:
      raise newException(LlmError, "Invalid LLM method or API path")
  let route = path.split('?', 1)[0]
  for segment in route.split('/'):
    if segment in [".", ".."] or segment.contains('%'):
      raise newException(LlmError, "LLM path must stay under /v1/")
  if client.nextId == int32.high:
    raise newException(LlmError, "LLM request ID limit reached")
  validateBaseUrl(client.config.baseUrl)
  var headers = @[("Content-Type", "application/json")]
  if client.config.sidecar:
    headers.add ("X-Coworld-Player-Slot", $client.slot)
  elif client.config.key.len > 0:
    headers.add ("Authorization", "Bearer " & client.config.key)
  when NativeRequests:
    if client.config.timeoutMs <= 0:
      raise newException(LlmError, "LLM timeout must be positive")
    if client.connection.curl == nil:
      client.connection.curl = newCurly(maxInFlight = 1)
    client.started = getMonoTime()
    client.connection.curl.startRequest(
      verb,
      client.config.baseUrl & path,
      headers = headers,
      body = body,
      timeout = max(1, (client.config.timeoutMs + 999) div 1000)
    )
    client.connection.inFlight = true
  inc client.nextId
  client.pending = client.nextId
  client.lastAsk = client.tick
  client.asked = true
  client.nextId

proc chat*(client: LlmClient, model, prompt: string): int32 =
  ## Sends one ordinary user message using a caller or host selected model.
  let selected =
    if client.config.sidecar: client.config.model
    elif model.len > 0: model
    else: client.config.model
  if selected.len == 0:
    raise newException(LlmError, "LLM model is required")
  client.ask("POST", "/v1/chat/completions", $(%*{
    "model": selected, "messages": [{"role": "user", "content": prompt}]
  }))

proc poll*(client: LlmClient, id: int32): int32 =
  ## Returns zero while pending, one on success, or minus one on failure.
  if id > 0 and id == client.pending:
    return 0
  if id > 0 and id == client.completed and client.failure.len == 0:
    return 1
  -1

proc status*(client: LlmClient, id: int32): int32 =
  ## Returns the latest response's HTTP status, or zero for another ID.
  if id > 0 and id == client.completed:
    client.httpStatus
  else:
    0

proc error*(client: LlmClient, id: int32): string =
  ## Returns the latest request error, or reports an unavailable result.
  if id > 0 and id == client.completed:
    client.failure
  else:
    "Unknown or expired LLM request"

proc response*(client: LlmClient, id: int32): string =
  ## Returns the latest completed JSON or SSE response body.
  if id > 0 and id == client.completed:
    client.body
  else:
    ""

proc contentText(content: JsonNode): string =
  ## Reads text content while leaving non-text data in the raw response.
  if content == nil:
    return
  case content.kind
  of JString:
    result = content.getStr()
  of JArray:
    for part in content:
      if part.kind == JObject and part.hasKey("text") and
        part["text"].kind == JString:
          result.add part["text"].getStr()
  else:
    discard

proc documentText(document: JsonNode): string =
  ## Reads Chat Completions or Responses API text from a JSON document.
  let choices = document{"choices"}
  if choices != nil and choices.kind == JArray and choices.len > 0:
    result = contentText(choices[0]{"message", "content"})
    if result.len == 0:
      result = contentText(choices[0]{"delta", "content"})
  let output = document{"output"}
  if output != nil and output.kind == JArray:
    for item in output:
      result.add contentText(item{"content"})
  if document{"type"}.getStr() == "response.output_text.delta":
    result.add document{"delta"}.getStr()

proc text*(client: LlmClient, id: int32): string =
  ## Extracts ordinary text from a completed JSON or SSE response.
  let body = client.response(id)
  if body.strip().startsWith("{"):
    return documentText(parseDocument(body))
  for line in body.splitLines():
    if line.startsWith("data:"):
      let data = line[5 .. ^1].strip()
      if data.len == 0 or data == "[DONE]":
        continue
      try:
        result.add documentText(parseDocument(data))
      except LlmError:
        discard # Ignore malformed SSE data events.

proc askOracle(client: LlmClient): int32 =
  ## Sends a JEV draft through this player's shared LLM client.
  defer:
    client.oracle.submit(result)
  if not client.oracle.enabled or client.ready != 0:
    return 0
  let body = client.oracle.requestBody(client.config.oracleModel)
  if body.len > 0:
    result = client.ask("POST", "/v1/systemone", body)

proc bindRuntime*(client: LlmClient, runtime: Runtime) =
  ## Borrows the runtime that owns these callbacks, avoiding a ref cycle.
  client.runtime = runtime

proc requestPoller*(client: LlmClient): RequestPoll =
  ## Polls this seat during the shared barrier without rerunning BASIC.
  result = proc(): bool =
    ## Delivers completed replies while keeping the simulation tick fixed.
    client.beginTick(client.tick)
    client.hasPending()

proc decisionCallback*(client: LlmClient): proc(tick: int32) =
  ## Keeps inference state outside the deterministic simulation modules.
  result = proc(tick: int32) =
    ## Advances the state belonging to this VM only.
    client.beginTick(tick)

proc jsonGet(document: JsonNode, path: string): string =
  ## Reads an RFC 6901 pointer as text or serialized JSON for non-strings.
  var current = document
  if path.len > 0:
    if path[0] != '/':
      raise newException(LlmError, "JSON pointer must start with a slash")
    for part in path[1 .. ^1].split('/'):
      if current == nil:
        return ""
      let key = part.replace("~1", "/").replace("~0", "~")
      case current.kind
      of JObject:
        current = current{key}
      of JArray:
        var index: int
        try:
          index = parseInt(key)
        except ValueError:
          return ""
        if index < 0 or index >= current.len:
          return ""
        current = current[index]
      else:
        return ""
  if current == nil:
    return ""
  if current.kind == JString: current.getStr() else: $current

proc addFunctions*(client: LlmClient, host: var Host) =
  ## Registers the BASIC calls directly on this player's LLM client.
  template register(name: string, arity: int, operation: untyped) =
    ## Shares BASIC value conversion and error handling between callbacks.
    block:
      let binding: NumericHostProc = proc(arguments: openArray[Value]): Value =
        ## Runs one LLM operation with values from this BASIC runtime.
        template text(index: int): string {.inject.} =
          ## Reads a BASIC string argument.
          client.runtime.getString(arguments[index])
        template integer(index: int): int32 {.inject.} =
          ## Reads an integer argument, rejecting fractional values.
          arguments[index].asInt()
        template output(text: string): Value {.inject.} =
          ## Copies a string result into BASIC storage.
          client.runtime.putString(text)
        var value {.inject.}: Value
        try:
          operation
        except LlmError, OracleError:
          raise newException(BasicError, getCurrentExceptionMsg())
        value
      discard host.addFunction(name, arity, binding, 256)
  register("llmAvailable", 0):
    value = int32(client.available)
  register("llmReady", 0):
    value = client.ready
  register("llmAsk", 2):
    value = client.chat(text(0), text(1))
  register("llmRequest", 3):
    value = client.ask(text(0), text(1), text(2))
  register("llmPoll", 1):
    value = client.poll(integer(0))
  register("llmStatus", 1):
    value = client.status(integer(0))
  register("llmResponse$", 1):
    value = output(client.response(integer(0)))
  register("llmRead$", 3):
    let
      body = client.response(integer(0))
      offset = integer(1)
      count = integer(2)
    if offset < 0 or count < 0:
      raise newException(LlmError, "LLM slice must be nonnegative")
    let start = min(int(offset), body.len)
    value = output(body[start ..< start + min(int(count), body.len - start)])
  register("llmText$", 1):
    value = output(client.text(integer(0)))
  register("llmError$", 1):
    value = output(client.error(integer(0)))
  register("jsonQuote$", 1):
    value = output(text(0).toJson())
  register("jsonGet$", 2):
    value = output(jsonGet(parseDocument(text(0)), text(1)))
  register("oracleAvailable", 0):
    value = int32(client.oracle.enabled and client.available)
  register("oracleReady", 0):
    value = if client.oracle.enabled: client.ready else: -1
  register("oracleState", 2):
    value = client.oracle.state(text(0), %integer(1))
  register("oracleStateText", 2):
    value = client.oracle.state(text(0), %text(1))
  register("oracleNote", 1):
    value = client.oracle.note(text(0))
  register("oracleQuestion", 3):
    value = client.oracle.question(text(0), integer(1), text(2))
  register("oracleCriterion", 3):
    value = client.oracle.criterion(text(0), text(1), text(2))
  register("oracleCriterionField", 4):
    value = client.oracle.criterionField(text(0), text(1), text(2), text(3))
  register("oracleAsk", 0):
    value = client.askOracle()
  register("oraclePoll", 1):
    value = client.oracle.poll(integer(0))
  register("oracleAnswer", 2):
    value = client.oracle.answer(integer(0), text(1)).value
  register("oracleConfidence", 2):
    value = client.oracle.answer(integer(0), text(1)).confidence
  register("oracleProbability", 3):
    value = client.oracle.answer(integer(0), text(1)).probabilities.getOrDefault(
      text(2), -1'i32
    )
