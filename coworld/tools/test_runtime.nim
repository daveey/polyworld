## Exercises the file handoff against compiled native Coworld games.

import
  std/[json, monotimes, net, os, osproc, strtabs, strutils, tempfiles,
    times, uri],
  crunchy, jsony

const
  Root = currentSourcePath().parentDir.parentDir.parentDir
  LogLimit = 10 * 1024 * 1024
  SocketTimeout = 5000
  Games = [("gota", 10), ("lvd", 2), ("cta", 4)]

proc fileUri(path: string): string =
  ## Encodes one absolute path for the runner's local file handoff.
  "file://" & encodeUrl(path, usePlus = false).replace("%2F", "/")

proc sourceHash(source: string): string =
  ## Computes the same SHA-256 content identifier as the platform.
  result = "sha256:"
  for value in sha256(cast[pointer](source.cstring), source.len):
    result.add value.toHex(2).toLowerAscii()

proc readBytes(socket: Socket, count: int): string =
  ## Reads a bounded protocol field without waiting forever on a broken game.
  while result.len < count:
    let bytes = socket.recv(count - result.len, timeout = SocketTimeout)
    doAssert bytes.len > 0, "server closed the connection early"
    result.add bytes

proc readHeaders(socket: Socket): string =
  ## Reads one HTTP response header without consuming a WebSocket frame.
  while not result.endsWith("\r\n\r\n"):
    doAssert result.len < 16 * 1024, "HTTP headers exceed the test limit"
    result.add socket.readBytes(1)

proc connectLocal(port: Port): Socket =
  ## Opens one local contract connection with a fixed timeout.
  result = newSocket()
  try:
    result.connect("127.0.0.1", port, timeout = SocketTimeout)
  except CatchableError:
    result.close()
    raise

proc checkHttp(port: Port, path: string) =
  ## Requires a successful response from one advertised HTTP endpoint.
  let socket = connectLocal(port)
  defer:
    socket.close()
  socket.send(
    "GET " & path & " HTTP/1.1\r\nHost: 127.0.0.1:" & $port &
    "\r\nConnection: close\r\n\r\n"
  )
  let headers = socket.readHeaders()
  doAssert headers.splitLines()[0].splitWhitespace()[0 .. 1] ==
    @["HTTP/1.1", "200"], path & ": " & headers

proc readFrame(socket: Socket): tuple[opcode: int, payload: string] =
  ## Reads the short, unmasked frames used by the status and Pong contract.
  let header = socket.readBytes(2)
  doAssert (header[0].ord and 0x80) != 0, "fragmented contract frame"
  doAssert (header[0].ord and 0x70) == 0, "unexpected frame extension"
  doAssert (header[1].ord and 0x80) == 0, "server frame must not be masked"
  let length = header[1].ord and 0x7f
  doAssert length < 126, "contract frames must fit the short frame format"
  result.opcode = header[0].ord and 0x0f
  result.payload = socket.readBytes(length)

proc checkWebSocket(port: Port) =
  ## Checks the upgrade, one status message, and an exact Ping/Pong exchange.
  let socket = connectLocal(port)
  defer:
    socket.close()
  socket.send(
    "GET /global HTTP/1.1\r\nHost: 127.0.0.1:" & $port & "\r\n" &
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
    "Sec-WebSocket-Version: 13\r\n" &
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
  )
  let headers = socket.readHeaders()
  doAssert headers.splitLines()[0].splitWhitespace()[0 .. 1] ==
    @["HTTP/1.1", "101"], headers
  doAssert headers.contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  let status = socket.readFrame()
  doAssert status.opcode == 1, "expected one text status message"
  doAssert status.payload.fromJson(JsonNode)["type"].getStr() == "status"
  const
    Payload = "coworld-certification-ping"
    Mask = "test"
  var ping = "\x89" & char(0x80 or Payload.len) & Mask
  for i, character in Payload:
    ping.add char(character.ord xor Mask[i mod Mask.len].ord)
  socket.send(ping)
  let pong = socket.readFrame()
  doAssert pong.opcode == 10, "expected Pong after Ping"
  doAssert pong.payload == Payload, "Pong changed the Ping payload"

proc episode(
    game: string,
    count: int,
    scripts: seq[string],
    failure = false,
    ticks = 240,
    expectedOutput = ""
) =
  ## Runs one local roster and inspects outputs at the completion marker.
  doAssert scripts.len == count
  let directory = createTempDir("coworld-" & game & "-", "")
  defer:
    removeDir(directory)
  let listener = newSocket()
  listener.bindAddr(Port(0), "127.0.0.1")
  let port = listener.getLocalAddr()[1]
  listener.close()
  let
    config = %*{
      "tokens": [], "players": [], "seed": 2026, "max_ticks": ticks
    }
    seats = newJArray()
    env = newStringTable(modeCaseSensitive)
    logPath = directory / "game.log"
  var
    boundedLog = false
    instructionFailure = false
  for key, value in envPairs():
    env[key] = value
  env["COGAME_HOST"] = "127.0.0.1"
  env["COGAME_PORT"] = $port
  for slot, source in scripts:
    let path = directory / ("player-" & $slot)
    writeFile(path, source)
    config["tokens"].add(%("token-" & $slot))
    config["players"].add %*{"name": "HOSTED-NAME-" & $slot & ".BAS"}
    seats.add %*{
      "slot": slot,
      "file_uri": path.fileUri(),
      "content_hash": source.sourceHash(),
      "size_bytes": source.len,
      "log_uri": (directory / ("player-" & $slot & ".log")).fileUri(),
      "artifact_uri": (directory / ("player-" & $slot & ".zip")).fileUri()
    }
    boundedLog = boundedLog or source.len > 7000
    instructionFailure = instructionFailure or source.contains("WHILE")
  let seatDocument = %*{
    "schema": "coworld-player-seats/1",
    "seats": seats,
    "player_status_uri": (directory / "status.json").fileUri()
  }
  for (key, value) in [("CONFIG", config), ("PLAYER_SEATS", seatDocument)]:
    let path = directory / (key & ".json")
    writeFile(path, value.toJson())
    env["COGAME_" & key & "_URI"] = path.fileUri()
  for (key, name) in [
    ("RESULTS", "results.json"),
    ("SAVE_REPLAY", "replay"),
    ("PLAYER_FAILURE", "failure.json")
  ]:
    env["COGAME_" & key & "_URI"] = (directory / name).fileUri()
  let process = startProcess(
    "/bin/sh",
    workingDir = Root,
    args = @[
      "-c",
      "exec " & quoteShell(Root / "tmp/coworld" / game) &
        " > " & quoteShell(logPath) & " 2>&1"
    ],
    env = env,
    options = {}
  )
  defer:
    if process.running():
      process.terminate()
    if process.waitForExit(5000) == -1:
      process.kill()
      discard process.waitForExit(5000)
    process.close()
  let
    marker = directory / (if failure: "failure.json" else: "results.json")
    deadline = getMonoTime() + initDuration(seconds = 120)
  while not fileExists(marker):
    doAssert process.running(), "exit " & $process.peekExitCode() &
      ": " & readFile(logPath)
    doAssert getMonoTime() < deadline, "episode timed out"
    sleep(20)
  let output = readFile(marker).fromJson(JsonNode)
  doAssert fileExists(directory / "status.json"), "completion preceded status"
  var logs: seq[string]
  for slot in 0 ..< count:
    logs.add readFile(directory / ("player-" & $slot & ".log"))
  if expectedOutput.len > 0:
    for private in logs:
      doAssert private.contains(expectedOutput), private
  for slot, private in logs:
    doAssert private.len <= LogLimit
    let marker = "PRIVATE-" & $slot
    if scripts[slot].contains(marker):
      doAssert private.contains(marker & " 1.50000")
      for otherSlot, other in logs:
        if otherSlot != slot:
          doAssert not other.contains(marker)
  doAssert not readFile(logPath).contains("PRIVATE-")
  if boundedLog:
    doAssert logs[0].len == LogLimit
    doAssert logs[0].endsWith("[Player log truncated at 10 MiB.]\n")
  if failure:
    doAssert not fileExists(directory / "results.json")
    doAssert output["failed_policy_index"].getInt() == 0
    doAssert logs[0].contains("BASIC error:")
  else:
    doAssert output["scores"].len == count
    if game == "gota":
      doAssert output["total_xp"].len == count
      for xp in output["total_xp"]:
        doAssert xp.getInt() >= 0
      for slot, score in output["scores"].elems:
        let expected = max(0, output["total_xp"][slot].getInt * 1440 -
          200 * output["ticks"].getInt) div 1440
        doAssert score.kind == JInt
        doAssert score.getInt() == expected
    else:
      for score in output["scores"]:
        doAssert score.kind == JInt
        doAssert score.getInt() in {0, 1}
      doAssert not output.hasKey("total_xp")
    let replay = readFile(directory / "replay")
    doAssert replay.len > 0
    var previous = -1
    for slot in 0 ..< count:
      let offset = replay.find("HOSTED-NAME-" & $slot & ".BAS")
      doAssert offset > previous, "replay names changed seat order"
      previous = offset
    doAssert not replay.contains("token-0")
    doAssert not replay.contains("PRIVATE-")
    for private in logs:
      doAssert private.contains("completed.") or
        private.contains("log truncated")
  checkHttp(port, "/healthz")
  checkHttp(port, "/client/global")
  checkWebSocket(port)
  doAssert process.running(), "server stopped before collection"
  if instructionFailure:
    doAssert logs[0].contains("BASIC error:")
    let status = readFile(directory / "status.json").fromJson(JsonNode)
    doAssert status["players"][0]["exit_code"].getInt() == 1
  if not failure:
    process.terminate()
    doAssert process.waitForExit(5000) == 0,
      "completed game shutdown failed"

for (game, count) in Games:
  var scripts: seq[string]
  for slot in 0 ..< count:
    scripts.add "PRINT \"PRIVATE-" & $slot & "\", 1.5\nEND\n"
  episode(game, count, scripts)
  episode(game, count, newSeq[string](count))
  for slot in 0 ..< scripts.len:
    scripts[slot] = "END\n"
  scripts[0] = "THIS IS NOT BASIC\n"
  episode(game, count, scripts, failure = true)
  scripts[0] = "WHILE 1\nWEND\n"
  episode(game, count, scripts)
  echo game, ": runtime contracts passed"

  for slot in 0 ..< scripts.len:
    scripts[slot] = """
sendChat(-2, "CHAT")
print pullMailbox$(), mailboxId()
"""
  episode(game, count, scripts, ticks = 3,
    expectedOutput = "CHAT")
  echo game, ": hosted mailbox integration passed"

episode(
  "lvd",
  2,
  @["PRINT \"" & repeat('x', 7900) & "\"\nEND\n", "END\n"],
  ticks = 28800
)
echo "10 MiB player log bound passed"
