import
  std/[json, math, os, random, strutils],
  jsony,
  confidences

const
  HeroNames* = ["Vanguard Knight", "Ranger", "Arcanist", "Druid Warden",
    "Demon Hunter", "Death Knight", "Crossbowman", "Lich", "Warlock",
    "Berserker"]
  MirrorSlots* = [3, 4, 2, 0, 1]
  StatNames* = ["level", "xp", "gold", "kills", "deaths", "assists"]
  RoleNames* = ["Frontline", "Carry", "Mage", "Support", "Fighter"]
  RolePairs* = [[0, 5], [1, 6], [2, 7], [3, 8], [4, 9]]
  RoleDraft* = """sub chooseHero()
  if draftTurnId <> selfId then
    exit sub
  end if
  bestClass = -1
  bestScore = -10000
  for candidate = 0 to 9
    if heroAvailable(candidate) then
      missingRole = 1
      for player = 0 to draftPlayerCount() - 1
        if draftPlayerTeam(player) = selfTeam then
          picked = draftedClass(draftPlayerId(player))
          if picked >= 0 then
            if heroRole(picked) = heroRole(candidate) then
              missingRole = 0
            end if
          end if
        end if
      next player
      if missingRole = 1 then
        ' Rotate equally eligible choices without historical hero ratings.
        score = 10 - ((candidate + selfId + worldTick) mod 10)
        ' Experiments supply a seeded tie-break preference per player.
        if draftConfigured = 1 and candidate = draftPreferred then
          score = 100
        end if
        if score > bestScore then
          bestScore = score
          bestClass = candidate
        end if
      end if
    end if
  next candidate
  if bestClass >= 0 then
    accepted = draftHero(bestClass)
  end if
end sub"""

type
  BalanceError* = object of CatchableError
  Lever* = object
    anchor*, field*, reason*: string
    increase*: bool
  Rule* = object
    strength*, weakness*: Lever
  BalanceStatus* = enum
    NoResults, Balanced, TooWeak, TooStrong

const
  Priority* = [6, 1, 4, 0, 2, 3, 5, 7, 8, 9]
  RangerFragility* = Lever(
    anchor: "name: \"Ranger\"",
    field: "baseHitPoints",
    reason: "Fragile when caught"
  )

const Rules*: array[10, Rule] = [
  Rule(strength: Lever(anchor: "name: \"Vanguard Knight\"",
    field: "hitPointsPerLevel", increase: true, reason: "Frontline durability"),
    weakness: Lever(anchor: "name: \"Vanguard Knight\"",
    field: "baseMovePerTick", reason: "Slow armored movement")),
  Rule(strength: Lever(anchor: "name: \"Ranger\"",
    field: "baseMovePerTick", increase: true, reason: "Mobile ranged carry"),
    weakness: Lever(anchor: "name: \"Ranger\"",
    field: "hitPointsPerLevel", reason: "Fragile when caught")),
  Rule(strength: Lever(anchor: "ArcaneMeteor: AbilitySpec(",
    field: "damage", increase: true, reason: "Heavy spell burst"),
    weakness: Lever(anchor: "name: \"Arcanist\"",
    field: "hitPointsPerLevel", reason: "Fragile burst mage")),
  Rule(strength: Lever(anchor: "HealingBloom: AbilitySpec(",
    field: "heal", increase: true, reason: "Ally healing"),
    weakness: Lever(anchor: "name: \"Druid Warden\"",
    field: "baseDamage", reason: "Weak basic attacks")),
  Rule(strength: Lever(anchor: "GaleSlash: AbilitySpec(",
    field: "damage", increase: true, reason: "Close-range assassin burst"),
    weakness: Lever(anchor: "name: \"Demon Hunter\"",
    field: "baseHitPoints", reason: "Vulnerable assassin")),
  Rule(strength: Lever(anchor: "SanguineChalice: AbilitySpec(",
    field: "heal", increase: true, reason: "Bruiser sustain"),
    weakness: Lever(anchor: "name: \"Death Knight\"",
    field: "baseMovePerTick", reason: "Slow bruiser movement")),
  Rule(strength: Lever(anchor: "name: \"Crossbowman\"",
    field: "baseDamage", increase: true, reason: "Heavy individual shots"),
    weakness: Lever(anchor: "name: \"Crossbowman\"",
    field: "attackTicks", increase: true, reason: "Slow reload")),
  Rule(strength: Lever(anchor: "BoneMarionette: AbilitySpec(",
    field: "controlTicks", increase: true, reason: "Longer control windows"),
    weakness: Lever(anchor: "name: \"Lich\"",
    field: "hitPointsPerLevel", reason: "Fragile control mage")),
  Rule(strength: Lever(anchor: "DreadTotem: AbilitySpec(",
    field: "heal", increase: true, reason: "Direct ally healing"),
    weakness: Lever(anchor: "name: \"Warlock\"",
    field: "baseDamage", reason: "Weak basic attacks")),
  Rule(strength: Lever(anchor: "name: \"Berserker\"",
    field: "baseDamage", increase: true, reason: "Aggressive melee attacks"),
    weakness: Lever(anchor: "name: \"Berserker\"",
    field: "baseMana", reason: "Limited spell resources"))
]

proc require*(condition: bool, message: string) =
  ## Rejects invalid inputs before they can contribute to an experiment.
  if not condition:
    raise newException(BalanceError, message)

proc readJson*(path: string): JsonNode =
  ## Reads JSON with an error identifying the failed experiment artifact.
  try:
    result = readFile(path).fromJson(JsonNode)
  except CatchableError as error:
    raise newException(BalanceError, path & ": " & error.msg)

proc saveJson*(path: string, data: JsonNode) =
  ## Replaces an artifact only after its complete JSON has been written.
  createDir(path.parentDir)
  let temporary = path & "." & $getCurrentProcessId() & ".tmp"
  writeFile(temporary, data.pretty & "\n")
  moveFile(temporary, path)

proc rolePolicy*(source: string): string =
  ## Replaces only the policy's draft selector with strict role coverage.
  let
    first = source.find("sub chooseHero()")
    last = source.find("\nend sub", first)
  require(first >= 0 and last > first, "Policy has no chooseHero subroutine")
  result = source[0 ..< first] & RoleDraft & source[last + 8 .. ^1]

proc bounds(source: string, lever: Lever): (int, int) =
  ## Locates exactly one field within the selected hero or ability spec.
  let anchor = source.find(lever.anchor)
  require(anchor >= 0, "Missing tuning anchor: " & lever.anchor)
  require(source.find(lever.anchor, anchor + 1) < 0,
    "Ambiguous tuning anchor: " & lever.anchor)
  let
    stop = source.find("\n    )", anchor)
    field = source.find(lever.field & ": ", anchor)
  require(stop >= 0 and field >= anchor and field < stop,
    "Missing tuning field: " & lever.field)
  result[0] = field + lever.field.len + 2
  result[1] = result[0]
  while result[1] < stop and source[result[1]] notin {',', '\n'}:
    inc result[1]

proc value*(source: string, lever: Lever): int =
  ## Reads integer tuning, including the existing tick-rate expression.
  let (first, last) = bounds(source, lever)
  let text = source[first ..< last].strip.replace("_", "")
  if text == "TickRate":
    return 24
  try:
    result = text.parseInt
  except ValueError:
    raise newException(BalanceError, "Unsupported tuning value: " & text)

proc replaceValue*(source: var string, lever: Lever, value: int) =
  ## Rewrites only the chosen scalar in a private source snapshot.
  let (first, last) = bounds(source, lever)
  source = source[0 ..< first] & $value & source[last .. ^1]

proc tuning*(source: string): JsonNode =
  ## Captures the strength and weakness levers for all ten heroes.
  result = newJArray()
  for hero, rule in Rules:
    result.add %*{"hero": HeroNames[hero],
      "strength": source.value(rule.strength),
      "weakness": source.value(rule.weakness)}
    if hero == 1:
      result[hero]["fragility"] = %source.value(RangerFragility)

proc schedule*(games, seed: int): JsonNode =
  ## Creates independent random lineups followed by their mirrored side swaps.
  require(games >= 4 and games mod 2 == 0, "Use an even game count >= 4")
  var rng = initRand(seed.int64)
  result = newJArray()
  for pair in 0 ..< games div 2:
    var roster = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    rng.shuffle(roster)
    let matchSeed = rng.rand(1 .. int32.high.int)
    var mirrored: array[10, int]
    for slot in 0 ..< 5:
      mirrored[5 + MirrorSlots[slot]] = roster[slot]
      mirrored[MirrorSlots[slot]] = roster[5 + slot]
    for side in 0 .. 1:
      result.add %*{"index": result.len, "pair": pair, "seed": matchSeed,
        "roster": (if side == 0: roster else: mirrored)}

proc fixedSchedule*(games, seed: int): JsonNode =
  ## Reuses mirrored rosters and one incrementing seed per game across batches.
  result = schedule(games, seed)
  require(seed >= 0 and seed.int64 + games.int64 <= int32.high.int64,
    "Incrementing seeds must fit positive int32 values")
  for index, job in result.elems:
    job["seed"] = %(seed + index)

proc roleSchedule*(games, seed: int): JsonNode =
  ## Gives both teams all five roles with fixed seeds and mirrored exposure.
  result = fixedSchedule(games, seed)
  var rng = initRand(seed.int64)
  var combinations: array[16, int]
  for index in 0 ..< combinations.len:
    combinations[index] = index
  rng.shuffle(combinations)
  for pair in 0 ..< games div 2:
    let mask = combinations[pair mod 16] xor (if rng.rand(1) == 0: 0 else: 31)
    var red, blue: array[5, int]
    for role, heroes in RolePairs:
      let side = (mask shr role) and 1
      red[role] = heroes[side]
      blue[role] = heroes[1 - side]
    rng.shuffle(red)
    rng.shuffle(blue)
    var roster, mirrored: array[10, int]
    for slot in 0 ..< 5:
      roster[slot] = red[slot]
      roster[5 + slot] = blue[slot]
      mirrored[5 + MirrorSlots[slot]] = red[slot]
      mirrored[MirrorSlots[slot]] = blue[slot]
    result[pair * 2]["roster"] = %roster
    result[pair * 2 + 1]["roster"] = %mirrored
    result[pair * 2]["draft"] = %"roles"
    result[pair * 2 + 1]["draft"] = %"roles"

proc balanceStatus*(row: JsonNode): BalanceStatus =
  ## Accepts a measured hero when its unrounded 95% interval touches 50%.
  if row["win_rate"].kind == JNull or row["margin95"].kind == JNull:
    return NoResults
  let
    rate = row["win_rate"].getFloat
    margin = row["margin95"].getFloat
  if rate - margin > 0.5 + 1e-12:
    TooStrong
  elif rate + margin < 0.5 - 1e-12:
    TooWeak
  else:
    Balanced

proc allBalanced*(summary: JsonNode): bool =
  ## Requires every hero to have a measured interval containing 50%.
  for row in summary["heroes"]:
    if row.balanceStatus != Balanced:
      return false
  true

proc statusLabel*(status: BalanceStatus): string =
  ## Returns a readable confidence-based decision for the report.
  case status
  of NoResults: "No decisive games"
  of Balanced: "Pass: includes 50%"
  of TooWeak: "Below 50%"
  of TooStrong: "Above 50%"

proc summarize*(games: JsonNode): JsonNode =
  ## Summarizes hero outcomes and uncertainty clustered by side-swap pair.
  require(games.len >= 4 and games.len mod 2 == 0, "Incomplete batch")
  result = %*{"games": games.len, "red_wins": 0, "blue_wins": 0,
    "draws": 0, "heroes": [], "seconds_total": 0.0}
  for game in games:
    let outcome = game["outcome"].getStr
    require(outcome in ["RedTeam", "BlueTeam", "draw", "time_limit"],
      "Unknown game outcome")
    let field = case outcome
      of "RedTeam": "red_wins"
      of "BlueTeam": "blue_wins"
      else: "draws"
    result[field] = %(result[field].getInt + 1)
    result["seconds_total"] = %(result["seconds_total"].getFloat +
      game["seconds"].getFloat)
    require(game["heroes"].len == 10, "Incomplete hero results")
  for hero in 0 ..< 10:
    var
      wins, losses, draws: int
      sides: array[2, int]
      pairWins, pairGames: seq[float64]
      totals: array[StatNames.len, float64]
      pairTotals: array[StatNames.len, seq[float64]]
      pairCounts: seq[int]
    for pair in 0 ..< games.len div 2:
      var won, decided = 0.0
      var pairValues: array[StatNames.len, float64]
      for side in 0 .. 1:
        let game = games[pair * 2 + side]
        require(game["job"]["pair"].getInt == pair,
          "Batch results must follow schedule order")
        var appearances = 0
        for slot, row in game["heroes"].elems:
          require(row["class"] == game["job"]["roster"][slot],
            "Played heroes differ from the assigned roster")
          if row["class"].getInt != hero:
            continue
          inc appearances
          let team = row["team"].getInt
          require(team in 0 .. 1, "Invalid hero team")
          inc sides[team]
          for metric, field in StatNames:
            totals[metric] += row[field].getFloat
            pairValues[metric] += row[field].getFloat
          let outcome = game["outcome"].getStr
          if outcome in ["draw", "time_limit"]:
            inc draws
          else:
            decided += 1
            if (outcome == "RedTeam") == (team == 0):
              inc wins
              won += 1
            else:
              inc losses
        require(appearances == 1, "Each hero must appear exactly once")
      pairWins.add(won)
      pairGames.add(decided)
      pairCounts.add(2)
      for metric in 0 ..< StatNames.len:
        pairTotals[metric].add(pairValues[metric])
    require(sides[0] == games.len div 2 and sides[1] == games.len div 2,
      "Hero side exposure is not balanced")
    let
      decided = wins + losses
      rate = if decided > 0: wins.float / decided.float else: 0.5
    var squares = 0.0
    for pair in 0 ..< pairWins.len:
      squares += pow(pairWins[pair] - rate * pairGames[pair], 2)
    let margin = if decided > 0:
      critical95(pairWins.len - 1) *
        sqrt(pairWins.len.float / (pairWins.len - 1).float * squares) /
        decided.float
      else: 0.5
    let row = %*{"hero": HeroNames[hero], "games": games.len,
      "wins": wins, "losses": losses, "draws": draws,
      "win_rate": rate, "margin95": margin,
      "red_games": sides[0], "blue_games": sides[1]}
    row["delta_pp"] = %(abs(rate - 0.5) * 100)
    if decided == 0:
      row["win_rate"] = newJNull()
      row["margin95"] = newJNull()
      row["delta_pp"] = newJNull()
    for metric, field in StatNames:
      row[field] = %(totals[metric] / games.len.float)
      row[field & "_margin95"] = %margin95(pairTotals[metric], pairCounts)
    if games[0]["heroes"][0].hasKey("diagnostics"):
      let diagnostics = newJObject()
      for game in games:
        for actor in game["heroes"]:
          if actor["class"].getInt != hero:
            continue
          for field, value in actor["diagnostics"]:
            if value.kind == JArray:
              if not diagnostics.hasKey(field):
                diagnostics[field] = newJArray()
                for item in value:
                  diagnostics[field].add(%0.0)
              for i, item in value.elems:
                diagnostics[field].elems[i] = %(diagnostics[field][i].getFloat +
                  item.getFloat / games.len.float)
            else:
              diagnostics[field] = %(diagnostics{field}.getFloat +
                value.getFloat / games.len.float)
      row["diagnostics"] = diagnostics
    result["heroes"].add(row)

proc poolBatches*(batches: openArray[JsonNode]): JsonNode =
  ## Keeps roster pairs separate when combining independent game batches.
  let games = newJArray()
  for batch in batches:
    require(batch.len >= 4 and batch.len mod 2 == 0, "Incomplete pooled batch")
    for index, game in batch.elems:
      require(game["job"]["pair"].getInt == index div 2,
        "Pooled batch results must follow schedule order")
      let entry = game.copy
      entry["job"]["pair"] = %(games.len div 2)
      games.add(entry)
  summarize(games)

proc adjust*(source: var string, baseline: string, summary: JsonNode,
    step: int): JsonNode =
  ## Buffs strengths below 45% and deepens weaknesses above 55%.
  require(step in 1 .. 50, "Step must be between 1 and 50 percent")
  result = newJArray()
  for hero, rule in Rules:
    let
      row = summary["heroes"][hero]
      wins = row["wins"].getInt
      decided = wins + row["losses"].getInt
    if decided == 0 or
      (wins * 100 >= decided * 45 and wins * 100 <= decided * 55):
        continue
    let
      buff = wins * 100 < decided * 45
      lever = if buff: rule.strength else: rule.weakness
      old = source.value(lever)
      base = baseline.value(lever)
      delta = max(1, int(round(old.float * step.float / 100)))
      proposed = old + (if lever.increase: delta else: -delta)
      updated = clamp(proposed, max(1, (base + 1) div 2), base * 2)
    if old == updated:
      continue
    source.replaceValue(lever, updated)
    result.add %*{"hero": HeroNames[hero],
      "kind": (if buff: "buff" else: "nerf"),
      "field": lever.field, "anchor": lever.anchor,
      "reason": lever.reason, "before": old, "after": updated,
      "win_rate": row["win_rate"]}

proc adjustOne*(source: var string, baseline: string, rounds: JsonNode,
    step: int, farthest = false): JsonNode =
  ## Changes one hero, bisecting a same-stat bracket after an overshoot.
  require(rounds.len > 0 and step in 1 .. 50, "Invalid search settings")
  result = newJArray()
  let current = rounds[rounds.len - 1]
  var
    target = -1
    role = ""
  if farthest:
    var distance = -1.0
    for hero in Priority:
      let row = current["heroes"][hero]
      if row.balanceStatus in {TooWeak, TooStrong}:
        let delta = abs(row["win_rate"].getFloat - 0.5)
        if delta > distance + 1e-12:
          target = hero
          distance = delta
    if target >= 0:
      for index in countdown(rounds.len - 2, 0):
        for change in rounds[index]["changes"]:
          if change["hero"].getStr == HeroNames[target]:
            role = change["lever"].getStr
        if role.len > 0:
          break
  elif rounds.len > 1:
    let changes = rounds[rounds.len - 2]["changes"]
    if changes.len == 1:
      for hero, name in HeroNames:
        if changes[0]["hero"].getStr == name and
          current["heroes"][hero].balanceStatus in {TooWeak, TooStrong}:
            target = hero
            role = changes[0]["lever"].getStr
  if target < 0:
    for hero in Priority:
      if current["heroes"][hero].balanceStatus in {TooWeak, TooStrong}:
        target = hero
        break
  if target < 0:
    return
  let
    row = current["heroes"][target]
    status = row.balanceStatus
  if role.len == 0:
    role = if status == TooWeak: "strength" else: "weakness"
  if target == 1 and role == "weakness" and status == TooStrong and
    source.value(Rules[target].weakness) <= 1:
      role = "fragility"
  let
    lever =
      if role == "strength": Rules[target].strength
      elif role == "fragility" and target == 1: RangerFragility
      else: Rules[target].weakness
    old = source.value(lever)
    base = baseline.value(lever)
    increasingHelps = (role == "strength") == lever.increase
    increase = (status == TooWeak) == increasingHelps
    delta = max(1, int(round(old.float * step.float / 100)))
  var
    updated = clamp(old + (if increase: delta else: -delta), 1, base * 8)
    bracket = -1
  for observation in rounds:
    let
      candidate = observation["tuning"][target][role].getInt
      context = observation["tuning"].copy
    context[target][role] = current["tuning"][target][role]
    if context != current["tuning"]:
      continue
    let otherStatus = observation["heroes"][target].balanceStatus
    if otherStatus in {TooWeak, TooStrong} and otherStatus != status and
      (bracket < 0 or abs(candidate - old) < abs(bracket - old)):
        bracket = candidate
  if bracket >= 0:
    updated = (old + bracket) div 2
    if updated == old or updated == bracket:
      return
  if updated == old:
    return
  source.replaceValue(lever, updated)
  result.add %*{"hero": HeroNames[target], "lever": role,
    "kind": (if status == TooWeak: "buff" else: "nerf"),
    "field": lever.field, "anchor": lever.anchor,
    "reason": lever.reason, "before": old, "after": updated,
    "method": (if bracket >= 0: "Walk back overshoot" else: "Expand step"),
    "bracket": bracket, "win_rate": row["win_rate"],
    "margin95": row["margin95"]}

proc htmlEscape(text: string): string =
  ## Escapes plain experiment labels before embedding them in HTML.
  text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

proc report*(directory: string, run: JsonNode, rounds: JsonNode) =
  ## Writes a static report with every batch and its exact tuning decisions.
  let
    sequential = run{"method"}.getStr in ["sequential", "farthest", "paired"]
    paired = run{"method"}.getStr == "paired"
    evaluate = run{"method"}.getStr == "evaluate"
    validationStart =
      if paired and fileExists(directory / "validation.json"):
        readJson(directory / "validation.json")["start_batch"].getInt
      else:
        9
    completed = fileExists(directory / "completion.json") or
      rounds.len == run["rounds"].getInt
  var html = """<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width"><title>GOTA balance lab</title>
<style>body{background:#111820;color:#edf1f5;font:16px system-ui;margin:40px auto;
max-width:1400px;padding:0 24px}h1{font-size:30px}h2{font-size:22px;margin-top:36px}
p{line-height:1.6;color:#b9c6d3}table{border-collapse:collapse;width:100%;margin:20px 0}
th,td{padding:10px;text-align:right;border-bottom:1px solid #324150}
th:first-child,td:first-child{text-align:left}th{color:#b9c6d3}a{color:#72c8ff}
.buff{color:#91ddaa}.nerf{color:#ffad92}.scroll{overflow-x:auto}</style>
<h1>GOTA balance lab</h1>"""
  if not completed:
    html = html.replace("<style>",
      "<meta http-equiv=\"refresh\" content=\"20\"><style>")
  html.add "<p id=\"balance-progress\">" & $rounds.len & " / " &
    $run["rounds"].getInt & " batches complete · " &
    $(rounds.len * run["games"].getInt) & " games. " &
    (if not completed:
      "Refreshes automatically every 20 seconds while running." else:
      "Experiment complete.") & "</p>"
  if fileExists(directory / "completion.json"):
    html.add "<p>" & readJson(directory / "completion.json")["reason"].getStr &
      ".</p>"
  html.add "<p>" & run["policy_label"].getStr.htmlEscape &
    " in all ten seats. " & $run["games"].getInt & " games per batch; " &
    $run["jobs"].getInt & " concurrent processes; " &
    (if evaluate: "fixed stats. Source " else:
      $run["step"].getInt & "% tuning steps. Source ") &
    run["commit"].getStr[0 .. 11] & ".</p>"
  html.add "<p>Random hero assignments with paired, mirrored side swaps. " &
    "Every hero appears in every game, half on each side. Win rate excludes " &
    "draws; ± is a 95% confidence margin clustered by roster pair. "
  if evaluate:
    html.add "Frozen evaluation, with no automatic stat changes. Seeds " &
      $run["seed"].getInt & "–" &
      $(run["seed"].getInt + run["games"].getInt - 1) &
      "; shuffled complete-role teams. All games retain replays.</p>"
  elif paired:
    html.add "Tuning batches reuse seeds 1988–2087 and shuffled complete-role " &
      "teams. Each batch requires a replay review and can change both heroes " &
      "in one role. Rejected candidates can revert to a tested base. " &
      "Validation begins at batch " & $validationStart &
      ", freezes selected stats, and uses new seed blocks starting at 11988 " &
      "with 10000 added per batch. Maximum ten batches. " &
      "Passing means the 95% interval includes 50%.</p>"
  elif sequential:
    html.add "Every batch reuses the same lineups and game seeds " &
      $run["seed"].getInt & "–" &
      $(run["seed"].getInt + run["games"].getInt - 1) &
      " (seed = " & $run["seed"].getInt & " + zero-based game number). " &
      (if run{"method"}.getStr == "farthest":
        "Each batch changes the hero farthest from 50% among those still " &
        "outside the confidence target. Delta is the absolute distance " &
        "from 50%, in percentage points. Maximum ten batches. "
      else:
        "One hero changes at a time, starting with Crossbowman, Ranger, " &
        "and Demon Hunter. ") &
      "A hero passes when its 95% interval includes 50%. " &
      "Overshoots are walked back on the same stat. These are exploratory " &
      "intervals on reused fixtures, not an independent validation.</p>"
  else:
    html.add "Each batch uses fresh seeds. The 45–55% tuning band is not " &
      "a significance test.</p>"
  html.add "<p>These results measure this policy's self-play, not the " &
    "whole league. Initial tuning: " &
    (if run{"initial_content"}.getStr.len > 0:
      run["initial_content"].getStr.htmlEscape else: "Archived engine commit") &
    ".</p>"
  if run{"draft"}.getStr == "roles":
    html.add "<p>The policy drafts one frontline, carry, mage, support, and " &
      "fighter per team. Old hero scores are removed. Seeded tie-breaks " &
      "keep roles complete and every hero at " &
      $(run["games"].getInt div 2) & " games per side.</p>"
  if fileExists(directory / "analysis-notes.json"):
    html.add "<h2>Replay findings</h2><ul>"
    for note in readJson(directory / "analysis-notes.json"):
      html.add "<li>" & note.getStr.htmlEscape & "</li>"
    html.add "</ul>"
  html.add "<p><a href=run.json>Run settings</a> · " &
    "<a href=report-data.json>All results with confidence intervals</a> · " &
    "<a href=final.patch>Last tested tuning patch</a></p>"
  if sequential and rounds.len > 0:
    var latest = rounds[rounds.len - 1]
    if paired and rounds.len >= validationStart:
      var validation: seq[JsonNode]
      for number in validationStart .. rounds.len:
        let games = newJArray()
        for index in 0 ..< run["games"].getInt:
          games.add readJson(directory /
            ("round-" & align($number, 2, '0')) / ($index & ".json"))
        validation.add(games)
      latest = poolBatches(validation)
      saveJson(directory / "validation-summary.json", latest)
    html.add "<h2>" & (if paired and rounds.len >= validationStart:
      "Validation: " & $((rounds.len - validationStart + 1) * 100) & " fresh games" else: "Latest confidence check") &
      "</h2><table><tr><th>Hero</th>" &
      "<th>Win rate ±95%</th><th>Delta (pp)</th>" &
      "<th>Interval</th><th>Decision</th></tr>"
    for row in latest["heroes"]:
      html.add "<tr><td>" & row["hero"].getStr & "</td>"
      if row["win_rate"].kind == JNull:
        html.add "<td>—</td><td>—</td><td>—</td>"
      else:
        let
          rate = row["win_rate"].getFloat * 100
          margin = row["margin95"].getFloat * 100
        html.add "<td>" & rate.formatFloat(ffDecimal, 1) & "% ± " &
          margin.formatFloat(ffDecimal, 1) & "</td><td>" &
          abs(rate - 50).formatFloat(ffDecimal, 1) & "</td><td>" &
          max(0.0, rate - margin).formatFloat(ffDecimal, 1) & "–" &
          min(100.0, rate + margin).formatFloat(ffDecimal, 1) & "%</td>"
      html.add "<td>" & row.balanceStatus.statusLabel & "</td></tr>"
    html.add "</table>"
    if paired:
      html.add "<h2>Role pairs</h2><table><tr><th>Role / pair</th>" &
        "<th>Decisive win rates</th><th>Delta (pp)</th><th>Target</th></tr>"
      for role, pair in RolePairs:
        let row = latest["heroes"][pair[0]]
        html.add "<tr><td>" & RoleNames[role] & ": " &
          HeroNames[pair[0]] & " / " & HeroNames[pair[1]] & "</td><td>"
        if row["win_rate"].kind == JNull:
          html.add "—</td><td>—"
        else:
          let rate = row["win_rate"].getFloat * 100
          html.add rate.formatFloat(ffDecimal, 1) & "% / " &
            (100 - rate).formatFloat(ffDecimal, 1) & "%</td><td>" &
            abs(rate - 50).formatFloat(ffDecimal, 1)
        html.add "</td><td>" & row.balanceStatus.statusLabel & "</td></tr>"
      html.add "</table>"
  html.add "<h2>Win rate by batch</h2><div class=scroll><table><tr><th>Hero</th>"
  for round in rounds:
    html.add "<th>" & $round["round"].getInt & "</th>"
  html.add "</tr>"
  for hero, name in HeroNames:
    html.add "<tr><td>" & name & "</td>"
    for round in rounds:
      let
        row = round["heroes"][hero]
        rate = row["win_rate"]
        color = if sequential and row.balanceStatus == Balanced:
          "buff" else: ""
      html.add "<td class=\"" & color & "\">" &
        (if rate.kind == JNull: "—" else:
          (rate.getFloat * 100).formatFloat(ffDecimal, 1) & "%") & "</td>"
    html.add "</tr>"
  html.add "</table></div>"
  if rounds.len > 1:
    let changes = newJArray()
    for index in 0 ..< rounds.len - 1:
      for change in rounds[index]["changes"]:
        var existing: JsonNode
        for candidate in changes:
          if candidate["hero"] == change["hero"] and
            candidate["field"] == change["field"] and
            candidate["anchor"] == change["anchor"]:
              existing = candidate
              break
        if existing == nil:
          changes.add(change.copy)
        else:
          existing["after"] = change["after"]
    html.add "<h2>Changes in the latest tested batch</h2>" &
      "<table><tr><th>Hero / attribute</th><th>Initial</th>" &
      "<th>Tested</th><th>Change</th></tr>"
    for change in changes:
      if paired:
        let lever = Lever(anchor: change["anchor"].getStr,
          field: change["field"].getStr)
        change["before"] = %readFile(directory / "baseline-content.nim").value(lever)
        change["after"] = %readFile(directory /
          ("round-" & align($rounds.len, 2, '0')) / "content.nim").value(lever)
        if change["before"] == change["after"]:
          continue
      let percent = 100 * (change["after"].getFloat /
        change["before"].getFloat - 1)
      html.add "<tr><td>" & change["hero"].getStr & " / " &
        change["field"].getStr & "</td><td>" & $change["before"].getInt &
        "</td><td>" & $change["after"].getInt & "</td><td>" &
        percent.formatFloat(ffDecimal, 1) & "%</td></tr>"
    html.add "</table>"
  for round in rounds:
    html.add "<h2>Batch " & $round["round"].getInt & "</h2><p>" &
      $round["red_wins"].getInt & " Red wins · " &
      $round["blue_wins"].getInt & " Blue wins · " &
      $round["draws"].getInt & " draws · " &
      round["wall_seconds"].getFloat.formatFloat(ffDecimal, 1) &
      " seconds</p><div class=scroll><table><tr><th>Hero</th><th>W/L/D</th>" &
      "<th>Win rate ±95%</th><th>Delta (pp)</th>" &
      "<th>Level</th><th>XP</th><th>Gold</th>" &
      "<th>K / D / A</th></tr>"
    for row in round["heroes"]:
      html.add "<tr><td>" & row["hero"].getStr & "</td><td>" &
        $row["wins"].getInt & "/" & $row["losses"].getInt & "/" &
        $row["draws"].getInt & "</td><td>"
      if row["win_rate"].kind == JNull:
        html.add "—"
      else:
        html.add (row["win_rate"].getFloat * 100).formatFloat(ffDecimal, 1) &
          "% ± " & (row["margin95"].getFloat * 100).formatFloat(ffDecimal, 1)
      html.add "</td>"
      html.add "<td>" &
        (if row["win_rate"].kind == JNull: "—" else:
          (abs(row["win_rate"].getFloat - 0.5) * 100).
            formatFloat(ffDecimal, 1)) & "</td>"
      for field in ["level", "xp", "gold"]:
        html.add "<td>" & row[field].getFloat.formatFloat(ffDecimal, 1)
        if row.hasKey(field & "_margin95"):
          html.add " ± " &
            row[field & "_margin95"].getFloat.formatFloat(ffDecimal, 1)
        html.add "</td>"
      html.add "<td>" & row["kills"].getFloat.formatFloat(ffDecimal, 1) &
        " / " & row["deaths"].getFloat.formatFloat(ffDecimal, 1) &
        " / " & row["assists"].getFloat.formatFloat(ffDecimal, 1) & "</td></tr>"
    html.add "</table></div>"
    if paired:
      if round.hasKey("decision"):
        html.add "<p><b>Replay review:</b> " &
          round["decision"]["diagnosis"].getStr.htmlEscape &
          " Base for next batch: " & $round["decision"]["base_batch"].getInt &
          ".</p>"
      else:
        html.add "<p>" & (if round["round"].getInt == 10:
          "Validation complete." else: "Awaiting replay review.") & "</p>"
    if paired or evaluate:
      html.add "<div class=scroll><table><tr><th>Hero diagnostics / game</th>" &
        "<th>Alive %</th><th>Hero damage</th><th>Objective damage</th>" &
        "<th>Spell damage</th><th>Spell overkill %</th>" &
        "<th>Casts passive / Q / W / R</th>" &
        "<th>Mana restored</th><th>Ally spell healing</th>" &
        "<th>Ally casts in full-HP ticks</th></tr>"
      for row in round["heroes"]:
        let d = row{"diagnostics"}
        if d.kind != JObject:
          continue
        let
          requested = d["requested"][0].getFloat + d["requested"][1].getFloat +
            d["requested"][2].getFloat + d["requested"][3].getFloat
          alive = 100 * d["aliveTicks"].getFloat /
            max(1.0, d["aliveTicks"].getFloat + d["deadTicks"].getFloat)
          overkill = 100 * (1 - d["spellDamage"].getFloat / max(1.0, requested))
        html.add "<tr><td>" & row["hero"].getStr & "</td><td>" &
          alive.formatFloat(ffDecimal, 1) & "</td>"
        for field in ["heroDamage", "objectiveDamage", "spellDamage"]:
          html.add "<td>" & d[field].getFloat.formatFloat(ffDecimal, 0) & "</td>"
        html.add "<td>" & overkill.formatFloat(ffDecimal, 1) & "</td><td>"
        for slot in 0 .. 3:
          if slot > 0:
            html.add " / "
          html.add d["casts"][slot].getFloat.formatFloat(ffDecimal, 1)
        html.add "</td>"
        for field in ["manaRestored", "allyHealing", "healthyAllyHealCasts"]:
          html.add "<td>" &
            (if d.hasKey(field): d[field].getFloat.formatFloat(ffDecimal, 1)
            else: "—") & "</td>"
        html.add "</tr>"
      html.add "</table></div>"
    html.add "<p>" &
      (if completed and round["round"].getInt == rounds.len:
        "Next-step suggestions (not applied):" else: "Changes for next batch:") &
      "</p><ul>"
    for change in round["changes"]:
      html.add "<li class=" & change["kind"].getStr & ">" &
        change["hero"].getStr & ": " & change["field"].getStr & " " &
        $change["before"].getInt & " → " & $change["after"].getInt &
        ". " & change["reason"].getStr & ". " &
        change{"method"}.getStr & ".</li>"
    html.add "</ul>"
  html.add "<p>The last tested tuning is in final-content.nim and final.patch. " &
    "The final batch's suggestions are saved separately and have not been tested.</p></html>"
  let temporary = directory / ("report-" & $getCurrentProcessId() & ".tmp")
  saveJson(directory / "report-data.json", rounds)
  writeFile(temporary, html)
  moveFile(temporary, directory / "report.html")
