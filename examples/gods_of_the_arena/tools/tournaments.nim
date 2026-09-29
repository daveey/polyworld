import
  std/[algorithm, json, math, os, posix, random, sequtils,
    sets, strutils, tables, times, uri],
  jsony,
  ../[content, scores]

const
  Root* = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  OutputRoot* = Root / "tmp/gota/tournaments"
  DefaultLeague* = "league_3c60897b-25cf-4b37-9d1a-8554c1198f28"
  Ladders* = ["wins", "score", "glory"]
  Titles* = ["Win / loss", "XP / minute", ScoreName]
  Schema* = 2
  Formats* = ["mixed", "mono"]
  SourceDirectory* = currentSourcePath().parentDir
  PlayerMetrics* = ["gold", "banked_gold", "level", "kills", "deaths",
    "assists", "tower_kills", "last_hits"]

type
  TournamentError* = object of CatchableError
  Values* = array[3, float64]
  Client* = object
    request*: proc(verb, path: string, body: JsonNode): JsonNode {.closure.}
    download*: proc(url: string): string {.closure.}
  Controls* = object
    concurrency*: int
    pollMilliseconds*: int
    retryFailed*: bool
    siteRoot*: string
    statsWorker*: string
    fault*: proc(point: string) {.closure.}

var stopping* {.volatile.}: bool

proc renameFile(source, destination: cstring): cint
    {.importc: "rename", header: "<stdio.h>".}
  ## Atomically replaces a path within the same filesystem.

proc require*(condition: bool, message: string) =
  ## Rejects invalid external data with a tournament-specific error.
  if not condition:
    raise newException(TournamentError, message)

proc now*(): string =
  ## Returns a UTC timestamp for durable records and reports.
  getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc parseJson*(text: string): JsonNode =
  ## Maps JSON parsing failures to the tournament error boundary.
  try:
    result = text.fromJson(JsonNode)
  except ValueError as error:
    raise newException(TournamentError, "Invalid JSON: " & error.msg)

proc readJson*(path: string): JsonNode =
  ## Reads a durable record with its file path in any error.
  try:
    result = parseJson(readFile(path))
  except CatchableError as error:
    raise newException(TournamentError, path & ": " & error.msg)

proc saveBytes*(path, content: string, controls = Controls()) =
  ## Flushes a complete sibling file before atomically replacing its target.
  let temporary = path & ".tmp"
  try:
    createDir(path.parentDir)
    let output = open(temporary, fmWrite)
    try:
      output.write(content)
      output.flushFile()
      require(fsync(output.getFileHandle()) == 0, "Cannot sync " & temporary)
    finally:
      output.close()
    if controls.fault != nil:
      controls.fault("replace:" & path.extractFilename)
    require(renameFile(temporary.cstring, path.cstring) == 0,
      "Cannot replace " & path)
    let descriptor = posix.open(path.parentDir.cstring, O_RDONLY)
    require(descriptor >= 0, "Cannot open directory " & path.parentDir)
    try:
      require(fsync(descriptor) == 0, "Cannot sync directory " & path.parentDir)
    finally:
      discard posix.close(descriptor)
  except OSError, IOError:
    raise newException(TournamentError, "Cannot save " & path & ": " &
      getCurrentExceptionMsg())

proc saveJson*(path: string, value: JsonNode, controls = Controls()) =
  ## Saves human-readable JSON using the atomic persistence boundary.
  saveBytes(path, value.pretty() & "\n", controls)

proc defaults*(): JsonNode =
  ## Returns the frozen settings used when creating a new tournament.
  %*{"games": 0, "top": 10, "format": "both", "seed": 2026,
    "check_every": 10, "league": DefaultLeague, "division": nil}

proc scheduleGames*(count, rosterSize: int, mode: string, seed: int): JsonNode =
  ## Samples balanced appearances, opponents, sides, and hero slots.
  require(count > 0, "--games must be positive")
  require(mode in ["mixed", "mono", "both"], "Unknown tournament format")
  require(rosterSize >= (if mode == "mono": 2 else: 10),
    "Mixed requires ten distinct policies; mono requires two")
  var
    rng = initRand(seed)
    budgets: array[2, int]
    appearances: array[2, seq[int]]
    roles: array[2, seq[array[10, int]]]
    opponents: array[2, Table[(int, int), int]]
  if mode == "both":
    budgets = [(count + 1) div 2, count div 2]
  else:
    budgets[if mode == "mixed": 0 else: 1] = count
  for kind in 0 ..< 2:
    appearances[kind] = newSeq[int](rosterSize)
    roles[kind] = newSeq[array[10, int]](rosterSize)
  result = newJArray()
  while budgets[0] + budgets[1] > 0:
    for kind in 0 ..< 2:
      if budgets[kind] == 0:
        continue
      var seats: seq[int]
      if kind == 0:
        var chosen = toSeq(0 ..< rosterSize)
        rng.shuffle(chosen)
        let counts = appearances[kind]
        chosen.sort(proc(a, b: int): int =
          ## Keeps seeded shuffle order among equally sampled policies.
          cmp(counts[a], counts[b]))
        chosen.setLen(10)
        var best = (high(int), high(int))
        for trial in 0 ..< 64:
          rng.shuffle(chosen)
          var cost: (int, int)
          for slot, policy in chosen:
            cost[0] += roles[kind][policy][slot]
          for a in chosen[0 ..< 5]:
            for b in chosen[5 ..< 10]:
              cost[1] += opponents[kind].getOrDefault((min(a, b), max(a, b)))
          if cost < best:
            best = cost
            seats = chosen
        for policy in chosen:
          inc appearances[kind][policy]
      else:
        var pairs: seq[(int, int)]
        for a in 0 ..< rosterSize:
          for b in a + 1 ..< rosterSize:
            pairs.add((a, b))
        rng.shuffle(pairs)
        var
          best = (high(int), high(int), high(int))
          a, b: int
        for pair in pairs:
          let
            first = appearances[kind][pair[0]]
            second = appearances[kind][pair[1]]
            cost = (max(first, second), first + second,
              opponents[kind].getOrDefault(pair))
          if cost < best:
            best = cost
            (a, b) = pair
        let
          direct = roles[kind][a][0] + roles[kind][b][5]
          reverse = roles[kind][b][0] + roles[kind][a][5]
        if reverse < direct or (reverse == direct and rng.rand(1) == 1):
          swap(a, b)
        seats = repeat(a, 5) & repeat(b, 5)
        inc appearances[kind][a]
        inc appearances[kind][b]
      for slot, policy in seats:
        inc roles[kind][policy][slot]
      for a in seats[0 ..< 5].toHashSet:
        for b in seats[5 ..< 10].toHashSet:
          let pair = (min(a, b), max(a, b))
          opponents[kind][pair] = opponents[kind].getOrDefault(pair) + 1
      result.add %*{"id": align($(result.len + 1), 6, '0'),
        "format": Formats[kind], "seed": rng.rand(2147483647), "seats": seats}
      dec budgets[kind]

proc seatWin*(raw: JsonNode, slot: int): int =
  ## Reads team victory independently of the numerical ladder score.
  let outcome = raw["outcome"].getStr
  ord((outcome == "RedTeam" and slot < 5) or
    (outcome == "BlueTeam" and slot >= 5))

proc validateResult*(raw, game, run: JsonNode) =
  ## Requires original ten-seat scores, XP, and a known team outcome.
  require(raw.kind == JObject, "Episode result must be an object")
  for field in ["scores", "total_xp"]:
    require(raw{field} != nil and raw[field].kind == JArray and
      raw[field].len == 10, "Results require ten " & field & " values")
    for value in raw[field]:
      if field == "total_xp":
        require(value.kind == JInt and value.getInt >= 0,
          "Invalid XP values")
      else:
        require(value.kind in {JInt, JFloat} and
          value.getFloat.classify notin {fcNan, fcInf, fcNegInf},
          "Invalid score values")
  let maximumTicks = run["game_config"]["max_ticks"].getInt +
    game["seats"].len * DraftPickTicks
  require(raw{"ticks"} != nil and raw["ticks"].kind == JInt and
    raw["ticks"].getInt in 0 .. maximumTicks,
    "Invalid result ticks")
  require(raw{"seed"} == game["seed"], "Result seed differs from schedule")
  let outcome = raw{"outcome"}.getStr
  require(outcome in ["RedTeam", "BlueTeam", "time_limit", "draw"],
    "Unknown game outcome")

proc gameValues*(game, raw: JsonNode): Table[int, Values] =
  ## Averages victories, XP per minute, and Emmett's Glory per policy.
  var counts: Table[int, int]
  for slot, entry in game["seats"].elems:
    let
      policy = entry.getInt
      xp = raw["total_xp"][slot].getInt
      ticks = raw["ticks"].getInt
      value = xpPerMinute(xp, ticks).float64
      won = raw.seatWin(slot).float64
    var values = result.getOrDefault(policy)
    values[0] += won
    values[1] += value
    values[2] += score(xp, ticks, won == 1).float64
    result[policy] = values
    counts[policy] = counts.getOrDefault(policy) + 1
  for policy, values in result.mpairs:
    for value in values.mitems:
      value /= counts[policy].float64

proc rankedRows*(run: JsonNode, totals: seq[Values],
    counts: seq[int], ladder: int): JsonNode =
  ## Ranks observed averages, marking ties and leaving unsampled ranks empty.
  var rows: seq[JsonNode]
  for i, policy in run["roster"].elems:
    let row = policy.copy()
    row["appearances"] = %counts[i]
    row["value"] = if counts[i] > 0: %(totals[i][ladder] /
      counts[i].float64) else: newJNull()
    row["movement"] = newJNull()
    rows.add(row)
  rows.sort(proc(a, b: JsonNode): int =
    ## Orders equal averages by the frozen policy-version identifier.
    result = cmp(a["value"].kind == JNull, b["value"].kind == JNull)
    if result == 0:
      result = cmp(b["value"].getFloat, a["value"].getFloat)
    if result == 0:
      result = cmp(a["id"].getStr, b["id"].getStr))
  result = newJArray()
  for i, row in rows:
    let sampled = row["appearances"].getInt > 0
    row["rank"] = if sampled: %(i + 1) else: newJNull()
    row["tied"] = %(sampled and ((i > 0 and
      rows[i - 1]["value"] == row["value"]) or (i + 1 < rows.len and
      rows[i + 1]["value"] == row["value"])))
    result.add(row)

proc rankChanges*(previous, current: JsonNode): int =
  ## Counts each policy whose displayed rank changed, including new samples.
  var old: Table[string, JsonNode]
  for row in previous:
    old[row["id"].getStr] = row["rank"]
  for row in current:
    if old[row["id"].getStr] != row["rank"]:
      inc result

proc addMovement(rows, previous: JsonNode) =
  ## Annotates standings with movement since their preceding checkpoint.
  var old: Table[string, JsonNode]
  for row in previous:
    old[row["id"].getStr] = row["rank"]
  for row in rows:
    let earlier = old.getOrDefault(row["id"].getStr)
    if earlier != nil and earlier.kind != JNull and row["rank"].kind != JNull:
      row["movement"] = %(earlier.getInt - row["rank"].getInt)

proc objectiveCounts*(xp, gold, kills: int): array[2, int] =
  ## Recovers tower and footman finishing blows from GotA's exact kill rewards.
  let
    remainingXp = xp - 150 * kills
    remainingGold = gold - 100 * kills
  require(remainingXp >= 0 and remainingGold >= 0 and
    remainingXp mod 25 == 0 and remainingGold mod 15 == 0,
    "Replay rewards cannot account for its kill totals")
  let
    towers = remainingGold div 15 - remainingXp div 25
    lastHits = remainingXp div 25 - 4 * towers
  require(towers >= 0 and lastHits >= 0,
    "Replay rewards produce invalid objective totals")
  [towers, lastHits]

proc validatePlayerStats*(stats, raw, game, run: JsonNode) =
  ## Requires verified replay seats to agree with saved original game results.
  require(stats{"verified"}.getBool and
    stats{"hash_mismatches"}.getInt(-1) == 0,
    "Player statistics require a verified replay")
  require(stats{"ticks"} == raw["ticks"] and
    stats{"outcome"} == raw["outcome"], "Replay result differs from saved game")
  require(stats{"heroes"} != nil and stats["heroes"].len == 10,
    "Player statistics require ten heroes")
  for slot, hero in stats["heroes"].elems:
    require(hero{"slot"}.getInt(-1) == slot and
      hero{"policy_version_id"} == run["roster"][game["seats"][slot].getInt]["id"],
      "Replay policy seats differ from the frozen schedule")
    require(hero{"xp"} == raw["total_xp"][slot] and
      hero{"win"}.getInt(-1) == raw.seatWin(slot),
      "Replay hero result differs from saved game")
    for field in PlayerMetrics:
      require(hero{field} != nil and hero[field].kind == JInt and
        hero[field].getInt >= 0, "Invalid player statistic: " & field)

proc playerRows*(run: JsonNode, records: seq[JsonNode]): JsonNode =
  ## Combines formats with one appearance per policy and hero-averaged mono stats.
  result = newJArray()
  for policy in run["roster"]:
    let row = policy.copy()
    for field in ["games", "wins", "losses", "timeouts", "draws",
        "mixed", "mono", "stats_games"]:
      row[field] = %0
    for field in ["xp", "minutes", "stats_minutes"]:
      row[field] = %0.0
    row["max_level"] = newJNull()
    for field in PlayerMetrics:
      row[field] = %0.0
    result.add(row)
  for i, game in run["schedule"].elems:
    let record = records[i]
    if record["state"].getStr != "completed":
      continue
    let
      raw = record["result"]
      stats = record{"player_stats"}
    validateResult(raw, game, run)
    if stats != nil:
      validatePlayerStats(stats, raw, game, run)
    var seats: Table[int, seq[int]]
    for slot, policy in game["seats"].elems:
      seats.mgetOrPut(policy.getInt, @[]).add(slot)
    for policy, slots in seats:
      let
        row = result[policy]
        outcome = if raw["outcome"].getStr == "time_limit": "timeouts"
          elif raw["outcome"].getStr == "draw": "draws"
          elif raw.seatWin(slots[0]) == 1: "wins" else: "losses"
      for field in ["games", game["format"].getStr, outcome]:
        row[field] = %(row[field].getInt + 1)
      row["minutes"] = %(row["minutes"].getFloat +
        raw["ticks"].getInt.float64 / 1440)
      if stats != nil:
        row["stats_games"] = %(row["stats_games"].getInt + 1)
        row["stats_minutes"] = %(row["stats_minutes"].getFloat +
          raw["ticks"].getInt.float64 / 1440)
      for slot in slots:
        row["xp"] = %(row["xp"].getFloat +
          raw["total_xp"][slot].getFloat / slots.len.float64)
        if stats != nil:
          row["max_level"] = %max(row["max_level"].getInt,
            stats["heroes"][slot]["level"].getInt)
          for field in PlayerMetrics:
            row[field] = %(row[field].getFloat +
              stats["heroes"][slot][field].getFloat / slots.len.float64)
  for row in result:
    let
      games = row["games"].getInt
      sampled = row["stats_games"].getInt
      deaths = row["deaths"].getFloat
    row["win_rate"] = if games > 0:
      %(100.0 * row["wins"].getInt.float64 / games.float64) else: newJNull()
    row["kda"] = if sampled > 0:
      %((row["kills"].getFloat + row["assists"].getFloat) / max(1.0, deaths))
      else: newJNull()
    row["gpm"] = if row["stats_minutes"].getFloat > 0:
      %(row["gold"].getFloat / row["stats_minutes"].getFloat)
      else: newJNull()
    row["xpm"] = if row["minutes"].getFloat > 0:
      %(row["xp"].getFloat / row["minutes"].getFloat)
      else: newJNull()
    for field in ["xp", "minutes"]:
      row["avg_" & field] = if games > 0:
        %(row[field].getFloat / games.float64) else: newJNull()
    for field in PlayerMetrics:
      row["avg_" & field] = if sampled > 0:
        %(row[field].getFloat / sampled.float64) else: newJNull()
      if sampled == 0:
        row[field] = newJNull()

proc summarize*(run: JsonNode, records: seq[JsonNode],
    status: string, error = ""): JsonNode =
  ## Recomputes deterministic standings from each format's completed prefix.
  var
    states: CountTable[string]
    included = 0
  let
    panels = newJArray()
    matches = newJArray()
  for record in records:
    states.inc(record["state"].getStr)
  for kind in Formats:
    var
      totals = newSeq[Values](run["roster"].len)
      counts = newSeq[int](run["roster"].len)
      histories: array[3, JsonNode]
      stable: array[3, JsonNode]
      completed, target, received: int
      gap = false
    for ladder in 0 ..< 3:
      histories[ladder] = newJArray()
      stable[ladder] = %*{"score": nil, "run": 0}
    for i, game in run["schedule"].elems:
      if game["format"].getStr != kind:
        continue
      inc target
      if records[i]["state"].getStr == "completed":
        inc received
      else:
        gap = true
      if gap:
        continue
      let raw = records[i]["result"]
      validateResult(raw, game, run)
      for policy, values in gameValues(game, raw):
        inc counts[policy]
        for ladder in 0 ..< 3:
          totals[policy][ladder] += values[ladder]
      inc completed
      if completed mod run["settings"]["check_every"].getInt == 0:
        for ladder in 0 ..< 3:
          let
            rows = rankedRows(run, totals, counts, ladder)
            history = histories[ladder]
          if history.len > 0:
            let score = rankChanges(history[history.len - 1]["rows"], rows)
            addMovement(rows, history[history.len - 1]["rows"])
            stable[ladder]["score"] = %score
            stable[ladder]["run"] = %(if score == 0:
              stable[ladder]["run"].getInt + 1 else: 0)
          history.add %*{"games": completed, "rows": rows,
            "score": stable[ladder]["score"],
            "run": stable[ladder]["run"]}
    included += completed
    for ladder in 0 ..< 3:
      let
        rows = rankedRows(run, totals, counts, ladder)
        history = histories[ladder]
      var previous = history.len - 1
      if previous >= 0 and history[previous]["games"].getInt == completed:
        dec previous
      if previous >= 0:
        addMovement(rows, history[previous]["rows"])
      panels.add %*{"id": kind & "-" & Ladders[ladder], "format": kind,
        "ladder": Ladders[ladder], "title": Titles[ladder], "target": target,
        "included": completed, "completed": received, "rows": rows,
        "history": history, "stability": stable[ladder]}
  for i, game in run["schedule"].elems:
    let
      record = records[i]
      match = game.copy()
      raw = record{"result"}
    match["state"] = record["state"]
    match["outcome"] = if raw{"outcome"} != nil: raw["outcome"]
      else: newJNull()
    match["minutes"] = %(raw{"ticks"}.getInt.float64 / 1440)
    for field in ["replay", "error"]:
      match[field] = if record.hasKey(field): record[field] else: newJNull()
    match["attempts"] = %record["attempts"].len
    matches.add(match)
  result = %*{"run": run["name"], "id": run["id"], "updated": now(),
    "created": run["created"], "status": status, "error": error,
    "target": run["schedule"].len, "completed": states["completed"],
    "included": included, "queued": states["planned"] + states["pending"] +
      states["submitted"] + states["submitting"],
    "running": states["running"], "failed": states["failed"],
    "roster": run["roster"], "release": run["release"],
    "settings": run["settings"], "panels": panels, "matches": matches,
    "players": playerRows(run, records)}

proc loadRecords*(directory: string, run: JsonNode): seq[JsonNode] =
  ## Loads authoritative game records and ignores abandoned temporary files.
  for game in run["schedule"]:
    let
      path = directory / "games" / (game["id"].getStr & ".json")
      record = if fileExists(path): readJson(path) else:
        %*{"id": game["id"], "state": "planned", "attempts": []}
    require(record{"id"} == game["id"], "Wrong game ID in " & path)
    require(record{"state"}.getStr in ["planned", "submitting", "pending",
      "submitted", "running", "failed", "completed"],
      "Unknown game state in " & path)
    require(record{"attempts"} != nil and record["attempts"].kind == JArray,
      "Missing attempts in " & path)
    result.add(record)

proc saveRecord*(directory: string, record: JsonNode,
    controls = Controls()) =
  ## Commits one game independently of summaries and reports.
  saveJson(directory / "games" / (record["id"].getStr & ".json"),
    record, controls)

proc requestBody*(run, game: JsonNode, attempt: int): JsonNode =
  ## Pins all seats, the release, and configuration to one durable attempt.
  let
    roster = newJArray()
    config = run["game_config"].copy()
    key = "gota-" & run["id"].getStr & "-" &
      game["id"].getStr & "-" & $attempt
  config["seed"] = game["seed"]
  for slot, policy in game["seats"].elems:
    roster.add %*{"slot": slot,
      "player": {"policy_ref": run["roster"][policy.getInt]["id"]}}
  %*{"coworld_id": run["release"]["id"],
    "variant_id": run["release"]["variant"],
    "idempotency_key": key,
    "num_episodes": 1, "roster": roster, "game_config_overrides": config,
    "notes": "GotA tournament " & run["name"].getStr & ", " &
      game["format"].getStr & " game " & game["id"].getStr &
      ", attempt " & $attempt & ". Request key: " & key & "."}

proc recoverRequest*(client: Client, attempt: JsonNode): JsonNode =
  ## Recovers an accepted request by its unique note without repeating a POST.
  let body = attempt["body"]
  var cursor = ""
  while true:
    let page = client.request("GET",
      "/v2/experience-requests?mine=true&limit=100&coworld_id=" &
      encodeUrl(body["coworld_id"].getStr) &
      (if cursor.len > 0: "&cursor=" & encodeUrl(cursor) else: ""), nil)
    for entry in page["entries"]:
      let detail = client.request("GET", "/v2/experience-requests/" &
        entry["id"].getStr, nil)
      if detail{"requested", "notes"} != body["notes"]:
        continue
      require(result == nil, "Multiple remote requests match " &
        body["idempotency_key"].getStr & "; inspect the saved attempts")
      require(detail["coworld_id"] == body["coworld_id"] and
        detail["episodes"].len == 1, "Recovered request has a different payload")
      let episode = detail["episodes"][0]
      for field, expected in body["game_config_overrides"]:
        if field notin ["players", "tokens"]:
          require(episode{"game_config", field} == expected,
            "Recovered game configuration differs: " & field)
      result = detail
    cursor = page{"next_cursor"}.getStr
    if cursor.len == 0:
      break
  require(result != nil, "Submission receipt is missing for " &
    body["idempotency_key"].getStr & ". No matching request is visible yet. " &
    "Resume to check again; no duplicate request was submitted. " &
    "If the original POST never reached Softmax, this attempt needs " &
    "manual reconciliation before it can be retried.")

proc receive*(client: Client, directory: string,
    run, game, record, detail: JsonNode, controls = Controls()) =
  ## Commits remote IDs before fetching and validating original seat results.
  require(detail{"coworld_id"} == run["release"]["id"],
    "Softmax returned a different release")
  require(detail{"episodes"} != nil and detail["episodes"].len == 1,
    "Expected one episode per scheduled game")
  let
    attempt = record["attempts"][record["attempts"].len - 1]
    episode = detail["episodes"][0]
    status = episode["status"].getStr
  attempt["request_id"] = detail["id"]
  attempt["episode_id"] = episode["id"]
  attempt["status"] = episode["status"]
  record["state"] = %(if status == "completed": "submitted" else: status)
  if status in ["failed", "cancelled"]:
    record["state"] = %"failed"
    record["error"] = %(episode{"error"}.getStr(status))
  record["updated"] = %now()
  saveRecord(directory, record, controls)
  if status == "completed":
    let expected = newJArray()
    for policy in game["seats"]:
      expected.add(run["roster"][policy.getInt]["id"])
    require(episode{"policy_version_ids"} == expected,
      "Remote seats differ from the saved schedule")
    let raw = client.request("GET", "/v2/episode-requests/" &
      episode["id"].getStr & "/artifacts/results", nil)
    if controls.fault != nil:
      controls.fault("result-received")
    record["result"] = raw
    saveRecord(directory, record, controls)
    if controls.fault != nil:
      controls.fault("result-saved")
    validateResult(raw, game, run)
    record["state"] = %"completed"
    record["replay"] = %(run["web_url"].getStr &
      "/observatory/v2/episode-requests/" & episode["id"].getStr & "/watch")
    if record.hasKey("error"):
      record.delete("error")
    saveRecord(directory, record, controls)
