## Cold/warm full-match benchmark. Credentials use the server's environment variables.
import
  std/[algorithm, json, monotimes, os, osproc, parseopt, sequtils, sets,
    strtabs, strutils, tables, times],
  crunchy, curly,
  ./fastxpfixtures,
  ../coworld/fast_xp/policies

const
  Policy = "109b99c1-3bb7-4276-b17e-378b43a97874"
  SourceHash = "cac27d33df9ab132d86e6db0fc3407e1ee6275bfad4ea2138e7f194d99259720"

proc digest(bytes: string): string =
  for value in sha256(bytes): result.add value.toHex(2).toLowerAscii()

proc median(values: seq[float]): float =
  let ordered = values.sorted()
  (ordered[(ordered.len - 1) div 2] + ordered[ordered.len div 2]) / 2

proc run() =
  var output, expected, cpu: string
  var repetitions = 3
  for kind, key, value in getopt():
    case key
    of "help", "h":
      echo "nim r tests/bench_fast_xp.nim --output:NEW_DIRECTORY [--repetitions:3] [--cpu:0] [--expected-replay-sha256:HASH]"
      return
    of "output": output = value
    of "repetitions": repetitions = parseInt(value)
    of "cpu": cpu = $parseInt(value)
    of "expected-replay-sha256": expected = value
    else: raise newException(ValueError, "Unknown argument: " & key)
  if output.len == 0 or repetitions < 1:
    raise newException(ValueError, "Supply --output:NEW_DIRECTORY and positive repetitions")
  if not fileExists(ServerPath) or not fileExists(FastXpDirectory / "gota_worker"):
    raise newException(IOError, "Build the fast-XP server and worker first")
  if getEnv("FAST_XP_OBSERVATORY_TOKEN").len == 0:
    raise newException(ValueError, "Set FAST_XP_OBSERVATORY_TOKEN; personal tokens also need FAST_XP_OBSERVATORY_ELEVATED=1")
  let root = absolutePath(output)
  if dirExists(root) or fileExists(root):
    raise newException(IOError, "Output directory must not already exist")
  createDir(root)
  setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
  # Fetch the inline seat separately, without warming the server's cache.
  putEnv("FAST_XP_CACHE_DIR", root / "setup-cache")
  let source = fetchPolicyBytes(Policy)
  doAssert digest(source) == SourceHash, "Benchmark source changed"
  removeDir(root / "setup-cache")
  let port = unusedPort()
  let base = "http://127.0.0.1:" & $port
  let env = environment(root, port)
  env["FAST_XP_WORKERS"] = "1"
  env["FAST_XP_GOTA_WORKER"] = FastXpDirectory / "gota_worker"
  let log = root / "server.log"
  let process = if cpu.len == 0: launch(ServerPath, log, env)
    else: launch(findExe("taskset"), log, env, @["-c", cpu, ServerPath])
  defer: stop(process)
  var ready = false
  for _ in 0 ..< 100:
    doAssert process.running(), "Benchmark server exited; see server.log"
    try:
      ready = (call(base, "/healthz")).status == 200
    except CatchableError: discard
    if ready: break
    sleep(100)
  doAssert ready, "Server did not become ready"
  let body = %*{"seed": 743478993, "config": {"max_ticks": 28800}, "roster": [
    {"slot": 0, "player": {"source": source}}, {"player": {"policy_ref": Policy}}]}
  var rows = newJArray()
  for repetition in 0 ..< repetitions:
    for mode in ["cold", "warm"]:
      if mode == "cold" and dirExists(root / "policies"): removeDir(root / "policies")
      let started = getMonoTime()
      let response = call(base, RunRoute, body)
      let wall = float((getMonoTime() - started).inMicroseconds) / 1_000_000
      doAssert response.status == 200, "Benchmark request failed: HTTP " & $response.status
      let files = archiveFiles(response.body, root)
      doAssert toHashSet(toSeq(files.keys)) == toHashSet(["replay.replay", "logs/slot-0.txt"])
      let hash = digest(files["replay.replay"])
      if expected.len == 0: expected = hash
      doAssert hash == expected, "Replay hash changed"
      doAssert "completed" in files["logs/slot-0.txt"] and "BASIC error" notin files["logs/slot-0.txt"]
      var timings = newJObject()
      for entry in response.headers["Server-Timing"].split(','):
        let fields = entry.strip().split(";dur=")
        timings[fields[0]] = %(parseFloat(fields[1]) / 1000)
      let dest = root / ($repetition & "-" & mode)
      createDir(dest)
      writeFile(dest / "response.zip", response.body)
      let row = %*{"mode": mode, "repetition": repetition, "wall_s": wall,
        "timings_s": timings, "replay_sha256": hash, "response_bytes": response.body.len}
      rows.add row
      writeFile(root / "measurements.json", rows.pretty())
      echo row
  var summary = newJObject()
  for mode in ["cold", "warm"]:
    var timings = newJObject()
    for key in ["wall", "fetch", "worker", "zip"]:
      var values: seq[float]
      for row in rows:
        if row["mode"].getStr() == mode:
          values.add(if key == "wall": row["wall_s"].getFloat() else: row["timings_s"][key].getFloat())
      timings[key & "_s"] = %median(values)
    summary[mode] = timings
  writeFile(root / "summary.json", summary.pretty())
  echo summary.pretty()

run()
