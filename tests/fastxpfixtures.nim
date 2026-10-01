import
  std/[json, monotimes, net, os, osproc, strtabs, strutils, tables, tempfiles, times],
  curly,
  zippy/ziparchives

type TestResponse* = object
  status*: int
  headers*: HttpHeaders
  body*: string

const
  FastXpDirectory* = currentSourcePath().parentDir.parentDir / "coworld" / "fast_xp"
  ServerPath* = FastXpDirectory / "server"
  RunRoute* = "/v1/games/gota/run"

proc unusedPort*(): int =
  let socket = newSocket()
  defer: socket.close()
  socket.bindAddr(Port(0), "127.0.0.1")
  int(socket.getLocalAddr()[1])

proc environment*(root: string, port: int): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): result[key] = value
  for pair in [("FAST_XP_PORT", $port), ("FAST_XP_HOST", "127.0.0.1"),
      ("FAST_XP_WORKERS", "2"), ("FAST_XP_TOKEN", ""), ("TMPDIR", root),
      ("FAST_XP_CACHE_DIR", root / "policies")]:
    result[pair[0]] = pair[1]

proc launch*(binary, log: string, env: StringTableRef, args: seq[string] = @[]): Process =
  startProcess("/bin/sh", args = @["-c", "binary=$1; log=$2; shift 2; exec \"$binary\" \"$@\" >\"$log\" 2>&1",
    "test", binary, log] & args, env = env, options = {})

proc stop*(process: Process) =
  if process.running():
    process.terminate()
    discard process.waitForExit(140_000)
  process.close()

proc call*(base, path: string, body: JsonNode = nil, token = "",
    httpMethod = "GET"): TestResponse =
  let client = newCurly()
  defer: client.close()
  let response = client.makeRequest(
    (if body == nil: httpMethod else: "POST"), base & path,
    @[("Content-Type", "application/json"), ("Authorization", "Bearer " & token)],
    (if body == nil: "" else: $body), timeout = 150)
  TestResponse(status: response.code, headers: response.headers, body: response.body)

proc startCall*(base, path: string, body: JsonNode, token = ""): Curly =
  result = newCurly()
  result.startRequest("POST", base & path,
    @[("Content-Type", "application/json"), ("Authorization", "Bearer " & token)],
    $body, timeout = 150)

proc finish*(client: Curly): TestResponse =
  defer: client.close()
  let (response, error) = client.waitForResponse()
  if error.len > 0: raise newException(IOError, error)
  TestResponse(status: response.code, headers: response.headers, body: response.body)

proc metrics*(base: string): JsonNode =
  let response = call(base, "/v1/metrics?minutes=1440")
  doAssert response.status == 200
  parseJson(response.body)

proc archiveFiles*(bytes, root: string): OrderedTable[string, string] =
  let (file, path) = createTempFile("response-", ".zip", root)
  file.write(bytes)
  file.close()
  defer: removeFile(path)
  let archive = openZipArchive(path)
  defer: archive.close()
  result = initOrderedTable[string, string]()
  for path in archive.walkFiles(): result[path] = archive.extractFile(path)

proc records*(path: string): seq[JsonNode] =
  if fileExists(path):
    for line in lines(path):
      try: result.add parseJson(line)
      except JsonParsingError: discard # A writer may not have finished its last line.

template waitUntil*(condition: untyped, process: Process, log: string, timeoutMs = 10_000) =
  block:
    let began = getMonoTime()
    while not (condition):
      doAssert process.running(), readFile(log)
      doAssert (getMonoTime() - began).inMilliseconds < timeoutMs, readFile(log)
      sleep(20)

proc assertNoMatchFiles*(root: string) =
  for kind, path in walkDir(root):
    doAssert kind != pcDir or not path.extractFilename().startsWith("fast-xp-"),
      "Temporary match files leaked: " & path
