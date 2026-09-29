import
  std/[algorithm, json, math, os, sequtils, sets, strutils, times, uri],
  curly, jsony, zippy,
  polyworld/[metrics, tapes],
  ../[content, maps, replays, scores, sim],
  confidences, heropages

const
  StatsRoot* = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  StatsLeague* = "league_3c60897b-25cf-4b37-9d1a-8554c1198f28"
  StatsApi* = "https://softmax.com/api/observatory/v2"
  StatsSchema* = 1
  FootmanKind = 3
  TowerKind = 4
  BarracksKind = 5
  NeutralKind = 6

type
  HeroStatsError* = object of CatchableError
  FetchPage* = proc(path: string): JsonNode {.closure.}

proc requireStats*(condition: bool, message: string) =
  ## Rejects invalid inputs and incomplete evidence at the tool boundary.
  if not condition:
    raise newException(HeroStatsError, message)

proc jsonStats*(value: string): JsonNode =
  ## Maps malformed external JSON to the hero statistics error type.
  try:
    result = value.fromJson(JsonNode)
  except ValueError as error:
    raise newException(HeroStatsError, "Invalid JSON: " & error.msg)

proc readStats*(path: string): JsonNode =
  ## Reads saved evidence with an explicit path on failure.
  try:
    result = jsonStats(readFile(path))
  except IOError, OSError:
    raise newException(HeroStatsError, path & ": " & getCurrentExceptionMsg())

proc saveStats*(path, value: string) =
  ## Replaces a complete local output after writing a sibling temporary file.
  try:
    createDir(path.parentDir)
    writeFile(path & ".tmp", value)
    moveFile(path & ".tmp", path)
  except IOError, OSError:
    raise newException(HeroStatsError, path & ": " & getCurrentExceptionMsg())

proc saveStats*(path: string, value: JsonNode) =
  ## Saves JSON using the same atomic replacement as replay downloads.
  saveStats(path, value.toJson)

proc timestamp*(value: string): Time =
  ## Parses API RFC 3339 timestamps, preserving fractional seconds.
  try:
    let format = "yyyy-MM-dd'T'HH:mm:ss"
    if value.len > 19 and value[19] == '.':
      var finish = 20
      while finish < value.len and value[finish] in Digits:
        inc finish
      let digits = finish - 20
      requireStats(digits in 1 .. 9, "Invalid timestamp precision")
      result = parseTime(value, format & "." & repeat('f', digits) &
        "zzz", utc())
    else:
      result = parseTime(value, format & "zzz", utc())
  except TimeParseError as error:
    raise newException(HeroStatsError, "Invalid timestamp: " & error.msg)

proc stamp*(value: Time): string =
  ## Formats a reproducible UTC time with nanosecond precision.
  value.utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fffffffff'Z'")

proc inWindow*(row: JsonNode, first, last: Time): bool =
  ## Includes finished requests by completion time in a half-open window.
  let completed = row{"completed_at"}.getStr
  completed.len > 0 and timestamp(completed) >= first and
    timestamp(completed) < last

proc safeId*(value: string): string =
  ## Restricts remotely supplied identifiers before using them as filenames.
  requireStats(value.len in 1 .. 100 and
    value.allCharsInSet(Letters + Digits + {'_', '-'}),
    "Invalid record identifier")
  value

proc download*(http: Curly, url: string): string =
  ## Retries public read requests without sending credentials to replay hosts.
  requireStats(url.startsWith("https://"), "Expected an HTTPS source URL")
  var message = ""
  for attempt in 0 ..< 3:
    try:
      let response = http.get(url, timeout = 60)
      if response.code in 200 .. 299:
        return response.body
      message = "HTTP " & $response.code & " from " & url
      if response.code notin [408, 429, 500, 502, 503, 504]:
        break
    except CatchableError as error:
      message = "Download failed: " & error.msg
    if attempt < 2:
      sleep(500 * (attempt + 1))
  raise newException(HeroStatsError, message)

proc pages*(fetch: FetchPage, path: string): seq[JsonNode] =
  ## Exhausts cursor pagination and rejects malformed or repeated pages.
  var
    cursor = ""
    cursors: HashSet[string]
  while true:
    let page = fetch(path & (if cursor.len == 0: "" else:
      "&cursor=" & encodeUrl(cursor)))
    requireStats(page{"entries"} != nil and
      page["entries"].kind == JArray, "Invalid listing for " & path)
    result.add(page["entries"].elems)
    cursor = page{"next_cursor"}.getStr
    if cursor.len == 0:
      break
    requireStats(cursor notin cursors, "Repeated pagination cursor")
    cursors.incl(cursor)

proc collect*(fetch: FetchPage, league: string,
    first, last: Time): JsonNode =
  ## Freezes every retained league request completed within the time window.
  requireStats(first < last, "The time window must have positive duration")
  let rounds = pages(fetch, "/rounds?league_id=" &
    encodeUrl(league) & "&limit=200")
  result = %*{"schema": StatsSchema, "league": league,
    "start": stamp(first), "end": stamp(last), "rounds": [],
    "matches": [], "unfinished_observed": 0}
  var seen: HashSet[string]
  for round in rounds:
    let
      completed = round{"completed_at"}.getStr
      created = round{"created_at"}.getStr
    if created.len > 0 and timestamp(created) >= last:
      continue
    if completed.len > 0 and timestamp(completed) < first:
      continue
    let id = safeId(round{"id"}.getStr)
    result["rounds"].add(round)
    let episodes = pages(fetch, "/rounds/" & id &
      "/episodes?limit=1000")
    for episode in episodes:
      if episode{"completed_at"}.getStr.len == 0:
        result["unfinished_observed"] =
          %(result["unfinished_observed"].getInt + 1)
      if not inWindow(episode, first, last):
        continue
      let episodeId = safeId(episode{"id"}.getStr)
      if episodeId in seen:
        continue
      seen.incl(episodeId)
      episode["round_id"] = %id
      episode["round_number"] = round["round_number"]
      result["matches"].add(episode)
    echo "Listed round ", round["round_number"].getInt, ": ",
      result["matches"].len, " finished requests in window"

proc inspectReplay*(path: string, metadata: JsonNode): JsonNode =
  ## Replays every tick and refuses statistics from divergent simulations.
  let
    bytes = readFile(path)
    data = decodeReplay(
      if bytes.startsWith("\x1f\x8b"): uncompress(bytes) else: bytes
    )
    seed = data.config.seed
  let gameMap = generateMap(seed, data.config.mapPreset)
  let game = newGame(
    gameMap,
    data.config.spawnIntervalTicks,
    0,
    true,
    data
  )
  requireStats(data.hashes.len > 0, "Replay contains no recorded ticks")
  game.replayPlayer = initReplayPlayer(data)
  game.historyPlayback = true
  when defined(replayEvents):
    var
      towerKills = newSeq[int](game.world.heroes.len)
      lastHits = newSeq[int](game.world.heroes.len)
      neutralKills = newSeq[int](game.world.heroes.len)
  while game.world.tick < data.hashes.len:
    let before = game.world.tick
    game.tickWorld(nil)
    requireStats(game.world.tick > before, "Replay stopped before its end")
    requireStats(game.hashCheck.mismatches == 0, game.hashCheck.error)
    when defined(replayEvents):
      for event in game.world.events:
        let slot = event.actor.player.int
        if event.kind != Death or slot notin 0 ..< towerKills.len:
          continue
        case event.target.kind
        of FootmanKind:
          inc lastHits[slot]
        of TowerKind, BarracksKind:
          inc towerKills[slot]
        of NeutralKind:
          inc neutralKills[slot]
        else:
          discard
  requireStats(game.replayPlayer.finished, "Unconsumed replay actions")
  let
    victories = game.world.scores()
    seatScores = scores(game.world.totalXp(), int(game.world.tick), victories)
    observed = metadata{"participant_scores"}
    players = metadata{"participants"}
  requireStats(observed != nil and observed.len == seatScores.len,
    "Missing authoritative seat scores")
  var positions: HashSet[int]
  for score in observed:
    let slot = score{"position"}.getInt(-1)
    requireStats(slot in 0 ..< seatScores.len and slot notin positions,
      "Invalid or duplicate score position")
    positions.incl(slot)
    requireStats(score["score"].getFloat == seatScores[slot].float64,
      "Replay XP, duration, or outcome differs from the league seat scores")
  result = %*{"schema": StatsSchema, "id": metadata["id"],
    "verified": true, "ticks": game.world.tick, "hash_mismatches": 0,
    "replay_version": data.header.gameVersion,
    "game_version": metadata{"coworld_version"}.getStr,
    "completed_at": metadata["completed_at"],
    "minutes": float64(game.world.tick) / float64(TickRate) / 60,
    "outcome": game.world.outcome(), "heroes": []}
  for slot, hero in game.world.heroes:
    var participant: JsonNode
    for player in players:
      if player{"position"}.getInt(-1) == slot:
        requireStats(participant == nil, "Duplicate participant position")
        participant = player
    requireStats(participant != nil, "Missing participant for replay seat")
    let values = game.world.stats.values[slot]
    result["heroes"].add %*{"slot": slot, "hero": hero.class.heroSpec.name,
      "class": hero.class.ord, "team": $hero.team, "win": victories[slot],
      "draw": not game.world.gameOver or game.world.draw, "level": hero.level,
      "xp": hero.totalXp, "xp_progress": hero.xp,
      "gold": values[GoldMetric], "banked_gold": hero.gold,
      "kills": values[KillsMetric], "deaths": values[LossesMetric],
      "assists": values[AssistsMetric],
      "player_id": participant{"player_id"}.getStr,
      "player_name": participant{"player_name"}.getStr,
      "policy_version_id": participant{"policy_version_id"}.getStr,
      "is_filler": participant{"is_filler"}.getBool}
    when defined(replayEvents):
      result["heroes"][slot]["tower_kills"] = %towerKills[slot]
      result["heroes"][slot]["last_hits"] = %lastHits[slot]
      result["heroes"][slot]["neutral_kills"] = %neutralKills[slot]

proc wilson*(wins, games: int): array[2, float64] =
  ## Computes a descriptive 95 percent Wilson interval for game outcomes.
  if games == 0:
    return [0.0, 1.0]
  let
    count = games.float64
    proportion = wins.float64 / count
    z = 1.959963984540054
    denominator = 1 + z * z / count
    middle = (proportion + z * z / (2 * count)) / denominator
    radius = z * sqrt(proportion * (1 - proportion) / count +
      z * z / (4 * count * count)) / denominator
  [max(0.0, middle - radius), min(1.0, middle + radius)]

proc aggregate*(records: seq[JsonNode], version = ""): JsonNode =
  ## Aggregates appearances separately from distinct games and players.
  result = newJArray()
  for class in HeroClass:
    var
      games, players, policies: HashSet[string]
      teams: HashSet[string]
      appearances, wins, draws = 0
      minutes = 0.0
      totals: array[7, float64]
      groupCounts: seq[int]
      groupTotals: array[7, seq[float64]]
    const Fields = ["level", "xp", "kills", "deaths", "assists", "gold",
      "banked_gold"]
    for record in records:
      if not record{"verified"}.getBool or
        (version.len > 0 and record["game_version"].getStr != version):
          continue
      var
        groupCount = 0
        groupTotal: array[7, float64]
      for hero in record["heroes"]:
        if hero["class"].getInt != class.ord:
          continue
        inc appearances
        inc groupCount
        wins += hero["win"].getInt
        draws += int(hero["draw"].getBool)
        minutes += record["minutes"].getFloat
        games.incl(record["id"].getStr)
        if hero["player_id"].getStr.len > 0:
          players.incl(hero["player_id"].getStr)
        policies.incl(hero["policy_version_id"].getStr)
        teams.incl(hero["team"].getStr)
        for i, field in Fields:
          totals[i] += hero[field].getFloat
          groupTotal[i] += hero[field].getFloat
      if groupCount > 0:
        groupCounts.add(groupCount)
        for i in 0 ..< Fields.len:
          groupTotals[i].add(groupTotal[i])
    if appearances == 0:
      continue
    let row = %*{"hero": class.heroSpec.name, "games": games.len,
      "appearances": appearances, "wins": wins, "draws": draws,
      "losses": appearances - wins - draws,
      "win_rate": wins.float64 / appearances.float64,
      "players": players.len, "policies": policies.len,
      "avg_minutes": minutes / appearances.float64,
      "xp_per_minute": totals[1] / minutes,
      "gold_per_minute": totals[5] / minutes,
      "kda_ratio": (totals[2] + totals[4]) / max(1.0, totals[3]),
      "kda_zero_deaths": totals[3] == 0,
      "team": (if teams.len == 1: toSeq(teams)[0] else: "Mixed")}
    for i, field in Fields:
      row["avg_" & field] = %(totals[i] / appearances.float64)
      if field in ["level", "xp", "gold"]:
        let key = "avg_" & field
        if groupCounts.len < 2:
          row[key & "_ci95"] = newJNull()
          row[key & "_margin95"] = newJNull()
        else:
          let
            margin = margin95(groupTotals[i], groupCounts)
            mean = row[key].getFloat
          row[key & "_ci95"] = %([mean - margin, mean + margin])
          row[key & "_margin95"] = %margin
    if appearances == games.len:
      row["win_rate_ci95"] = %wilson(wins, games.len)
    else:
      row["win_rate_ci95"] = newJNull()
    result.add(row)
  result.elems.sort(proc(a, b: JsonNode): int =
    ## Sorts by win rate, then lifetime XP, then the hero name.
    result = cmp(b["win_rate"].getFloat, a["win_rate"].getFloat)
    if result == 0:
      result = cmp(b["avg_xp"].getFloat, a["avg_xp"].getFloat)
    if result == 0:
      result = cmp(a["hero"].getStr, b["hero"].getStr))

proc decimal(value: JsonNode, digits = 1): string =
  ## Formats one report statistic without changing its exported precision.
  formatFloat(value.getFloat, ffDecimal, digits)

proc heroTable(rows: JsonNode): string =
  ## Presents comparable end-of-game averages with explicit metric labels.
  result = "| Hero | Games | Win % | Avg level | Avg XP | Avg K / D / A | " &
    "Avg gold earned | Players |\n|---|---:|---:|---:|---:|---:|---:|---:|\n"
  for row in rows:
    result.add "| " & row["hero"].getStr & " | " & $row["games"].getInt &
      " | " & formatFloat(row["win_rate"].getFloat * 100, ffDecimal, 1) &
      " | " & decimal(row["avg_level"], 2) & " | " &
      decimal(row["avg_xp"]) & " | " & decimal(row["avg_kills"]) &
      " / " & decimal(row["avg_deaths"]) & " / " &
      decimal(row["avg_assists"]) & " | " & decimal(row["avg_gold"]) &
      " | " & $row["players"].getInt & " |\n"

proc exportCsv*(path: string, rows: JsonNode, fields: openArray[string]) =
  ## Quotes each CSV value, including commas and newlines in player names.
  var output = fields.join(",") & "\n"
  for row in rows:
    var values: seq[string]
    for field in fields:
      let node = row{field}
      var value = ""
      if node != nil and node.kind != JNull:
        value = if node.kind == JString: node.getStr else: node.toJson
      values.add("\"" & value.replace("\"", "\"\"") & "\"")
    output.add(values.join(",") & "\n")
  saveStats(path, output)

proc publishStats*(directory: string, manifest: JsonNode): JsonNode =
  ## Publishes verified totals, version splits, exclusions, and auditable seats.
  var
    records: seq[JsonNode]
    versions: HashSet[string]
    appearances = newJArray()
    exclusions = newJArray()
    sides: array[2, HashSet[string]]
    lineups: array[2, HashSet[string]]
    failed, missing, pending = 0
  for match in manifest["matches"]:
    let
      id = safeId(match["id"].getStr)
      path = directory / "stats" / (id & ".json")
    if match["status"].getStr != "completed":
      inc failed
      exclusions.add %*{"id": id, "reason": match["status"],
        "error": match{"error"}}
      continue
    if match{"replay_url"}.getStr.len == 0:
      inc missing
      exclusions.add %*{"id": id, "reason": "missing_replay"}
      continue
    if not fileExists(path):
      inc pending
      exclusions.add %*{"id": id, "reason": "not_analyzed"}
      continue
    let record = readStats(path)
    if not record{"verified"}.getBool:
      exclusions.add(record)
      continue
    record["round_number"] = match["round_number"]
    records.add(record)
    versions.incl(record["game_version"].getStr)
    var names: array[2, seq[string]]
    for hero in record["heroes"]:
      let
        side = if hero["team"].getStr == "RedTeam": 0 else: 1
        row = hero.copy()
      sides[side].incl(hero["hero"].getStr)
      names[side].add(hero["hero"].getStr)
      for field in ["id", "game_version", "completed_at", "minutes",
          "outcome", "replay_version"]:
        row[field] = record[field]
      row["round_number"] = match["round_number"]
      row["replay_url"] = match["replay_url"]
      appearances.add(row)
    for side in 0 ..< 2:
      names[side].sort()
      lineups[side].incl(names[side].join(", "))
  result = %*{"schema": StatsSchema, "league": manifest["league"],
    "start": manifest["start"], "end": manifest["end"],
    "finished_requests": manifest["matches"].len,
    "verified_games": records.len, "hero_appearances": appearances.len,
    "failed_requests": failed, "missing_replays": missing,
    "pending": pending, "excluded": exclusions,
    "heroes": aggregate(records), "versions": [], "teams": []}
  if records.len > 0:
    var firstRound = high(int)
    var lastRound = 0
    for record in records:
      firstRound = min(firstRound, record["round_number"].getInt)
      lastRound = max(lastRound, record["round_number"].getInt)
    result["first_round"] = %firstRound
    result["last_round"] = %lastRound
  var versionNames = toSeq(versions)
  versionNames.sort()
  var report = "# GOTA hero statistics\n\nCompletion window: " &
    manifest["start"].getStr & " inclusive to " &
    manifest["end"].getStr & " exclusive.\n\n" &
    $records.len & " verified games, " & $appearances.len &
    " hero appearances, " & $exclusions.len & " excluded requests.\n\n" &
    heroTable(result["heroes"])
  for version in versionNames:
    var count = 0
    for record in records:
      if record["game_version"].getStr == version:
        inc count
    let rows = aggregate(records, version)
    result["versions"].add %*{"version": version, "games": count,
      "heroes": rows}
    report.add "\n## Version " & version & "\n\n" & $count &
      " verified games.\n\n" & heroTable(rows)
  report.add "\n## Interpretation and definitions\n\n"
  for side in 0 ..< 2:
    var wins, draws = 0
    let team = if side == 0: "RedTeam" else: "BlueTeam"
    for record in records:
      wins += int(record["outcome"].getStr == team)
      draws += int(record["outcome"].getStr in ["time_limit", "draw"])
    result["teams"].add %*{"team": team, "games": records.len,
      "wins": wins, "draws": draws, "heroes": toSeq(sides[side]),
      "distinct_lineups": lineups[side].len,
      "win_rate_ci95": wilson(wins, records.len)}
  let fixed = records.len > 0 and lineups[0].len == 1 and lineups[1].len == 1
  result["fixed_faction_lineups"] = %fixed
  if fixed:
    report.add "Every verified game uses the same hero lineup per faction. " &
      "Heroes on a faction share its outcome. These win rates cannot " &
      "isolate an individual hero's strength or justify a specific nerf. " &
      "The independent outcome count is the number of matches, not ten " &
      "times that number.\n\n"
  report.add "Win rate is wins / appearances, including time-limit draws " &
    "as non-wins. Games counts distinct matches containing that class. " &
    "Averages are per hero appearance at the final recorded tick. XP is " &
    "lifetime XP, not progress toward the next level. Gold earned is the " &
    "simulation's cumulative reward counter, excluding starting gold; " &
    "unspent gold is exported separately. K/D/A are three separate " &
    "averages. Assists use the game's ten-second damage attribution. " &
    "Per-minute rates use total stat / total hero-minutes. Damage and " &
    "healing totals are not tracked by these GOTA simulation versions " &
    "and are not reported as zero.\n\n" &
    "Every included replay matches every recorded state hash and all " &
    "platform seat scores. Unsupported or divergent replays are excluded, " &
    "never treated as zero stats. Version splits prevent pooling releases " &
    "from hiding changes. Player skill, repeated policies, fixed roles, " &
    "and team composition confound causal balance conclusions. Wilson " &
    "intervals are descriptive and assume independent matches; repeated " &
    "matchups can make them too narrow.\n\n" &
    "Level, XP, and gold means include 95% Student t confidence intervals " &
    "with game-clustered standard errors. Multiple appearances of the same " &
    "hero in a game are not treated as independent samples. The intervals " &
    "estimate sampling uncertainty in the mean, not the spread of individual " &
    "games or proof that heroes differ. Repeated policies across games and " &
    "draft choices can still confound comparisons.\n\n" &
    "The window uses completed_at, not request creation or round time. " &
    "Only retained visible league rounds are enumerated. Failed completed " &
    "requests and missing artifacts are listed in summary.json. The " &
    "frozen manifest and per-match JSON retain source URLs and players.\n"
  const HeroFields = ["hero", "team", "games", "appearances", "wins",
    "losses", "draws", "win_rate", "avg_level", "avg_xp", "avg_kills",
    "avg_deaths", "avg_assists", "avg_gold", "avg_banked_gold",
    "avg_minutes",
    "xp_per_minute", "gold_per_minute", "kda_ratio", "players", "policies",
    "avg_level_margin95", "avg_xp_margin95", "avg_gold_margin95",
    "avg_level_ci95", "avg_xp_ci95", "avg_gold_ci95"]
  saveStats(directory / "summary.json", result)
  saveStats(directory / "report.md", report)
  exportCsv(directory / "heroes.csv", result["heroes"], HeroFields)
  let versionRows = newJArray()
  for version in result["versions"]:
    for hero in version["heroes"]:
      let row = hero.copy()
      row["version"] = version["version"]
      versionRows.add(row)
  exportCsv(directory / "heroes_by_version.csv", versionRows,
    @["version"] & @HeroFields)
  exportCsv(directory / "appearances.csv", appearances,
    ["id", "round_number", "completed_at", "game_version", "slot",
    "hero", "team", "win", "draw", "level", "xp", "xp_progress",
    "kills", "deaths", "assists", "gold", "banked_gold", "minutes",
    "player_id", "player_name",
    "policy_version_id", "is_filler", "replay_url"])
  writeHeroStats(
    directory / "report.html",
    result,
    appearances,
    getEnv("POLYWORLD_ART", StatsRoot.parentDir / "polyworld_art")
  )
