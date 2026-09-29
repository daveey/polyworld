import
  std/[json, os, osproc, posix, sequtils, sets, strutils, tables],
  tournaments, reports, runners, softmax, sites, collections,
  ../scores

const
  DataRoot = Root.parentDir / "polyworld_art"
  TestRoot = Root / "tmp/gota/tournament-tests"

proc fixture(count = 41, mode = "both", interval = 10): JsonNode =
  ## Builds a named fixture that never submits hosted games.
  result = %*{"schema": Schema, "id": "nim-fixture", "name": "Nim fixture",
    "created": "2026-09-14T00:00:00Z", "settings": defaults(),
    "server": "https://softmax.com/api", "web_url": "https://softmax.com",
    "release": {"id": "cow_fixture", "version": "test fixture",
      "variant": "competition"}, "game_config": {"max_ticks": 28800},
    "roster": [], "schedule": scheduleGames(count, 10, mode, 17)}
  result["settings"]["games"] = %count
  result["settings"]["format"] = %mode
  result["settings"]["check_every"] = %interval
  for policy in 0 ..< 10:
    result["roster"].add %*{"id": "policy-" & align($policy, 2, '0'),
      "name": "Fixture policy " & $(policy + 1),
      "version": "fixture:v" & $(policy + 1)}

proc resultFor(game: JsonNode, outcome = "RedTeam", ticks = 720): JsonNode =
  ## Produces seat-attributed tournament scores and explicit team outcomes.
  result = %*{"scores": [], "outcome": outcome, "ticks": ticks,
    "seed": game["seed"], "total_xp": []}
  for slot, policy in game["seats"].elems:
    result["total_xp"].add %((policy.getInt + 1) * 100 + slot)
    result["scores"].add %score(
      result["total_xp"][slot].getInt, ticks, result.seatWin(slot) == 1
    )

proc completed(run: JsonNode): seq[JsonNode] =
  ## Creates one completed authoritative record per fixture game.
  for game in run["schedule"]:
    result.add %*{"id": game["id"], "state": "completed", "attempts": [],
      "result": resultFor(game)}

proc statsFor(run, game, raw: JsonNode): JsonNode =
  ## Builds verified seat counters with distinct values for mono averaging.
  result = %*{"verified": true, "hash_mismatches": 0, "ticks": raw["ticks"],
    "outcome": raw["outcome"], "heroes": []}
  for slot, policy in game["seats"].elems:
    result["heroes"].add %*{"slot": slot,
      "policy_version_id": run["roster"][policy.getInt]["id"],
      "xp": raw["total_xp"][slot], "win": raw.seatWin(slot),
      "gold": slot * 50 + 100, "banked_gold": slot * 5,
      "level": slot + 1, "kills": slot + 1, "deaths": slot,
      "assists": 10, "tower_kills": 1, "last_hits": slot * 2}

proc fresh(name: string): string =
  ## Resets only the bounded fixture output owned by this test suite.
  result = TestRoot / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc fakeClient(directory: string, pauseAfterAccept = false): Client =
  ## Models durable remote requests that survive the local runner process.
  let path = directory / "remote.json"
  if not fileExists(path):
    saveJson(path, newJObject())
  result.request = proc(verb, route: string, body: JsonNode): JsonNode =
    ## Rejects repeated POSTs and lets accepted games complete while stopped.
    let requests = readJson(path)
    if verb == "POST":
      let key = body["idempotency_key"].getStr
      require(not requests.hasKey(key), "Duplicate POST for a saved attempt")
      if not requests.hasKey(key):
        let
          id = $requests.len
          policies = newJArray()
          fail = fileExists(directory / "fail-next")
        if fail:
          removeFile(directory / "fail-next")
        for seat in body["roster"]:
          policies.add(seat["player"]["policy_ref"])
        requests[key] = %*{"id": "xreq_" & id,
          "coworld_id": body["coworld_id"], "body": body,
          "requested": {"notes": body["notes"]},
          "episodes": [{"id": "ereq_" & id,
            "status": (if fail: "failed" else: "pending"),
            "game_config": body["game_config_overrides"],
            "policy_version_ids": policies}]}
        saveJson(path, requests)
      require(requests[key]["body"] == body, "Conflicting idempotency key")
      if pauseAfterAccept:
        writeFile(directory / "accepted", "yes")
        var waited = 0
        while not stopping and waited < 30000:
          sleep(10)
          waited += 10
      return requests[key].copy()
    if route.startsWith("/v2/experience-requests?"):
      let entries = newJArray()
      for key, request in requests:
        entries.add %*{"id": request["id"]}
      return %*{"entries": entries, "next_cursor": nil}
    for key, request in requests:
      let episode = request["episodes"][0]
      if route.endsWith("/" & request["id"].getStr):
        episode["status"] = %"completed"
        saveJson(path, requests)
        return request.copy()
      if route.contains("/" & episode["id"].getStr & "/artifacts/results"):
        let game = %*{"seed": request["body"]["game_config_overrides"]["seed"],
          "seats": []}
        for seat in request["body"]["roster"]:
          let id = seat["player"]["policy_ref"].getStr
          game["seats"].add %parseInt(id[7 .. ^1])
        return resultFor(game)
    raise newException(TournamentError, "Unknown fake request: " & route)

proc assertEquivalent(first, second: JsonNode) =
  ## Compares final values and checkpoint histories independently of timestamps.
  for field in ["target", "completed", "included", "panels", "roster",
      "players"]:
    doAssert first[field] == second[field], "Mismatch in " & field

proc stop() {.noconv.} =
  ## Allows subprocess SIGINT tests to finish their in-flight response.
  stopping = true

if paramCount() > 0 and paramStr(1) == "worker":
  setControlCHook(stop)
  let
    directory = paramStr(2)
    run = readJson(directory / "run.json")
  quit(execute(fakeClient(directory, true), directory, run, DataRoot,
    Controls(concurrency: 2)))

createDir(TestRoot)
echo "Checking exact counts and balanced sampling"
for (mode, count, mixed, mono) in [
  ("both", 11, 6, 5), ("mixed", 10, 10, 0), ("mono", 9, 0, 9)
]:
  let schedule = scheduleGames(count, 10, mode, 44)
  doAssert schedule == scheduleGames(count, 10, mode, 44)
  doAssert schedule.len == count
  doAssert schedule.elems.countIt(it["format"].getStr == "mixed") == mixed
  doAssert schedule.elems.countIt(it["format"].getStr == "mono") == mono
  for game in schedule:
    let seats = game["seats"].elems.mapIt(it.getInt)
    if game["format"].getStr == "mixed":
      doAssert seats.toHashSet.len == 10
    else:
      doAssert seats[0 ..< 5].toHashSet.len == 1
      doAssert seats[5 ..< 10].toHashSet.len == 1
      doAssert seats[0] != seats[5]
for mode in ["mixed", "mono"]:
  var
    counts = newSeq[int](13)
    slots = newSeq[array[10, int]](13)
  for game in scheduleGames(260, 13, mode, 19):
    for policy in game["seats"].elems.mapIt(it.getInt).toHashSet:
      inc counts[policy]
    for slot, policy in game["seats"].elems:
      inc slots[policy.getInt][slot]
  doAssert counts.max - counts.min <= 1
  for policy in slots:
    if mode == "mixed":
      doAssert policy.max - policy.min <= 10
    else:
      doAssert abs(policy[0] - policy[5]) <= 8

for (count, size, mode) in [(0, 10, "both"), (10, 9, "mixed"), (5, 1, "mono")]:
  var rejected = false
  try:
    discard scheduleGames(count, size, mode, 1)
  except TournamentError:
    rejected = true
  doAssert rejected

echo "Checking whole-point scores, timeouts, and mono averages"
for mode in ["mixed", "mono"]:
  let run = fixture(1, mode)
  let game = run["schedule"][0]
  for outcome in ["RedTeam", "BlueTeam", "time_limit", "draw"]:
    let raw = resultFor(game, outcome, 721)
    validateResult(raw, game, run)
    let values = gameValues(game, raw)
    for policy, value in values:
      var adjusted, wins, count, published: float64
      for slot, participant in game["seats"].elems:
        if participant.getInt == policy:
          adjusted += (raw["total_xp"][slot].getInt * 1440 div 721).float64
          wins += raw.seatWin(slot).float64
          doAssert raw["scores"][slot].kind == JInt
          published += raw["scores"][slot].getFloat
          count += 1
      doAssert abs(value[0] - wins / count) < 1e-9
      doAssert abs(value[1] - adjusted / count) < 1e-9
      doAssert abs(value[2] - published / count) < 1e-9
      let glory = if wins > 0: adjusted / count else: 0.0
      doAssert abs(value[2] - glory) < 1e-9
  let raw = resultFor(game, "time_limit", 28800)
  for slot in 0 ..< 10:
    raw["total_xp"].elems[slot] = %0
  for policy, values in gameValues(game, raw):
    doAssert values == [0.0, 0.0, 0.0]
  let victory = resultFor(game, "RedTeam", 28800)
  for slot in 0 ..< 10:
    victory["total_xp"].elems[slot] = %0
  for policy, values in gameValues(game, victory):
    doAssert values[1] == 0.0
    doAssert values[2] == 0.0
  raw["scores"].elems[0] = %"invalid score"
  var rejected = false
  try:
    validateResult(raw, game, run)
  except TournamentError:
    rejected = true
  doAssert rejected

echo "Checking result duration includes bounded drafting time"
block:
  let
    run = fixture(1, "mixed")
    game = run["schedule"][0]
  for ticks in [28800, 28909, 31200]:
    validateResult(resultFor(game, "time_limit", ticks), game, run)
  for ticks in [-1, 31201]:
    var rejected = false
    try:
      validateResult(resultFor(game, "time_limit", ticks), game, run)
    except TournamentError:
      rejected = true
    doAssert rejected

echo "Checking zero XP and victory gating precede policy averages"
block:
  let
    run = fixture(1, "mono")
    game = run["schedule"][0]
    raw = resultFor(game, "RedTeam", 1440)
  for slot in 0 ..< 10:
    raw["total_xp"].elems[slot] = %(if slot mod 5 == 0: 0 else: 1000)
  for policy, values in gameValues(game, raw):
    doAssert values[1] == 800.0
    doAssert values[2] == 800.0 * values[0]

echo "Checking Emmett's Glory reports survive resume"
block:
  let
    directory = fresh("emmetts-glory")
    run = fixture(40)
    records = completed(run)
  doAssert not run["settings"].hasKey("xp_per_minute")
  for record in records:
    record["result"]["ticks"] = %2880
    record["result"]["total_xp"] = %repeat(1000, 10)
  let summary = summarize(run, records, "completed")
  for panel in summary["panels"]:
    if panel["ladder"].getStr == "glory":
      doAssert panel["title"].getStr == "Emmett's Glory"
    for row in panel["rows"]:
      if row["appearances"].getInt == 0:
        continue
      if panel["ladder"].getStr == "score":
        doAssert row["value"].getFloat == 500.0
      elif panel["ladder"].getStr == "glory":
        let index = if panel["format"].getStr == "mixed": 0 else: 3
        for wins in summary["panels"][index]["rows"]:
          if wins["id"] == row["id"]:
            doAssert abs(row["value"].getFloat -
              500.0 * wins["value"].getFloat) < 1e-9
  saveJson(directory / "run.json", run)
  let resumed = readJson(directory / "run.json")
  validateResume(resumed, parseArguments(@["--run", "fixture"]))
  doAssert resumed["settings"] == run["settings"]
  assertEquivalent(summary, summarize(resumed, records, "completed"))

echo "Checking ties, rank exchanges and stability resets"
block:
  let run = fixture(41, "mixed")
  for game in run["schedule"]:
    game["seats"] = %toSeq(0 ..< 10)
  let records = completed(run)
  let summary = summarize(run, records, "completed")
  let panel = summary["panels"][1]
  doAssert panel["history"].len == 4
  doAssert panel["stability"]["score"].getInt == 0
  doAssert panel["stability"]["run"].getInt == 3
  doAssert panel["included"].getInt == 41
  doAssert summary["completed"].getInt == 41
  doAssert panel["history"][0]["score"].kind == JNull
  let totals = newSeq[Values](10)
  var counts = repeat(1, 10)
  counts[9] = 0
  let rows = rankedRows(run, totals, counts, 0)
  doAssert rows[0]["tied"].getBool
  doAssert rows[0]["id"].getStr == "policy-00"
  doAssert rows[9]["rank"].kind == JNull
  let changed = rows.copy()
  changed[0]["rank"] = %2
  changed[1]["rank"] = %1
  doAssert rankChanges(rows, changed) == 2
  records[5]["state"] = %"pending"
  let gap = summarize(run, records, "running")
  doAssert gap["completed"].getInt == 40
  doAssert gap["included"].getInt == 5
  doAssert gap["panels"][1]["history"].len == 0
block:
  let run = fixture(4, "mono", 1)
  for game in run["schedule"]:
    game["seats"] = %(repeat(0, 5) & repeat(1, 5))
  let records = completed(run)
  for i, record in records:
    for slot in 0 ..< 10:
      record["result"]["total_xp"].elems[slot] = %(if i < 2:
        (if slot < 5: 100 else: 0) else: (if slot < 5: 0 else: 1000))
  let history = summarize(run, records, "completed")["panels"][4]["history"]
  doAssert history[1]["run"].getInt == 1
  doAssert history[2]["score"].getInt == 2
  doAssert history[2]["run"].getInt == 0
  doAssert history[3]["run"].getInt == 1

echo "Checking durable retries and interrupted atomic replacements"
let
  run = fixture(6, "both", 1)
  baselineDirectory = fresh("uninterrupted")
saveJson(baselineDirectory / "run.json", run)
doAssert execute(fakeClient(baselineDirectory), baselineDirectory, run,
  DataRoot, Controls(concurrency: 2)) == 0
let baseline = readJson(baselineDirectory / "summary.json")
for point in ["remote-acceptance", "result-received",
    "result-saved",
    "replace:000001.json", "replace:report.html"]:
  let directory = fresh(point.replace(':', '-'))
  saveJson(directory / "run.json", run)
  var fired = false
  let fault = proc(location: string) =
    ## Simulates abrupt failure at one precise persistence boundary.
    if point == "replace:report.html" and not loadRecords(directory,
      run).anyIt(it["state"].getStr == "completed"):
        return
    if not fired and location == point:
      fired = true
      raise newException(TournamentError, "Injected interruption")
  var failed = false
  try:
    discard execute(fakeClient(directory), directory, run, DataRoot,
      Controls(concurrency: 2, fault: fault))
  except TournamentError:
    failed = true
  doAssert failed and fired
  doAssert readJson(directory / "summary.json")["status"].getStr == "paused"
  doAssert execute(fakeClient(directory), directory, run, DataRoot,
    Controls(concurrency: 4)) == 0
  assertEquivalent(baseline, readJson(directory / "summary.json"))
  doAssert readJson(directory / "remote.json").len == 6
block:
  let directory = fresh("unconfirmed-submission")
  saveJson(directory / "run.json", run)
  let record = loadRecords(directory, run)[0]
  record["state"] = %"submitting"
  record["attempts"].add %*{"body": requestBody(run, run["schedule"][0], 1)}
  saveRecord(directory, record)
  var unresolved = false
  try:
    discard execute(fakeClient(directory), directory, run, DataRoot,
      Controls(concurrency: 4))
  except TournamentError:
    unresolved = true
  doAssert unresolved
  doAssert readJson(directory / "remote.json").len == 0
  doAssert readJson(directory / "games/000001.json")["state"].getStr ==
    "submitting"
  discard fakeClient(directory).request("POST", "/v2/experience-requests",
    record["attempts"][0]["body"])
  doAssert execute(fakeClient(directory), directory, run, DataRoot,
    Controls(concurrency: 4)) == 0
  doAssert readJson(directory / "remote.json").len == 6
block:
  let directory = fresh("atomic")
  let path = directory / "state.json"
  saveJson(path, %*{"old": true})
  try:
    saveJson(path, %*{"new": true}, Controls(fault: proc(point: string) =
      ## Interrupts after the temporary file is durable.
      raise newException(TournamentError, "Injected replacement failure")))
  except TournamentError:
    discard
  doAssert readJson(path) == %*{"old": true}
  doAssert fileExists(path & ".tmp")
block:
  let directory = fresh("failed-retry")
  saveJson(directory / "run.json", run)
  writeFile(directory / "fail-next", "yes")
  doAssert execute(fakeClient(directory), directory, run, DataRoot,
    Controls(concurrency: 2)) == 1
  doAssert readJson(directory / "summary.json")["failed"].getInt == 1
  doAssert execute(fakeClient(directory), directory, run, DataRoot,
    Controls(concurrency: 2, retryFailed: true)) == 0
  doAssert readJson(directory / "remote.json").len == 7
  doAssert readJson(directory / "games/000001.json")["attempts"].len == 2
  assertEquivalent(baseline, readJson(directory / "summary.json"))

echo "Checking real SIGINT and SIGKILL recovery after remote acceptance"
for signal in [SIGINT, SIGKILL]:
  let directory = fresh("signal-" & $signal)
  saveJson(directory / "run.json", run)
  let worker = startProcess(getAppFilename(), args = @["worker", directory],
    options = {poParentStreams})
  var waited = 0
  while not fileExists(directory / "accepted") and waited < 10000:
    doAssert worker.running()
    sleep(20)
    waited += 20
  doAssert fileExists(directory / "accepted")
  doAssert posix.kill(worker.processID.cint, signal) == 0
  discard worker.waitForExit(10000)
  doAssert not worker.running()
  worker.close()
  if signal == SIGINT:
    doAssert readJson(directory / "summary.json")["status"].getStr == "paused"
  doAssert execute(fakeClient(directory), directory, run, DataRoot,
    Controls(concurrency: 4)) == 0
  doAssert readJson(directory / "remote.json").len == 6
  assertEquivalent(baseline, readJson(directory / "summary.json"))

echo "Checking report escaping, embedded assets, authentication and arguments"
block:
  let unsafe = run.copy()
  unsafe["roster"][0]["name"] = %"</script><img src=x onerror=alert(1)> & \""
  let html = render(summarize(unsafe, completed(unsafe), "completed"), DataRoot)
  doAssert "</script><img src=x" notin html
  doAssert "&lt;/script&gt;&lt;img" in html
  doAssert "data:font/ttf;base64," in html
  doAssert "data:image/png;base64," in html
  doAssert "@@" notin html
  doAssert html.count("class=ladder-stability") == 6
  doAssert html.count("<article class=\"panel ladder\"") == 6
  doAssert "setInterval" notin html
  doAssert "data-status=\"completed\"" in html
  doAssert "<style id=\"gota-site-style\">" in html
  doAssert "class=\"site-header wrap\"" in html
  doAssert "aria-current=\"page\">Player standings" in html
  doAssert "Match history" notin html
  doAssert "id=matches" notin html
  doAssert html.count("id=player-stats") == 1
  for label in ["Gold earned", "XP / level", "K / D / A", "KDA ratio",
      "towers", "last hits", "GPM / XPM"]:
    doAssert label in html

echo "Checking stability units and checkpoint sparklines"
block:
  let
    sample = fixture(81, "both", 5)
    summary = summarize(sample, completed(sample), "completed")
  for panel in summary["panels"]:
    panel["stability"] = %*{"score": 0, "run": 3}
    panel["history"] = %*[
      {"games": 5, "score": nil}, {"games": 10, "score": 8},
      {"games": 15, "score": 0}, {"games": 20, "score": 2},
      {"games": 25, "score": 0}
    ]
  let html = render(summary, DataRoot)
  doAssert html.count("Stability: 0 player swaps · Streak: 15 games") == 6
  doAssert html.count("class=stability-chart") == 6
  doAssert html.count("data-swaps=") == 24
  doAssert "data-games=\"5\"" notin html
  doAssert html.count("data-games=\"20\" data-swaps=\"2\"") == 6
  doAssert html.count("points=\"4,12 121.33,44 238.67,36 356,44\"") == 6
  doAssert html.count("Every 5 games") == 6
  doAssert "10–25 games" in html
  for panel in summary["panels"]:
    panel["history"] = %*[{"games": 5, "score": nil}]
  let baseline = render(summary, DataRoot)
  doAssert baseline.count("Swap history starts after 10 games.") == 6
  doAssert "<svg class=stability-chart" notin baseline
  for panel in summary["panels"]:
    panel["history"].add %*{"games": 10, "score": 0}
  let single = render(summary, DataRoot)
  doAssert single.count("points=\"180,44\"") == 6
  doAssert single.count("data-swaps=") == 6

echo "Checking player outcomes, objective counts, coverage and mono averages"
block:
  doAssert objectiveCounts(0, 0, 0) == [0, 0]
  doAssert objectiveCounts(675, 450, 3) == [1, 5]
  var rejected = false
  try:
    discard objectiveCounts(10, 0, 0)
  except TournamentError:
    rejected = true
  doAssert rejected
  let sample = fixture(3)
  sample["schedule"][0]["seats"] = %toSeq(0 ..< 10)
  sample["schedule"][1]["seats"] = %(@[0, 0, 0, 0, 0, 1, 1, 1, 1, 1])
  sample["schedule"][2]["seats"] = %toSeq(0 ..< 10)
  var records = completed(sample)
  records[2]["result"] = resultFor(sample["schedule"][2], "time_limit")
  for i in 0 ..< 2:
    records[i]["player_stats"] = statsFor(sample, sample["schedule"][i],
      records[i]["result"])
  let rows = playerRows(sample, records)
  doAssert rows[0]["games"].getInt == 3
  doAssert rows[0]["wins"].getInt == 2
  doAssert rows[0]["losses"].getInt == 0
  doAssert rows[0]["timeouts"].getInt == 1
  doAssert rows[0]["stats_games"].getInt == 2
  doAssert rows[0]["avg_gold"].getFloat == 150
  doAssert rows[0]["avg_kills"].getFloat == 2
  doAssert rows[0]["avg_deaths"].getFloat == 1
  doAssert rows[0]["avg_assists"].getFloat == 10
  doAssert rows[0]["avg_level"].getFloat == 2
  doAssert rows[0]["max_level"].getInt == 5
  doAssert rows[0]["gpm"].getFloat == 300
  doAssert abs(rows[0]["xpm"].getFloat - 302.0 / 1.5) < 0.000001
  doAssert rows[0]["kda"].getFloat == 12
  doAssert abs(rows[0]["avg_xp"].getFloat - 302.0 / 3) < 0.000001
  doAssert rows[1]["losses"].getInt == 1
  doAssert rows[2]["kda"].getFloat == 6.5
  doAssert playerRows(sample, records) == rows
  records[2]["result"] = resultFor(sample["schedule"][2], "draw")
  let drawn = playerRows(sample, records)
  doAssert drawn[0]["draws"].getInt == 1
  doAssert drawn[0]["timeouts"].getInt == 0
  doAssert drawn[0]["wins"] == rows[0]["wins"]
  doAssert drawn[0]["losses"] == rows[0]["losses"]
  records[0].delete("player_stats")
  let partial = playerRows(sample, records)
  doAssert partial[2]["avg_gold"].kind == JNull
  doAssert partial[2]["max_level"].kind == JNull
  doAssert partial[2]["gpm"].kind == JNull
  doAssert partial[0]["gpm"].getFloat == 400
  for mutation in ["xp", "slot", "policy_version_id", "gold"]:
    let invalid = statsFor(sample, sample["schedule"][1], records[1]["result"])
    invalid["heroes"][0][mutation] = newJNull()
    var rejected = false
    try:
      validatePlayerStats(invalid, records[1]["result"], sample["schedule"][1],
        sample)
    except TournamentError:
      rejected = true
    doAssert rejected

echo "Checking resumable replay-stat collection without repeated ingestion"
block:
  let
    directory = fresh("player-stats")
    sample = fixture(1, "mixed")
    game = sample["schedule"][0]
    record = completed(sample)[0]
    output = directory / "replays/000001-stats.json"
    stats = statsFor(sample, game, record["result"])
  record["attempts"].add %*{"request_id": "xreq_test", "episode_id": "ereq_test"}
  saveJson(output, stats)
  var
    requests, downloads: int
    client: Client
  client.request = proc(verb, path: string, body: JsonNode): JsonNode =
    ## Returns only the existing completed episode, never a new game.
    doAssert verb == "GET"
    inc requests
    %*{"episodes": [{"id": "ereq_test", "coworld_id": sample["release"]["id"],
      "game_config": {"seed": game["seed"]},
      "replay_url": (if requests == 1: "" else:
        "https://example.com/replay")}]}
  client.download = proc(url: string): string =
    ## Records a single public replay download.
    inc downloads
    "saved replay bytes"
  let controls = Controls(statsWorker: findExe("true"))
  stopping = false
  collectStats(client, directory, sample, game, record, controls)
  doAssert record.hasKey("stats_error")
  doAssert not record.hasKey("player_stats")
  for i in 0 ..< 2:
    collectStats(client, directory, sample, game, record, controls)
  doAssert requests == 2 and downloads == 1
  doAssert not record.hasKey("stats_error")
  doAssert record["player_stats"] == stats
  doAssert record["result"] == resultFor(game)
  doAssert record["attempts"].len == 1
  doAssert readJson(directory / "games/000001.json")["player_stats"] == stats

echo "Checking matching local and site reports with atomic replacement"
block:
  let
    directory = fresh("site-export")
    siteRoot = directory / "polyworld-buff"
    destination = siteRoot / "GOTA/standings/index.html"
    css = readFile(SourceDirectory / "standings.css") &
      "\n.site-header { color: #abcdef; }\n"
  createDir(siteRoot / "GOTA")
  writeFile(siteRoot / "GOTA/index.html", "Existing game guide")
  writeFile(siteRoot / "GOTA/site.css", css)
  for status in ["running", "paused", "failed", "completed"]:
    publish(directory, run, completed(run), status, DataRoot,
      controls = Controls(siteRoot: siteRoot))
    let
      local = readFile(directory / "report.html")
      page = readFile(destination)
    doAssert css in local
    doAssert "href=\"../site.css\"" in page
    doAssert "gota-site-style" notin page
    doAssert "href=\"../heros/\"" in page
    doAssert "data-status=\"" & status & "\"" in page
    doAssert "base64," notin page
    doAssert "setInterval" notin page
    doAssert page.count("class=ladder-stability") == 6
    doAssert readFile(siteRoot / "GOTA/index.html") == "Existing game guide"
    doAssert readFile(siteRoot / "GOTA/site.css") == css
  for (_, path) in Assets:
    doAssert readFile(siteRoot / "GOTA/assets" / path) ==
      readFile(DataRoot / path)
  let previous = readFile(destination)
  var rejected = false
  try:
    publish(directory, run, completed(run), "paused", DataRoot,
      controls = Controls(siteRoot: siteRoot, fault: proc(point: string) =
        ## Simulates interruption just before the public HTML is replaced.
        if point == "replace:index.html":
          raise newException(TournamentError, "Interrupted site replacement")))
  except TournamentError:
    rejected = true
  doAssert rejected
  doAssert readFile(destination) == previous
  let arguments = parseArguments(@["--run", "fixture", "--site", siteRoot])
  doAssert arguments["site"].getStr == siteRoot
  doAssert not arguments["settings"].hasKey("site")
  validateResume(run, arguments)
  doAssert parseArguments(@["--run", "fixture", "--no-site"])["no_site"].getBool
block:
  let credentials = %*{"tokens": {"server": "user"}, "player_sessions": {
    "server": {"active": "p", "cache": {"p": {"token": "player",
      "expires_at": "2999-01-01T00:00:00.123456+00:00"}}}}}
  doAssert tokenFromCredentials(credentials, "server") == "user"
  credentials["tokens"].delete("server")
  doAssert tokenFromCredentials(credentials, "server") == "player"
  credentials["tokens"]["server"] = %"user"
  credentials["player_sessions"]["server"]["cache"]["p"]["expires_at"] =
    %"2000-01-01T00:00:00+00:00"
  doAssert tokenFromCredentials(credentials, "server") == "user"
for options in [@["--run", "../escape"], @["--run", "x", "--games", "0"],
    @["--run", "x", "--format", "unknown"], @["--run", "x", "--top", "101"],
    @["--run", "x", "--site", "site", "--no-site"]]:
  var rejected = false
  try:
    discard parseArguments(options)
  except TournamentError:
    rejected = true
  doAssert rejected
validateResume(run, parseArguments(@["--run", "fixture", "--concurrency", "9"]))
var rejected = false
try:
  validateResume(run, parseArguments(@["--run", "fixture", "--games", "7"]))
except TournamentError:
  rejected = true
doAssert rejected

echo "All Nim tournament checks passed"
