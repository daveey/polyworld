import
  std/[base64, json, locks, monotimes, os, osproc, posix, sequtils, sets,
    strtabs, strutils, tables, tempfiles, times],
  crunchy, curly, mummy,
  ./[neuralfixtures, fastxpfixtures]

var mockLock: Lock
initLock(mockLock)

proc digest(source: string): string =
  for value in sha256(source): result.add value.toHex(2).toLowerAscii()

proc appendRecord(root, file, value: string) =
  withLock mockLock:
    let output = open(root / file, fmAppend)
    output.writeLine(value)
    output.close()

proc mockRequest(request: mummy.Request) {.gcsafe.} =
  let root = paramStr(2)
  case request.path
  of "/healthz": request.respond(200, body = "ok")
  of "/v2/policy-files/download":
    let reference = request.queryParams["policy_ref"]
    appendRecord(root, "lookups", reference)
    if request.headers["Authorization"] != "Bearer fake-observatory-token":
      appendRecord(root, "failures", "Missing Observatory credential")
    if request.headers["X-Use-Elevated-Privileges"] != "true":
      appendRecord(root, "failures", "Missing elevation header")
    let status = if fileExists(root / "deny"): 401 else:
      case reference
      of "missing:v1": 404
      of "invalid:v1": 400
      of "nofile:v1": 409
      of "denied:v1": 403
      of "expired:v1": 401
      else: 200
    if reference == "lookup-redirect:v1":
      request.respond(302, @[("Location", "/must-not-follow")])
    elif status != 200:
      request.respond(status, body = "{\"detail\":\"do not expose upstream response bodies\"}")
    elif reference == "bad-metadata:v1":
      request.respond(200, body = "{\"oops\":true}")
    else:
      let source = if reference == "broken:v1": "print \"private-compile-secret\"\nif\n"
        else: readFile(root / "source")
      let hash = if reference == "hash-mismatch:v1": repeat('b', 64) else: digest(source)
      var metadata = %*{"policy_version_id": "11111111-1111-4111-8111-111111111111",
        "content_hash": hash, "size_bytes": source.len, "expires_in_seconds": 300,
        "download_url": "http://127.0.0.1:" & paramStr(3) & "/artifact?ref=" & reference}
      case reference
      of "size-mismatch:v1": metadata["size_bytes"] = %(source.len + 1)
      of "oversize:v1": metadata["size_bytes"] = %(16 * 1024 * 1024 + 1)
      of "unsafe-url:v1": metadata["download_url"] = %"http://example.com/bot"
      else: discard
      request.respond(200, body = $metadata)
  of "/artifact":
    let reference = request.queryParams["ref"]
    appendRecord(root, "downloads", reference)
    if request.headers["Authorization"].len > 0 or request.headers["X-Use-Elevated-Privileges"].len > 0:
      appendRecord(root, "failures", "Credentials leaked to artifact host")
    writeFile(root / "entered", "")
    let began = getMonoTime()
    while fileExists(root / "hold") and (getMonoTime() - began).inSeconds < 15: sleep(10)
    case reference
    of "slow:v1":
      sleep(11_000)
      request.respond(504)
    of "download-fails:v1": request.respond(403)
    of "redirect:v1": request.respond(302, @[("Location", "/must-not-follow")])
    else:
      request.respond(200, body = if reference == "broken:v1": "print \"private-compile-secret\"\nif\n"
        else: readFile(root / "source"))
  else:
    appendRecord(root, "failures", "Unexpected request: " & request.path)
    request.respond(404)

proc checkWorkerEnvironment() =
  for key, _ in envPairs(): doAssert not key.startsWith("FAST_XP_")
  doAssert not existsEnv("FAKE_OTHER_SECRET")
  let worker = readFile(getTempDir() / "real-worker")
  let args = allocCStringArray([worker])
  discard execv(worker.cstring, args)
  deallocCStringArray(args)
  quit("Could not execute production worker", 1)

proc source(marker: string): JsonNode =
  %*{"source": "print \"" & marker & "\"\nend"}

proc withField(body: JsonNode, key: string, value: JsonNode): JsonNode =
  result = body.copy()
  result[key] = value

proc names(files: OrderedTable[string, string]): HashSet[string] =
  toSeq(files.keys).toHashSet()

proc lineCount(path: string): int =
  if fileExists(path):
    for line in lines(path):
      if line.len > 0: inc result

proc run() =
  let root = createTempDir("api-test-", "")
  defer: removeDir(root)
  let port = unusedPort()
  let mockPort = unusedPort()
  let base = "http://127.0.0.1:" & $port
  let mockBase = "http://127.0.0.1:" & $mockPort
  let originalSource = "print \"private-opponent\"\nend"
  writeFile(root / "source", originalSource)
  writeFile(root / "real-worker", FastXpDirectory / "gota_worker")
  let env = environment(root, port)
  env["FAST_XP_TOKEN"] = "test-token"
  env["FAST_XP_OBSERVATORY_URL"] = mockBase
  env["FAST_XP_OBSERVATORY_TOKEN"] = "fake-observatory-token"
  env["FAST_XP_OBSERVATORY_ELEVATED"] = "1"
  env["FAST_XP_GOTA_WORKER"] = getAppFilename()
  env["FAKE_OTHER_SECRET"] = "must-not-reach-worker"
  let mockLog = root / "mock.log"
  let mock = launch(getAppFilename(), mockLog, env, @["--mock", root, $mockPort])
  defer: stop(mock)
  let log = root / "server.log"
  let process = launch(ServerPath, log, env)
  defer:
    removeFile(root / "hold")
    stop(process)
  waitUntil(records(log).anyIt(it["event"].getStr() == "server_started"), process, log)
  var mockReady = false
  waitUntil((block:
    try: mockReady = (call(mockBase, "/healthz")).status == 200
    except CatchableError: discard
    mockReady), mock, mockLog)
  proc api(path: string, body: JsonNode = nil, token = "test-token",
      httpMethod = "GET"): TestResponse =
    call(base, path, body, token, httpMethod)
  doAssert (api("/")).status == 200
  doAssert "color-scheme:dark" in (api("/")).body
  doAssert (api("/v1/metrics?minutes=1440")).status == 200
  doAssert (api("/v1/metrics?minutes=1")).status == 400
  doAssert (api("/v1/metrics", httpMethod = "POST")).status == 405
  doAssert (api("/docs/llms.txt")).status == 200
  doAssert "run.md" in (api("/docs/llms.txt")).body
  doAssert "policy" in (api("/docs/run.md")).body
  doAssert (api("/unknown")).status == 404
  doAssert (api(RunRoute)).status == 405
  doAssert (api(RunRoute, %*{}, token = "wrong")).status == 401
  let body = %*{"seed": 743478993, "config": {"max_ticks": 240},
    "roster": [{"player": {"policy_ref": "relh:v231"}, "slot": -1}]}
  var invalids: seq[JsonNode]
  for value in [%0, %11, %true]: invalids.add body.withField("num_episodes", value)
  invalids.add body.withField("num_episodes", %2).withField("seed", %2147483647)
  for value in [%true, %2147483648'i64]: invalids.add body.withField("seed", value)
  invalids.add body.withField("roster", %*[])
  invalids.add body.withField("extra", %1)
  for ticks in [0, 28801]: invalids.add body.withField("config", %*{"max_ticks": ticks})
  invalids.add body.withField("players", %*[{"source": "END"}])
  for player in [%*{}, %*{"source": "END", "policy_ref": "x:v1"},
      %*{"source": " "}, %*{"source": 123}, %*{"source": "END\0"},
      %*{"source": "END", "canReadLog": true}, %*{"policy_ref": ""}, %*{"policy_ref": 123}]:
    invalids.add body.withField("roster", %*[{"player": player}])
  for slot in [10, 0]:
    invalids.add body.withField("roster", %*[{"player": {"policy_ref": "x:v1"}, "slot": slot}])
  invalids.add body.withField("roster", %*[
    {"player": {"policy_ref": "x:v1"}, "slot": 0}, {"player": {"policy_ref": "x:v1"}, "slot": 0}])
  for invalid in invalids: doAssert (api(RunRoute, invalid)).status == 400, $invalid
  let mixed = %*[{"player": source("mine"), "slot": 0},
    {"player": {"policy_ref": "relh:v231"}, "slot": -1}]
  let cache = root / "policies"
  let hash = digest(originalSource)
  for roster in [mixed, body["roster"], %*[{"player": {"policy_ref": "109b99c1-3bb7-4276-b17e-378b43a97874"}}]]:
    let before = lineCount(root / "lookups")
    let response = api(RunRoute, body.withField("roster", roster))
    doAssert response.status == 200, response.body
    doAssert lineCount(root / "lookups") == before + 1
    let files = archiveFiles(response.body, root)
    var expected = ["replay.replay"].toHashSet()
    if roster == mixed:
      expected.incl "logs/slot-0.txt"
      doAssert "mine" in files["logs/slot-0.txt"]
    doAssert files.names() == expected
  doAssert lineCount(root / "downloads") == 1
  doAssert readFile(cache / hash) == originalSource
  doAssert getFilePermissions(cache) == {fpUserRead, fpUserWrite, fpUserExec}
  doAssert getFilePermissions(cache / hash) == {fpUserRead, fpUserWrite}
  writeFile(root / "deny", "")
  doAssert (api(RunRoute, body)).status == 502
  removeFile(root / "deny")
  writeFile(cache / hash, "corrupt")
  doAssert (api(RunRoute, body)).status == 200
  doAssert lineCount(root / "downloads") == 2
  doAssert readFile(cache / hash) == originalSource
  for (reference, expected) in [("missing:v1", 404), ("invalid:v1", 400), ("nofile:v1", 409),
      ("denied:v1", 502), ("expired:v1", 502), ("hash-mismatch:v1", 502),
      ("size-mismatch:v1", 502), ("bad-metadata:v1", 502), ("unsafe-url:v1", 502),
      ("oversize:v1", 502), ("download-fails:v1", 502), ("redirect:v1", 502),
      ("lookup-redirect:v1", 502), ("slow:v1", 504), ("broken:v1", 422)]:
    removeFile(cache / hash)
    let response = api(RunRoute, body.withField("roster", %*[{"player": {"policy_ref": reference}}]))
    doAssert response.status == expected, reference & ": " & $response.status & " " & response.body
    for secret in ["private-compile-secret", "upstream response bodies", "fake-observatory-token"]:
      doAssert secret notin response.body
  doAssert not fileExists(cache / repeat('b', 64))
  for path in walkFiles(cache / "*.part"): doAssert false, "Leaked download: " & path
  removeFile(cache / hash)
  removeFile(root / "entered")
  writeFile(root / "hold", "")
  let beforeDownloads = lineCount(root / "downloads")
  let beforeLookups = lineCount(root / "lookups")
  var pending: seq[Curly]
  for _ in 0 ..< 16: pending.add startCall(base, RunRoute, body, "test-token")
  try:
    waitUntil(fileExists(root / "entered"), process, log, 5000)
    waitUntil(lineCount(root / "lookups") >= beforeLookups + 16, process, log, 5000)
    doAssert lineCount(root / "lookups") == beforeLookups + 16
    doAssert (api("/healthz")).status == 200
    let overflow = api(RunRoute, body)
    doAssert overflow.status == 429 and overflow.headers["Retry-After"] == "5"
    let m = metrics(base)
    doAssert m["admitted_requests"].getInt() == 16 and m["rejected_requests"].getInt() >= 1
  finally: removeFile(root / "hold")
  for request in pending: doAssert (finish(request)).status == 200
  doAssert lineCount(root / "downloads") == beforeDownloads + 1
  doAssert lineCount(root / "failures") == 0
  doAssert "fake-observatory-token" notin readFile(log)
  let package = zipFixture([("policy.bas", "end\n"), ("model.bin", repeat('x', 2 * 1024 * 1024))])
  writeFile(root / "source", package)
  let packageRoster = %*[{"slot": 0, "player": {"policy_ref": "package:v1"}},
    {"player": {"source": "end"}}]
  let packaged = api(RunRoute, body.withField("roster", packageRoster))
  doAssert packaged.status == 200, packaged.body
  doAssert readFile(cache / digest(package)) == package
  var packageNames = ["replay.replay"].toHashSet()
  for slot in 1 ..< 10: packageNames.incl "logs/slot-" & $slot & ".txt"
  doAssert archiveFiles(packaged.body, root).names() == packageNames
  let upload = zipFixture([("nested/policy.bas", "print \"uploaded-package\"\nend\n"),
    ("assets/data.bin", repeat('x', 5 * 1024 * 1024))])
  let uploaded = %*{"package_base64": encode(upload)}
  let uploadRoster = %*[{"slot": 0, "player": uploaded},
    {"slot": 5, "player": source("inline-seat")}, {"player": {"policy_ref": "package:v1"}}]
  let response = api(RunRoute, body.withField("roster", uploadRoster))
  doAssert response.status == 200, response.body
  let files = archiveFiles(response.body, root)
  doAssert files.names() == ["replay.replay", "logs/slot-0.txt", "logs/slot-5.txt"].toHashSet()
  doAssert "uploaded-package" in files["logs/slot-0.txt"]
  doAssert "inline-seat" in files["logs/slot-5.txt"]
  for player in [%*{"package_base64": "!invalid!"}, %*{"package_base64": "ZW5k"},
      %*{"package_base64": 1}, %*{"package_base64": ""},
      uploaded.withField("source", %"end"), uploaded.withField("policy_ref", %"package:v1")]:
    doAssert (api(RunRoute, body.withField("roster", %*[{"player": player}]))).status == 400
  let tooLarge = encode("PK\x03\x04" & repeat('x', 16 * 1024 * 1024 - 3))
  doAssert (api(RunRoute, body.withField("roster",
    %*[{"player": {"package_base64": tooLarge}}]))).status == 413
  for files in [@[("../escape.bas", "end")], @[("a.bas", "end"), ("b.bas", "end")],
      @[("data.bin", "x")], @[("policy.bas", "if\n")]]:
    let player = %*{"package_base64": encode(zipFixture(files))}
    doAssert (api(RunRoute, body.withField("roster", %*[{"player": player}]))).status == 422
  let batch = body.withField("num_episodes", %3).withField("roster", %*[
    {"slot": 0, "player": source("pinned")}, {"player": source("moving")},
    {"player": {"policy_ref": "package:v1"}}])
  var hashes: seq[seq[string]]
  let before = lineCount(root / "lookups")
  for _ in 0 ..< 2:
    let response = api(RunRoute, batch)
    doAssert response.status == 200, response.body
    let files = archiveFiles(response.body, root)
    let manifest = parseJson(files["manifest.json"])
    doAssert manifest["request_id"].getStr() == response.headers["X-Request-ID"]
    var current: seq[string]
    var expected = ["manifest.json"].toHashSet()
    for i, game in toSeq(manifest["games"].items):
      doAssert game["seed"].getInt() == body["seed"].getInt() + i
      doAssert game["status"].getStr() == "completed" and game["active_bots"].getInt() == 10
      var seats = @[0]
      for j in 0 ..< 9: seats.add 1 + ((j - i) mod 2 + 2) mod 2
      doAssert game["roster_entries_by_slot"] == %seats
      let prefix = "games/" & align($i, 3, '0') & "/"
      expected.incl prefix & "replay.replay"
      current.add digest(files[prefix & "replay.replay"])
      for slot, entry in seats:
        if entry != 2:
          let path = prefix & "logs/slot-" & $slot & ".txt"
          expected.incl path
          doAssert (if slot == 0: "pinned" else: "moving") in files[path]
    doAssert files.names() == expected
    hashes.add current
  doAssert hashes[0] == hashes[1]
  doAssert lineCount(root / "lookups") == before + 2
  var rosters: seq[(JsonNode, seq[string])]
  rosters.add (%*[{"player": source("all-seats")}], newSeqWith(10, "all-seats"))
  var reversed = newJArray()
  for slot in countdown(9, 0): reversed.add %*{"slot": slot, "player": source("seat-" & $slot)}
  rosters.add (reversed, toSeq(0 ..< 10).mapIt("seat-" & $it))
  rosters.add (%*[{"slot": 5, "player": source("pinned")},
    {"player": source("open-a")}, {"player": source("open-b")}],
    @["open-a", "open-b", "open-a", "open-b", "open-a", "pinned", "open-b", "open-a", "open-b", "open-a"])
  for (roster, markers) in rosters:
    let response = api(RunRoute, body.withField("roster", roster))
    doAssert response.status == 200, response.body
    doAssert response.headers["Content-Type"] == "application/zip"
    doAssert response.headers["Cache-Control"] == "no-store"
    doAssert response.headers["Server-Timing"].startsWith("run;dur=")
    let files = archiveFiles(response.body, root)
    var expected = ["replay.replay"].toHashSet()
    for slot in 0 ..< 10: expected.incl "logs/slot-" & $slot & ".txt"
    doAssert files.names() == expected and files["replay.replay"].len > 0
    for slot, marker in markers:
      let output = files["logs/slot-" & $slot & ".txt"]
      doAssert marker in output and "completed" in output and "BASIC error" notin output
  let broken = api(RunRoute, body.withField("roster", %*[{"player": {"source": "if\n"}}]))
  doAssert broken.status == 422 and "slot 0" in parseJson(broken.body)["error"].getStr()
  doAssert (api("/healthz")).status == 200
  assertNoMatchFiles(root)
  let m = metrics(base)
  doAssert m["cache_hits"].getInt() > 0 and m["cache_misses"].getInt() > 0
  doAssert m["failed_games"].getInt() > 0
  for private in ["fake-observatory-token", "private-opponent", "download_url", "source", "policy_ref"]:
    doAssert private notin $m

if existsEnv("COGAME_CONFIG_URI"):
  checkWorkerEnvironment()
elif paramCount() > 0 and paramStr(1) == "--mock":
  newServer(mockRequest, workerThreads = 24).serve(Port(parseInt(paramStr(3))), "127.0.0.1")
else:
  run()
