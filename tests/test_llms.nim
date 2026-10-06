import
  std/[json, monotimes, net, os, strutils, tempfiles, times],
  bassy, fixxy,
  polyworld/[cli, llms, mailboxes, oracles, timings],
  ../examples/gods_of_the_arena/[bots, maps, replays, sim]

const
  JevRequest = staticRead("fixtures/jev_request.bas")
  JevResponse = staticRead("fixtures/jev_response.json")

var
  ports: Channel[int]
  received: Channel[string]

proc sendReply(socket: Socket, body: string, status = "200 OK") =
  ## Sends a fixed-length response from the local mock sidecar.
  socket.send("HTTP/1.1 " & status & "\r\nContent-Type: application/json\r\n" &
    "Content-Length: " & $body.len & "\r\nConnection: close\r\n\r\n" & body)

proc serve() {.thread.} =
  ## Emulates inference routes without making any external API calls.
  let server = newSocket()
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  ports.send(int(server.getLocalAddr()[1]))
  var
    paired: Socket
    strategyRequests = 0
  while true:
    var socket: Socket
    server.accept(socket)
    let first = socket.recvLine(timeout = 3000)
    if first.contains("/stop"):
      socket.close()
      break
    var
      headers = first & "\n"
      length = 0
    while true:
      let line = socket.recvLine(timeout = 3000)
      if line.len == 0 or line == "\r\n":
        break
      headers.add line & "\n"
      if line.toLowerAscii.startsWith("content-length:"):
        length = parseInt(line.split(':', 1)[1].strip())
    var body: string
    while body.len < length:
      body.add socket.recv(length - body.len, timeout = 3000)
    received.send(headers & body)
    try:
      if first.contains("/pair"):
        if paired == nil:
          paired = socket
          continue
        paired.sendReply("{}")
        paired.close()
        paired = nil
        socket.sendReply("{}")
      elif first.contains("/systemone"):
        if body.contains("\"regression\""):
          let reply = parseDocument(body)["state"]["regression"].getStr()
          if reply == "delay":
            sleep(180)
            socket.sendReply("{}")
          else:
            socket.sendReply(reply)
        elif body.contains("Gods of the Arena, a team lane battle"):
          socket.sendReply(JevResponse)
        elif body.contains("\"strategy\""):
          inc strategyRequests
          if strategyRequests <= 5:
            let
              strategy = ["gank", "defend", "push", "regroup", "farm"][
                strategyRequests - 1]
              lane = ["bottom", "top", "mid", "bottom", "top"][
                strategyRequests - 1]
            socket.sendReply("{\"answers\":{\"strategy\":{\"choice\":\"" &
              strategy & "\"},\"lane\":{\"choice\":\"" & lane & "\"}}}")
          elif strategyRequests == 6:
            socket.sendReply("""{"answers":{"strategy":{"choice":"gank"}}}""")
          else:
            socket.sendReply("{}", "429 Too Many Requests")
        else:
          socket.sendReply("""{"answers":{
            "guard":{"noul":0.8},
            "mode":{"choice":"hold","confidence":0.7,
              "probabilities":{"hold":0.7,"push":0.3}},
            "risk":{"score":1.5}}}""")
      elif first.contains("/slow"):
        sleep(180)
        socket.sendReply("{}")
      elif first.contains("/huge"):
        socket.sendReply(repeat('x', MaxResponseBytes + 100))
      elif first.contains("/failure"):
        socket.sendReply("{\"error\":\"spend limit\"}", "429 Too Many Requests")
      elif first.contains("/stream"):
        let stream = "data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\n\n" &
          "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n" &
          "data: [DONE]\n\n"
        socket.sendReply(stream)
      else:
        socket.sendReply("""{"choices":[{"message":{"content":"hello",
          "tool_calls":[{"id":"call-1","function":{"name":"move",
            "arguments":"{}"}}]}}],"usage":{"total_tokens":12}}""")
    except OSError:
      discard # Oversize and timed-out requests deliberately close early.
    socket.close()
  if paired != nil:
    paired.close()
  server.close()

proc settle(client: LlmClient, id: int32, tick: int32) =
  ## Bounds the test wait independently of the request's own deadline.
  let deadline = getMonoTime() + initDuration(seconds = 3)
  while client.poll(id) == 0:
    doAssert getMonoTime() < deadline, "request remained pending"
    client.beginTick(tick)
    sleep(1)

echo "Testing the LLM endpoint allowlist before opening connections"
block:
  let names = [
    "COGAME_LLM", "COWORLD_LLM_ENDPOINT", "COGAME_LLM_BASE_URL",
    "COGAME_LLM_KEY", "OPENROUTER_API_KEY", "COGAME_LLM_INTERVAL",
    "COGAME_LLM_TIMEOUT_MS", "COWORLD_LLM_MODEL"
  ]
  var saved: seq[(string, bool, string)]
  for name in names:
    saved.add (name, existsEnv(name), getEnv(name))
    delEnv(name)
  defer:
    for (name, existed, value) in saved:
      if existed:
        putEnv(name, value)
      else:
        delEnv(name)
  putEnv("COGAME_LLM_KEY", "test-only-key")
  doAssert llmConfig().baseUrl == "https://openrouter.ai/api"
  for endpoint in [
    "https://openrouter.ai/api", "https://OPENROUTER.AI:443/api/",
    "http://localhost:9100", "https://localhost:9100/api",
    "http://127.0.0.1:12345", "http://[::1]:9100"
  ]:
    for name in ["COGAME_LLM_BASE_URL", "COWORLD_LLM_ENDPOINT"]:
      putEnv(name, endpoint)
      let config = llmConfig()
      discard newLlmClient(0, config)
      doAssert config.sidecar == (name == "COWORLD_LLM_ENDPOINT")
      delEnv(name)
  putEnv("COWORLD_LLM_ENDPOINT", "http://localhost:9100")
  putEnv("COWORLD_LLM_MODEL", "anthropic/claude-sonnet-4.6")
  doAssert llmConfig().model == "anthropic/claude-sonnet-4.6"
  delEnv("COWORLD_LLM_ENDPOINT")
  delEnv("COWORLD_LLM_MODEL")
  for endpoint in [
    "https://example.com/api", "https://openrouter.ai.evil.test/api",
    "https://evilopenrouter.ai/api", "https://localhost.evil.test",
    "http://openrouter.ai/api", "https://openrouter.ai:8443/api",
    "https://openrouter.ai/other", "https://user@openrouter.ai/api",
    "https://openrouter.ai@evil.test/api", "https://openrouter.ai/api?x=1",
    "https://openrouter.ai/api#fragment", "https://openrouter.ai/api\n",
    "https://openrouter.ai\\@evil.test/api", "https://%6fpenrouter.ai/api",
    "http://127.0.0.1:0", "http://localhost:65536", "http://localhost:abc",
    "http://192.168.1.1", "http://127.1", "http://2130706433"
  ]:
    for name in ["COGAME_LLM_BASE_URL", "COWORLD_LLM_ENDPOINT"]:
      putEnv(name, endpoint)
      var rejected = false
      try:
        discard llmConfig()
      except LlmError:
        rejected = true
      doAssert rejected, endpoint
      delEnv(name)
    var rejected = false
    try:
      discard newLlmClient(0, LlmConfig(baseUrl: endpoint))
    except LlmError:
      rejected = true
    doAssert rejected, endpoint
  let client = newLlmClient(0, LlmConfig(
    baseUrl: "http://localhost:1", interval: 1, timeoutMs: 10
  ))
  client.config.baseUrl = "https://example.com/api"
  var rejected = false
  try:
    discard client.ask("POST", "/v1/chat/completions", "{}")
  except LlmError:
    rejected = true
  doAssert rejected and not client.hasPending()

echo "Testing the native sidecar transport and complete OpenRouter payloads"
block:
  ports.open(1)
  received.open(32)
  var thread: Thread[void]
  createThread(thread, serve)
  let port = ports.recv()
  defer:
    let stop = newSocket()
    stop.connect("127.0.0.1", Port(port))
    stop.send("GET /stop HTTP/1.1\r\n\r\n")
    stop.close()
    joinThread(thread)
    ports.close()
    received.close()
  let config = LlmConfig(
    baseUrl: "http://127.0.0.1:" & $port,
    key: "must-not-be-sent", sidecar: true,
    model: "test/model", oracleModel: DefaultOracleModel,
    interval: 2, timeoutMs: 1000
  )
  let client = newLlmClient(3, config)
  client.beginTick(0)
  let body = """{"model":"test/model","messages":[{"role":"user",
    "content":[{"type":"text","text":"hello"}]}],
    "tools":[{"type":"function","function":{"name":"move"}}],
    "response_format":{"type":"json_object"},"provider":{"order":["test"]}}"""
  let id = client.ask("POST", "/v1/chat/completions", body)
  doAssert id == 1
  doAssert client.ask("POST", "/v1/chat/completions", body) == 0
  client.settle(id, 1)
  doAssert client.poll(id) == 1
  doAssert client.text(id) == "hello"
  doAssert client.response(id).contains("tool_calls")
  let request = received.recv()
  doAssert request.endsWith(body)
  doAssert request.contains("X-Coworld-Player-Slot: 3")
  doAssert not request.toLowerAscii.contains("authorization:")
  doAssert not request.contains("must-not-be-sent")
  doAssert client.ready == 1

  echo "Testing normal strings through the published BASIC chat example"
  let chatClient = newLlmClient(4, config)
  var chatHost = initHost()
  chatClient.addFunctions(chatHost)
  let chatSource = readFile(
    currentSourcePath().parentDir / "../examples/inference/chat.bas"
  )
  var chatRuntime = initRuntime(compile(chatSource, chatHost), chatHost)
  chatClient.bindRuntime(chatRuntime)
  chatClient.beginTick(0)
  discard chatRuntime.run()
  waitForRequests([chatClient.requestPoller()])
  doAssert received.recv().contains("test/model")
  chatRuntime.restart()
  chatClient.beginTick(1)
  discard chatRuntime.run()
  doAssert chatRuntime.getString(chatRuntime.getGlobalValue("answer$")) ==
    "hello"

  echo "Testing a mailbox DM becomes an LLM reply to the original sender"
  block:
    let
      directory = createTempDir("polyworld-mailbox-llm-", "")
      idle = directory / "idle.bas"
      responder = currentSourcePath().parentDir /
        "../examples/inference/mailbox_llm.bas"
      settings = [
        ("COWORLD_LLM_ENDPOINT", config.baseUrl),
        ("COGAME_LLM", "on"),
        ("COGAME_LLM_MODEL", "test/model")
      ]
    var saved: seq[(string, bool, string)]
    for (name, value) in settings:
      saved.add (name, existsEnv(name), getEnv(name))
      putEnv(name, value)
    defer:
      removeDir(directory)
      for (name, existed, value) in saved:
        if existed:
          putEnv(name, value)
        else:
          delEnv(name)
    writeFile(idle, "idle = 0")
    let game = newGame(generateMap(54), 240, 10, false, ReplayData(),
      drafting = false)
    game.loadBots([
      BotGroup(path: idle, count: 1),
      BotGroup(path: responder, count: 1),
      BotGroup(path: idle, count: 8)
    ])
    doAssert game.sendChat(0, 1, "What should we do?") == 1
    game.world.tick = 1
    game.runBotDecisions()
    let vm = game.heroVms[1]
    doAssert not vm.failed, vm.lastError
    waitForRequests([vm.pollRequests])
    doAssert received.recv().contains("What should we do?")
    game.world.tick = 2
    game.runBotDecisions()
    doAssert not vm.failed, vm.lastError
    let inbox = game.inboxes[0]
    doAssert inbox.count == 1
    doAssert inbox.messages[inbox.first] == "hello"
    doAssert inbox.pop() == 1
    doAssert game.inboxes[1].count == 0

  echo "Testing raw streaming replies, HTTP failures, and response bounds"
  client.beginTick(2)
  let stream = client.ask("POST", "/v1/stream", "{\"stream\":true}")
  doAssert client.response(id).contains("tool_calls")
  client.settle(stream, 3)
  doAssert client.poll(id) == -1
  doAssert client.status(id) == 0
  doAssert client.response(id) == ""
  doAssert client.error(id).contains("expired")
  doAssert client.text(stream) == "hello"
  doAssert client.response(stream).endsWith("data: [DONE]\n\n")
  discard received.recv()
  client.beginTick(4)
  let failed = client.ask("POST", "/v1/failure", "{}")
  client.settle(failed, 5)
  doAssert client.poll(failed) == -1
  doAssert client.status(failed) == 429
  doAssert client.response(failed).contains("spend limit")
  discard received.recv()
  client.beginTick(6)
  let huge = client.ask("POST", "/v1/huge", "{}")
  client.settle(huge, 7)
  doAssert client.poll(huge) == -1
  doAssert client.response(huge).len <= MaxResponseBytes
  discard received.recv()

  echo "Testing native Jev flattening and structured BASIC strings"
  let scriptClient = newLlmClient(5, config)
  var host = initHost()
  scriptClient.addFunctions(host)
  let program = compile("""
if request = 0 then
  oracleState("candidates[0].hp", 3)
  oracleQuestion("guard", 0, "Guard the objective?")
  oracleCriterion("guard", "true", "We are hurt.")
  oracleCriterion("guard", "false", "We can safely advance.")
  oracleQuestion("mode", 2, "Choose an objective.")
  oracleCriterion("mode", "hold", "Hold.")
  oracleCriterion("mode", "push", "Advance.")
  oracleQuestion("risk", 1, "How risky?")
  oracleCriterion("risk", "", "Safe.")
  oracleCriterion("risk", "", "Risky.")
  request = oracleAsk()
else
  status = oraclePoll(request)
  guard = oracleAnswer(request, "guard")
  mode = oracleAnswer(request, "mode")
  risk = oracleAnswer(request, "risk")
  probability = oracleProbability(request, "mode", "push")
end if
""", host)
  var runtime = initRuntime(program, host)
  scriptClient.bindRuntime(runtime)
  scriptClient.beginTick(0)
  discard runtime.run()
  waitForRequests([scriptClient.requestPoller()])
  let sent = received.recv()
  doAssert sent.contains("\"candidates\":[{\"hp\":3}]")
  doAssert sent.contains(DefaultOracleModel)
  runtime.restart()
  scriptClient.beginTick(1)
  discard runtime.run()
  doAssert runtime.getGlobal("status") == 3
  doAssert runtime.getGlobal("guard") == 800
  doAssert runtime.getGlobal("mode") == 0
  doAssert runtime.getGlobal("risk") == 1500
  doAssert runtime.getGlobal("probability") == 300
  let answered = runtime.getGlobal("request")
  doAssert scriptClient.oracle.poll(answered) == 3
  runtime.restart()
  runtime.setGlobal("request", 0)
  scriptClient.beginTick(2)
  discard runtime.run()
  let replacement = runtime.getGlobal("request")
  doAssert replacement > answered
  doAssert scriptClient.oracle.poll(answered) == 3
  waitForRequests([scriptClient.requestPoller()])
  discard received.recv()
  doAssert scriptClient.oracle.poll(replacement) == 3
  doAssert scriptClient.oracle.poll(answered) == -1
  doAssert scriptClient.oracle.answer(answered, "guard").value == -1
  doAssert scriptClient.response(answered) == ""
  scriptClient.close()
  doAssert scriptClient.oracle.poll(replacement) == -1
  doAssert scriptClient.response(replacement) == ""

  echo "Testing empty JEV answers and timeouts settle BASIC polling"
  block:
    var short = config
    short.timeoutMs = 40
    for reply in [
      "{\"answers\":{}}", "{}", "{\"answers\":null}",
      "{\"answers\":{\"guard\":{\"noul\":\"invalid\"}}}",
      "not json", "delay"
    ]:
      let testClient = newLlmClient(0,
        if reply == "delay": short else: config)
      var host = initHost()
      testClient.addFunctions(host)
      let program = compile("""
if request = 0 then
  oracleStateText("regression", fixture$)
  oracleQuestion("guard", 0, "Guard?")
  oracleCriterion("guard", "true", "Yes")
  oracleCriterion("guard", "false", "No")
  request = oracleAsk()
else
  result = oraclePoll(request)
end if
""", host)
      var runtime = initRuntime(program, host)
      testClient.bindRuntime(runtime)
      runtime.setGlobal("fixture$", runtime.putString(reply))
      testClient.beginTick(0)
      discard runtime.run()
      let id = runtime.getGlobal("request")
      doAssert id > 0 and testClient.oracle.poll(id) == 0
      testClient.settle(id, 1)
      discard received.recv()
      runtime.restart()
      testClient.beginTick(2)
      discard runtime.run()
      doAssert runtime.getGlobal("result") == -1
      doAssert not testClient.hasPending()
      doAssert testClient.oracle.pending == 0
      if reply == "delay":
        doAssert testClient.error(id).contains("timed out")
      else:
        doAssert testClient.status(id) == 200
        doAssert testClient.ready == 0
        runtime.restart()
        runtime.setGlobal("request", 0)
        runtime.setGlobal("fixture$", runtime.putString(
          "{\"answers\":{\"guard\":{\"noul\":0.8}}}"
        ))
        testClient.beginTick(2)
        discard runtime.run()
        let next = runtime.getGlobal("request")
        doAssert next > id
        testClient.settle(next, 3)
        discard received.recv()
        doAssert testClient.oracle.poll(next) == 1
      testClient.close()

  echo "Testing BASIC readback of the captured live OpenRouter JEV response"
  block:
    let scriptClient = newLlmClient(0, config)
    var host = initHost()
    scriptClient.addFunctions(host)
    let program = compile(JevRequest, host)
    var runtime = initRuntime(program, host)
    scriptClient.bindRuntime(runtime)
    scriptClient.beginTick(0)
    discard runtime.run()
    doAssert runtime.getGlobal("request") > 0
    waitForRequests([scriptClient.requestPoller()])
    let request = received.recv()
    doAssert request.startsWith("POST /v1/systemone HTTP/")
    doAssert request.contains("X-Coworld-Player-Slot: 0")
    doAssert not request.toLowerAscii.contains("authorization:")
    doAssert not request.contains("must-not-be-sent")
    runtime.restart()
    scriptClient.beginTick(1)
    discard runtime.run()
    doAssert runtime.getGlobal("answers") == 2
    doAssert runtime.getGlobal("strategy") == 0
    doAssert runtime.getGlobal("lane") == 1
    doAssert runtime.getString(runtime.getGlobalValue("model$")) ==
      "typesafe/jev-1.13-20260917"

  echo "Testing GotA's JEV bot follows strategy and lane advice periodically"
  block:
    let settings = [
      ("COWORLD_LLM_ENDPOINT", config.baseUrl),
      ("COGAME_LLM", "on"),
      ("COGAME_ORACLE", "on"),
      ("COGAME_LLM_INTERVAL", "1"),
      ("COGAME_LLM_TIMEOUT_MS", "1000"),
      ("COGAME_ORACLE_MODEL", DefaultOracleModel)
    ]
    var saved: seq[(string, bool, string)]
    for (name, value) in settings:
      saved.add (name, existsEnv(name), getEnv(name))
      putEnv(name, value)
    defer:
      for (name, existed, value) in saved:
        if existed:
          putEnv(name, value)
        else:
          delEnv(name)
    let
      root = currentSourcePath().parentDir / "../examples/gods_of_the_arena"
      game = newGame(generateMap(54), 240, 10, false, ReplayData(),
        drafting = false)
    game.recorder = initReplayRecorder(game.currentSetup(16000), game.map.preset)
    game.loadBots([
      BotGroup(path: root / "players/jev.bas", count: 1),
      BotGroup(path: root / "players/rusher.bas", count: 9)
    ])
    let vm = game.heroVms[0]
    for round in 0 ..< 7:
      let tick = int32([1, 361, 4321, 4681, 14401, 14761, 15121][round])
      game.world.tick = tick
      game.runBotDecisions()
      doAssert not vm.failed, vm.lastError
      doAssert vm.runtime.getGlobal("request") > 0
      waitForRequests([vm.pollRequests])
      let
        sent = received.recv()
        body = parseDocument(sent[sent.find('{') .. ^1])
      doAssert sent.contains("X-Coworld-Player-Slot: 0")
      let expectedStage =
        if round < 2: "early laning and farming"
        elif round < 4: "mid game rotations and objectives"
        else: "late game and finishing the enemy god"
      doAssert body["state"]["stage"].getStr == expectedStage
      doAssert body["state"]["situation"].getStr.contains("HP:")
      doAssert body["state"]["notes"][0].getStr.contains("allied heroes=")
      doAssert body["questions"]["strategy"]["criteria"].len == 5
      doAssert body["questions"]["lane"]["criteria"].len == 3
      game.world.tick = tick + 1
      game.runBotDecisions()
      doAssert not vm.failed, vm.lastError
      doAssert vm.runtime.getGlobal("request") == 0
      let
        expectedStrategy = [1, 3, 2, 4, 0, 0, 0][round]
        expectedLane = [2, 0, 1, 2, 0, 0, 0][round]
      doAssert vm.runtime.getGlobal("strategy") == expectedStrategy
      doAssert vm.runtime.getGlobal("chosenLane") == expectedLane
      if round == 0:
        doAssert vm.runtime.getGlobalValue("goalX").asFixed >
          fixed(int32(mapTiles() * 8 div 10))
      elif round == 1:
        doAssert vm.runtime.getGlobalValue("goalX").asFixed ==
          vm.runtime.getGlobalValue("homeX").asFixed
      game.world.tick = tick + 7
      game.runBotDecisions()
      doAssert not vm.failed, vm.lastError
      doAssert not vm.pollRequests()
      doAssert not received.tryRecv().dataAvailable
    doAssert game.recorder.data.actions.len > 0
    game.world.heroes[0].hp = 1
    game.world.tick += 6
    game.runBotDecisions()
    doAssert not vm.failed, vm.lastError
    doAssert vm.runtime.getGlobal("retreating") == 1
    var lastOwn: ReplayAction
    for action in game.recorder.data.actions:
      if action.heroId == game.world.heroes[0].id:
        lastOwn = action
    doAssert lastOwn.kind == ActionWalkTo
    doAssert lastOwn.first == vm.runtime.getGlobalValue("spawnX").asFixed.toInt

  echo "Testing the barrier submits all seats before waiting for any seat"
  let
    first = newLlmClient(0, config)
    second = newLlmClient(1, config)
  first.beginTick(10)
  second.beginTick(10)
  let
    firstId = first.ask("POST", "/v1/pair", "{}")
    secondId = second.ask("POST", "/v1/pair", "{}")
  waitForRequests([first.requestPoller(), second.requestPoller()])
  doAssert first.poll(firstId) == 1
  doAssert second.poll(secondId) == 1
  discard received.recv()
  discard received.recv()

  echo "Testing timeouts settle a barrier instead of advancing forever"
  var short = config
  short.timeoutMs = 40
  let slow = newLlmClient(2, short)
  slow.beginTick(10)
  let slowId = slow.ask("POST", "/v1/slow", "{}")
  waitForRequests([slow.requestPoller()])
  doAssert slow.poll(slowId) == -1
  doAssert slow.error(slowId).contains("timed out")
  discard received.recv()
  doAssert slow.ready == -1
  doAssert slow.ask("POST", "/v1/chat/completions", "{}") == 0
  let deadline = getMonoTime() + initDuration(seconds = 3)
  while slow.ready < 0:
    doAssert getMonoTime() < deadline, "late response was not drained"
    slow.beginTick(12)
    sleep(1)
  doAssert slow.poll(slowId) == -1
  doAssert slow.response(slowId) == ""
  let retry = slow.chat("", "after timeout")
  doAssert retry > slowId
  slow.settle(retry, 12)
  doAssert slow.text(retry) == "hello"
  discard received.recv()
  slow.close()
  client.close()

  echo "Testing resets discard old replies and closed clients can reopen"
  client.beginTick(20)
  let abandoned = client.chat("", "before reset")
  doAssert abandoned > 0
  client.beginTick(0)
  doAssert not client.hasPending()
  let resetDeadline = getMonoTime() + initDuration(seconds = 3)
  while client.ready < 0:
    doAssert getMonoTime() < resetDeadline, "reset request was not drained"
    client.beginTick(0)
    sleep(1)
  doAssert client.poll(abandoned) == -1
  doAssert client.response(abandoned) == ""
  discard received.recv()
  let reopened = client.chat("", "after reset")
  client.settle(reopened, 0)
  doAssert client.text(reopened) == "hello"
  discard received.recv()
  client.close()

echo "Testing invalid JSON and API paths fail at the library boundary"
block:
  for body in ["{broken}", repeat('[', 65) & "0" & repeat(']', 65)]:
    var rejected = false
    try:
      discard parseDocument(body)
    except LlmError:
      rejected = true
    doAssert rejected
  let client = newLlmClient(0, LlmConfig(
    baseUrl: "http://127.0.0.1:1", sidecar: true, timeoutMs: 10
  ))
  for path in ["/v1/../admin", "/v1/%2e%2e/admin", "/v1/a\x00b"]:
    var rejected = false
    try:
      discard client.ask("POST", path, "{}")
    except LlmError:
      rejected = true
    doAssert rejected
  let scriptClient = newLlmClient(0, LlmConfig())
  var host = initHost()
  scriptClient.addFunctions(host)
  for name in ["chat", "jev", "request"]:
    let source = readFile(currentSourcePath().parentDir /
      "../examples/inference" / (name & ".bas"))
    discard compile(source, host)

echo "Testing wall-clock pacing and unlimited speed"
block:
  let start = getMonoTime()
  var pacer = initTickPacer(100)
  for i in 0 ..< 4:
    pacer.pace()
  doAssert (getMonoTime() - start).inMilliseconds >= 35
  var unlimited = initTickPacer(0)
  unlimited.pace()
